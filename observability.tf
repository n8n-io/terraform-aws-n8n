# ── Redis exporter (opt-in) ───────────────────────────────────────────────────
# Bull queue depth is the signal KEDA scales workers on, and it is the first
# thing anyone asks for during an incident. n8n's own /metrics does expose a
# queue gauge, but it does not work in multi-main topologies, which is every
# tier example this module ships: only the leader main reports, so the figure
# is wrong rather than missing, which is worse. Redis itself is the source of
# truth, and this exporter is the supported way to read it from inside the
# cluster (queue depth, eviction counts, engine load, connected clients).
#
# Off by default. redis_exporter_enabled = false creates none of it, which is
# also why this is a plain Deployment rather than anything the n8n chart
# renders: the chart has no exporter of its own to enable.
#
# The exporter reads the same endpoint and the same AUTH token n8n itself
# uses, so it cannot drift from the queue n8n is actually running on. It does
# not scrape anything; a Prometheus that already discovers pods by annotation
# picks it up from the pod annotations below, and a Prometheus Operator setup
# points a ServiceMonitor at the Service.
#
# NOTE ON THE CHECKOV GATE: checkov registers its CKV_K8S_* Terraform checks
# against the UNSUFFIXED resource names (kubernetes_deployment,
# kubernetes_service) and has none for the _v1 variants used here, so a clean
# checkov run says nothing at all about this file: measured on the pinned
# 3.3.9, examples/large/pgbouncer.tf's kubernetes_deployment draws 27 checks
# while this Deployment draws zero. The _v1 names are kept anyway, because the
# module root uses versioned names throughout (kubernetes_ingress_v1,
# kubernetes_service_account_v1, kubernetes_horizontal_pod_autoscaler_v2), and
# picking an older name to be seen by a scanner is the wrong trade. The pod
# hardening below is therefore written to satisfy those checks by hand rather
# than because the gate demanded it: dropped capabilities, no privilege
# escalation, a read-only root filesystem, an explicit non-root UID, a memory
# limit, and both probes. Keep it that way when editing this file, since
# nothing in CI will tell you if it regresses.

resource "kubernetes_deployment_v1" "redis_exporter" {
  count = var.redis_exporter_enabled ? 1 : 0

  metadata {
    name = "redis-exporter"
    # local.namespace_name, not var.namespace: on the create_namespace path
    # this resolves to the namespace resource's own attribute, which is what
    # puts an edge into the graph and stops the Deployment being created
    # before the namespace exists. See AGENTS.md on mocks not enforcing
    # dependency ordering.
    namespace = local.namespace_name
    labels = {
      "app"                          = "redis-exporter"
      "app.kubernetes.io/name"       = "redis-exporter"
      "app.kubernetes.io/component"  = "metrics"
      "app.kubernetes.io/part-of"    = "n8n"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    # One replica deliberately. Two would double every counter a naive
    # Prometheus query sums, and there is nothing to fail over to: the
    # exporter holds no state and a restart re-reads Redis from scratch.
    replicas = 1

    selector {
      match_labels = { "app" = "redis-exporter" }
    }

    template {
      metadata {
        labels = { "app" = "redis-exporter" }

        # The annotation-based scrape convention. Harmless when the cluster's
        # Prometheus uses ServiceMonitors instead: nothing reads them.
        annotations = {
          "prometheus.io/scrape" = "true"
          "prometheus.io/port"   = "9121"
          "prometheus.io/path"   = "/metrics"
        }
      }

      spec {
        container {
          name  = "redis-exporter"
          image = var.redis_exporter_image

          # rediss:// when the endpoint speaks TLS. local.redis_tls_active is
          # the same local n8n and KEDA read, so the exporter cannot end up
          # with a different view of the endpoint than the workloads have.
          #
          # Certificate verification is deliberately left on, and the two
          # things that would break it were checked against the exporter
          # rather than assumed. Its image copies /etc/ssl/certs in from the
          # builder stage, so the Amazon Root CA that signs ElastiCache
          # certificates is present (a scratch image without it would fail
          # every TLS connection, which is the usual cause of this class of
          # bug). And REDIS_EXPORTER_TLS_SERVER_NAME is only needed when the
          # certificate name differs from the dialled address, which it does
          # not here on the module-managed path: local.redis_host is the
          # replication group's own AWS endpoint, and ElastiCache certificates
          # cover that name.
          #
          # The case that DOES need it is external Redis (create_elasticache =
          # false) where redis_host is a friendly CNAME pointing at an
          # ElastiCache FQDN: the certificate then names the target, not the
          # alias, and verification fails. The fix there is
          # REDIS_EXPORTER_TLS_SERVER_NAME set to the underlying endpoint
          # hostname, never REDIS_EXPORTER_SKIP_TLS_VERIFICATION. Not wired as
          # an input until someone hits it; see redis_exporter_image.
          env {
            name  = "REDIS_ADDR"
            value = "${local.redis_tls_active ? "rediss" : "redis"}://${local.redis_host}:${local.redis_port}"
          }

          # Bull queue depth, which is the whole reason this exporter exists.
          # It does NOT come for free: the default metric set is built from
          # Redis INFO, which carries aggregate database statistics and no
          # per-key lengths at all, so without this the exporter would export
          # everything EXCEPT the number anyone turned it on for.
          #
          # check-single-keys names exact keys rather than patterns, so it
          # costs one O(1) LLEN per key per scrape and never scans the keyspace
          # (check-keys takes glob patterns and can SCAN, which is not
          # something to point at a production queue). Each key is exported as
          # redis_key_size{key="..."}.
          #
          # The two keys are the same pair the KEDA ScaledObject already scales
          # on, built from the same local, so the exporter and the autoscaler
          # cannot end up watching different lists: :jobs:wait is the backlog
          # KEDA reacts to, :jobs:active is what workers currently hold. If
          # redis_key_prefix changes, all four call sites move together.
          env {
            name  = "REDIS_EXPORTER_CHECK_SINGLE_KEYS"
            value = "${local.redis_key_prefix_value}:jobs:wait,${local.redis_key_prefix_value}:jobs:active"
          }

          # ACL username, external Redis only (local.redis_username_value is
          # null whenever the module manages the cluster). Same treatment as
          # redis.username in the Helm values: not a credential, so it is a
          # literal rather than a Secret reference.
          dynamic "env" {
            for_each = local.redis_username_value != null ? [1] : []
            content {
              name  = "REDIS_USER"
              value = local.redis_username_value
            }
          }

          # AUTH token from the same Secret the chart mounts as
          # QUEUE_BULL_REDIS_PASSWORD. name/key mirror the redis.passwordSecret
          # block in n8n.tf exactly: the module-managed
          # kubernetes_secret.n8n_redis by default, or the caller's own Secret
          # when redis_auth_token_secret_ref is set, in which case the module
          # never reads the value and neither does this.
          dynamic "env" {
            for_each = local.redis_auth_active ? [1] : []
            content {
              name = "REDIS_PASSWORD"
              value_from {
                secret_key_ref {
                  name = var.redis_auth_token_secret_ref != null ? var.redis_auth_token_secret_ref.name : kubernetes_secret.n8n_redis[0].metadata[0].name
                  key  = var.redis_auth_token_secret_ref != null ? local.redis_auth_token_secret_ref_key : "password"
                }
              }
            }
          }

          port {
            name           = "metrics"
            container_port = 9121
          }

          # The exporter holds no state and does no work between scrapes, so
          # these are deliberately small. Memory is capped but CPU is not:
          # a throttled exporter reports late during exactly the incident it
          # exists for, and one pod without a CPU limit cannot starve a node.
          resources {
            requests = {
              cpu    = "10m"
              memory = "32Mi"
            }
            limits = {
              memory = "64Mi"
            }
          }

          # Both probes hit /metrics rather than a dedicated health path: the
          # exporter's readiness IS its ability to answer a scrape, and it
          # answers on /metrics even while Redis is unreachable (the
          # redis_up gauge goes to 0), so a Redis outage does not also delete
          # the only thing that could tell you about it.
          liveness_probe {
            http_get {
              path = "/metrics"
              port = 9121
            }
            initial_delay_seconds = 10
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 3
          }

          readiness_probe {
            http_get {
              path = "/metrics"
              port = 9121
            }
            initial_delay_seconds = 5
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 3
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = true
            # 59000 is the UID the upstream image already declares
            # (USER 59000:59000 in its Dockerfile), so this matches it rather
            # than overriding it.
            #
            # Note what pinning the UID actually does, since it is easy to get
            # backwards: run_as_user WINS over the image's own USER, so this
            # decides the UID outright and run_as_non_root can no longer reject
            # an image that would otherwise have run as root. That is the
            # trade. It buys a container that starts predictably whatever a
            # mirrored or rebuilt image declares, and it costs the ability to
            # detect such a rebuild through the non-root check. The consequence
            # for anyone overriding redis_exporter_image: the container runs as
            # 59000 regardless, so a custom image has to work as that UID.
            # Documented on the variable too.
            #
            # The exporter reads a socket and writes nothing, so it needs no
            # writable filesystem either.
            run_as_user = 59000
            capabilities {
              drop = ["ALL"]
            }
          }
        }
      }
    }
  }

  # local.namespace_name only carries an ordering edge on the create_namespace
  # path, where it resolves to the namespace resource's own attribute. With
  # create_namespace = false it is a plain literal, leaving these resources
  # with no edge to the node group at all: on a first apply they can be
  # scheduled before any node exists. Every other kubernetes_* resource in this
  # module carries the same explicit depends_on for exactly this reason (see
  # kubernetes_secret.n8n_redis in n8n.tf).
  depends_on = [aws_eks_node_group.n8n]
}

resource "kubernetes_service_v1" "redis_exporter" {
  count = var.redis_exporter_enabled ? 1 : 0

  metadata {
    name      = "redis-exporter"
    namespace = local.namespace_name
    labels = {
      "app"                          = "redis-exporter"
      "app.kubernetes.io/name"       = "redis-exporter"
      "app.kubernetes.io/component"  = "metrics"
      "app.kubernetes.io/part-of"    = "n8n"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    selector = { "app" = "redis-exporter" }

    port {
      name        = "metrics"
      port        = 9121
      target_port = 9121
      protocol    = "TCP"
    }
  }

  # Same reasoning as the Deployment above.
  depends_on = [aws_eks_node_group.n8n]
}
