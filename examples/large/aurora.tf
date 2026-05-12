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

resource "aws_rds_cluster" "n8n" {
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

  # Hardening defaults. Aurora leaves storage_encrypted = false unless set
  # explicitly (CKV_AWS_96 — "Ensure all data stored in Aurora is securely
  # encrypted at rest"), which is Registry table-stakes for any new RDS-family
  # resource. IAM database authentication (CKV_AWS_162) and postgresql log
  # export to CloudWatch (CKV_AWS_354) round out the baseline so a new resource
  # does not regress curated findings. copy_tags_to_snapshot (CKV_AWS_313)
  # propagates the existing tag set onto automated + manual snapshots.
  # CKV_AWS_327 (encrypt with a customer-managed KMS key rather than the
  # AWS-managed `aws/rds` key) is intentionally deferred — tracked as a
  # follow-up alongside the other still-failing Aurora findings: instance-
  # level CKV_AWS_353 / CKV_AWS_118, cluster-level CKV_AWS_139, and log-group
  # CKV_AWS_158.
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
# with "Never expire" retention. CMK encryption on the log group (CKV_AWS_158)
# is intentionally deferred alongside the cluster-level CKV_AWS_327 follow-up.
resource "aws_cloudwatch_log_group" "aurora_postgresql" {
  name              = "/aws/rds/cluster/${var.cluster_name}-aurora/postgresql"
  retention_in_days = 365

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-aurora-postgresql-logs" })
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

  lifecycle {
    ignore_changes = [engine_version]
  }

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-reader" })
}
