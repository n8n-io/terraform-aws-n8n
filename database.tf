resource "random_password" "db_password" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# ── Security group ────────────────────────────────────────────────────────────
# Allow inbound PostgreSQL only from within the VPC — nodes and pods can reach
# the database; nothing from the public internet can.

resource "aws_security_group" "rds" {
  name        = "n8n-rds-sg-${local.cluster_name}"
  description = "Allow PostgreSQL access from within the VPC"
  vpc_id      = local.vpc_id

  ingress {
    description = "PostgreSQL from VPC"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr_block]
  }

  egress {
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

# Migrates state from pre-create_database releases of this module where this
# resource was unconditional. Existing applies upgrade in place rather than
# planning a destroy+recreate.
moved {
  from = aws_db_subnet_group.n8n
  to   = aws_db_subnet_group.n8n[0]
}

resource "aws_db_subnet_group" "n8n" {
  count = var.create_database ? 1 : 0

  name       = "n8n-db-subnet-group-${local.cluster_name}"
  subnet_ids = local.private_subnets

  tags = merge(local.common_tags, { Name = "n8n-db-subnet-group-${local.cluster_name}" })
}

# ── RDS PostgreSQL instance ───────────────────────────────────────────────────
# Skipped when create_database = false — the caller provides an external
# database (e.g. Amazon Aurora). n8n.tf uses db_host / db_password directly
# in that case.

# Migrates state from pre-create_database releases of this module where this
# resource was unconditional. Existing applies upgrade in place rather than
# planning a destroy+recreate (which would drop the database).
moved {
  from = aws_db_instance.n8n
  to   = aws_db_instance.n8n[0]
}

resource "aws_db_instance" "n8n" {
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
  backup_retention_period = 7

  # skip_final_snapshot = true matches the teardown guide's --skip-final-snapshot.
  # Set to false and provide final_snapshot_identifier if you want a backup on destroy.
  skip_final_snapshot      = true
  delete_automated_backups = true

  tags = merge(local.common_tags, { Name = "n8n-postgres-${local.cluster_name}" })
}
