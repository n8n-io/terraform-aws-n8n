# ── Security group ────────────────────────────────────────────────────────────
# Skipped along with the rest of the Redis tier when create_elasticache = false:
# nothing in the module would attach to it, and the caller's own Redis carries
# its own rules.

resource "aws_security_group" "redis" {
  count = var.create_elasticache ? 1 : 0

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
# Shared by both topologies. var.private_subnets already validates >= 2 subnets,
# which is what multi_az_enabled needs to place the primary and replica apart.

resource "aws_elasticache_subnet_group" "n8n" {
  count = var.create_elasticache ? 1 : 0

  name       = "n8n-redis-subnet-group-${local.cluster_name}"
  subnet_ids = local.private_subnets

  tags = merge(local.common_tags, { Name = "n8n-redis-subnet-group-${local.cluster_name}" })
}

# ── ElastiCache Redis ─────────────────────────────────────────────────────────
# n8n uses Redis as the queue backend for distributing workflow executions
# between worker pods, and for coordinating multi-main instances.
#
# Two mutually exclusive topologies, chosen by redis_high_availability_enabled.
# They are different resource types, so switching between them is a destroy and
# recreate: `moved` cannot bridge resource types, and the queue goes with the
# node. The flip is a maintenance-window operation, not a rolling change. See
# README → "Redis high availability".
#
# Both pin engine 7.1 and listen on 6379, so the only thing the toggle changes
# about the endpoint n8n connects to is its hostname. The single-node cluster
# leaves `port` unset deliberately. It inherits the same 6379 from the engine
# default, and writing it out now would be a gratuitous attribute change on
# every existing deployment for a value that is already what it says.

# Default: one node, no failover. Cheapest, and a single point of failure for
# both the queue and multi-main leader election.
resource "aws_elasticache_cluster" "n8n" {
  count = var.create_elasticache && !var.redis_high_availability_enabled ? 1 : 0

  # ElastiCache cluster IDs are capped at 20 characters.
  # Pattern: <cluster_name>-redis keeps us within budget for cluster names up to 14 chars.
  cluster_id         = "${local.cluster_name}-redis"
  engine             = "redis"
  engine_version     = "7.1"
  node_type          = var.redis_node_type
  num_cache_nodes    = 1
  subnet_group_name  = aws_elasticache_subnet_group.n8n[0].name
  security_group_ids = [aws_security_group.redis[0].id]

  tags = merge(local.common_tags, { Name = "${local.cluster_name}-redis" })
}

# Opt-in: primary + one replica across two AZs, with ElastiCache promoting the
# replica automatically. num_cache_clusters = 2 is the minimum topology
# automatic_failover_enabled accepts and the cheapest that removes the single
# point of failure; multi_az_enabled is what forces the replica into a second AZ
# rather than leaving both nodes exposed to one AZ event.
#
# What this buys is that the queue survives the node loss, NOT that n8n rides
# the failover out. Measured on a live cluster: promotion took ~20s, the queued
# executions were intact on the promoted node afterwards, and every main, worker
# and webhook pod exited and restarted while it happened. n8n's
# RedisClientService calls process.exit once Redis has been unreachable for
# QUEUE_BULL_REDIS_TIMEOUT_THRESHOLD; raising that to 30s was tried here and
# only moved the exit later, so n8n's default is left alone. See README ->
# "What this actually buys you, measured".
resource "aws_elasticache_replication_group" "n8n" {
  count = var.create_elasticache && var.redis_high_availability_enabled ? 1 : 0

  # Deliberately NOT "<cluster_name>-redis", which is what the cluster above
  # uses. ElastiCache shares one identifier namespace between cache clusters and
  # replication groups, and rejects a second resource reusing the name:
  #
  #   InvalidParameterValue: Cannot have a cluster and replication group with
  #   same identifier. Please use a different identifier.
  #
  # The two resources are independent, so Terraform is free to create this one
  # while the cluster it replaces still exists. With a shared name the apply
  # that flips the toggle would destroy the old cache and then fail to create
  # the replacement, leaving the deployment with no queue backend at all and
  # needing a second apply to recover. A distinct suffix removes the ordering
  # hazard in both directions, so enabling and disabling are each one apply.
  #
  # This constraint was found the hard way on a live cluster while building the
  # sibling redis_transit_encryption_enabled path (#41), not reasoned about.
  #
  # The suffix is "-redis-rg" (replication group) rather than "-redis-ha", even
  # though high availability is the only thing that selects this resource today.
  # #41 needs a replication group as well, for an unrelated reason: auth_token
  # exists only on this resource type. Both toggles therefore converge on this
  # one resource, and a topology-specific name would misdescribe it for a caller
  # who wanted only TLS. Naming it neutrally now is free; renaming it after
  # release is not, because replication_group_id forces replacement and anyone
  # who had already opted in would lose their queue a second time.
  #
  # Length: replication group IDs cap at 40 characters. cluster_name is capped
  # at 14 by its own validation, so 14 + 9 = 23 leaves ample headroom.
  replication_group_id = "${local.cluster_name}-redis-rg"
  description          = "n8n Bull queue and multi-main coordination (HA) for ${local.cluster_name}"

  engine         = "redis"
  engine_version = "7.1"
  node_type      = var.redis_node_type
  port           = 6379

  num_cache_clusters         = 2
  automatic_failover_enabled = true
  multi_az_enabled           = true

  # Set here, in the commit that introduces this resource, precisely because it
  # is ForceNew. Adding it later would replace the cache for everyone who had
  # already enabled HA, which is the same trap replication_group_id above
  # carries. It costs nothing (AWS-managed key, no KMS charge) and the
  # single-node aws_elasticache_cluster path has no equivalent argument, so the
  # default deployment is unaffected either way.
  #
  # This is at-rest only and is independent of transit encryption, which arrives
  # with redis_transit_encryption_enabled (#41). Checkov CKV_AWS_191 additionally
  # wants a customer-managed KMS key here; that is left unaddressed on purpose,
  # matching how the module already treats RDS, and is a deliberate default for
  # a getting-started template rather than an oversight.
  at_rest_encryption_enabled = true

  subnet_group_name  = aws_elasticache_subnet_group.n8n[0].name
  security_group_ids = [aws_security_group.redis[0].id]

  tags = merge(local.common_tags, { Name = "${local.cluster_name}-redis-rg" })
}

# ── External-Redis diagnostic checks ───────────────────────────────────────
# The same two-direction input mistake database.tf guards against, on the Redis
# tier. "X is required when Y" is already a hard error (redis_host is required
# when create_elasticache = false). The inverse, "X is ignored when Y", plans and
# applies cleanly while quietly discarding what the caller asked for. That is
# what these cover.
#
# Written as `guard ? body : true` rather than `!guard || body`: Terraform 1.9,
# which CI pins, does not short-circuit `||`, so the second operand is evaluated
# even when the first already decides the result. See AGENTS.md.

# create_elasticache defaults to true, so a caller who sets redis_host expecting
# the module to use their Redis gets a module-managed ElastiCache instead, and
# n8n queues onto that. Both exist, the apply succeeds, and the executions land
# somewhere the caller is not watching. A warning rather than an error, because
# staging redis_host in tfvars ahead of a cutover is legitimate.
check "external_redis_inputs_require_create_elasticache_false" {
  assert {
    condition = var.create_elasticache ? (
      var.redis_host == null && var.redis_port == 6379
    ) : true
    error_message = join("", [
      "redis_host or redis_port is set while create_elasticache = true, so both are ignored: the ",
      "module creates its own ElastiCache Redis and points n8n and KEDA at that, not at the Redis ",
      "you supplied. Set create_elasticache = false to use an external Redis.",
    ])
  }
}

# The sizing and topology inputs only reach resources that are not created when
# create_elasticache = false, so tuning them there has no effect on the caller's
# own Redis.
#
# "Is this input at its default?" is only expressible by repeating the default,
# since HCL cannot read a variable's default at runtime. KEEP THE LITERAL IN
# LOCKSTEP WITH variables.tf: a default bumped there without updating this check
# makes every create_elasticache = false caller who left the input alone warn
# spuriously.
check "redis_tuning_requires_module_managed_elasticache" {
  assert {
    condition = var.create_elasticache ? true : (
      var.redis_node_type == "cache.t3.medium" &&
      !var.redis_high_availability_enabled
    )
    error_message = join("", [
      "redis_node_type or redis_high_availability_enabled is set while create_elasticache = false. ",
      "The module creates no ElastiCache in that mode, so neither applies. Sizing and failover are ",
      "properties of the Redis you supply via redis_host.",
    ])
  }
}
