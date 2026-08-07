resource "random_password" "db_password" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# ── Customer Managed KMS key (optional) ───────────────────────────────────────
# A single CMK encrypts the RDS instance storage (CKV_AWS_16), Performance
# Insights data (CKV_AWS_354), and the postgresql CloudWatch log group
# (CKV_AWS_158) — replacing the AWS-managed `aws/rds` default. Mirrors the
# Aurora CMK pattern established for examples/large/ (PR #13).
#
# Gated on var.db_storage_encrypted so callers with existing unencrypted RDS
# deployments can opt out and avoid the RDS replacement that enabling storage
# encryption triggers (AWS does not support flipping storage_encrypted in
# place — see README.md → "Upgrading from a pre-CMK apply").
#
# enable_key_rotation     = true → annual rotation, no operator action.
# deletion_window_in_days = 7    → AWS minimum so `terraform destroy` recycles
#                                  the key as fast as AWS permits.
#
# The key policy grants the regional CloudWatch Logs service principal the
# Encrypt/Decrypt actions needed for the log group, scoped via
# kms:EncryptionContext:aws:logs:arn to this instance's postgresql log group
# only — the key cannot be used to read any other log group's data. RDS uses
# the key via IAM-mediated access, covered by the EnableRootAccess statement
# plus the caller's IAM permissions.
#
# aws_kms_alias.db uses name_prefix so apply→destroy→apply cycles do not
# collide on the alias name during the 7-day key deletion window. The
# auto-generated AWS suffix makes the alias unique per apply.

locals {
  # Derived ARN used by aws_db_instance.n8n (storage + PI) and
  # aws_cloudwatch_log_group.rds_postgresql. null when the CMK is not created
  # so each consumer falls back to the AWS provider default (unencrypted /
  # AWS-managed key) without a plan diff.
  db_kms_key_arn = try(aws_kms_key.db[0].arn, null)
}

resource "aws_kms_key" "db" {
  count = var.create_database && var.db_storage_encrypted ? 1 : 0

  description             = "CMK for module-managed RDS ${local.cluster_name} (storage + Performance Insights + postgresql logs)"
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
        Principal = { Service = "logs.${local.aws_region}.amazonaws.com" }
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
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${local.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/rds/instance/n8n-postgres-${local.cluster_name}/postgresql"
          }
        }
      },
    ]
  })

  tags = merge(local.common_tags, { Name = "n8n-rds-${local.cluster_name}" })
}

resource "aws_kms_alias" "db" {
  count = var.create_database && var.db_storage_encrypted ? 1 : 0

  name_prefix   = "alias/n8n-rds-${local.cluster_name}-"
  target_key_id = aws_kms_key.db[0].key_id
}

# ── Security group ────────────────────────────────────────────────────────────
# Allow inbound PostgreSQL only from within the VPC — nodes and pods can reach
# the database; nothing from the public internet can.

resource "aws_security_group" "rds" {
  # checkov:skip=CKV_AWS_382:Egress-all is intentional. RDS does not originate arbitrary outbound traffic; restricting it risks silently breaking AWS API calls (KMS, CloudWatch) routed through the VPC without a matching VPC endpoint, for no real security benefit on a non-internet-facing managed service.
  name        = "n8n-rds-sg-${local.cluster_name}"
  description = "Allow PostgreSQL access from within the VPC"
  vpc_id      = local.vpc_id

  ingress {
    description = "PostgreSQL from VPC"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    # The VPC CIDR is always allowed so nodes and pods can reach the database.
    # db_allowed_cidr_blocks appends ranges outside the VPC (corporate network,
    # VPN pool, peered VPC). Keeping them inline rather than expecting the
    # caller to attach a standalone aws_security_group_rule at the root means
    # they survive `terraform plan` instead of being stripped on every run.
    #
    # distinct() because passing the VPC CIDR again, or repeating an entry, is
    # an easy mistake that AWS would reject as a duplicate rule at apply time
    # while the plan looked clean. The intent behind a repeated CIDR is
    # unambiguous, so collapsing it beats failing on it.
    cidr_blocks = distinct(concat([local.vpc_cidr_block], var.db_allowed_cidr_blocks))
  }

  # Allowing by security group is preferable to allowing by CIDR for anything
  # inside the VPC: membership follows the instances rather than their
  # addresses, so it keeps working through subnet changes and IP reuse. Use it
  # for a bastion, a migration runner, or an app tier that already has its own
  # group. CIDR blocks remain the right tool for ranges AWS cannot resolve to a
  # security group, such as a corporate network reached over VPN.
  #
  # Declared as a dynamic block so the rule does not exist at all when the list
  # is empty, which keeps this a no-op diff for deployments that never set it.
  dynamic "ingress" {
    for_each = length(var.db_allowed_security_group_ids) > 0 ? [1] : []

    content {
      description     = "PostgreSQL from allowed security groups"
      from_port       = 5432
      to_port         = 5432
      protocol        = "tcp"
      security_groups = distinct(var.db_allowed_security_group_ids)
    }
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "n8n-rds-sg-${local.cluster_name}" })
}

# ── Subnet group ──────────────────────────────────────────────────────────────
# RDS must be placed in private subnets. We need at least two subnets in
# different AZs for Multi-AZ support.
# Skipped when create_database = false — the caller manages its own subnet
# group (e.g. for an Aurora cluster created in the example folder).

resource "aws_db_subnet_group" "n8n" {
  count = var.create_database ? 1 : 0

  name       = "n8n-db-subnet-group-${local.cluster_name}"
  subnet_ids = local.private_subnets

  tags = merge(local.common_tags, { Name = "n8n-db-subnet-group-${local.cluster_name}" })
}

# ── Enhanced Monitoring IAM role ──────────────────────────────────────────────
# RDS Enhanced Monitoring writes OS-level metrics (CPU steal, swap, per-process
# activity, IOPS depth) to CloudWatch Logs at a configurable cadence that the
# vanilla CloudWatch metrics do not surface. 60-second granularity is the
# AWS-recommended default for production and the cheapest billable interval.
# Conditional on create_database so callers using an external database
# (db_host / db_password) do not get an unused IAM role.

resource "aws_iam_role" "rds_enhanced_monitoring" {
  count = var.create_database ? 1 : 0

  name = "n8n-rds-monitoring-${local.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "rds_enhanced_monitoring" {
  count = var.create_database ? 1 : 0

  role       = aws_iam_role.rds_enhanced_monitoring[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# ── CloudWatch Log Group for postgresql log export ────────────────────────────
# Created explicitly so we own retention; without this resource, RDS auto-
# creates /aws/rds/instance/<id>/postgresql with "Never expire" retention as
# soon as enabled_cloudwatch_logs_exports is set on the instance below.
# Encrypted with the module CMK (clears CKV_AWS_158) when
# var.db_storage_encrypted is true; null-passthrough otherwise so existing
# unencrypted deployments see no plan change on this resource either.

resource "aws_cloudwatch_log_group" "rds_postgresql" {
  count = var.create_database ? 1 : 0

  name              = "/aws/rds/instance/n8n-postgres-${local.cluster_name}/postgresql"
  retention_in_days = 365
  kms_key_id        = local.db_kms_key_arn

  tags = merge(local.common_tags, { Name = "n8n-postgres-${local.cluster_name}-logs" })
}

# ── Parameter group (query logging + enforced TLS) ────────────────────────────
# RDS's default parameter group logs no statements at all (log_statement =
# none, log_min_duration_statement = -1), so the postgresql export configured on
# the instance below carries only startup, error and checkpoint lines. This
# group turns on the two settings that make that export useful for diagnosing a
# slow or stuck n8n instance (CKV2_AWS_30) and requires TLS on every connection
# (CKV2_AWS_69).
#
# Deliberately not log_statement = "all". n8n's queries carry workflow and
# execution payloads, so logging every statement would copy customer data into
# CloudWatch Logs and scale ingestion cost with execution volume. "ddl" logs
# schema changes only (n8n runs migrations on startup, which is exactly what
# you want in the log after an upgrade), and the 1000 ms threshold catches slow
# queries without touching normal traffic.
#
# rds.force_ssl = 1 is already the RDS default for PostgreSQL 15 and later (it
# is 0 on 14 and older), so at this module's default db_engine_version it
# changes nothing and only closes the gap for callers who pin an older major.
# It is safe against the module's own topology either way: n8n connects over
# TLS by default (db_postgresdb_ssl_enabled), and the documented reason to set
# that to false is an in-cluster pooler that terminates TLS on its own upstream
# leg to the database.
#
# Operational note for existing deployments: switching an instance from the
# default parameter group to a custom one takes effect only after a reboot, so
# the new settings land in the next maintenance window (or on a manual reboot),
# not at apply time. New deployments get them from the start.
#
# name_prefix plus create_before_destroy because a major-version bump changes
# `family`, which forces replacement, and RDS refuses to delete a parameter
# group that is still attached to an instance.

resource "aws_db_parameter_group" "n8n" {
  count = var.create_database ? 1 : 0

  name_prefix = "n8n-postgres-${local.cluster_name}-"
  family      = "postgres${split(".", var.db_engine_version)[0]}"

  parameter {
    name  = "log_statement"
    value = "ddl"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.common_tags, { Name = "n8n-postgres-${local.cluster_name}" })
}

# ── RDS PostgreSQL instance ───────────────────────────────────────────────────
# Skipped when create_database = false — the caller provides an external
# database (e.g. Amazon Aurora). n8n.tf uses db_host / db_password directly
# in that case.

resource "aws_db_instance" "n8n" {
  # checkov:skip=CKV2_AWS_30:Query logging IS configured: aws_db_parameter_group.n8n above sets log_statement and log_min_duration_statement, and parameter_group_name below attaches it. Checkov reports this resource twice, once unexpanded and once as the count copy `[0]`, and only the count copy fails: checkov does not build the graph edge between two count-expanded resources, so the copy never sees its own parameter group. Verified by deleting `count` from the parameter group alone, which makes both copies pass while nothing else changes. Neither `one(aws_db_parameter_group.n8n[*].name)` nor any other reference form works around it, and the count has to stay because create_database = false means no database resources at all. Not a coverage gap: tests/defaults.tftest.hcl asserts the group's family and its full parameter set, so a regression there fails `terraform test`. The attachment itself is not plan-assertable, because name_prefix means the group's name is only known after apply.
  # checkov:skip=CKV_AWS_293:Deletion protection is intentionally left at the provider default (false) so `terraform destroy` works cleanly during evaluation and example teardown. Flip to `true` for production. See examples/*/README.md → "Production considerations" for the full set of teardown-friendly defaults to review before promoting any example to production.
  count = var.create_database ? 1 : 0

  identifier        = "n8n-postgres-${local.cluster_name}"
  engine            = "postgres"
  engine_version    = var.db_engine_version
  instance_class    = var.db_instance_class
  allocated_storage = var.db_allocated_storage

  db_name  = "n8n_enterprise"
  username = "n8n"
  password = random_password.db_password.result

  db_subnet_group_name    = aws_db_subnet_group.n8n[0].name
  vpc_security_group_ids  = [aws_security_group.rds.id]
  publicly_accessible     = false
  multi_az                = var.db_multi_az
  backup_retention_period = var.db_backup_retention_period

  # Hardening defaults. Each maps to a Checkov finding that would otherwise
  # ride on `soft_fail = true` in CI. iam_database_authentication_enabled and
  # the CloudWatch log export are in-place changes. copy_tags_to_snapshot
  # propagates the existing tag set to automated and manual snapshots.
  # auto_minor_version_upgrade is the AWS-recommended default for managed
  # patching during the maintenance window.
  iam_database_authentication_enabled = true
  enabled_cloudwatch_logs_exports     = ["postgresql"]
  copy_tags_to_snapshot               = true
  auto_minor_version_upgrade          = true

  # DDL + slow-query logging, so the export above carries something useful.
  # See the parameter group above for why it is not log_statement = "all".
  parameter_group_name = aws_db_parameter_group.n8n[0].name

  # Performance Insights with the default 7-day retention window is included
  # in the AWS free tier. Setting the retention period explicitly prevents
  # silent cost regression if AWS changes the default. PI data is encrypted
  # with the module CMK (clears CKV_AWS_354) when var.db_storage_encrypted is
  # true; null-passthrough otherwise.
  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  performance_insights_kms_key_id       = local.db_kms_key_arn

  # Enhanced Monitoring: 60s is the AWS-recommended production default and the
  # cheapest billable interval. Sub-60s scales with CloudWatch Logs ingestion
  # volume; only worth turning down for targeted debugging.
  monitoring_interval = 60
  monitoring_role_arn = aws_iam_role.rds_enhanced_monitoring[0].arn

  # Storage encryption with the module CMK (clears CKV_AWS_16). Passing false /
  # null preserves the prior unencrypted default so existing applies see no
  # plan change. Flipping db_storage_encrypted from false to true on an
  # existing instance forces a replacement — AWS does not support enabling
  # storage encryption in place. See README.md → "Upgrading from a pre-CMK
  # apply" for the snapshot → restore-with-encryption migration recipe.
  storage_encrypted = var.db_storage_encrypted
  kms_key_id        = local.db_kms_key_arn

  # skip_final_snapshot = true matches the teardown guide's --skip-final-snapshot.
  # Set to false and provide final_snapshot_identifier if you want a backup on destroy.
  skip_final_snapshot      = true
  delete_automated_backups = true

  # Ensure the log group exists (with our 365-day retention) before RDS would
  # otherwise auto-create it at "Never expire" as soon as
  # enabled_cloudwatch_logs_exports is set above.
  depends_on = [aws_cloudwatch_log_group.rds_postgresql]

  lifecycle {
    # auto_minor_version_upgrade = true lets AWS bump engine_version during the
    # maintenance window. Ignore the resulting drift here so the next
    # `terraform apply` doesn't try to downgrade back to var.db_engine_version
    # — RDS does not support minor-version downgrades and the apply would fail.
    ignore_changes = [engine_version]
  }

  tags = merge(local.common_tags, { Name = "n8n-postgres-${local.cluster_name}" })
}

# ── Backup retention diagnostic check ──────────────────────────────────────
# 0 is a legitimate value AWS accepts, and the validation on
# db_backup_retention_period allows it deliberately: some evaluation and
# ephemeral-environment deployments genuinely do not want backups. It is worth
# saying out loud, though, because setting it to 0 also disables point-in-time
# recovery, which is not obvious from the variable name and is discovered at
# the worst possible moment.

check "db_backup_retention_disabled" {
  assert {
    condition = var.create_database ? var.db_backup_retention_period > 0 : true
    error_message = join("", [
      "db_backup_retention_period is 0, which disables automated RDS backups and, with them, ",
      "point-in-time recovery for n8n's database. Intentional for ephemeral environments; set it to ",
      "at least 1 (the module default is 7) for anything holding real workflows or credentials.",
    ])
  }
}

# ── External-database diagnostic checks ────────────────────────────────────
# A cross-variable input mistake has two directions, and only one of them is a
# hard error. "X is required when Y" fails the plan outright, and the module
# already enforces it: db_host and db_password are required when
# create_database = false. The inverse, "X is ignored when Y", plans and applies
# cleanly while quietly discarding what the caller asked for. These checks cover
# that second direction, so a value that will have no effect is surfaced instead
# of swallowed.
#
# This one matters most. create_database defaults to true, so a caller who sets
# db_host expecting the module to use their database gets a module-managed RDS
# instance instead, and n8n connects to that. Both databases exist, the apply
# succeeds, and the workflows land somewhere the caller is not looking. Warn
# rather than fail, because staging db_host in tfvars ahead of the cutover is a
# legitimate thing to do.

check "external_db_inputs_require_create_database_false" {
  assert {
    condition = var.create_database ? (
      var.db_host == null && var.db_password == null
    ) : true
    error_message = join("", [
      "db_host or db_password is set while create_database = true, so both are ignored: the module ",
      "creates its own RDS instance and points n8n at that, not at the database you supplied. Set ",
      "create_database = false to use an external database.",
    ])
  }
}

# The instance-shaping inputs only reach aws_db_instance.n8n, which is not
# created when create_database = false. Tuning them there has no effect on the
# caller's own database.
#
# "Is this input at its default?" is only expressible by repeating the default,
# since HCL cannot read a variable's default at runtime. KEEP THESE LITERALS IN
# LOCKSTEP WITH variables.tf: a default bumped there without updating this
# check makes every create_database = false caller who left the input alone
# warn spuriously. db_engine_version is deliberately not compared, because its
# description invites bumping it ("Bump as needed without forking") and it is
# the one default that changes routinely; the small coverage loss beats a
# check that goes stale on every engine bump.

check "rds_tuning_requires_module_managed_database" {
  assert {
    condition = var.create_database ? true : (
      var.db_instance_class == "db.t3.small" &&
      var.db_allocated_storage == 50 &&
      var.db_multi_az &&
      var.db_storage_encrypted &&
      var.db_backup_retention_period == 7
    )
    error_message = join("", [
      "An RDS sizing or hardening input (db_instance_class, db_allocated_storage, ",
      "db_multi_az, db_storage_encrypted, db_backup_retention_period) is set while ",
      "create_database = false. The module creates no RDS instance in that mode, so none of them apply. ",
      "Configure these on the database you supply via db_host.",
    ])
  }
}
