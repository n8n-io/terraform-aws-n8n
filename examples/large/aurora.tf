# ── Aurora PostgreSQL (I/O-Optimized) ─────────────────────────────────────────
# Aurora I/O-Optimized removes the IOPS ceiling that limits RDS gp3 at high
# write throughput. Benchmarked at 14,000–15,000 TPS sustained without
# degradation at 960+ req/s — RDS gp3 saturated at ~600 req/s under the same
# load.
#
# Two instances (writer + reader) provide:
#   - Automatic failover to the reader if the writer becomes unavailable.
#   - Read replica offloads reporting / analytics queries from the writer.
#
# The module-managed RDS instance is skipped (db_host is set in main.tf).

resource "random_password" "aurora" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_db_subnet_group" "aurora" {
  name       = "${var.cluster_name}-aurora"
  subnet_ids = module.vpc.private_subnets

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-aurora-subnet-group" })
}

resource "aws_security_group" "aurora" {
  name        = "${var.cluster_name}-aurora-sg"
  description = "Allow PostgreSQL from within the VPC"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "PostgreSQL from VPC"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [module.vpc.vpc_cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-aurora-sg" })
}

# ── Customer Managed KMS key ──────────────────────────────────────────────────
# A single CMK encrypts the Aurora cluster storage (CKV_AWS_327), the writer +
# reader Performance Insights data (CKV_AWS_354), and the postgresql CloudWatch
# Log Group (CKV_AWS_158) — replacing the AWS-managed `aws/rds` default. Annual
# rotation is on; deletion_window_in_days = 7 (AWS minimum) so destroys recycle
# the key as fast as AWS permits.
#
# The key policy explicitly grants the CloudWatch Logs service principal the
# encrypt/decrypt actions needed for the log group, scoped via the
# kms:EncryptionContext:aws:logs:arn condition so the key cannot be used to
# read any other log group's data. RDS uses the key via IAM-mediated access
# (covered by the EnableRootAccess statement plus the caller's IAM permissions).
#
# The alias uses name_prefix so apply→destroy→apply cycles do not collide on
# the alias name during the 7-day key deletion window. See README.md →
# "KMS key after terraform destroy".

data "aws_caller_identity" "current" {}

resource "aws_kms_key" "aurora" {
  description             = "CMK for Aurora cluster ${var.cluster_name} (storage + Performance Insights + postgresql logs)"
  enable_key_rotation     = true
  deletion_window_in_days = 7

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
      {
        Sid       = "AllowCloudWatchLogsEncrypt"
        Effect    = "Allow"
        Principal = { Service = "logs.${var.aws_region}.amazonaws.com" }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/rds/cluster/${var.cluster_name}-aurora/postgresql"
          }
        }
      },
    ]
  })

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-aurora" })
}

resource "aws_kms_alias" "aurora" {
  name_prefix   = "alias/${var.cluster_name}-aurora-"
  target_key_id = aws_kms_key.aurora.key_id
}

resource "aws_rds_cluster" "n8n" {
  # checkov:skip=CKV_AWS_139:Deletion protection is intentionally disabled in this reference example so `terraform destroy` works cleanly during evaluation and load testing. Flip to `true` for production use. See README.md → "Production considerations".
  cluster_identifier = "${var.cluster_name}-aurora"
  engine             = "aurora-postgresql"
  engine_version     = "16.4"

  database_name   = "n8n_enterprise"
  master_username = "n8n"
  master_password = random_password.aurora.result

  db_subnet_group_name   = aws_db_subnet_group.aurora.name
  vpc_security_group_ids = [aws_security_group.aurora.id]

  # I/O-Optimized storage: no per-I/O charges, predictable cost at high write
  # throughput. Breaks even vs standard Aurora at ~25% I/O utilization.
  storage_type = "aurora-iopt1"
  kms_key_id   = aws_kms_key.aurora.arn

  # Hardening defaults. Aurora leaves storage_encrypted = false unless set
  # explicitly (CKV_AWS_96 — "Ensure all data stored in Aurora is securely
  # encrypted at rest"), which is Registry table-stakes for any new RDS-family
  # resource. IAM database authentication (CKV_AWS_162) and postgresql log
  # export to CloudWatch (CKV_AWS_324) round out the baseline so a new resource
  # does not regress curated findings. copy_tags_to_snapshot (CKV_AWS_313)
  # propagates the existing tag set onto automated + manual snapshots.
  # kms_key_id below points at the CMK declared above: it clears CKV_AWS_327
  # (Aurora storage CMK) and combines with the per-instance
  # performance_insights_kms_key_id and the log group's kms_key_id to clear
  # CKV_AWS_354 (PI CMK) and CKV_AWS_158 (log-group CMK). CKV_AWS_139
  # (deletion protection) is intentionally skipped via the checkov:skip
  # annotation above so `terraform destroy` works cleanly during evaluation.
  storage_encrypted                   = true
  iam_database_authentication_enabled = true
  enabled_cloudwatch_logs_exports     = ["postgresql"]

  backup_retention_period = 7
  skip_final_snapshot     = true
  deletion_protection     = false
  copy_tags_to_snapshot   = true

  # Ensure the log group exists (with our retention) before RDS would otherwise
  # auto-create it at "Never expire".
  depends_on = [aws_cloudwatch_log_group.aurora_postgresql]

  lifecycle {
    # auto_minor_version_upgrade = true on the instances lets AWS bump the
    # engine version during the maintenance window (clears CKV_AWS_226). Ignore
    # the resulting drift here so the next `terraform apply` doesn't try to
    # downgrade back to the originally-pinned engine_version — Aurora does
    # not support minor-version downgrades and the apply would fail.
    ignore_changes = [engine_version]
  }

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-aurora" })
}

# CloudWatch Log Group for the postgresql log export. Created explicitly so we
# own retention (CKV_AWS_338); without this resource, RDS auto-creates the group
# with "Never expire" retention. Encrypted with the Aurora CMK declared above
# (CKV_AWS_158); the key policy includes a CloudWatch Logs service-principal
# statement scoped to this exact log-group ARN via the encryption-context
# condition.
resource "aws_cloudwatch_log_group" "aurora_postgresql" {
  name              = "/aws/rds/cluster/${var.cluster_name}-aurora/postgresql"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.aurora.arn

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-aurora-postgresql-logs" })
}

# ── Enhanced Monitoring IAM role ──────────────────────────────────────────────
# RDS Enhanced Monitoring writes OS-level metrics (CPU steal, swap, per-process
# activity, IOPS depth) to CloudWatch Logs at a configurable cadence. 60-second
# granularity is the AWS-recommended default for production and the cheapest
# billable interval; sub-60s costs scale with CloudWatch Logs ingestion volume.
# Shared by writer + reader.

resource "aws_iam_role" "rds_enhanced_monitoring" {
  name = "${var.cluster_name}-rds-monitoring"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-rds-monitoring" })
}

resource "aws_iam_role_policy_attachment" "rds_enhanced_monitoring" {
  role       = aws_iam_role.rds_enhanced_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "aws_rds_cluster_instance" "writer" {
  identifier         = "${var.cluster_name}-writer"
  cluster_identifier = aws_rds_cluster.n8n.id
  instance_class     = var.aurora_instance_class
  engine             = aws_rds_cluster.n8n.engine
  engine_version     = aws_rds_cluster.n8n.engine_version

  # CKV_AWS_226: pick up Aurora-PostgreSQL minor releases during the maintenance
  # window. See the cluster's lifecycle.ignore_changes above — it also covers
  # the instances, since AWS upgrades them in lockstep with the cluster.
  auto_minor_version_upgrade = true

  # CKV_AWS_353: Performance Insights with the default 7-day retention window
  # is included in the AWS free tier. Pinning the retention period explicitly
  # prevents silent cost regression if AWS changes the default. CKV_AWS_354 (PI
  # data encrypted with a customer-managed KMS key) is intentionally deferred
  # — tracked alongside the cluster-level CKV_AWS_327 CMK follow-up.
  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  performance_insights_kms_key_id       = aws_kms_key.aurora.arn

  # CKV_AWS_118: RDS Enhanced Monitoring at the 60-second AWS-recommended
  # cadence. See the aws_iam_role.rds_enhanced_monitoring resource above.
  monitoring_interval = 60
  monitoring_role_arn = aws_iam_role.rds_enhanced_monitoring.arn

  lifecycle {
    ignore_changes = [engine_version]
  }

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-writer" })
}

resource "aws_rds_cluster_instance" "reader" {
  identifier         = "${var.cluster_name}-reader"
  cluster_identifier = aws_rds_cluster.n8n.id
  instance_class     = var.aurora_instance_class
  engine             = aws_rds_cluster.n8n.engine
  engine_version     = aws_rds_cluster.n8n.engine_version

  # CKV_AWS_226: pick up Aurora-PostgreSQL minor releases during the maintenance
  # window. See the cluster's lifecycle.ignore_changes above — it also covers
  # the instances, since AWS upgrades them in lockstep with the cluster.
  auto_minor_version_upgrade = true

  # CKV_AWS_353: Performance Insights with the default 7-day retention window
  # is included in the AWS free tier. Pinning the retention period explicitly
  # prevents silent cost regression if AWS changes the default. CKV_AWS_354 (PI
  # data encrypted with a customer-managed KMS key) is intentionally deferred
  # — tracked alongside the cluster-level CKV_AWS_327 CMK follow-up.
  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  performance_insights_kms_key_id       = aws_kms_key.aurora.arn

  # CKV_AWS_118: RDS Enhanced Monitoring at the 60-second AWS-recommended
  # cadence. See the aws_iam_role.rds_enhanced_monitoring resource above.
  monitoring_interval = 60
  monitoring_role_arn = aws_iam_role.rds_enhanced_monitoring.arn

  lifecycle {
    ignore_changes = [engine_version]
  }

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-reader" })
}
