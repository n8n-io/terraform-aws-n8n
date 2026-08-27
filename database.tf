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
# Also gated on var.create_db_kms_key: when a caller supplies their own KMS key
# (e.g. a centrally-managed CMK a security team already owns), the module must
# not mint a second one.
#
# The toggle is a boolean rather than `var.db_kms_key_arn == null`, even though
# the ARN's nullness looks like it carries the same information. It does not,
# for count purposes. An input is only plan-time-known if the *caller's*
# expression for it is, and `db_kms_key_arn = aws_kms_key.mine.arn` is a
# perfectly reasonable thing to write and completely unknown until apply.
# Comparing that to null yields an unknown, and an unknown count fails the plan
# outright with "The count value depends on resource attributes that cannot be
# determined until apply". A boolean the caller writes as a literal sidesteps
# it, and lets the ARN beside it be computed. Same reasoning as
# create_database / create_elasticache elsewhere in this module; see
# docs/customer-managed-infrastructure.md → "Why a static boolean, not
# `x == null` inference".
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
  # aws_cloudwatch_log_group.rds_postgresql. Prefers a caller-supplied BYO key
  # (var.db_kms_key_arn) over the module-managed CMK, and falls back to null
  # when neither exists so each consumer falls back to the AWS provider
  # default (unencrypted / AWS-managed key) without a plan diff.
  #
  # Gated on var.db_storage_encrypted so that flag stays the single switch
  # deciding whether this module encrypts anything with a CMK at all. Without
  # the gate a BYO key still reached the log group below while
  # db_storage_encrypted = false, which contradicted both that resource's
  # null-passthrough contract and the db_kms_key_arn check block further down
  # telling the caller their key was unused.
  db_kms_key_arn = var.db_storage_encrypted ? (
    var.create_db_kms_key ? try(aws_kms_key.db[0].arn, null) : var.db_kms_key_arn
  ) : null

  # The postgresql log group's key, deliberately not local.db_kms_key_arn.
  #
  # CloudWatch Logs is the one consumer of the key that AWS refuses outright
  # rather than degrades, and it needs a statement in the key policy naming
  # logs.<region>.amazonaws.com (see aws_cloudwatch_log_group.rds_postgresql
  # below). On the module-managed path the module wrote that statement itself,
  # so the CMK is used exactly as it always was. On the BYO path the module
  # cannot see, add to, or verify the caller's key policy, so it does not assume
  # the statement is there: the log group falls back to CloudWatch's own
  # AWS-managed encryption unless the caller opts in by setting
  # db_logs_kms_key_arn, which is their assertion that the key can be used.
  db_logs_kms_key_arn = var.db_storage_encrypted ? (
    var.create_db_kms_key ? try(aws_kms_key.db[0].arn, null) : (var.db_logs_kms_key_enabled ? var.db_logs_kms_key_arn : null)
  ) : null
}

resource "aws_kms_key" "db" {
  count = var.create_database && var.db_storage_encrypted && var.create_db_kms_key ? 1 : 0

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
  count = var.create_database && var.db_storage_encrypted && var.create_db_kms_key ? 1 : 0

  name_prefix   = "alias/n8n-rds-${local.cluster_name}-"
  target_key_id = aws_kms_key.db[0].key_id
}

# ── Caller-supplied key preflight ─────────────────────────────────────────────
# Describes each caller-supplied key so a key that cannot possibly work is
# rejected while planning instead of part-way through the apply. Between them,
# these two reads plus the db_byo_kms_keys_are_usable check below catch a
# mistyped or deleted key, a disabled one, one pending deletion, and an
# asymmetric or sign-only one, every reason RDS or CloudWatch Logs will refuse
# a key except the one that matters most, the missing key-policy statement,
# which no AWS provider data source exposes (there is no policy attribute on
# data.aws_kms_key and no aws_kms_key_policy data source at all).
#
# This deliberately hard-fails the plan rather than warning, and it adds no IAM
# requirement the apply did not already have: "To create an RDS resource using a
# customer managed key, a user must have permissions to call the following
# operations on the customer managed key: kms:CreateGrant, kms:DescribeKey"
# (AmazonRDS/latest/UserGuide/Overview.Encryption.Keys.html). A caller who
# cannot describe the key cannot create the instance either, so the failure is
# the same one, moved earlier and made legible. s3.tf deliberately does not do
# this for s3_kms_key_arn; see the comment next to its checks for why the same
# reasoning does not carry over there.
#
# Gated on the same conditions as local.db_kms_key_arn: no read happens unless
# the key actually reaches a resource.

data "aws_kms_key" "db_byo" {
  count = var.create_database && var.db_storage_encrypted && !var.create_db_kms_key ? 1 : 0

  key_id = var.db_kms_key_arn
}

data "aws_kms_key" "db_logs_byo" {
  count = var.create_database && var.db_storage_encrypted && !var.create_db_kms_key && var.db_logs_kms_key_enabled ? 1 : 0

  key_id = var.db_logs_kms_key_arn
}

# ── Restore-source snapshot ───────────────────────────────────────────────────
# Read so the checks further down can compare what the snapshot IS against what
# the configuration claims it is. Worth the read because every mismatch here
# lands on a ForceNew argument: the restored instance's encryption state and KMS
# key come from the snapshot and cannot be set while restoring, so a
# configuration that disagrees produces a plan that wants to replace the instance
# on every apply and can never succeed in doing so.
#
# Hard-fails the plan when the snapshot does not exist or cannot be described,
# which is the same failure the restore itself would hit, moved earlier. No new
# IAM requirement: rds:DescribeDBSnapshots is table stakes for restoring from one.

data "aws_db_snapshot" "restore" {
  count = var.create_database && var.db_snapshot_identifier != null ? 1 : 0

  db_snapshot_identifier = var.db_snapshot_identifier
}

locals {
  # Both caller-supplied keys flattened into one list, each carrying the name of
  # the input it came from, so a single check block can assert on all of them and
  # still name the offending input in its error message. Empty on every path
  # where neither data source was read, which makes each alltrue() below
  # vacuously true rather than needing its own null guard.
  db_byo_kms_keys = concat(
    [for d in data.aws_kms_key.db_byo : {
      input     = "db_kms_key_arn"
      arn       = d.arn
      key_state = d.key_state
      key_usage = d.key_usage
      key_spec  = d.key_spec
    }],
    [for d in data.aws_kms_key.db_logs_byo : {
      input     = "db_logs_kms_key_arn"
      arn       = d.arn
      key_state = d.key_state
      key_usage = d.key_usage
      key_spec  = d.key_spec
    }],
  )
}

# ── Security group ────────────────────────────────────────────────────────────
# Allow inbound PostgreSQL only from within the VPC — nodes and pods can reach
# the database; nothing from the public internet can.
#
# Skipped when create_database = false: its only consumer is
# aws_db_instance.n8n[0]'s vpc_security_group_ids below, so a module-managed
# database is the only case this group ever attaches to anything. Without this
# gate, an external-database deployment got a security group that named and
# tagged itself after n8n but sat on nothing.

resource "aws_security_group" "rds" {
  # checkov:skip=CKV_AWS_382:Egress-all is intentional. RDS does not originate arbitrary outbound traffic; restricting it risks silently breaking AWS API calls (KMS, CloudWatch) routed through the VPC without a matching VPC endpoint, for no real security benefit on a non-internet-facing managed service.
  # checkov:skip=CKV2_AWS_5:This group IS attached, at aws_db_instance.n8n[0]'s vpc_security_group_ids below, the only consumer named in the header comment above. Checkov does not always resolve that attachment through a caller module's own `module "n8n" { source = ... }` invocation once this resource carries a `count` tied to create_database, the same tooling limitation already documented on aws_security_group.redis in redis.tf and on CKV2_AWS_30 in this file. Verified live: the group has exactly one ingress-side consumer and it is always attached whenever create_database = true creates this group at all.
  count = var.create_database ? 1 : 0

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

  permissions_boundary = var.iam_permissions_boundary_arn

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
#
# This is the one consumer of the key that AWS refuses outright rather than
# degrades. RDS reaches the key through a grant, so storage and Performance
# Insights work with nothing more than the default root statement in the key
# policy. CloudWatch Logs does not: creating a log group against a key whose
# policy has no logs.<region>.amazonaws.com statement fails with
# InvalidParameterException, and it fails here, before the instance is created,
# leaving a half-built stack. No AWS provider data source returns a key policy,
# so the module cannot check for that statement at plan time.
#
# Hence local.db_logs_kms_key_arn rather than local.db_kms_key_arn: the module
# only puts a key on this log group when it knows the key can be used.
#
#   - Module-managed CMK: used, unchanged. The module wrote the
#     AllowCloudWatchLogsEncrypt statement onto aws_kms_key.db itself.
#   - db_kms_key_arn (BYO), db_logs_kms_key_arn unset: no CMK. The log group
#     falls back to CloudWatch's AWS-managed encryption, which is still
#     encryption at rest, and the CMK still covers storage and Performance
#     Insights, the data that actually matters. A check block says out loud
#     that this happened, so it is disclosed rather than silent.
#   - db_logs_kms_key_arn set: used. Setting it is the caller stating that this
#     key's policy names the CloudWatch Logs service principal, which is a claim
#     only they can make.
#
# README.md → "Bring your own KMS key for RDS" carries the statement to add (it
# is the AllowCloudWatchLogsEncrypt statement on aws_kms_key.db above).

resource "aws_cloudwatch_log_group" "rds_postgresql" {
  count = var.create_database ? 1 : 0

  name              = "/aws/rds/instance/n8n-postgres-${local.cluster_name}/postgresql"
  retention_in_days = 365
  kms_key_id        = local.db_logs_kms_key_arn

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
# Opt-in because engine_version is intentionally ignored on the instance. An
# existing database can therefore still run PostgreSQL 16 while
# var.db_engine_version is 18.4; attaching a postgres18 group to it fails at the
# RDS API. Callers enable this only when the live major matches the configured
# major. Switching from the default group takes effect after a reboot.
#
# name_prefix plus create_before_destroy because a major-version bump changes
# `family`, which forces replacement, and RDS refuses to delete a parameter
# group that is still attached to an instance.

resource "aws_db_parameter_group" "n8n" {
  count = var.create_database && var.db_query_logging_enabled ? 1 : 0

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
  # checkov:skip=CKV2_AWS_30:Query logging is an explicit opt-in through db_query_logging_enabled. Enabling it creates aws_db_parameter_group.n8n with log_statement and log_min_duration_statement and attaches it below. It cannot safely default on because engine_version is ignored: an upgraded module can configure 18.4 while the live instance remains on 16, and RDS rejects a postgres18 group on that instance. Checkov also builds no graph edge between the two count-expanded resources, so it cannot see the attachment even on the enabled path. Tests assert both the safe default and the opt-in group's exact contents.
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
  vpc_security_group_ids  = [aws_security_group.rds[0].id]
  publicly_accessible     = false
  multi_az                = var.db_multi_az
  backup_retention_period = var.db_backup_retention_period

  # Written as `? true : null` rather than passing the bool straight through,
  # matching redis.tf: apply_immediately is a request-time flag the API never
  # reports back, so existing instances have it null in state and an explicit
  # `false` would render as an in-place update on every such deployment for a
  # change that alters nothing. Without this set, a db_instance_class change
  # reports "Apply complete" while AWS queues the class change in
  # PendingModifiedValues for the next maintenance window; see the variable
  # description for the measured incident.
  apply_immediately = var.db_apply_immediately ? true : null

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

  # Opt-in DDL + slow-query logging. null preserves the instance's current
  # default/custom group and, critically, avoids attaching a family derived
  # from a newer configured engine version to an older live engine.
  parameter_group_name = var.db_query_logging_enabled ? aws_db_parameter_group.n8n[0].name : null

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

  # Restore from an existing snapshot instead of creating an empty database.
  # Null (the default) creates an empty one exactly as before. ForceNew, so this
  # is for standing a stack up, not for reloading a live one. The generated
  # password above still lands: the provider issues a ModifyDBInstance right
  # after the restore, because RestoreDBInstanceFromDBSnapshot takes no password
  # parameter. Encryption, by contrast, comes from the snapshot and cannot be set
  # while restoring, which is what the db_snapshot_* checks below are about.
  snapshot_identifier = var.db_snapshot_identifier

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

# ── BYO KMS key diagnostic check ────────────────────────────────────────────
# db_kms_key_arn only reaches anything when the module both manages the RDS
# instance (create_database = true) and encrypts its storage
# (db_storage_encrypted = true). Set it alongside create_database = false, or
# alongside db_storage_encrypted = false, and the plan and apply both succeed
# while the supplied key is never referenced anywhere: the caller's own
# database, or an intentionally-unencrypted module-managed one, is unaffected.
# Warn rather than fail: staging db_kms_key_arn in tfvars ahead of flipping
# db_storage_encrypted, or ahead of a future cutover away from an external
# database, is a legitimate thing to do.

check "db_kms_key_arn_requires_module_managed_encrypted_database" {
  assert {
    condition = var.db_kms_key_arn != null ? (
      var.create_database && var.db_storage_encrypted && !var.create_db_kms_key
    ) : true
    error_message = join("", [
      "db_kms_key_arn is set but ignored: it only encrypts a module-managed RDS instance ",
      "(create_database = true) with storage encryption enabled (db_storage_encrypted = true) and the ",
      "module's own CMK turned off (create_db_kms_key = false). With create_database = false the module ",
      "creates no RDS instance to encrypt; with db_storage_encrypted = false the instance is left ",
      "unencrypted and no KMS key of any kind is used; with create_db_kms_key left at its default the ",
      "module mints and uses its own key and never reads this ARN.",
    ])
  }
}

check "db_logs_kms_key_arn_requires_db_logs_kms_key_enabled" {
  assert {
    condition = var.db_logs_kms_key_arn != null ? (
      var.db_logs_kms_key_enabled && var.create_database && var.db_storage_encrypted
    ) : true
    error_message = join("", [
      "db_logs_kms_key_arn is set but ignored: it only applies on the bring-your-own-key path, with ",
      "db_logs_kms_key_enabled = true to opt the log group onto it (and with create_database = true and ",
      "db_storage_encrypted = true, so a log group and a CMK both exist). Setting the ARN alone changes ",
      "nothing. With create_db_kms_key left at its default the module creates its own CMK, already carrying ",
      "the CloudWatch Logs statement, and encrypts the postgresql log group with it.",
    ])
  }
}

# ── BYO key usability checks ────────────────────────────────────────────────
# Backed by data.aws_kms_key.db_byo / .db_logs_byo above. Each assert names the
# input and the resolved ARN so the message points at the tfvars line to fix
# rather than at a key ID the reader then has to look up.
#
# These are warnings, not hard failures, which is the right severity even though
# every condition here is fatal at apply time: the data source reads already
# hard-fail the plan on a key that does not exist or cannot be described, so
# these add diagnosis, not enforcement. A reader who sees "pending deletion"
# knows immediately what to do; InvalidParameterException from RDS 90 seconds
# into an apply does not tell them that.

check "db_byo_kms_keys_are_usable" {
  assert {
    condition = alltrue([for k in local.db_byo_kms_keys : k.key_state == "Enabled"])
    error_message = join("", [
      "Caller-supplied KMS key is not in the Enabled state: ",
      join(", ", [for k in local.db_byo_kms_keys : "${k.input} = ${k.arn} is ${k.key_state}" if k.key_state != "Enabled"]),
      ". Neither RDS nor CloudWatch Logs can use a key that is disabled, pending deletion, pending import or ",
      "unavailable, so the apply fails when it reaches them. Enable the key (or cancel its deletion), or supply ",
      "one that is enabled.",
    ])
  }

  assert {
    condition = alltrue([for k in local.db_byo_kms_keys : k.key_usage == "ENCRYPT_DECRYPT"])
    error_message = join("", [
      "Caller-supplied KMS key has the wrong key usage: ",
      join(", ", [for k in local.db_byo_kms_keys : "${k.input} = ${k.arn} is ${k.key_usage}" if k.key_usage != "ENCRYPT_DECRYPT"]),
      ". RDS storage, Performance Insights and CloudWatch Logs all need a key with key usage ENCRYPT_DECRYPT; a ",
      "SIGN_VERIFY or GENERATE_VERIFY_MAC key cannot encrypt anything and key usage cannot be changed after ",
      "creation, so this needs a different key.",
    ])
  }

  assert {
    condition = alltrue([for k in local.db_byo_kms_keys : k.key_spec == "SYMMETRIC_DEFAULT"])
    error_message = join("", [
      "Caller-supplied KMS key is not symmetric: ",
      join(", ", [for k in local.db_byo_kms_keys : "${k.input} = ${k.arn} is ${k.key_spec}" if k.key_spec != "SYMMETRIC_DEFAULT"]),
      ". RDS and CloudWatch Logs support symmetric encryption keys only (SYMMETRIC_DEFAULT). An asymmetric key ",
      "reports key usage ENCRYPT_DECRYPT too, so the spec is what distinguishes it, and it is fixed at creation ",
      "time. Supply a symmetric key.",
    ])
  }
}

# Region is asserted from the ARN string rather than from the data source,
# because it holds whether or not the key was read: an ARN in another region is
# worth flagging even on a path where the key is currently ignored, since it is a
# latent failure waiting for create_database or db_storage_encrypted to flip.
# KMS keys are regional and neither RDS nor CloudWatch Logs can reach across
# regions, so there is no legitimate cross-region case to accommodate here.
# Account is deliberately not asserted: a CMK shared from a central security
# account is a legitimate and expected setup.

check "db_byo_kms_key_regions_match" {
  assert {
    condition = alltrue([
      for arn in compact([var.db_kms_key_arn, var.db_logs_kms_key_arn]) :
      split(":", arn)[3] == local.aws_region
    ])
    error_message = join("", [
      "Caller-supplied KMS key is in the wrong region: ",
      join(", ", [
        for arn in compact([var.db_kms_key_arn, var.db_logs_kms_key_arn]) :
        "${arn} is in ${split(":", arn)[3]}" if split(":", arn)[3] != local.aws_region
      ]),
      ", but this module deploys into ${local.aws_region}. KMS keys are regional: RDS cannot encrypt an instance ",
      "with a key from another region, and CloudWatch Logs cannot encrypt a log group with one either. Supply a ",
      "key in ${local.aws_region}, or a multi-Region replica's ARN in that region.",
    ])
  }
}

# ── postgresql log group encryption disclosure ──────────────────────────────
# Not a mistake, and not something the caller has to act on. It is stated out
# loud because "I gave the module my CMK" and "everything the module creates is
# encrypted with my CMK" are different claims, and a security reviewer will
# eventually ask which one is true. See aws_cloudwatch_log_group.rds_postgresql
# above for why the module does not assume a caller-supplied key can be used by
# CloudWatch Logs.

check "db_kms_key_arn_does_not_encrypt_postgresql_logs" {
  assert {
    condition = (var.create_database && var.db_storage_encrypted && !var.create_db_kms_key) ? (
      var.db_logs_kms_key_enabled
    ) : true
    error_message = join("", [
      "db_kms_key_arn encrypts the RDS instance's storage and Performance Insights data, but NOT the postgresql ",
      "CloudWatch log group, which falls back to CloudWatch's AWS-managed encryption. CloudWatch Logs rejects a ",
      "key whose policy does not name logs.${local.aws_region}.amazonaws.com, and no data source lets the module ",
      "check whether yours does, so it does not assume it. To put the log group on your key too: add the ",
      "AllowCloudWatchLogsEncrypt statement from README.md -> \"Bring your own KMS key for RDS\" to the key ",
      "policy, then set db_logs_kms_key_arn to the same ARN and db_logs_kms_key_enabled = true. Nothing is ",
      "unencrypted either way.",
    ])
  }
}

# ── Snapshot restore checks ─────────────────────────────────────────────────
# Every one of these guards a ForceNew argument. The restored instance's engine,
# encryption state and KMS key all come from the snapshot and cannot be set while
# restoring, so a configuration that disagrees with the snapshot does not fail
# once: it produces a plan that wants to replace the instance, forever, and the
# replacement can never reconcile. Catching that at plan time is the difference
# between a legible message and a stack that looks restored but re-plans a
# replacement on every apply.

check "db_snapshot_identifier_requires_module_managed_database" {
  assert {
    condition = var.db_snapshot_identifier != null ? var.create_database : true
    error_message = join("", [
      "db_snapshot_identifier is set but ignored: with create_database = false the module manages no RDS ",
      "instance to restore into, and it cannot restore a snapshot into the external database you supplied ",
      "via db_host. Restore that one yourself, or set create_database = true to have the module own the ",
      "restored instance.",
    ])
  }
}

check "db_snapshot_engine_is_postgres" {
  assert {
    condition = alltrue([for s in data.aws_db_snapshot.restore : s.engine == "postgres"])
    error_message = join("", [
      "db_snapshot_identifier points at a ",
      join(", ", [for s in data.aws_db_snapshot.restore : s.engine]),
      " snapshot, and n8n needs PostgreSQL. RDS can restore across some engine families, but this module ",
      "sets engine = \"postgres\" on the instance and n8n's schema exists only there.",
    ])
  }
}

check "db_snapshot_encryption_matches_configuration" {
  assert {
    condition = alltrue([for s in data.aws_db_snapshot.restore : s.encrypted == var.db_storage_encrypted])
    error_message = join("", [
      "db_snapshot_identifier points at ",
      alltrue([for s in data.aws_db_snapshot.restore : s.encrypted]) ? "an encrypted" : "an unencrypted",
      " snapshot while db_storage_encrypted = ${var.db_storage_encrypted}. A restore inherits the ",
      "snapshot's encryption state and cannot change it: RestoreDBInstanceFromDBSnapshot takes no ",
      "encryption parameter, and storage_encrypted is ForceNew, so Terraform will want to replace the ",
      "instance on every apply and never be able to. Set db_storage_encrypted to match the snapshot, or ",
      "copy the snapshot to the encryption state you want first (aws rds copy-db-snapshot --kms-key-id) ",
      "and restore from the copy.",
    ])
  }

  # The key is compared on its ID rather than by whole-string equality, because
  # the snapshot's kms_key_id may come back as either the full ARN or the bare
  # key ID depending on how the snapshot was created, and a false mismatch here
  # would be worse than no check: it would tell a correct configuration it is
  # wrong. A UUID suffix match is specific enough in practice.
  assert {
    condition = alltrue([
      for s in data.aws_db_snapshot.restore :
      s.encrypted ? (
        var.db_kms_key_arn != null ? endswith(s.kms_key_id, element(split("/", var.db_kms_key_arn), 1)) : false
      ) : true
    ])
    error_message = join("", [
      "db_snapshot_identifier points at a snapshot encrypted with ",
      join(", ", [for s in data.aws_db_snapshot.restore : s.kms_key_id]),
      ", which is not what db_kms_key_arn names (currently ",
      var.db_kms_key_arn == null ? "null, so the module would mint its own CMK" : var.db_kms_key_arn,
      "). A restored instance keeps the snapshot's key, and kms_key_id is ForceNew, so the module cannot ",
      "re-key it: a module-created CMK can never match a pre-existing snapshot, and a different ",
      "caller-supplied key cannot either. Set db_kms_key_arn to the snapshot's own key, or copy the ",
      "snapshot to the key you want and restore from the copy.",
    ])
  }
}

check "db_snapshot_fits_allocated_storage" {
  assert {
    condition = alltrue([for s in data.aws_db_snapshot.restore : s.allocated_storage <= var.db_allocated_storage])
    error_message = join("", [
      "db_snapshot_identifier points at a snapshot of ",
      join(", ", [for s in data.aws_db_snapshot.restore : tostring(s.allocated_storage)]),
      " GB while db_allocated_storage is ${var.db_allocated_storage} GB. AWS requires the restored ",
      "instance to be allocated at least as much storage as the snapshot holds, or the restore fails. ",
      "Raise db_allocated_storage to at least the snapshot's size; RDS storage can grow later but not ",
      "shrink.",
    ])
  }
}

# The restore checks above all describe the instance. This one describes what is
# inside it. n8n encrypts stored credentials with N8N_ENCRYPTION_KEY, so a
# snapshot carries ciphertext that only the key of the instance it was taken from
# can read. Restore without supplying that key and the module mints a new one:
# the apply succeeds, the workflows come back, and every credential in them is
# unreadable, with no rerun that fixes it.
#
# Unlike the encryption-state mismatch above, nothing about this is visible in the
# plan or in AWS. Both sides are plain inputs, though, so it costs nothing to
# catch. It stays a check rather than a validation because there is one legitimate
# reading of this combination: restoring for the workflow data while accepting
# that the credentials in it are disposable.
check "db_snapshot_restore_needs_the_original_encryption_key" {
  assert {
    condition = (var.create_database && var.db_snapshot_identifier != null) ? (
      var.n8n_encryption_key != null || var.n8n_encryption_key_secret_ref != null
    ) : true
    error_message = join("", [
      "db_snapshot_identifier is set but neither n8n_encryption_key nor n8n_encryption_key_secret_ref is, ",
      "so the module will generate a fresh N8N_ENCRYPTION_KEY. n8n cannot decrypt credentials stored under ",
      "a different key, so the restored database will come back with its workflows intact and every ",
      "credential in them unreadable. This fails at runtime, not at apply, and re-applying does not fix it. ",
      "Set n8n_encryption_key (or n8n_encryption_key_secret_ref, if the key lives in a caller-managed Secret) ",
      "to the key the snapshot's instance ran under: it is the n8n_encryption_key output of the deployment ",
      "the snapshot came from, emitted once at apply time. If the credentials in this snapshot are genuinely ",
      "disposable and only the workflow data matters, this warning is expected and can be ignored.",
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
      var.db_backup_retention_period == 7 &&
      !var.db_apply_immediately
    )
    error_message = join("", [
      "An RDS sizing or hardening input (db_instance_class, db_allocated_storage, ",
      "db_multi_az, db_storage_encrypted, db_backup_retention_period, db_apply_immediately) is set while ",
      "create_database = false. The module creates no RDS instance in that mode, so none of them apply. ",
      "Configure these on the database you supply via db_host.",
    ])
  }
}
