# ── Locals ────────────────────────────────────────────────────────────────────
# Shared values derived from inputs: input aliases, the common tag set every
# taggable resource merges in, and the deterministic S3 bucket name.

locals {
  # Aliases for inputs so the rest of the module can reference them uniformly.
  # Formerly sourced from the sibling prerequisites workspace via
  # data.terraform_remote_state.
  aws_region      = var.aws_region
  cluster_name    = var.cluster_name
  n8n_domain      = var.n8n_domain
  vpc_id          = var.vpc_id
  private_subnets = var.private_subnets
  public_subnets  = var.public_subnets
  vpc_cidr_block  = var.vpc_cidr_block
  certificate_arn = var.route53_zone_id != null ? aws_acm_certificate_validation.n8n[0].certificate_arn : var.certificate_arn

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
