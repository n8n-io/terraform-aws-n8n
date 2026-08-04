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
# Shared by both engine resources below — only the engine swaps with
# var.redis_transit_encryption_enabled, not the placement or the firewall.

resource "aws_elasticache_subnet_group" "n8n" {
  name       = "n8n-redis-subnet-group-${local.cluster_name}"
  subnet_ids = local.private_subnets

  tags = merge(local.common_tags, { Name = "n8n-redis-subnet-group-${local.cluster_name}" })
}

# ── AUTH token ────────────────────────────────────────────────────────────────
# Only generated on the opt-in path. random_password.db_password and
# random_password.task_runner_token are both unconditional, but this one is
# count-gated deliberately: the contract for this feature is that a caller who
# leaves redis_transit_encryption_enabled at its default sees NO plan diff, and
# an unconditional random_password would still render `Plan: 1 to add`.
#
# ElastiCache AUTH constraints: 16-128 printable characters, and the only
# permitted non-alphanumerics are ! & # $ ^ < > - — a broader special set (the
# one db_password uses) is rejected at create time.
# https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/auth.html

resource "random_password" "redis_auth_token" {
  count = var.redis_transit_encryption_enabled ? 1 : 0

  length           = 64
  special          = true
  override_special = "!&#$^<>-"
}

# ── ElastiCache Redis ─────────────────────────────────────────────────────────
# n8n uses Redis as the queue backend for distributing workflow executions
# between worker pods, and for coordinating multi-main instances.
#
# Two mutually exclusive resources back one logical cache, because AWS splits
# the capability across resource types: auth_token exists ONLY on
# aws_elasticache_replication_group, and AWS further requires transit
# encryption to be on before AUTH can be enabled at all. There is no argument
# combination that puts an AUTH token on aws_elasticache_cluster.
#
# Migrating everyone to the replication group would have been simpler to read,
# but it replaces the cache for every existing deployment — so the default path
# keeps the cluster resource it has always used, and only callers who opt in
# take the replacement. Consumers read local.redis_host rather than either
# resource directly.

resource "aws_elasticache_cluster" "n8n" {
  count = var.redis_transit_encryption_enabled ? 0 : 1

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

resource "aws_elasticache_replication_group" "n8n" {
  count = var.redis_transit_encryption_enabled ? 1 : 0

  # Deliberately NOT "<cluster_name>-redis", which is what the cluster above
  # uses. ElastiCache shares one identifier namespace between cache clusters and
  # replication groups, and rejects a second resource reusing the name:
  #
  #   InvalidParameterValue: Cannot have a cluster and replication group with
  #   same identifier. Please use a different identifier.
  #
  # These are two independent resources, so Terraform is free to create this one
  # while the cluster still exists. With a shared name, flipping the variable
  # destroys the old cache and then fails to create the replacement, leaving the
  # deployment with no queue backend at all and needing a second apply to
  # recover. Confirmed against a live cluster, not reasoned about — the failed
  # apply is what put this comment here.
  #
  # A distinct suffix removes the ordering hazard in both directions, so
  # enabling and disabling the flag are both single-apply operations.
  #
  # Length: replication group IDs cap at 40 characters. cluster_name is capped
  # at 14 by its own validation, so 14 + 10 = 24 leaves ample headroom.
  replication_group_id = "${local.cluster_name}-redis-tls"
  description          = "n8n queue backend (TLS + AUTH) for ${local.cluster_name}"
  engine               = "redis"
  engine_version       = "7.1"
  node_type            = var.redis_node_type
  port                 = 6379
  subnet_group_name    = aws_elasticache_subnet_group.n8n.name
  security_group_ids   = [aws_security_group.redis.id]

  # Single node with no replica and no automatic failover, matching the cluster
  # path exactly. This variable buys encryption and authentication; it must not
  # quietly also buy a second node and double the bill. Availability is a
  # separate decision and belongs behind its own input.
  num_cache_clusters = 1

  transit_encryption_enabled = true
  auth_token                 = random_password.redis_auth_token[0].result

  # Unused on create; declared so a later token change rotates (both the old
  # and new token valid during the roll) instead of cutting over instantly and
  # breaking every pod that has not yet been restarted with the new value.
  auth_token_update_strategy = "ROTATE"

  tags = merge(local.common_tags, { Name = "${local.cluster_name}-redis-tls" })
}
