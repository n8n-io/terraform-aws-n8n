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
# n8n_chart_version.

locals {
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
