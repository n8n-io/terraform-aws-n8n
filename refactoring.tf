# ── State refactoring ─────────────────────────────────────────────────────────
# Every `moved` block in the module lives here rather than beside the resource
# it renames. Collecting them makes the upgrade surface reviewable in a single
# diff: what a consumer needs to know before bumping the module version is
# exactly this file.
#
# `moved` blocks are declarative and position-independent, so relocating them
# from the resource files changes nothing about how Terraform applies them.
#
# Do not delete entries. A consumer upgrading across several releases at once
# replays the whole chain, so removing an old block turns an in-place upgrade
# into a destroy and recreate for anyone who skipped that version.

# ── Adding count to previously unconditional resources ────────────────────────
# Gating a resource on a `create_*` toggle changes its address from `.n8n` to
# `.n8n[0]`. Without these, existing deployments plan a destroy and recreate.

# create_database (0.2.0). Skipped when the caller supplies an external
# database, e.g. an Aurora cluster created in the example folder.
moved {
  from = aws_db_subnet_group.n8n
  to   = aws_db_subnet_group.n8n[0]
}

moved {
  from = aws_db_instance.n8n
  to   = aws_db_instance.n8n[0]
}

# create_ingress. Recreating this one would also tear down the ALB the Load
# Balancer Controller provisioned for it, so the block matters more than most.
moved {
  from = kubernetes_ingress_v1.n8n
  to   = kubernetes_ingress_v1.n8n[0]
}

# create_elasticache. Skipped when the caller points n8n at an external Redis,
# e.g. one endpoint shared between regions in a cross-region HA/DR topology.
#
# These three cover the default path only, where the Redis tier stays a
# single-node cluster. There is deliberately no block for the replication group
# redis_high_availability_enabled = true creates: `moved` cannot bridge two
# different resource types, so that switch is a destroy and recreate no matter
# how it is written. See redis.tf and README → "Redis high availability".
moved {
  from = aws_security_group.redis
  to   = aws_security_group.redis[0]
}

moved {
  from = aws_elasticache_subnet_group.n8n
  to   = aws_elasticache_subnet_group.n8n[0]
}

moved {
  from = aws_elasticache_cluster.n8n
  to   = aws_elasticache_cluster.n8n[0]
}
