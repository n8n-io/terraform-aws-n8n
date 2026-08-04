# ── Locals ────────────────────────────────────────────────────────────────────
# Shared values derived from inputs: input aliases, the common tag set every
# taggable resource merges in, and the deterministic S3 bucket name.

locals {
  # Aliases for inputs so the rest of the module can reference them uniformly.
  # Formerly sourced from the sibling prerequisites workspace via
  # data.terraform_remote_state.
  aws_region   = var.aws_region
  cluster_name = var.cluster_name
  n8n_domain   = var.n8n_domain

  # Every hostname n8n answers on, primary first. Single source of truth for the
  # ACM certificate's name list, the Route 53 validation records, the alias
  # records, and the Ingress host rules, so those four cannot drift apart.
  # n8n_domain stays first and canonical: it is what n8n advertises.
  #
  # Lowercased because ACM stores certificate names in lowercase: the
  # validation-record lookups in dns.tf match each name against the
  # certificate's computed domain_validation_options, and a mixed-case input
  # would never match, failing the apply with an error that does not name the
  # cause. Kubernetes also rejects uppercase Ingress hosts. DNS itself is
  # case-insensitive, so normalizing here changes nothing a caller can observe.
  acm_domain_names = distinct(concat(
    [lower(var.n8n_domain)],
    [for d in var.n8n_additional_domains : lower(d)],
  ))
  vpc_id          = var.vpc_id
  private_subnets = var.private_subnets
  public_subnets  = var.public_subnets
  vpc_cidr_block  = var.vpc_cidr_block
  certificate_arn = var.route53_zone_id != null ? aws_acm_certificate_validation.n8n[0].certificate_arn : var.certificate_arn

  # Service coordinates the Helm chart creates. Named here so the module-managed
  # Ingress and the outputs a bring-your-own Ingress consumes cannot drift apart.
  n8n_service_name         = "n8n-main"
  n8n_webhook_service_name = "n8n-webhook-processor"
  n8n_service_port         = 5678

  # Path prefixes that must reach the webhook processors rather than the mains.
  #
  # The module runs the chart with disableProductionWebhooksOnMainProcess = true,
  # which in n8n disables exactly these five endpoint families on the main pods
  # (packages/cli/src/abstract-server.ts, where the `if (this.webhooksEnabled)` block
  # registers handlers for form, webhook, form-waiting, webhook-waiting and mcp).
  # Any of them left routed to n8n-main returns 404: waiting webhooks never
  # resume, Form Trigger nodes break, and MCP server triggers are unreachable.
  #
  # The first four mirror charts/n8n/templates/ingress-webhook.yaml in
  # n8n-io/n8n-hosting, the upstream reference for this split. /mcp is not in
  # that template: the chart omits it even though n8n registers the live MCP
  # handler in the same block disableProductionWebhooksOnMainProcess disables,
  # so a chart-only deployment leaves /mcp pointed at pods that cannot serve it.
  # Trailing slashes are omitted (the chart writes "/webhook/"): under pathType Prefix the AWS Load Balancer Controller
  # expands "/webhook" to match both the bare prefix and "/webhook/*", so the
  # slashless form is a superset and cannot regress a bare-prefix request.
  #
  # The Slack and Telegram human-in-the-loop callbacks use fixed paths under
  # /webhook-waiting, so they are already covered by that prefix.
  n8n_webhook_path_prefixes = [
    "/webhook",
    "/webhook-waiting",
    "/form",
    "/form-waiting",
    "/mcp",
  ]

  # Annotations on the module-managed Ingress. Callers override any of these,
  # and add controller features the module has no opinion on (WAF ACL, SSL
  # policy, subnet pinning, access logs, ALB group sharing), through
  # var.ingress_annotations. Last write wins.
  ingress_default_annotations = {
    "kubernetes.io/ingress.class"               = "alb"
    "alb.ingress.kubernetes.io/scheme"          = var.ingress_scheme
    "alb.ingress.kubernetes.io/target-type"     = "ip"
    "alb.ingress.kubernetes.io/certificate-arn" = local.certificate_arn
    "alb.ingress.kubernetes.io/listen-ports"    = jsonencode([{ HTTP = 80 }, { HTTPS = 443 }])
    "alb.ingress.kubernetes.io/ssl-redirect"    = "443"

    "alb.ingress.kubernetes.io/load-balancer-attributes" = "idle_timeout.timeout_seconds=300"

    # Session stickiness pins each browser to the same main pod for 3 hours.
    # Without it, WebSocket connections break as the ALB round-robins between
    # main pods. Overriding this key drops that guarantee.
    "alb.ingress.kubernetes.io/target-group-attributes" = "stickiness.enabled=true,stickiness.lb_cookie.duration_seconds=10800,deregistration_delay.timeout_seconds=30"

    "alb.ingress.kubernetes.io/healthcheck-path" = "/healthz"
  }

  ingress_annotations = merge(local.ingress_default_annotations, var.ingress_annotations)

  # Redis endpoint, abstracted over the two mutually exclusive engine resources
  # in redis.tf (see the comment there for why there are two). Everything that
  # needs to reach the queue — the Helm values, the KEDA triggers, the
  # redis_endpoint output — reads this rather than picking a resource, so the
  # two paths cannot drift apart.
  #
  # Branching on the variable rather than try()/coalesce() over both resources:
  # the variable is known at plan time, so the unselected resource's [0] is
  # never indexed. try() would also mask a genuine error in the live branch as
  # a silent fallback to the dead one.
  redis_host = var.redis_transit_encryption_enabled ? (
    aws_elasticache_replication_group.n8n[0].primary_endpoint_address
    ) : (
    aws_elasticache_cluster.n8n[0].cache_nodes[0].address
  )

  # Extra KEDA Redis trigger metadata needed once the queue backend enforces TLS
  # and an AUTH token. Empty on the default path, so the rendered ScaledObject
  # stays byte-identical to what existing releases already run.
  #
  # passwordFromEnv does not carry the token. It names an environment variable,
  # and KEDA resolves it against the *scale target's* pod spec, specifically
  # containers[0], since the ScaledObject sets no envSourceContainerName. On the
  # worker Deployment containers[0] is `n8n-worker` (task-runner is a sidecar
  # after it), and that is the container the chart already gives
  # QUEUE_BULL_REDIS_PASSWORD to via secretKeyRef. KEDA follows the secretKeyRef
  # rather than requiring a literal value, so the token reaches the scaler
  # without ever appearing in the ScaledObject manifest.
  #
  # That resolution needs KEDA to be able to read Secrets outside its own
  # namespace. The KEDA chart allows it by default (permissions.operator and
  # permissions.metricServer both have restrict.secret = false); setting
  # KEDA_RESTRICT_SECRET_ACCESS=true on the operator would break this path.
  # keda.tf installs the chart without overriding those values.
  keda_redis_auth_metadata = var.redis_transit_encryption_enabled ? {
    enableTLS       = "true"
    passwordFromEnv = "QUEUE_BULL_REDIS_PASSWORD"
  } : {}

  common_tags = merge(
    {
      ManagedBy = "terraform"
      Project   = "n8n"
    },
    var.tags,
  )

  # cluster_name + last 6 digits of the account ID keeps names unique across
  # both clusters in the same account and accounts with the same cluster name.
  s3_bucket_name = "n8n-${local.cluster_name}-${substr(data.aws_caller_identity.current.account_id, 6, 6)}"

  # ── n8n_extra_env collision guard ──────────────────────────────────────────
  # config.extraEnv is appended LAST in every n8n container's env list (see the
  # n8n Helm chart's deployment-*.yaml templates), and Kubernetes resolves
  # duplicate env names last-wins. So any name a caller passes via
  # var.n8n_extra_env overrides the value the module or chart set for it. These
  # two lists are the reserved surface the escape hatch must not touch:
  # connection, identity, storage, license, and topology vars whose override
  # would silently break or hijack the deployment.
  #
  # Exact names: set by the module in config.extraEnv / the n8n secret, plus the
  # chart-rendered identity/topology/storage/license vars not covered by a
  # prefix below. Keep in sync with the extraEnv block in n8n.tf and the chart
  # values the module sets (database/redis/s3/multiMain/license/secretRefs).
  n8n_managed_env_names = [
    # Set by the module in config.extraEnv or the n8n secret.
    "N8N_ENCRYPTION_KEY",
    "N8N_LOG_LEVEL",
    "N8N_LOG_OUTPUT",
    "N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS",
    "N8N_METRICS",
    "N8N_REINSTALL_MISSING_PACKAGES",
    "N8N_COMMUNITY_PACKAGES_PREVENT_LOADING",
    "WEBHOOK_URL",
    "N8N_TEMPLATES_ENABLED",
    "N8N_PERSONALIZATION_ENABLED",
    "N8N_OTEL_ENABLED",
    "N8N_OTEL_EXPORTER_OTLP_ENDPOINT",
    "N8N_OTEL_EXPORTER_OTLP_HEADERS",
    "N8N_OTEL_EXPORTER_SERVICE_NAME",
    "N8N_OTEL_TRACES_SAMPLE_RATE",
    "N8N_OTEL_TRACES_INCLUDE_NODE_SPANS",
    "N8N_OTEL_TRACES_INJECT_OUTBOUND",
    "N8N_OTEL_TRACES_PRODUCTION_ONLY",
    "N8N_LOG_STREAMING_MANAGED_BY_ENV",
    "N8N_LOG_STREAMING_DESTINATIONS",
    # Rendered by the chart from module values (identity, topology, storage,
    # license). DB_*, QUEUE_*, N8N_RUNNERS_*, N8N_EXTERNAL_STORAGE_S3_*,
    # N8N_MULTI_MAIN_*, and AWS_* are covered by n8n_managed_env_prefixes.
    "EXECUTIONS_MODE",
    "OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS",
    "N8N_DEFAULT_BINARY_DATA_MODE",
    "N8N_AVAILABLE_BINARY_DATA_MODES",
    "N8N_LICENSE_ACTIVATION_KEY",
    "N8N_LICENSE_DETACH_FLOATING_ON_SHUTDOWN",
    "N8N_HOST",
    "N8N_PORT",
    "N8N_PROTOCOL",
    "N8N_EDITOR_BASE_URL",
    "N8N_DISABLE_PRODUCTION_MAIN_PROCESS",
    "N8N_NATIVE_PYTHON_RUNNER",
    "TZ",
  ]

  # Whole env-var families the module/chart owns, matched by prefix so the guard
  # stays correct when the chart adds new members. This intentionally fails
  # closed: it also blocks DB_*/QUEUE_* *tuning* vars the module does not set
  # today (e.g. DB_LOGGING_ENABLED). If a caller has a genuine need for one, add
  # an exact-match carve-out rather than narrowing the prefix.
  n8n_managed_env_prefixes = [
    "DB_",
    "QUEUE_",
    "N8N_RUNNERS_",
    "N8N_EXTERNAL_STORAGE_S3_",
    "N8N_MULTI_MAIN_",
    "AWS_",
  ]
}
