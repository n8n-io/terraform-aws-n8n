# ── Customer Managed KMS key (optional) ───────────────────────────────────────
# Encrypts the replication group's at-rest data (CKV_AWS_191) with a
# module-created CMK instead of the AWS-managed key ElastiCache defaults to.
# Same rotation and deletion-window shape as aws_kms_key.db in database.tf,
# but without that key's CloudWatch Logs statement: ElastiCache does not write
# through this key the way RDS writes its postgresql log group through
# aws_kms_key.db, it only uses the key to encrypt the replication group's own
# storage. AWS documents that ElastiCache creates the grant it needs on this
# key itself at creation time, via the caller's own kms:CreateGrant
# permission, so the EnableRootAccess statement below is enough. Unlike the
# HA/TLS measurements elsewhere in this file, that is what AWS's documentation
# says, not something exercised against a live replication group.
#
# kms_key_id only exists on aws_elasticache_replication_group, so this key
# (like the resource it encrypts) only ever applies to the opt-in topology.
# There is no way to give the default single-node aws_elasticache_cluster a
# CMK: enabling this on a deployment that asked for neither HA nor TLS moves
# it onto the replication group too, at the same one-node cost but a
# different resource type. See var.redis_kms_encryption_enabled's description
# in variables.tf.
locals {
  redis_kms_key_arn = try(aws_kms_key.redis[0].arn, null)
}

resource "aws_kms_key" "redis" {
  # redis_kms_encryption_enabled is one of the three inputs OR'd into
  # local.redis_needs_replication_group, so it being true already implies
  # that local is true too; testing only the variable here avoids restating
  # the implication.
  count = var.create_elasticache && var.redis_kms_encryption_enabled ? 1 : 0

  description             = "CMK for module-managed ElastiCache Redis ${local.cluster_name}"
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
    ]
  })

  tags = merge(local.common_tags, { Name = "n8n-redis-${local.cluster_name}" })
}

resource "aws_kms_alias" "redis" {
  count = var.create_elasticache && var.redis_kms_encryption_enabled ? 1 : 0

  name_prefix   = "alias/n8n-redis-${local.cluster_name}-"
  target_key_id = aws_kms_key.redis[0].key_id
}

# ── Security group ────────────────────────────────────────────────────────────
# Skipped along with the rest of the Redis tier when create_elasticache = false:
# nothing in the module would attach to it, and the caller's own Redis carries
# its own rules.

resource "aws_security_group" "redis" {
  # checkov:skip=CKV_AWS_382:Egress-all is intentional. ElastiCache does not originate arbitrary outbound traffic; restricting it risks silently breaking AWS API calls (KMS, CloudWatch) routed through the VPC without a matching VPC endpoint, for no real security benefit on a non-internet-facing managed service.
  # checkov:skip=CKV2_AWS_5:This group IS attached: both Redis topologies reference it as security_group_ids = [aws_security_group.redis[0].id], aws_elasticache_cluster.n8n and aws_elasticache_replication_group.n8n below, and exactly one of the two exists for any given input. Checkov does not build the graph edge between two count-expanded resources, so it cannot see either attachment. Verified by deleting `count` from this resource alone, which makes the finding disappear while nothing else changes; the same artifact is documented on CKV2_AWS_30 in database.tf. The count has to stay, because create_elasticache = false means no Redis tier at all and nothing for this group to attach to.
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
    description = "Allow all outbound"
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

# ── AUTH token ────────────────────────────────────────────────────────────────
# Only generated on the module-managed, opt-in path. random_password.db_password
# is unconditional, but this one is count-gated deliberately: the contract for
# this feature is that a caller who leaves redis_transit_encryption_enabled at
# its default sees NO plan diff, and an unconditional random_password would
# still render `Plan: 1 to add`.
#
# Also gated on create_elasticache: with create_elasticache = false and
# redis_auth_token set, local.redis_auth_active is true but the credential is
# the caller's own (local.redis_auth_token_value reads var.redis_auth_token on
# that path), so generating one here would mint a random password nothing ever
# uses while still consuming an apply.
#
# ElastiCache AUTH constraints: 16-128 printable characters, and the only
# permitted non-alphanumerics are ! & # $ ^ < > - . A broader special set (the
# one db_password uses) is rejected at create time.
# https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/auth.html

resource "random_password" "redis_auth_token" {
  count = var.create_elasticache && local.redis_auth_active ? 1 : 0

  length           = 64
  special          = true
  override_special = "!&#$^<>-"
}

# ── ElastiCache Redis ─────────────────────────────────────────────────────────
# n8n uses Redis as the queue backend for distributing workflow executions
# between worker pods, and for coordinating multi-main instances.
#
# Two mutually exclusive resources back one logical cache, because AWS splits
# the capabilities this module needs across resource types:
#
#   - a replica with automatic failover exists only on the replication group
#   - auth_token exists ONLY on the replication group, and AWS further requires
#     transit encryption to be on before AUTH can be enabled at all
#   - kms_key_id (a customer-managed key) exists ONLY on the replication group
#
# So redis_high_availability_enabled, redis_transit_encryption_enabled and
# redis_kms_encryption_enabled each select the replication group, for
# unrelated reasons, and ANY ONE being set is enough. They are independent:
# TLS does not buy a replica, HA does not buy encryption, and a CMK does not
# buy either. See the attributes below, each gated on its own variable.
#
# Migrating everyone to the replication group would have been simpler to read,
# but it replaces the cache for every existing deployment. The default path
# therefore keeps the cluster resource it has always used, and only callers who
# opt into one of the three features take the replacement. `moved` cannot
# bridge resource types, and the queue goes with the node, so the flip is a
# maintenance-window operation rather than a rolling change. See README →
# "Redis high availability".
#
# Consumers read local.redis_host rather than picking a resource, so the paths
# cannot drift apart. Both pin engine 7.1 and listen on 6379, so the only thing
# either toggle changes about the endpoint is its hostname (and, for TLS,
# whether the client must speak it). The single-node cluster leaves `port`
# unset deliberately. It inherits the same 6379 from the engine default, and
# writing it out now would be a gratuitous attribute change on every existing
# deployment for a value that is already what it says.

# Default: one node, no failover, and no at-rest or transit encryption. Redis
# OSS at-rest encryption is only available on a replication group; the
# standalone aws_elasticache_cluster resource exposes no encryption argument.
# Cheapest, and a single point of failure for both the queue and multi-main
# leader election.
resource "aws_elasticache_cluster" "n8n" {
  count = var.create_elasticache && !local.redis_needs_replication_group ? 1 : 0

  # ElastiCache cluster IDs are capped at 20 characters.
  # Pattern: <cluster_name>-redis keeps us within budget for cluster names up to 14 chars.
  cluster_id         = "${local.cluster_name}-redis"
  engine             = "redis"
  engine_version     = "7.1"
  node_type          = var.redis_node_type
  num_cache_nodes    = 1
  subnet_group_name  = aws_elasticache_subnet_group.n8n[0].name
  security_group_ids = [aws_security_group.redis[0].id]

  # Daily snapshot (CKV_AWS_134). n8n uses this Redis as a BullMQ queue/cache,
  # not a source of truth, so a snapshot only shortens recovery of in-flight
  # queued executions after a failure - it's cheap insurance, not a durability
  # requirement.
  snapshot_retention_limit = var.redis_snapshot_retention_limit

  tags = merge(local.common_tags, { Name = "${local.cluster_name}-redis" })
}

# Opt-in per feature. Each variable controls only its own attribute(s) below,
# and none of the three interacts with another beyond all three sharing this
# one resource, so every reachable combination is:
#
#   HA only         two nodes across two AZs, automatic failover, plaintext, ElastiCache-managed key
#   TLS only        one node, no failover, transit encryption + AUTH, ElastiCache-managed key
#   CMK only        one node, no failover, plaintext, customer-managed key
#   HA + TLS        two nodes across two AZs, automatic failover, encryption + AUTH, ElastiCache-managed key
#   HA + CMK        two nodes across two AZs, automatic failover, plaintext, customer-managed key
#   TLS + CMK       one node, no failover, transit encryption + AUTH, customer-managed key
#   HA + TLS + CMK  two nodes across two AZs, automatic failover, encryption + AUTH, customer-managed key
#
# kms_key_id is the only line redis_kms_encryption_enabled touches: it never
# changes node count, failover, or encryption/AUTH, it only ever swaps which
# column of the ElastiCache-managed/customer-managed pair applies to whatever the
# other two produced.
#
# On the HA attributes: num_cache_clusters = 2 is the minimum topology
# automatic_failover_enabled accepts and the cheapest that removes the single
# point of failure; multi_az_enabled is what forces the replica into a second AZ
# rather than leaving both nodes exposed to one AZ event. A caller who asked
# only for encryption stays at one node: TLS must not quietly also buy a second
# node and double the bill. Availability is a separate decision behind its own
# input.
#
# What HA buys is that the queue survives the node loss, NOT that n8n rides the
# failover out. Measured on a live cluster: promotion took ~20s, the queued
# executions were intact on the promoted node afterwards, and every main, worker
# and webhook pod exited and restarted while it happened. n8n's
# RedisClientService calls process.exit once Redis has been unreachable for
# QUEUE_BULL_REDIS_TIMEOUT_THRESHOLD; raising that to 30s was tried here and
# still fell short of this failover. A larger budget can ride one out, and
# wiring the threshold up is the follow-up in PR #77, so n8n's default is
# left alone here. See README ->
# "What this actually buys you, measured".
resource "aws_elasticache_replication_group" "n8n" {
  # checkov:skip=CKV2_AWS_50:Automatic failover and Multi-AZ are wired to var.redis_high_availability_enabled below, so this check passes for the caller who asks for high availability and fails only on the TLS-only shape, where it is describing the design rather than a defect. This one resource is selected by EITHER redis_high_availability_enabled OR redis_transit_encryption_enabled, and the two are deliberately independent: enabling transit encryption must not also add a second node and double the Redis bill. See the comment above this resource for the three reachable shapes. A caller who wants the failover this check asks for sets redis_high_availability_enabled = true, which is exactly what the input is for.
  # checkov:skip=CKV_AWS_30:Transit encryption is wired to var.redis_transit_encryption_enabled below (transit_encryption_enabled = local.redis_managed_tls_active), so this check passes for the caller who asks for it and fails only on the HA-only and CMK-only shapes, same "describing the design rather than a defect" reasoning as CKV2_AWS_50 above: a caller who wants transit encryption sets redis_transit_encryption_enabled = true, which is exactly what the input is for. On this module's own all-defaults path this resource does not even exist (count above), so the finding only ever describes a shape someone deliberately opted into.
  # checkov:skip=CKV_AWS_31:Same rationale and same resource as CKV_AWS_30 immediately above: the AUTH token rides on transit encryption (auth_token below is non-null only once redis_transit_encryption_mode = "required"), so this finding and CKV_AWS_30 always move together and are accepted for the same reason.
  count = var.create_elasticache && local.redis_needs_replication_group ? 1 : 0

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
  # The suffix is "-redis-rg" (replication group) rather than "-redis-ha" or
  # "-redis-tls" because both features select this one resource. A
  # topology-specific name would misdescribe it for half its callers, and
  # replication_group_id forces replacement, so a name corrected after release
  # would cost every early adopter their queue a second time.
  #
  # Length: replication group IDs cap at 40 characters. cluster_name is capped
  # at 14 by its own validation, so 14 + 9 = 23 leaves ample headroom.
  replication_group_id = "${local.cluster_name}-redis-rg"
  description          = var.redis_high_availability_enabled ? "n8n Bull queue and multi-main coordination (HA) for ${local.cluster_name}" : "n8n Bull queue and multi-main coordination for ${local.cluster_name}"

  engine         = "redis"
  engine_version = "7.1"
  node_type      = var.redis_node_type
  port           = 6379

  num_cache_clusters         = var.redis_high_availability_enabled ? 2 : 1
  automatic_failover_enabled = var.redis_high_availability_enabled
  multi_az_enabled           = var.redis_high_availability_enabled

  # transit_encryption_enabled is Optional+Computed on this resource, so the
  # HA-only path writing an explicit `false` matches what the API already
  # reports and produces no diff for anyone who enabled HA before this variable
  # existed. redis_managed_tls_active, not redis_tls_active: this argument
  # describes a property of the replication group this module itself manages,
  # and redis_tls_active also covers the external-Redis reporting path, which
  # has nothing to do with what this resource's own attribute should be.
  transit_encryption_enabled = local.redis_managed_tls_active
  auth_token                 = local.redis_auth_active ? random_password.redis_auth_token[0].result : null

  # Gated on the same variable as auth_token above, and for the same reason: the
  # argument describes a property of transit encryption, so writing it on a
  # plaintext group is at best noise. `null` is how the provider spells "not
  # set", which keeps the HA-only path's plan identical to what it was before
  # this argument existed.
  #
  # The default is "required", so a first-time create is TLS-only and nothing
  # here changes for a caller who is not migrating. What this exists for is the
  # other direction: AWS refuses to turn transit encryption on for a group that
  # already exists unless it passes through "preferred" first, and "preferred"
  # accepts TLS and plaintext simultaneously, which is what makes the pods'
  # cutover survivable. See README -> "Adding TLS to an existing replication
  # group".
  transit_encryption_mode = local.redis_transit_encryption_mode

  # Written as `? true : null` rather than passing the bool straight through so
  # that the default produces no diff at all for deployments that predate this
  # input. apply_immediately is a request-time flag rather than something the
  # API reports back, so a group created before this existed has it null in
  # state, and an explicit `false` would render as an in-place update on every
  # such deployment for a change that alters nothing.
  #
  # Required by AWS for any transit-encryption modification, which is why it is
  # an input at all rather than a constant. Left at the AWS default otherwise:
  # forcing it on globally would make unrelated modifications skip the
  # maintenance window the caller chose.
  apply_immediately = local.redis_apply_immediately

  # Declared so a later token change rotates (both the old and new token valid
  # during the roll) instead of cutting over instantly and breaking every pod
  # that has not yet been restarted with the new value.
  #
  # Gated on the same variable as auth_token, and NOT set unconditionally: the
  # provider rejects this argument outright when there is no token to rotate,
  # with `"auth_token_update_strategy": "auth_token" must be specified`. That
  # makes the HA-only path fail at plan time. Neither terraform validate nor
  # terraform test catches it, because the test framework's mocked provider does
  # not run the real provider's argument validation. A live plan does.
  auth_token_update_strategy = local.redis_auth_active ? "ROTATE" : null

  # Set here, in the commit that introduces this resource, precisely because it
  # is ForceNew. Adding it later would replace the cache for everyone who had
  # already enabled HA, which is the same trap replication_group_id above
  # carries. It costs nothing (ElastiCache-managed key, no KMS charge) and the
  # single-node aws_elasticache_cluster path has no equivalent argument, so the
  # default deployment is unaffected either way.
  #
  # This is at-rest only and is independent of transit encryption, which arrives
  # with redis_transit_encryption_enabled (#41).
  at_rest_encryption_enabled = true

  # null (the ElastiCache-managed key) unless redis_kms_encryption_enabled opts
  # into a module-managed CMK. This resource is always encrypted at rest; the
  # default standalone aws_elasticache_cluster above is not. ForceNew, like
  # replication_group_id above, so changing it on an existing replication group
  # replaces that group and drops the queue. Clears Checkov finding CKV_AWS_191.
  kms_key_id = local.redis_kms_key_arn

  # Same knob and same reasoning as the single-node cluster above. Set here too
  # so that turning on HA or TLS does not silently drop the daily snapshot the
  # default topology takes: the two resources are independent, and a caller who
  # left var.redis_snapshot_retention_limit alone did not ask for that.
  snapshot_retention_limit = var.redis_snapshot_retention_limit

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
      !var.redis_high_availability_enabled &&
      !var.redis_apply_immediately &&
      !var.redis_kms_encryption_enabled &&
      var.redis_snapshot_retention_limit == 1 &&
      var.redis_transit_encryption_mode == "required"
    )
    error_message = join("", [
      "redis_node_type, redis_high_availability_enabled, redis_apply_immediately, ",
      "redis_kms_encryption_enabled, redis_snapshot_retention_limit or ",
      "redis_transit_encryption_mode is set while create_elasticache = false. The module creates no ",
      "ElastiCache in that mode, so none of them apply. Sizing, failover, modification timing, at-rest ",
      "encryption, snapshot retention and the \"preferred\"/\"required\" migration lever are all ",
      "properties of the replication group the module itself manages; the Redis you supply via ",
      "redis_host has none of them. Its TLS and AUTH posture are controlled by ",
      "redis_transit_encryption_enabled, redis_auth_token and redis_username instead.",
    ])
  }
}

# redis_transit_encryption_mode is written only when transit encryption is on,
# so setting it while the feature is off silently does nothing. Worth a warning
# specifically because "preferred" is the migration lever: a caller who sets the
# mode intending to begin the migration, but has not yet set
# redis_transit_encryption_enabled, gets a clean apply that leaves Redis exactly
# as plaintext as it was. That reads like the first step succeeded.
# preferred is a state to pass through, not one to settle in, and settling in it
# is silent otherwise: the endpoint speaks TLS, the pods speak TLS, everything
# looks like the feature is on, and the cache is still reachable in cleartext by
# anything on the VPC with no credential at all. AWS will not accept an AUTH
# token in this mode, so a deployment parked here is encrypted and
# unauthenticated whether or not the caller meant it to be.
#
# Fires on every apply for as long as the mode is preferred, which is the point:
# during the migration it is a reminder that step two is outstanding, and
# afterwards it is the only thing that would ever say so.
check "redis_transit_encryption_mode_preferred_is_transitional" {
  assert {
    # Gated on redis_managed_tls_active, not redis_tls_active: this check is
    # about the module-managed replication group's migration lever
    # specifically, which has no meaning against an external Redis. With
    # transit encryption off, or on the external path, the mode reaches
    # nothing, so the sibling checks are the accurate complaint and this one
    # would only pile noise on top of them.
    condition = local.redis_managed_tls_active ? (
      var.redis_transit_encryption_mode != "preferred"
    ) : true
    error_message = join("", [
      "redis_transit_encryption_mode = \"preferred\" accepts plaintext AND TLS on the same endpoint, and ",
      "AWS refuses to put an AUTH token on a group in this mode, so Redis is currently reachable ",
      "unencrypted and unauthenticated from anywhere in the VPC. This is the intended middle step of the ",
      "migration in README -> \"Adding TLS to an existing replication group\", not a resting place: once ",
      "every pod has rolled onto TLS, set the mode back to \"required\" to close the plaintext listener ",
      "and let the AUTH token land.",
    ])
  }
}

check "redis_transit_encryption_mode_requires_transit_encryption" {
  assert {
    # Scoped to the module-managed path with the same nesting style as the
    # sibling checks in this file: create_elasticache = false is the accurate
    # complaint above (redis_tuning_requires_module_managed_elasticache), so
    # this one stays silent there rather than piling a second, less specific
    # warning on top of it.
    condition = var.create_elasticache ? (
      var.redis_transit_encryption_enabled ? true : (
        var.redis_transit_encryption_mode == "required"
      )
    ) : true
    error_message = join("", [
      "redis_transit_encryption_mode is set while redis_transit_encryption_enabled = false, so it is ",
      "ignored and Redis stays plaintext. The mode selects which clients an ENCRYPTED endpoint ",
      "accepts; it does not turn encryption on. If you are staging the migration described in README ",
      "-> \"Adding TLS to an existing replication group\", set redis_transit_encryption_enabled = true ",
      "in the same apply that sets the mode to \"preferred\".",
    ])
  }
}

# The reverse of external_redis_inputs_require_create_elasticache_false: a
# caller who supplies redis_auth_token expecting it to reach their own Redis
# gets it silently discarded instead, because the module generates and manages
# its own token on the ElastiCache it provisions and has no path to substitute
# a caller-supplied value there.
check "redis_auth_token_requires_external_redis" {
  assert {
    condition = var.create_elasticache ? var.redis_auth_token == null : true
    error_message = join("", [
      "redis_auth_token is set while create_elasticache = true, so it is ignored: the module generates ",
      "and manages its own AUTH token on the ElastiCache it provisions (see ",
      "redis_transit_encryption_enabled) and cannot put a caller-supplied credential on infrastructure ",
      "it owns. Set create_elasticache = false to use an external Redis with your own AUTH token.",
    ])
  }
}

# Same shape again for the ACL username, with one difference worth stating: this
# one is ignored because honouring it would be actively harmful, not merely
# meaningless. ElastiCache AUTH authenticates as Redis's default user and the
# service exposes no username, so sending one would break a connection that
# works. local.redis_username_value resolves it to null on this path so it
# reaches neither the chart nor the KEDA triggers.
check "redis_username_requires_external_redis" {
  assert {
    condition = var.create_elasticache ? var.redis_username == null : true
    error_message = join("", [
      "redis_username is set while create_elasticache = true, so it is ignored: ElastiCache AUTH has no ",
      "username concept, its token authenticates as Redis's default user, and passing a username on ",
      "this path would break a working connection rather than tighten it. Set create_elasticache = ",
      "false to use an external Redis 6+ endpoint that authenticates against a named ACL user.",
    ])
  }
}
