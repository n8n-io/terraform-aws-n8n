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

  backup_retention_period = 7
  skip_final_snapshot     = true
  deletion_protection     = false

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-aurora" })
}

resource "aws_rds_cluster_instance" "writer" {
  identifier         = "${var.cluster_name}-writer"
  cluster_identifier = aws_rds_cluster.n8n.id
  instance_class     = var.aurora_instance_class
  engine             = aws_rds_cluster.n8n.engine
  engine_version     = aws_rds_cluster.n8n.engine_version

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-writer" })
}

resource "aws_rds_cluster_instance" "reader" {
  identifier         = "${var.cluster_name}-reader"
  cluster_identifier = aws_rds_cluster.n8n.id
  instance_class     = var.aurora_instance_class
  engine             = aws_rds_cluster.n8n.engine
  engine_version     = aws_rds_cluster.n8n.engine_version

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-reader" })
}
