data "aws_caller_identity" "current" {}

# ── S3 bucket ─────────────────────────────────────────────────────────────────
# All n8n pods (main, workers, webhook processors) share this bucket for binary
# storage (file attachments, etc.) so every pod reads from the same place. With
# n8n_execution_data_storage_mode = "s3" the same bucket and connection also
# hold execution data (n8n.tf).
#
# No aws_s3_bucket_lifecycle_configuration here, deliberately. The two data
# types the bucket can hold need opposite treatment:
#
#   workflows/{wf}/executions/{exec}/binary_data/{fileId}       pruned by S3
#   workflows/{wf}/executions/{exec}/execution_data/bundle.json pruned by n8n
#
# n8n delegates binary-data deletion to S3 (its S3 byte store implements no
# delete-by-prefix), so only a lifecycle rule ever reclaims those objects. n8n
# deletes execution-data bundles itself on the executions hard-delete path, and
# the n8n docs warn that a lifecycle rule can remove bundles it still
# references. A rule cannot be scoped to just one of them either: S3 lifecycle
# filters match a literal key prefix (no wildcards) and both layouts share
# workflows/{wf}/executions/{exec}/, with the distinguishing segment after two
# variable IDs; n8n tags neither object, so a tag filter is out too. Leaving the
# choice to the caller (see the S3 lifecycle section in README.md) is the only
# option that cannot silently delete live data.

resource "aws_s3_bucket" "n8n" {
  # checkov:skip=CKV_AWS_21:Versioning would defeat n8n's own pruning. n8n prunes execution data in S3 itself (the EXECUTIONS_DATA_* settings, per the n8n docs' external-storage page), and with versioning enabled those deletes only write delete markers, so the bundles persist as noncurrent versions. Nothing here reclaims them: this module ships no lifecycle configuration (header comment above), and the same docs warn against a lifecycle rule over execution data because it can delete objects n8n still references. Enabling versioning by default would silently turn "pruned" execution data into "retained indefinitely", which inverts what an operator setting a retention window asked for. A caller who wants versioning can add aws_s3_bucket_versioning plus a noncurrent-version expiry rule scoped to their own retention policy.
  # checkov:skip=CKV_AWS_18:Server access logging needs a second bucket to receive the logs, which this single-bucket module does not create, and that log bucket would fail this same check unless it logged to a third one. Recording data-plane access to this bucket is CloudTrail S3 data events, an account-level setting outside a workload module's scope.
  # checkov:skip=CKV_AWS_144:Cross-region replication needs a destination bucket in a second region and a second provider alias. This module deploys a single-region stack (one VPC, one EKS cluster, one database), so replicating this bucket alone would not produce anything recoverable elsewhere; multi-region DR is a property of the caller's topology, not of this bucket.
  # checkov:skip=CKV2_AWS_61:No lifecycle configuration, by design and for the reasons documented in the header comment above. Leaving object expiry to the caller is the only option that cannot silently delete data n8n still references.
  # checkov:skip=CKV2_AWS_62:Event notifications exist to drive downstream consumers, and nothing in this module consumes S3 events; n8n reads and writes the bucket directly through its own S3 client. An aws_s3_bucket_notification here would have no destination to point at.
  bucket = local.s3_bucket_name

  # Allow terraform destroy to drop the bucket even when n8n has written
  # binary attachments — without this, destroy fails with BucketNotEmpty.
  force_destroy = true

  tags = merge(local.common_tags, { Name = local.s3_bucket_name })
}

resource "aws_s3_bucket_public_access_block" "n8n" {
  bucket = aws_s3_bucket.n8n.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# ── Bucket encryption ─────────────────────────────────────────────────────────
# S3 encrypts every object at rest unconditionally (SSE-S3 with S3-managed
# keys has been the floor for all buckets since January 2023), so this section
# decides *which* key, not whether. A bucket default of SSE-KMS with a
# module-managed CMK matches what the module already does for RDS storage,
# Performance Insights, EKS Secrets and every log group, and it clears
# CKV_AWS_145. Gated behind var.s3_kms_encryption_enabled for callers who would
# rather not add KMS to this path.
#
# bucket_key_enabled = true turns on S3 Bucket Keys, which derive a
# bucket-level data key instead of calling KMS once per object. n8n writes one
# object per binary attachment and, with n8n_execution_data_storage_mode =
# "s3", one per execution, so without this the KMS request bill would scale
# with execution volume.

resource "aws_kms_key" "s3" {
  count = var.s3_kms_encryption_enabled ? 1 : 0

  description             = "CMK for module-managed S3 bucket ${local.s3_bucket_name} (n8n binary and execution data)"
  enable_key_rotation     = true
  deletion_window_in_days = 7

  # Root access only. The n8n pod role reaches the key through its own IAM
  # policy below, which works because this statement delegates key access to
  # account IAM. Same shape as aws_kms_key.db in database.tf.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccess"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
    ]
  })

  tags = merge(local.common_tags, { Name = local.s3_bucket_name })
}

resource "aws_kms_alias" "s3" {
  count = var.s3_kms_encryption_enabled ? 1 : 0

  name_prefix   = "alias/${local.s3_bucket_name}-"
  target_key_id = aws_kms_key.s3[0].key_id
}

resource "aws_s3_bucket_server_side_encryption_configuration" "n8n" {
  count = var.s3_kms_encryption_enabled ? 1 : 0

  bucket = aws_s3_bucket.n8n.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.s3[0].arn
    }

    bucket_key_enabled = true
  }
}

# ── IAM policy for S3 access ──────────────────────────────────────────────────

resource "aws_iam_policy" "s3" {
  name = "n8n-s3-access-policy-${local.cluster_name}"
  tags = local.common_tags

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [{
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
        ]
        Resource = [
          aws_s3_bucket.n8n.arn,
          "${aws_s3_bucket.n8n.arn}/*",
        ]
      }],
      # SSE-KMS is not transparent to the caller the way SSE-S3 is: against a
      # bucket whose default is aws:kms, S3 rejects GetObject without
      # kms:Decrypt and PutObject without kms:GenerateDataKey. Without this
      # statement every binary-data read and write fails with AccessDenied, so
      # it is gated on the same variable as the bucket default itself.
      var.s3_kms_encryption_enabled ? [{
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
        ]
        Resource = [aws_kms_key.s3[0].arn]
      }] : [],
    )
  })
}

# ── IAM role for S3 (Pod Identity) ────────────────────────────────────────────
# The n8n Kubernetes service account (n8n-enterprise) assumes this role via
# EKS Pod Identity to access S3 without any hard-coded credentials in the pod.

resource "aws_iam_role" "s3" {
  name = "n8n-s3-role-${local.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "s3" {
  role       = aws_iam_role.s3.name
  policy_arn = aws_iam_policy.s3.arn
}

resource "aws_eks_pod_identity_association" "s3" {
  cluster_name    = aws_eks_cluster.n8n.name
  namespace       = var.namespace
  service_account = local.n8n_service_account_name
  role_arn        = aws_iam_role.s3.arn

  tags = local.common_tags

  depends_on = [aws_eks_addon.pod_identity_agent]
}
