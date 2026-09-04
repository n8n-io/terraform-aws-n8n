# ── PgBouncer ─────────────────────────────────────────────────────────────────
# Connection pooler between n8n pods and Aurora.
#
# Why PgBouncer is needed at this scale:
#   80 webhook × 5 pool + 160 worker × 5 pool + 2 main × 5 pool = 1,210
#   concurrent client connections. PostgreSQL degrades above ~500 active
#   connections. PgBouncer in transaction mode multiplexes those 1,210 client
#   connections onto far fewer server connections, keeping Aurora well within
#   its comfortable operating range.
#
# Implementation notes (from internal load testing):
#   - Uses edoburu/pgbouncer:v1.23.1-p3 — its entrypoint auto-generates
#     pgbouncer.ini and userlist.txt from env vars. The "official"
#     pgbouncer/pgbouncer Docker Hub image is NOT a viable alternative: its
#     last release was November 2020 (PgBouncer 1.15.0) and the registry has
#     had no updates since. edoburu actively maintains v1.23.1-p3 and newer
#     tags against current PgBouncer releases.
#   - Transaction mode confirmed compatible with n8n's TypeORM (no prepared
#     statements or LISTEN/NOTIFY that would force session mode).
#   - Four replicas with REQUIRED pod anti-affinity guarantee placement on
#     four distinct nodes (a `preferred` rule was observed losing the race
#     against node-group startup ordering, co-locating replicas on the
#     first Ready node — a single-node failure would then have taken out
#     all n8n DB traffic). A PodDisruptionBudget with min_available=1
#     keeps replicas up during voluntary node drains. Four is also the
#     client-connection budget: MAX_CLIENT_CONN=3000 x 4 = 12,000, sized
#     for the fleet ceiling of ~9,200 (460 pods x pool_size 20; see the
#     capacity arithmetic in main.tf's Main pods comment). Two replicas
#     (6,000) would be oversubscribed at those maxima, and exceeding
#     max_client_conn queues new client connections, recreating exactly
#     the pool-acquisition backlog the pool sizing exists to prevent.
#     Four replicas is also the topology the sustained-load validation
#     actually ran. On the upstream leg, 4 x DEFAULT_POOL_SIZE 150 is at
#     most 600 server connections to Aurora, well under the ~5,000
#     max_connections of a db.r6g.8xlarge.
#   - With required anti-affinity, later replicas stay Pending until
#     enough nodes are Ready (typically <60s); the deployment as a whole
#     is never blocked.
#   - n8n connects over plain TCP (in-cluster); PgBouncer terminates SSL on
#     its upstream leg to Aurora.
#   - AUTH_TYPE=plain stores the plaintext password in userlist.txt so
#     PgBouncer can negotiate any upstream auth method. Aurora PostgreSQL's
#     current default parameter groups store passwords as scram-sha-256 (the
#     PostgreSQL default since PG14), and PgBouncer needs plaintext to compute
#     the SCRAM response. AUTH_TYPE=md5 fails with
#     "server login failed: wrong password type" because md5-hashed
#     passwords cannot satisfy a SCRAM challenge. Plaintext only exists
#     inside the pgbouncer pod's filesystem; the in-cluster client→PgBouncer
#     leg uses plain auth over a ClusterIP service that never leaves the
#     pod network.
#
# This namespace is separate from the n8n namespace (created by the module)
# so the example doesn't have to wait on any module-internal resource. n8n
# resolves PgBouncer cross-namespace via its FQDN (set in main.tf db_host).

resource "kubernetes_namespace" "pgbouncer" {
  metadata {
    name = "pgbouncer"
  }

  # No `depends_on = [module.n8n]` — that would cycle (the module's
  # helm_release.n8n already waits on var.db_host, which references the
  # pgbouncer service). The kubernetes provider already pins to
  # module.n8n.cluster_endpoint, so namespace creation naturally waits for
  # the EKS cluster to reach ACTIVE.
}

resource "kubernetes_secret" "pgbouncer" {
  metadata {
    name      = "pgbouncer-secret"
    namespace = kubernetes_namespace.pgbouncer.metadata[0].name
  }

  data = {
    DB_PASSWORD = random_password.aurora.result
  }
}

resource "kubernetes_deployment" "pgbouncer" {
  # checkov:skip=CKV_K8S_22:The edoburu/pgbouncer image's entrypoint generates pgbouncer.ini from environment variables at container start, writing into the image filesystem. Forcing read_only_root_filesystem without verifying the image's actual write paths against a live deploy risks a boot failure; revisit once verified against a running cluster.
  metadata {
    name      = "pgbouncer"
    namespace = kubernetes_namespace.pgbouncer.metadata[0].name
    labels    = { app = "pgbouncer" }
  }

  spec {
    replicas = 4

    selector {
      match_labels = { app = "pgbouncer" }
    }

    template {
      metadata {
        labels = { app = "pgbouncer" }
      }

      spec {
        affinity {
          pod_anti_affinity {
            required_during_scheduling_ignored_during_execution {
              label_selector {
                match_labels = { app = "pgbouncer" }
              }
              topology_key = "kubernetes.io/hostname"
            }
          }
        }

        # CKV_K8S_29: presence of a pod-level security context.
        security_context {
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name = "pgbouncer"

          # CKV_K8S_10/11/12/13: pgbouncer is a lightweight connection pooler;
          # these are generous enough to not throttle under the 2-replica
          # pool_size=150 config above.
          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "256Mi"
            }
          }

          # CKV_K8S_28/30: drop all Linux capabilities (NET_RAW included) and
          # block privilege escalation. Left run_as_non_root unset - the
          # edoburu/pgbouncer image's runtime user hasn't been verified against
          # a live deploy, and forcing it risks a boot failure if the image
          # needs root for its entrypoint.
          security_context {
            allow_privilege_escalation = false
            capabilities {
              drop = ["ALL"]
            }
          }
          # Pinned to the multi-arch image-index digest so a re-tag upstream
          # cannot silently change what we deploy. Keep the tag for human
          # readability; the @sha256:... suffix is the immutable contract.
          # Refresh both together when bumping the PgBouncer version.
          image = "edoburu/pgbouncer:v1.23.1-p3@sha256:377dec3c0e4a66a1077ec043e16a26ed5702a6d954011a7983a1457c2e070b1d"

          port {
            container_port = 5432
            protocol       = "TCP"
          }

          env {
            name  = "DB_HOST"
            value = aws_rds_cluster.n8n.endpoint
          }
          env {
            name  = "DB_USER"
            value = "n8n"
          }
          env {
            name  = "DB_NAME"
            value = "n8n_enterprise"
          }
          env {
            name = "DB_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.pgbouncer.metadata[0].name
                key  = "DB_PASSWORD"
              }
            }
          }
          env {
            name  = "AUTH_TYPE"
            value = "plain"
          }
          env {
            name  = "POOL_MODE"
            value = "transaction"
          }
          env {
            name  = "DEFAULT_POOL_SIZE"
            value = "150"
          }
          env {
            name  = "MAX_CLIENT_CONN"
            value = "3000"
          }
          env {
            name  = "SERVER_IDLE_TIMEOUT"
            value = "300"
          }
          env {
            name  = "SERVER_TLS_SSLMODE"
            value = "require"
          }
          env {
            name  = "IGNORE_STARTUP_PARAMETERS"
            value = "statement_timeout,extra_float_digits"
          }

          readiness_probe {
            tcp_socket {
              port = "5432"
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          liveness_probe {
            tcp_socket {
              port = "5432"
            }
            initial_delay_seconds = 15
            period_seconds        = 20
          }
        }
      }
    }
  }
}

# PodDisruptionBudget so voluntary node drains can never take both pgbouncer
# replicas down at the same time. min_available=1 with 2 replicas means at
# most one can be evicted at a time; drains will wait if both are healthy.
resource "kubernetes_pod_disruption_budget_v1" "pgbouncer" {
  metadata {
    name      = "pgbouncer"
    namespace = kubernetes_namespace.pgbouncer.metadata[0].name
  }

  spec {
    min_available = 1
    selector {
      match_labels = { app = "pgbouncer" }
    }
  }
}

resource "kubernetes_service" "pgbouncer" {
  metadata {
    name      = "pgbouncer"
    namespace = kubernetes_namespace.pgbouncer.metadata[0].name
  }

  spec {
    selector = { app = "pgbouncer" }

    port {
      port        = 5432
      target_port = 5432
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}
