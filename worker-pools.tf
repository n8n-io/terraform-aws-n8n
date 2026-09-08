# ── Worker pools ──────────────────────────────────────────────────────────────
# Maps var.n8n_worker_pools onto the chart's queueMode.workerGroups, which
# renders one worker Deployment per pool plus a KEDA ScaledObject watching that
# pool's own `jobs-<name>` queue.
#
# The module keeps its own input shape rather than passing the chart's through
# verbatim: pool names are validated at plan time (see variables.tf), the
# per-pool sizing knobs fall back to the module-wide worker defaults instead of
# the chart's, and a pool here is always a pool, whereas a chart worker group
# without a poolName is just an extra unlabelled worker deployment.
#
# Requires a chart version whose queueMode.workerGroups exists. See
# n8n_chart_version and the two checks at the bottom of this file.

locals {
  # First released chart that renders queueMode.workerGroups. PLACEHOLDER: at
  # the time of writing the feature is an open PR (n8n-io/n8n-hosting#189)
  # against the chart's preview/worker-pools branch, no published version
  # carries it (1.11.0 is the newest, and does not), and release-please cuts a
  # minor for a feat, so 1.12.0 is the earliest plausible number. Replace with
  # the real version when the chart ships, and drop the prerelease clause in
  # the check below if the preview line is retired with it.
  n8n_worker_pools_min_chart_version = "1.12.0"

  # First n8n release that reads N8N_WORKER_POOLS_ENABLED and
  # N8N_WORKER_POOL_NAME (packages/@n8n/config, scaling-mode.config.ts, first
  # tagged in n8n@2.39.0). Older images accept both variables and ignore them:
  # mains never route to a pool and pool workers consume the default queue.
  n8n_worker_pools_min_n8n_minor = 39

  # Semver core of n8n_chart_version, or null for a prerelease (anything with a
  # hyphen, e.g. 1.11.0-preview.workerpools.1). Helm never resolves a
  # prerelease unless the caller names it exactly, so a prerelease here is a
  # deliberate choice and the version check below takes the caller's word.
  n8n_chart_version_core = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.n8n_chart_version)) ? [
    for part in split(".", var.n8n_chart_version) : tonumber(part)
  ] : null

  n8n_worker_pools_min_chart_version_core = [
    for part in split(".", local.n8n_worker_pools_min_chart_version) : tonumber(part)
  ]

  # Lexicographic compare on [major, minor, patch]. Weighted arithmetic would be
  # shorter but breaks silently past 99 in any position.
  n8n_chart_renders_worker_pools = local.n8n_chart_version_core == null ? true : (
    local.n8n_chart_version_core[0] != local.n8n_worker_pools_min_chart_version_core[0]
    ? local.n8n_chart_version_core[0] > local.n8n_worker_pools_min_chart_version_core[0]
    : local.n8n_chart_version_core[1] != local.n8n_worker_pools_min_chart_version_core[1]
    ? local.n8n_chart_version_core[1] > local.n8n_worker_pools_min_chart_version_core[1]
    : local.n8n_chart_version_core[2] >= local.n8n_worker_pools_min_chart_version_core[2]
  )

  n8n_worker_groups = [
    for p in var.n8n_worker_pools : {
      # One group per pool, and the group is the pool: the chart allows a group
      # with no poolName (extra workers on the default queue), but this module
      # has n8n_worker_keda_{min,max}_replicas for sizing the default workers
      # and does not need a second way to do it.
      name     = p.name
      poolName = p.name

      concurrency = coalesce(p.concurrency, var.n8n_worker_concurrency)
      extraEnv    = p.extra_env

      resources = {
        requests = {
          cpu    = coalesce(p.cpu_request, var.n8n_worker_cpu_request)
          memory = coalesce(p.memory_request, var.n8n_worker_memory_request)
        }
        limits = {
          cpu    = coalesce(p.cpu_limit, var.n8n_worker_cpu_limit)
          memory = coalesce(p.memory_limit, var.n8n_worker_memory_limit)
        }
      }

      keda = {
        minReplicaCount = p.min_replicas
        maxReplicaCount = p.max_replicas
        # Same threshold the module gives the default worker's scaler, so a
        # pool's queue depth is read on the same scale as the default queue's.
        jobsPerReplica = var.n8n_worker_keda_jobs_per_replica

        # The same TLS and AUTH metadata the default worker's two triggers
        # carry (see the merge sites in n8n.tf). The chart builds a pool's
        # triggers itself from the queue name, so this is the only route the
        # metadata has into them, and without it a pool's scaler talks
        # plaintext to a TLS-only endpoint and the pool sits at min_replicas
        # with nothing crashing to announce it. Empty on a deployment without
        # transit encryption or AUTH, and the chart guards the block with
        # `with`, so it renders nothing on that path.
        #
        # Verified on a live TLS cluster, including the counterfactual: removing
        # enableTLS from one pool's triggers put its ScaledObject into
        # READY=False and logged `connection to redis failed: i/o timeout` in
        # the KEDA operator, and restoring it recovered. Those two are the
        # signals to trust. `kubectl get hpa` is not: its TARGETS column read
        # <unknown> for every worker HPA in both the healthy and the broken
        # state, so it gives a false alarm on a working release and false
        # reassurance on a broken one. The metric itself resolves through
        # /apis/external.metrics.k8s.io.
        triggerMetadata = local.keda_redis_auth_metadata
      }
    }
  ]
}

# ── Guards ────────────────────────────────────────────────────────────────────
# Both of these exist because the failure they catch is silent in every other
# place it could be caught. A chart that predates queueMode.workerGroups has no
# additionalProperties: false on queueMode, so Helm accepts the key, renders
# nothing for it, and the release succeeds: N8N_WORKER_POOLS_ENABLED lands on
# every pod, no pool Deployment or ScaledObject exists, and every project
# pinned to a pool quietly runs on the default queue. Mocked plan-time tests
# cannot see any of that, and neither can a real plan; only counting the
# rendered Deployments after apply can (tests/scripts/verify-worker-pools.sh).
#
# These are checks rather than validations because n8n_chart_repository can
# point at a private mirror whose version strings this module cannot reason
# about, and a caller running a preview build should be able to proceed past a
# warning rather than fight a hard stop.

check "worker_pools_require_a_chart_that_renders_them" {
  assert {
    condition = length(var.n8n_worker_pools) > 0 ? local.n8n_chart_renders_worker_pools : true
    error_message = join("", [
      "n8n_worker_pools declares ${length(var.n8n_worker_pools)} pool(s) but n8n_chart_version = \"${var.n8n_chart_version}\" ",
      "predates queueMode.workerGroups (first released in ${local.n8n_worker_pools_min_chart_version}). ",
      "That chart accepts the key and renders nothing for it, so the release would apply cleanly with ",
      "N8N_WORKER_POOLS_ENABLED switched on and no pool Deployment or ScaledObject behind it, and every ",
      "project pinned to a pool would run on the default queue. Pin n8n_chart_version to ",
      "${local.n8n_worker_pools_min_chart_version} or later, or to a prerelease build that carries the ",
      "feature (a version with a hyphen is taken at your word), or remove the pools.",
    ])
  }
}

check "worker_pools_require_n8n_2_39" {
  assert {
    condition = length(var.n8n_worker_pools) > 0 && var.n8n_image_tag != null ? (
      can(regex("^[0-9]+\\.[0-9]+\\.", var.n8n_image_tag)) ? (
        tonumber(split(".", var.n8n_image_tag)[0]) > 2 ? true : (
          tonumber(split(".", var.n8n_image_tag)[0]) == 2
          ? tonumber(split(".", var.n8n_image_tag)[1]) >= local.n8n_worker_pools_min_n8n_minor
          : false
        )
      ) : true
    ) : true
    error_message = join("", [
      "n8n_worker_pools is set but n8n_image_tag is pinned to \"${coalesce(var.n8n_image_tag, "null")}\", ",
      "which predates worker pools (n8n >= 2.${local.n8n_worker_pools_min_n8n_minor}). Older images accept ",
      "N8N_WORKER_POOLS_ENABLED and N8N_WORKER_POOL_NAME and ignore both: mains never route to a pool and ",
      "pool workers consume the default queue, so the pods come up healthy and the feature does nothing. ",
      "Pin n8n_image_tag to 2.${local.n8n_worker_pools_min_n8n_minor}.0 or later. Leaving it null selects ",
      "the chart's floating `stable` tag, which this check cannot see; confirm that tag is new enough ",
      "before relying on it.",
    ])
  }
}
