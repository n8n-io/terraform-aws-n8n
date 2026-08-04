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

# ── IAM policy for S3 access ──────────────────────────────────────────────────

resource "aws_iam_policy" "s3" {
  name = "n8n-s3-access-policy-${local.cluster_name}"
  tags = local.common_tags

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
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
    }]
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
  service_account = "n8n-enterprise"
  role_arn        = aws_iam_role.s3.arn

  tags = local.common_tags

  depends_on = [aws_eks_addon.pod_identity_agent]
}
