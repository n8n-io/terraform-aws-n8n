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

# Skipped when create_s3_bucket = false: the caller provides an existing
# bucket (existing_s3_bucket_name) and owns its lifecycle, public-access
# block, and encryption configuration. Only the IAM policy and Pod Identity
# role below are attached to that bucket in that mode.
resource "aws_s3_bucket" "n8n" {
  # checkov:skip=CKV_AWS_21:Versioning would defeat n8n's own pruning. n8n prunes execution data in S3 itself (the EXECUTIONS_DATA_* settings, per the n8n docs' external-storage page), and with versioning enabled those deletes only write delete markers, so the bundles persist as noncurrent versions. Nothing here reclaims them: this module ships no lifecycle configuration (header comment above), and the same docs warn against a lifecycle rule over execution data because it can delete objects n8n still references. Enabling versioning by default would silently turn "pruned" execution data into "retained indefinitely", which inverts what an operator setting a retention window asked for. A caller who wants versioning can add aws_s3_bucket_versioning plus a noncurrent-version expiry rule scoped to their own retention policy.
  # checkov:skip=CKV_AWS_18:Server access logging needs a second bucket to receive the logs, which this single-bucket module does not create, and that log bucket would fail this same check unless it logged to a third one. Recording data-plane access to this bucket is CloudTrail S3 data events, an account-level setting outside a workload module's scope.
  # checkov:skip=CKV_AWS_144:Cross-region replication needs a destination bucket in a second region and a second provider alias. This module deploys a single-region stack (one VPC, one EKS cluster, one database), so replicating this bucket alone would not produce anything recoverable elsewhere; multi-region DR is a property of the caller's topology, not of this bucket.
  # checkov:skip=CKV2_AWS_61:No lifecycle configuration, by design and for the reasons documented in the header comment above. Leaving object expiry to the caller is the only option that cannot silently delete data n8n still references.
  # checkov:skip=CKV2_AWS_62:Event notifications exist to drive downstream consumers, and nothing in this module consumes S3 events; n8n reads and writes the bucket directly through its own S3 client. An aws_s3_bucket_notification here would have no destination to point at.
  # checkov:skip=CKV2_AWS_6:This bucket IS fronted by a public-access block, aws_s3_bucket_public_access_block.n8n below. Checkov does not always resolve that attachment through a caller module's own `module "n8n" { source = ... }` invocation once this resource carries a `count` tied to create_s3_bucket, the same tooling limitation already documented on aws_security_group.rds in database.tf and on CKV2_AWS_30 there. Verified live: the public-access block exists and is attached whenever create_s3_bucket = true creates this bucket at all.
  # checkov:skip=CKV_AWS_145:This bucket IS encrypted with a Customer Managed KMS Key by default, aws_s3_bucket_server_side_encryption_configuration.n8n below, gated on the same var.create_s3_bucket count and subject to the same nested-module resolution limitation as CKV2_AWS_6 above. s3_kms_encryption_enabled defaults to true precisely to satisfy this check; see that variable and the bucket-encryption section below for the mechanism.
  count = var.create_s3_bucket ? 1 : 0

  bucket = local.s3_bucket_name_generated

  # Allow terraform destroy to drop the bucket even when n8n has written
  # binary attachments — without this, destroy fails with BucketNotEmpty.
  force_destroy = true

  tags = merge(local.common_tags, { Name = local.s3_bucket_name_generated })
}

resource "aws_s3_bucket_public_access_block" "n8n" {
  count = var.create_s3_bucket ? 1 : 0

  bucket = aws_s3_bucket.n8n[0].id

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
# rather not add KMS to this path. Set s3_kms_key_arn to use an existing
# Customer Managed Key instead of the CMK this module would otherwise create
# for itself; see local.s3_kms_key_arn (locals.tf).
#
# bucket_key_enabled = true turns on S3 Bucket Keys, which derive a
# bucket-level data key instead of calling KMS once per object. n8n writes one
# object per binary attachment and, with n8n_execution_data_storage_mode =
# "s3", one per execution, so without this the KMS request bill would scale
# with execution volume. Only meaningful under SSE-KMS; AES256 ignores it.
#
# Skipped when create_s3_bucket = false, along with the public-access block
# above: attaching an encryption configuration to a bucket the caller owns is
# the caller's decision, not the module's. s3_kms_key_arn still matters on that
# path, though: see the IAM policy below.

resource "aws_kms_key" "s3" {
  count = var.create_s3_bucket && var.s3_kms_encryption_enabled && var.create_s3_kms_key ? 1 : 0

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
  count = var.create_s3_bucket && var.s3_kms_encryption_enabled && var.create_s3_kms_key ? 1 : 0

  name_prefix   = "alias/${local.s3_bucket_name}-"
  target_key_id = aws_kms_key.s3[0].key_id
}

resource "aws_s3_bucket_server_side_encryption_configuration" "n8n" {
  count = var.create_s3_bucket ? 1 : 0

  bucket = aws_s3_bucket.n8n[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.s3_kms_encryption_enabled ? "aws:kms" : "AES256"
      kms_master_key_id = var.s3_kms_encryption_enabled ? local.s3_kms_key_arn : null
    }

    bucket_key_enabled = var.s3_kms_encryption_enabled
  }

  # On upgrades, install kms:Decrypt / kms:GenerateDataKey on the existing pod
  # role before the bucket starts encrypting new writes with this key. Without
  # this edge Terraform may update the managed policy and bucket in parallel,
  # briefly breaking binary and execution-data reads/writes.
  depends_on = [aws_iam_role_policy_attachment.s3]
}

# ── IAM policy for S3 access ──────────────────────────────────────────────────
# Resource ARNs come from local.s3_bucket_arn (locals.tf) rather than
# aws_s3_bucket.n8n directly, so this policy targets the right bucket whether
# the module created it or the caller supplied an existing one.
#
# The second statement is what makes SSE-KMS usable. Under SSE-S3 the bucket
# key is invisible to callers and s3:* alone is enough, but under SSE-KMS S3
# performs the crypto as the *requesting principal*: a GetObject needs
# kms:Decrypt and a PutObject needs kms:GenerateDataKey, both held by the pod's
# role, or every binary-data read and write comes back AccessDenied. Granting
# the bucket without the key is the failure mode this statement exists to
# prevent: the bucket looks correctly configured and n8n still cannot use it.
#
# Present whenever s3_kms_key_arn is set, on both the module-managed and the
# caller-supplied bucket path. That is the whole reason the input stays
# meaningful when create_s3_bucket = false: the module does not encrypt someone
# else's bucket, but it does have to tell the pod role which key that bucket is
# already encrypted with.
#
# kms:DescribeKey is included because the S3 client resolves key metadata before
# uploading. Scoped to the one key ARN rather than "*" so the role cannot touch
# any other key in the account.

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
          local.s3_bucket_arn,
          "${local.s3_bucket_arn}/*",
        ]
      }],
      # SSE-KMS is not transparent to the caller the way SSE-S3 is: against a
      # bucket whose default is aws:kms, S3 rejects GetObject without
      # kms:Decrypt and PutObject without kms:GenerateDataKey. Without this
      # statement every binary-data read and write fails with AccessDenied.
      # Present whenever local.s3_kms_key_arn resolves to a key, on both the
      # module-managed and the caller-supplied bucket path (see locals.tf).
      local.s3_kms_key_arn == null ? [] : [{
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey",
        ]
        Resource = [local.s3_kms_key_arn]
      }],
    )
  })
}

# ── IAM role for S3 (Pod Identity) ────────────────────────────────────────────
# The n8n Kubernetes service account (n8n-enterprise) assumes this role via
# EKS Pod Identity to access S3 without any hard-coded credentials in the pod.
#
# This is also the role the External Secrets AWS grant below attaches to, since
# EKS binds exactly one role to a given {cluster, namespace, service account}
# tuple: a second association for the same tuple is not the way to add a
# second grant, a second managed policy on this role is. The name keeps its
# n8n-s3-role- prefix for compatibility (renaming it would recreate the role
# for every existing deployment); read it as "the n8n pod's AWS grants", not
# "S3 only", once n8n_external_secrets_aws_enabled = true.

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

  permissions_boundary = var.iam_permissions_boundary_arn

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "s3" {
  role       = aws_iam_role.s3.name
  policy_arn = aws_iam_policy.s3.arn
}

resource "aws_eks_pod_identity_association" "s3" {
  cluster_name    = local.eks_cluster_name
  namespace       = var.namespace
  service_account = local.n8n_service_account_name
  role_arn        = aws_iam_role.s3.arn

  tags = local.common_tags

  depends_on = [aws_eks_addon.pod_identity_agent]
}

# ── IAM policy for External Secrets (AWS Secrets Manager) ────────────────────
# Opt-in: see var.n8n_external_secrets_aws_enabled. Names, not ARNs, come in
# through var.n8n_external_secrets_aws_secret_names and are resolved here so the
# GetSecretValue statement below can be scoped to concrete ARNs rather than a
# wildcard, which is what makes "this role cannot read secret X" a provable
# claim instead of a hope.
data "aws_secretsmanager_secret" "external_secrets" {
  for_each = var.n8n_external_secrets_aws_enabled ? toset(var.n8n_external_secrets_aws_secret_names) : []

  name = each.value
}

resource "aws_iam_policy" "external_secrets" {
  count = var.n8n_external_secrets_aws_enabled ? 1 : 0

  name = "n8n-external-secrets-policy-${local.cluster_name}"
  tags = local.common_tags

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # AWS defines no resource-level permissions on either action: a policy
        # that tries to scope them to specific ARNs is accepted by IAM and
        # silently returns an empty vault at runtime instead of failing, so
        # both stay "*" and GetSecretValue below is the real gate.
        Effect   = "Allow"
        Action   = ["secretsmanager:ListSecrets", "secretsmanager:BatchGetSecretValue"]
        Resource = "*"
      },
      {
        # batchGetSecretValue still requires GetSecretValue on each entry in
        # its SecretIdList in addition to BatchGetSecretValue, so this is the
        # statement that actually decides what n8n can read.
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [for s in data.aws_secretsmanager_secret.external_secrets : s.arn]
      },
      {
        # Without this, an allow-listed secret encrypted with a customer
        # managed KMS key is unreadable: Secrets Manager decrypts through the
        # *caller's* credentials, so GetSecretValue on such a secret fails
        # with AccessDenied on kms:Decrypt no matter how the secret's own
        # resource policy reads. Secrets left on the AWS-managed
        # aws/secretsmanager key never needed it, which is why the gap only
        # shows up once someone points n8n at a properly key-managed secret.
        #
        # Scoped by condition rather than by resource. Deriving key ARNs from
        # data.aws_secretsmanager_secret.external_secrets is not reliable:
        # DescribeSecret returns kms_key_id as whatever was set at creation
        # (a key ID, an alias, an alias ARN, or nothing at all for the
        # AWS-managed key), and only one of those four spellings is usable as
        # an IAM Resource. kms:ViaService is exact where an ARN list would be
        # a guess: it permits Decrypt only when Secrets Manager itself is the
        # caller, in this region.
        #
        # kms:ViaService alone is necessary but not sufficient: it still lets
        # this role decrypt through Secrets Manager for ANY secret's key, not
        # only the allow-listed ones, if some other policy or the secret's
        # own resource policy ever grants it GetSecretValue on a secret this
        # allow list never named. kms:EncryptionContext:SecretARN closes
        # that: Secrets Manager sets this encryption context to the secret's
        # own ARN on every Decrypt it proxies, so pinning it to the resolved
        # allow-listed ARNs makes KMS itself enforce the same boundary
        # GetSecretValue's Resource list does above, rather than trusting
        # that no other policy ever grants a wider GetSecretValue.
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService"                  = "secretsmanager.${local.aws_region}.amazonaws.com"
            "kms:EncryptionContext:SecretARN" = [for s in data.aws_secretsmanager_secret.external_secrets : s.arn]
          }
        }
      },
      {
        # This module keeps its own secrets (DB password, Redis AUTH token,
        # N8N_ENCRYPTION_KEY, task runner token, licence key) in Kubernetes
        # Secrets, never in AWS Secrets Manager, so nothing in this account
        # carries the ManagedBy = terraform tag from local.common_tags today
        # and this statement matches zero resources. It is written anyway,
        # unconditionally, because an explicit Deny costs nothing to hold in
        # reserve and beats every Allow, including a wildcard some other
        # policy attaches to this role later: if the module ever gains an
        # AWS-Secrets-Manager-backed credential of its own, this statement is
        # what keeps a workflow builder's vault connection from reading it,
        # with no change required here.
        Effect   = "Deny"
        Action   = ["secretsmanager:GetSecretValue", "secretsmanager:BatchGetSecretValue"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/ManagedBy" = "terraform"
          }
        }
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "external_secrets" {
  count = var.n8n_external_secrets_aws_enabled ? 1 : 0

  role       = aws_iam_role.s3.name
  policy_arn = aws_iam_policy.external_secrets[0].arn
}

# Best-effort plan-time echo of the Deny statement above. ListSecrets' own
# Filters have no way to match an exact tag key/value pair together (tag-key
# and tag-value each match independently, across any of a secret's tags), so
# this can both under- and over-match in a busy account; it exists as an early
# warning, not the boundary itself. The Deny statement is what actually holds
# at runtime regardless of what this data source returns.
data "aws_secretsmanager_secrets" "module_managed" {
  count = var.n8n_external_secrets_aws_enabled ? 1 : 0

  filter {
    name   = "tag-key"
    values = ["ManagedBy"]
  }

  filter {
    name   = "tag-value"
    values = ["terraform"]
  }
}

check "external_secrets_allow_list_excludes_module_managed_secrets" {
  assert {
    condition = var.n8n_external_secrets_aws_enabled ? length(setintersection(
      toset([for s in data.aws_secretsmanager_secret.external_secrets : s.arn]),
      toset(try(data.aws_secretsmanager_secrets.module_managed[0].arns, [])),
    )) == 0 : true
    error_message = join("", [
      "n8n_external_secrets_aws_secret_names includes a secret tagged ManagedBy = terraform, the same tag this ",
      "module applies to everything it creates. This module keeps its own credentials in Kubernetes Secrets, not ",
      "AWS Secrets Manager, so this most likely means an unrelated Terraform-managed secret shares that tag value ",
      "in this account/region, or a secret the module manages elsewhere was pointed at n8n's vault by name. Either ",
      "way, confirm every name in this list is meant to be readable by any n8n user who can create a credential, ",
      "since that is what a vault connection using this role grants.",
    ])
  }
}

# ── BYO-bucket diagnostic checks ──────────────────────────────────────────────
# Same "X is ignored when Y" shape as the external-database checks in
# database.tf: each of these plans and applies cleanly while quietly
# discarding what the caller asked for, so they are worth surfacing even
# though neither is a hard error.

check "existing_s3_bucket_name_requires_create_s3_bucket_false" {
  assert {
    condition = var.create_s3_bucket ? var.existing_s3_bucket_name == null : true
    error_message = join("", [
      "existing_s3_bucket_name is set while create_s3_bucket = true, so it is ignored: the module creates its ",
      "own S3 bucket and points n8n at that, not at the bucket you supplied. Set create_s3_bucket = false to use ",
      "an existing bucket.",
    ])
  }
}

# No check for s3_kms_key_arn alongside create_s3_bucket = false. That
# combination used to be an "X is ignored when Y" case and was flagged as one,
# but it no longer is: the input now also grants the pod role kms:Decrypt and
# kms:GenerateDataKey on that key (see aws_iam_policy.s3 above), which is
# exactly what a caller pointing n8n at their own SSE-KMS bucket needs. Warning
# on it would now steer people away from the one setting that makes their
# deployment work.
#
# The inverse (an SSE-KMS bucket supplied with no s3_kms_key_arn) is the
# remaining footgun, and it is not checkable: the module would have to read the
# bucket's encryption configuration, which means a data source, an AWS call at
# plan time, and a hard failure for anyone whose credentials cannot read it.
# Documented on the variable and in README.md instead.
#
# For the same reason there is no data.aws_kms_key describing s3_kms_key_arn,
# even though database.tf has exactly that for db_kms_key_arn. The difference is
# who needs the key: creating an encrypted RDS instance requires the caller to
# hold kms:DescribeKey and kms:CreateGrant on the key already, so describing it
# at plan time asks for nothing new. Here the key is only ever a string the
# module writes into an IAM policy and, on the create_s3_bucket = true path, into
# a bucket encryption configuration. Nothing in that requires the Terraform
# caller to have any permission on the key at all: the principal that needs
# kms:Decrypt and kms:GenerateDataKey is the n8n pod role, at runtime. Adding a
# plan-time describe would invent an IAM requirement the apply does not have.
#
# What is checkable without an API call is the region, below.

# KMS keys are regional, and S3 rejects a bucket encryption configuration naming
# a key from another region. On the create_s3_bucket = false path nothing fails
# at apply time at all: the IAM policy is written happily, and every object read
# and write then fails with AccessDenied at runtime, which is the worst place to
# discover it. Asserted from the ARN string, so it costs nothing and holds on
# both paths. Account is deliberately not asserted: a CMK shared from a central
# security account is a legitimate setup, and cross-account SSE-KMS works as long
# as the key policy allows the pod role.

# The "X is ignored when Y" half of create_s3_kms_key's contract, matching
# database.tf's db_kms_key_arn check. With the module creating its own bucket
# and its own CMK, local.s3_kms_key_arn (locals.tf) resolves to that CMK and
# this input is read nowhere at all, so a caller who set it and expected their
# key to be used gets told rather than left to find out from the bucket's
# encryption configuration. Warn rather than fail: staging the ARN in tfvars
# ahead of flipping create_s3_kms_key is a legitimate thing to do, and on the
# create_s3_bucket = false path the ARN is meaningful on its own (it is what
# grants the pod role kms:Decrypt on your bucket's key), so this deliberately
# does not fire there.
check "s3_kms_key_arn_requires_create_s3_kms_key_false" {
  assert {
    condition = (var.s3_kms_key_arn != null && var.create_s3_bucket && var.s3_kms_encryption_enabled) ? (
      !var.create_s3_kms_key
    ) : true
    error_message = join("", [
      "s3_kms_key_arn is set but ignored: with create_s3_kms_key left at its default the module mints its own ",
      "Customer Managed Key and encrypts the bucket it creates with that, never reading this ARN. Set ",
      "create_s3_kms_key = false to encrypt with the key you supplied instead.",
    ])
  }
}

check "s3_kms_key_arn_region_matches" {
  assert {
    condition = var.s3_kms_key_arn == null ? true : split(":", var.s3_kms_key_arn)[3] == local.aws_region
    error_message = join("", [
      "s3_kms_key_arn is in ${var.s3_kms_key_arn == null ? "" : split(":", var.s3_kms_key_arn)[3]}, but this ",
      "module deploys into ${local.aws_region}. KMS keys are regional: S3 cannot encrypt objects in a bucket in ",
      "one region with a key from another. With create_s3_bucket = true the apply fails setting the bucket's ",
      "encryption configuration; with create_s3_bucket = false it succeeds, and every n8n binary-data read and ",
      "write then fails with AccessDenied at runtime instead. Supply a key in ${local.aws_region}, or a ",
      "multi-Region replica's ARN in that region.",
    ])
  }
}
