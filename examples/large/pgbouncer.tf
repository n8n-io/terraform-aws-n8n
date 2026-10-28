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
#   - Eight replicas with REQUIRED pod anti-affinity guarantee placement on
#     eight distinct nodes (a `preferred` rule was observed losing the race
#     against node-group startup ordering, co-locating replicas on the
#     first Ready node — a single-node failure would then have taken out
#     all n8n DB traffic). A PodDisruptionBudget with max_unavailable=1
#     keeps at least seven of eight replicas up during voluntary node
#     drains. Eight is also the client-connection budget:
#     MAX_CLIENT_CONN=3000 x 8 = 24,000, sized
#     for the fleet ceiling of ~9,200 (460 pods x pool_size 20; see the
#     capacity arithmetic in main.tf's Main pods comment).
#     **Measured 2026-10-17 (pre-release chart 2.0 build — the
#     n8n-io/n8n-hosting#250 tree, before `2.0.0-rc.1` was published; not
#     re-run on `2.0.0-rc.1` — synthetic 500ms-I/O workflow):**
#     the originally-shipped 4 replicas at `resources.limits.cpu = 500m`
#     each pegged 96-100% CPU around 700-1,000 exec/s — PgBouncer is
#     single-threaded (one process, up to ~1 vCPU per replica; the
#     deployed edoburu image has no SO_REUSEPORT multi-process supervisor,
#     so more cores per pod buy nothing past 1 vCPU, only more replicas
#     do), and that CPU ceiling was the tier's actual sustained-throughput
#     limiter, not Aurora or Redis (both stayed <=60% CPU at the same
#     load). Doubling to 8 replicas at `limits.cpu = 1000m` (per-replica
#     CPU never exceeds ~32% even at the new ceiling, confirmed via
#     `kubectl top pod` container metrics, not `SHOW POOLS`/`SHOW STATS`,
#     which report pool and transaction counters rather than CPU) raised the
#     CPU-bound ceiling roughly 1.5-1.6x, to ~950-1,000 req/s. Raising
#     `DEFAULT_POOL_SIZE` instead (tried 150->400) made throughput worse,
#     not better: `pg_stat_activity` during the failure showed ~95% of all
#     Aurora backends simultaneously blocked on `LWLock:BufferContent` — a
#     Postgres-internal buffer-page lock convoy, confirmed independent of
#     PgBouncer (every pool showed `cl_waiting=0`, never queuing clients)
#     and independent of webhook pod count (doubling `n8n_webhook_hpa_max_replicas`
#     to 160 cut the error rate at a fixed offered rate but did not fix
#     the latency collapse). A larger pool just let more backends pile
#     onto the same contended page. Aurora CPU (14-53%) and CommitLatency
#     (0.1-1.8ms) stayed low throughout, so the ~950-1,000 req/s ceiling is
#     not an Aurora capacity limit either — it is Postgres-internal lock
#     contention this example's schema/write pattern runs into above
#     roughly 1,000 req/s, and raising replica count, pool size or webhook
#     pod count does not move it. The exact contended relation was not
#     identified (the live window closed before a `pg_locks` join could
#     catch it); treat ~950-1,000 req/s as this tier's ceiling until that
#     investigation happens at the application/query level — outside
#     PgBouncer's reach. On the upstream leg, 8 x DEFAULT_POOL_SIZE 150 is
#     at most 1,200 server connections to Aurora at full pool saturation,
#     well under the ~5,000 max_connections of a db.r6g.8xlarge (the
#     formula-derived value, confirmed via `SHOW max_connections`).
#   - STATS_USERS=n8n (same credential as DB_USER/DB_PASSWORD, no separate
#     secret) makes `SHOW POOLS`/`STATS`/`CLIENTS`/`SERVERS` reachable
#     against the `pgbouncer` admin pseudo-database from an in-cluster psql
#     client — required for the pool diagnosis above; per-replica CPU came
#     from `kubectl top` / container metrics instead, since PgBouncer's
#     `SHOW` commands report pool and transaction counters, not CPU.
#     `stats_users` (not `admin_users`) is enough here: PgBouncer's console
#     access control lets `stats_users` run every `SHOW` command except
#     `SHOW FDS`, so it does not need `admin_users`' broader console rights
#     (`PAUSE`/`SUSPEND`/`RESUME`/`SHUTDOWN`/`RELOAD`/`SET`/`KILL`), which
#     every n8n pod holding this credential would otherwise also get.
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
    replicas = 8

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

          # CKV_K8S_10/11/12/13: pgbouncer is single-threaded (one process
          # per pod, no SO_REUSEPORT multi-process supervisor in this
          # image), so a CPU limit above ~1 vCPU buys nothing — only more
          # replicas raise the ceiling. 500m pegged 96-100% around
          # 700-1,000 exec/s (see the top-of-file comment); 1000m keeps
          # per-replica usage under ~32% at this tier's measured ceiling.
          resources {
            requests = {
              cpu    = "600m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "1000m"
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
          env {
            name  = "STATS_USERS"
            value = "n8n"
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

# PodDisruptionBudget so voluntary node drains can never take more than one
# pgbouncer replica down at a time, regardless of replica count: drains will
# wait once one replica is already unavailable.
resource "kubernetes_pod_disruption_budget_v1" "pgbouncer" {
  metadata {
    name      = "pgbouncer"
    namespace = kubernetes_namespace.pgbouncer.metadata[0].name
  }

  spec {
    max_unavailable = 1
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
