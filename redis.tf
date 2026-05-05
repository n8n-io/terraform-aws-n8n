# ── Security group ────────────────────────────────────────────────────────────

resource "aws_security_group" "redis" {
  name        = "n8n-redis-sg-${local.cluster_name}"
  description = "Allow Redis access from within the VPC"
  vpc_id      = local.vpc_id

  ingress {
    description = "Redis from VPC"
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "n8n-redis-sg-${local.cluster_name}" })
}

# ── Subnet group ──────────────────────────────────────────────────────────────

resource "aws_elasticache_subnet_group" "n8n" {
  name       = "n8n-redis-subnet-group-${local.cluster_name}"
  subnet_ids = local.private_subnets

  tags = merge(local.common_tags, { Name = "n8n-redis-subnet-group-${local.cluster_name}" })
}

# ── ElastiCache Redis cluster ─────────────────────────────────────────────────
# n8n uses Redis as the queue backend for distributing workflow executions
# between worker pods, and for coordinating multi-main instances.

resource "aws_elasticache_cluster" "n8n" {
  # ElastiCache cluster IDs are capped at 20 characters.
  # Pattern: <cluster_name>-redis keeps us within budget for cluster names up to 14 chars.
  cluster_id         = "${local.cluster_name}-redis"
  engine             = "redis"
  engine_version     = "7.1"
  node_type          = var.redis_node_type
  num_cache_nodes    = 1
  subnet_group_name  = aws_elasticache_subnet_group.n8n.name
  security_group_ids = [aws_security_group.redis.id]

  tags = merge(local.common_tags, { Name = "${local.cluster_name}-redis" })
}
