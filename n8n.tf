# ── Encryption key ────────────────────────────────────────────────────────────

resource "random_id" "n8n_encryption_key" {
  byte_length = 32
}

# ── Task runner auth token ─────────────────────────────────────────────────────
# Generated once and stored in state. Used as the shared secret between the n8n
# task broker (port 5679) and the runner sidecars on main and worker pods.
# Only active when n8n_task_runners_enabled = true.

resource "random_password" "task_runner_token" {
  length  = 32
  special = false
}

# ── Namespace ─────────────────────────────────────────────────────────────────

resource "kubernetes_namespace" "n8n" {
  metadata {
    name = var.namespace
  }

  timeouts {
    delete = "2m"
  }

  depends_on = [aws_eks_node_group.n8n]
}

# ── Secrets ───────────────────────────────────────────────────────────────────
# Multi-main needs two secrets: one for core n8n config, one for the DB password.

resource "kubernetes_secret" "n8n" {
  metadata {
    name      = "n8n-enterprise-secrets"
    namespace = kubernetes_namespace.n8n.metadata[0].name
  }

  data = {
    N8N_ENCRYPTION_KEY = random_id.n8n_encryption_key.hex
    N8N_HOST           = local.n8n_domain
    N8N_PORT           = "5678"
    N8N_PROTOCOL       = "http"
    WEBHOOK_URL        = coalesce(var.n8n_webhook_url, "https://${local.n8n_domain}")
  }
}

resource "kubernetes_secret" "n8n_db" {
  metadata {
    name      = "n8n-enterprise-db-secret"
    namespace = kubernetes_namespace.n8n.metadata[0].name
  }

  data = {
    # Use caller-supplied password when an external DB is provided, otherwise use the generated one.
    password = var.create_database ? random_password.db_password.result : var.db_password
  }
}

# ── Helm release ──────────────────────────────────────────────────────────────

resource "helm_release" "n8n" {
  name            = "n8n"
  repository      = "oci://ghcr.io/n8n-io/n8n-helm-chart"
  chart           = "n8n"
  version         = var.n8n_chart_version
  namespace       = kubernetes_namespace.n8n.metadata[0].name
  wait            = true
  timeout         = var.n8n_helm_timeout
  atomic          = true
  cleanup_on_fail = true

  values = [yamlencode({
    license = {
      enabled       = true
      activationKey = var.n8n_license_key
    }

    multiMain = {
      enabled  = true
      replicas = 2
      antiAffinity = {
        type = "preferred"
      }
    }

    queueMode = {
      enabled            = true
      workerReplicaCount = 2
      workerConcurrency  = var.n8n_worker_concurrency
    }

    webhookProcessor = {
      enabled                                = true
      replicaCount                           = 2
      disableProductionWebhooksOnMainProcess = true
    }

    database = {
      type        = "postgresdb"
      useExternal = true
      # Module-managed RDS when create_database = true, otherwise the caller-supplied
      # db_host (which may point at an external DB or an in-cluster connection pooler).
      host     = var.create_database ? aws_db_instance.n8n[0].address : var.db_host
      port     = 5432
      database = "n8n_enterprise"
      schema   = "public"
      user     = "n8n"
      passwordSecret = {
        name = kubernetes_secret.n8n_db.metadata[0].name
        key  = "password"
      }
    }

    redis = {
      enabled     = true
      useExternal = true
      host        = aws_elasticache_cluster.n8n.cache_nodes[0].address
      port        = 6379
      tls         = false
    }

    s3 = {
      enabled = true
      bucket = {
        name   = aws_s3_bucket.n8n.bucket
        region = local.aws_region
      }
      auth = { autoDetect = true }
      storage = {
        mode           = "s3"
        availableModes = "filesystem,s3"
      }
    }

    # S3 credentials are injected by EKS Pod Identity (s3.tf).
    # awsRoleArn is provided only to satisfy the chart's template validation —
    # the actual auth comes from the Pod Identity agent, not IRSA.
    serviceAccount = {
      create     = true
      name       = "n8n-enterprise"
      awsRoleArn = aws_iam_role.s3.arn
    }

    secretRefs = {
      existingSecret = kubernetes_secret.n8n.metadata[0].name
    }

    service = {
      type = "ClusterIP"
      port = 5678
    }

    hpa = {
      main = {
        enabled                        = true
        minReplicas                    = var.n8n_main_hpa_min_replicas
        maxReplicas                    = var.n8n_main_hpa_max_replicas
        targetCPUUtilizationPercentage = var.n8n_main_hpa_cpu_threshold
      }
      webhookProcessor = {
        enabled                        = true
        minReplicas                    = var.n8n_webhook_hpa_min_replicas
        maxReplicas                    = var.n8n_webhook_hpa_max_replicas
        targetCPUUtilizationPercentage = var.n8n_webhook_hpa_cpu_threshold
      }
    }

    # ── KEDA: queue-depth autoscaling for workers ─────────────────────────────
    # Scales workers based on Redis queue depth rather than CPU — workers appear
    # only when there are jobs and scale in proportion to backlog.
    # Two triggers: bull:jobs:wait (queued jobs) + bull:jobs:active (jobs held by
    # workers waiting for a task runner). KEDA takes the MAX of both.
    # Webhook processor HPA is created externally in scaling.tf (chart skips it
    # when keda.enabled = true).
    keda = {
      enabled = true
      worker = {
        pollingInterval = 15
        cooldownPeriod  = 60
        minReplicaCount = var.n8n_worker_keda_min_replicas
        maxReplicaCount = var.n8n_worker_keda_max_replicas
        triggers = [
          {
            type = "redis"
            metadata = {
              address    = "${aws_elasticache_cluster.n8n.cache_nodes[0].address}:6379"
              listName   = "bull:jobs:wait"
              listLength = tostring(var.n8n_worker_keda_jobs_per_replica)
            }
            authenticationRef = { name = "" }
          },
          {
            type = "redis"
            metadata = {
              address    = "${aws_elasticache_cluster.n8n.cache_nodes[0].address}:6379"
              listName   = "bull:jobs:active"
              listLength = tostring(var.n8n_worker_keda_jobs_per_replica)
            }
            authenticationRef = { name = "" }
          }
        ]
      }
    }

    resources = {
      main = {
        requests = { cpu = var.n8n_main_cpu_request, memory = var.n8n_main_memory_request }
        limits   = { cpu = var.n8n_main_cpu_limit, memory = var.n8n_main_memory_limit }
      }
      worker = {
        requests = { cpu = var.n8n_worker_cpu_request, memory = var.n8n_worker_memory_request }
        limits   = { cpu = var.n8n_worker_cpu_limit, memory = var.n8n_worker_memory_limit }
      }
      webhookProcessor = {
        requests = { cpu = var.n8n_webhook_cpu_request, memory = var.n8n_webhook_memory_request }
        limits   = { cpu = var.n8n_webhook_cpu_limit, memory = var.n8n_webhook_memory_limit }
      }
    }

    executions = {
      timeout     = var.n8n_execution_timeout
      timeoutMax  = var.n8n_execution_timeout_max
      concurrency = { productionLimit = var.n8n_execution_concurrency_limit }
      data = {
        saveOnError          = "all"
        saveOnSuccess        = "all"
        saveOnProgress       = false
        saveManualExecutions = true
      }
      pruning = {
        enabled            = true
        maxAge             = var.n8n_pruning_max_age
        maxCount           = var.n8n_pruning_max_count
        hardDeleteBuffer   = 1
        hardDeleteInterval = 15
        softDeleteInterval = 60
      }
    }

    config = {
      timezone = var.n8n_timezone
      extraEnv = concat(
        # Direct connections to RDS/Aurora use SSL with the AWS CA (not trusted by Node.js — safe
        # to skip cert verification within the VPC). Set db_postgresdb_ssl_enabled = false when
        # n8n's DB host is an in-cluster pooler (e.g. PgBouncer) that handles SSL on its upstream leg.
        var.db_postgresdb_ssl_enabled ? [
          { name = "DB_POSTGRESDB_SSL_ENABLED", value = "true" },
          { name = "DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED", value = "false" },
          ] : [
          { name = "DB_POSTGRESDB_SSL_ENABLED", value = "false" },
        ],
        [
          { name = "N8N_LOG_LEVEL", value = "info" },
          { name = "N8N_LOG_OUTPUT", value = "json" },
          { name = "N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS", value = "true" },
          # Override the internally computed http://host:5678 URL so webhooks show the correct HTTPS address.
          { name = "WEBHOOK_URL", value = coalesce(var.n8n_webhook_url, "https://${local.n8n_domain}") },
          { name = "N8N_RUNNERS_TASK_REQUEST_TIMEOUT", value = tostring(var.n8n_runners_task_request_timeout) },
          # Keeps ElastiCache from dropping idle Redis subscriber connections under sustained load.
          # Without this, Bull detects dropped connections, emits queue errors, and pods crash.
          { name = "QUEUE_BULL_REDIS_KEEP_ALIVE", value = "true" },
          { name = "DB_POSTGRESDB_POOL_SIZE", value = tostring(var.db_postgresdb_pool_size) },
        ]
      )
    }

    # ── Graceful shutdown ─────────────────────────────────────────────────────
    # preStop sleep drains the pod from load balancer backends before SIGTERM.
    # terminationGracePeriodSeconds gives in-flight executions time to complete.
    lifecycle = {
      main = {
        terminationGracePeriodSeconds = var.n8n_termination_grace_period
        preStop = {
          enabled = true
          command = ["/bin/sh", "-c", "sleep ${var.n8n_prestop_sleep}"]
        }
      }
      worker = {
        terminationGracePeriodSeconds = var.n8n_termination_grace_period
        preStop = {
          enabled = true
          command = ["/bin/sh", "-c", "sleep ${var.n8n_prestop_sleep}"]
        }
      }
      webhookProcessor = {
        terminationGracePeriodSeconds = var.n8n_termination_grace_period
        preStop = {
          enabled = true
          command = ["/bin/sh", "-c", "sleep ${var.n8n_prestop_sleep}"]
        }
      }
    }

    # ── Task runners ─────────────────────────────────────────────────────────
    # When enabled, a sidecar container (n8nio/runners) is added to both main and
    # worker pods to execute JavaScript and Python code in isolation from the n8n
    # process. The n8n container runs a task broker on port 5679; each sidecar
    # connects to it over localhost using the auto-generated auth token.
    taskRunners = {
      enabled = var.n8n_task_runners_enabled
      authToken = {
        value = random_password.task_runner_token.result
      }
      broker = {
        listenAddress = "0.0.0.0"
        port          = 5679
      }
      launcher = {
        logLevel            = "info"
        autoShutdownTimeout = var.n8n_task_runner_auto_shutdown_timeout
      }
      nativePythonRunner = var.n8n_task_runner_python_enabled
      resources = {
        requests = { cpu = var.n8n_task_runner_cpu_request, memory = var.n8n_task_runner_memory_request }
        limits   = { cpu = var.n8n_task_runner_cpu_limit, memory = var.n8n_task_runner_memory_limit }
      }
    }

    # ── Pod Disruption Budget ─────────────────────────────────────────────────
    # Ensures at least one main pod stays running during node drains or rollouts.
    pdb = {
      enabled      = true
      minAvailable = 1
    }
  })]

  depends_on = [
    helm_release.lbc,
    helm_release.keda,
    aws_db_instance.n8n, # no-op (empty list) when create_database = false
    aws_elasticache_cluster.n8n,
    aws_iam_role_policy_attachment.s3,
    aws_eks_pod_identity_association.s3,
  ]
}

# ── Ingress ───────────────────────────────────────────────────────────────────
# Session stickiness pins each browser to the same main pod for 3 hours.
# Without this, WebSocket connections break as the ALB round-robins between pods.

resource "kubernetes_ingress_v1" "n8n" {
  metadata {
    name      = "n8n-ingress"
    namespace = kubernetes_namespace.n8n.metadata[0].name
    annotations = {
      "kubernetes.io/ingress.class"                        = "alb"
      "alb.ingress.kubernetes.io/scheme"                   = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"              = "ip"
      "alb.ingress.kubernetes.io/certificate-arn"          = local.certificate_arn
      "alb.ingress.kubernetes.io/listen-ports"             = jsonencode([{ HTTP = 80 }, { HTTPS = 443 }])
      "alb.ingress.kubernetes.io/ssl-redirect"             = "443"
      "alb.ingress.kubernetes.io/load-balancer-attributes" = "idle_timeout.timeout_seconds=300"
      "alb.ingress.kubernetes.io/target-group-attributes"  = "stickiness.enabled=true,stickiness.lb_cookie.duration_seconds=10800,deregistration_delay.timeout_seconds=30"
      "alb.ingress.kubernetes.io/healthcheck-path"         = "/healthz"
    }
  }

  spec {
    ingress_class_name = "alb"

    rule {
      host = local.n8n_domain
      http {
        # Webhook traffic must go to the dedicated webhook-processor.
        # Production webhooks are disabled on main pods (disableProductionWebhooksOnMainProcess=true).
        path {
          path      = "/webhook"
          path_type = "Prefix"
          backend {
            service {
              name = "n8n-webhook-processor"
              port { number = 5678 }
            }
          }
        }
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "n8n-main"
              port { number = 5678 }
            }
          }
        }
      }
    }
  }

  wait_for_load_balancer = true

  timeouts {
    create = "10m"
    delete = "5m"
  }

  depends_on = [
    helm_release.n8n,
    aws_iam_role.lbc,
    aws_iam_role_policy_attachment.lbc,
    time_sleep.wait_for_alb_cleanup,
  ]
}

# ── Destroy-time pause ────────────────────────────────────────────────────────
# After the Ingress is deleted, the LBC begins deprovisioning the ALB. The ALB
# deletion is asynchronous — ENIs and security groups may linger for 30-60s.
# This pause gives AWS time to fully release those resources before Terraform
# moves on to deleting the namespace, node group, and cluster.
#
# Dependency chain (create order, reversed for destroy):
#   namespace → time_sleep → ingress
# Destroy order (reversed):
#   1. kubernetes_ingress_v1.n8n        ← Ingress deleted, LBC starts ALB teardown
#   2. time_sleep.wait_for_alb_cleanup  ← pauses 60s for ENI/SG release
#   3. kubernetes_namespace.n8n         ← namespace deleted (resources fully gone)

resource "time_sleep" "wait_for_alb_cleanup" {
  destroy_duration = "60s"

  depends_on = [kubernetes_namespace.n8n]
}
