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

  # Single source of truth for var.alb_ssl_policy's default, so the
  # create_ingress = false tuning check (n8n.tf) can compare against it
  # without a second hardcoded copy of the literal. variable "default" values
  # must themselves be constant literals (no references to locals allowed),
  # so variables.tf keeps its own copy of this string; keep the two in sync
  # when changing either.
  alb_ssl_policy_default = "ELBSecurityPolicy-TLS13-1-2-2021-06"

  # Annotations on the module-managed Ingress. Callers override any of these,
  # and add controller features the module has no opinion on (WAF ACL, subnet
  # pinning, access logs, ALB group sharing), through var.ingress_annotations.
  # Last write wins.
  ingress_default_annotations = {
    "kubernetes.io/ingress.class"               = "alb"
    "alb.ingress.kubernetes.io/scheme"          = var.ingress_scheme
    "alb.ingress.kubernetes.io/target-type"     = "ip"
    "alb.ingress.kubernetes.io/certificate-arn" = local.certificate_arn
    "alb.ingress.kubernetes.io/listen-ports"    = jsonencode([{ HTTP = 80 }, { HTTPS = 443 }])
    "alb.ingress.kubernetes.io/ssl-redirect"    = "443"
    "alb.ingress.kubernetes.io/ssl-policy"      = var.alb_ssl_policy

    "alb.ingress.kubernetes.io/load-balancer-attributes" = "idle_timeout.timeout_seconds=300"

    # Session stickiness pins each browser to the same main pod for 3 hours.
    # Without it, WebSocket connections break as the ALB round-robins between
    # main pods. Overriding this key drops that guarantee.
    "alb.ingress.kubernetes.io/target-group-attributes" = "stickiness.enabled=true,stickiness.lb_cookie.duration_seconds=10800,deregistration_delay.timeout_seconds=30"

    "alb.ingress.kubernetes.io/healthcheck-path" = "/healthz"
  }

  # Source restrictions on the ALB security group LBC creates. Each key is
  # omitted entirely when its input is empty, so the default keeps LBC's own
  # default of 0.0.0.0/0 and no existing deployment sees a plan diff.
  #
  # Dropping the key is a cleanliness choice, not a safety one. LBC keys its
  # 0.0.0.0/0 default off the *parsed* CIDR and prefix list sets being empty
  # rather than off the annotations being absent, so rendering an empty value
  # would behave identically. Verified live against LBC v3.5.0: an Ingress
  # carrying inbound-cidrs="" still gets 0.0.0.0/0 on every listen port.
  #
  # Both annotations are ignored by LBC when alb.ingress.kubernetes.io/security-groups
  # is set, because the caller then owns the security group. The check block in
  # n8n.tf warns about that combination rather than failing: a silently
  # unrestricted ALB is the failure mode worth surfacing.
  ingress_source_restriction_annotations = merge(
    length(var.alb_inbound_cidrs) > 0 ? {
      "alb.ingress.kubernetes.io/inbound-cidrs" = join(",", var.alb_inbound_cidrs)
    } : {},
    length(var.alb_inbound_prefix_list_ids) > 0 ? {
      "alb.ingress.kubernetes.io/security-group-prefix-lists" = join(",", var.alb_inbound_prefix_list_ids)
    } : {},
  )

  # var.ingress_annotations stays last: it is documented as the unconditional
  # last-write-wins escape hatch, and inbound-cidrs was a documented use of it
  # before alb_inbound_cidrs existed. Rejecting that key here (the n8n_extra_env
  # approach) would fail the plan for callers who already locked their ALB down
  # the only way the module offered. Setting both raises a check warning.
  ingress_annotations = merge(
    local.ingress_default_annotations,
    local.ingress_source_restriction_annotations,
    var.ingress_annotations,
  )

  # ── Redis topology selection ───────────────────────────────────────────────
  # Two independent features both require aws_elasticache_replication_group,
  # for unrelated reasons: automatic failover and auth_token are each available
  # only on that resource type. Naming the disjunction once keeps the two
  # resources in redis.tf provably mutually exclusive. Written inline in both
  # counts, the pair would be two expressions that have to be kept each other's
  # exact negation by hand, and getting that wrong means either two caches or
  # none.
  redis_needs_replication_group = (
    var.redis_high_availability_enabled || var.redis_transit_encryption_enabled
  )

  # ── Redis connection coordinates ───────────────────────────────────────────
  # What n8n and KEDA actually connect to, abstracted over the three sources so
  # the Helm values, the KEDA triggers and the redis_endpoint output cannot
  # drift apart:
  #
  #   create_elasticache = false     → the caller's own Redis (var.redis_host)
  #   redis_needs_replication_group  → the replication group's primary
  #                                    endpoint, a name AWS repoints at the
  #                                    surviving node on failover
  #   otherwise                      → the single cache node's address
  #
  # Branching on the variables rather than try()/coalesce() over both resources:
  # the variables are known at plan time, so the unselected resource's [0] is
  # never indexed. try() would also mask a genuine error in the live branch as a
  # silent fallback to the dead one.
  #
  # Shadowing var.redis_host / var.redis_port with locals of the same name is
  # deliberate and matches local.certificate_arn above: consumers read the
  # local, and the local is the only place the choice is made.
  redis_host = (
    var.create_elasticache
    ? (
      local.redis_needs_replication_group
      ? aws_elasticache_replication_group.n8n[0].primary_endpoint_address
      : aws_elasticache_cluster.n8n[0].cache_nodes[0].address
    )
    : var.redis_host
  )

  # Both module-managed topologies listen on 6379, so var.redis_port only ever
  # describes an endpoint the module did not create.
  redis_port = var.create_elasticache ? 6379 : var.redis_port

  # Extra KEDA Redis trigger metadata needed once the queue backend enforces TLS
  # and an AUTH token. Empty on every other path, so the rendered ScaledObject
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
  keda_redis_auth_metadata = local.redis_tls_active ? {
    enableTLS       = "true"
    passwordFromEnv = "QUEUE_BULL_REDIS_PASSWORD"
  } : {}

  # Rolls main, worker and webhook processor pods when the AUTH token changes.
  # Lifted out of the Helm values for the same reason keda_redis_auth_metadata
  # is: helm_release.values is unknown at plan time (it embeds the Redis
  # endpoint), so this is the layer where the contract is assertable. See the
  # long comment at the merge site in n8n.tf for why the chart's own
  # checksum/secret cannot cover a Secret created outside the chart.
  redis_pod_annotations = local.redis_tls_active ? {
    "checksum/redis-auth-token" = sha256(random_password.redis_auth_token[0].result)
  } : {}

  # Whether the endpoint n8n is being pointed at actually speaks TLS and demands
  # a token. Gated on create_elasticache as well as the variable, so the clients
  # can never be configured for a posture the module did not provision. A hard
  # validation on redis_transit_encryption_enabled already rejects that
  # combination, but the clients read this rather than the raw variable so the
  # invariant holds at the point of use.
  redis_tls_active = var.create_elasticache && var.redis_transit_encryption_enabled

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

  # ── n8n service account ────────────────────────────────────────────────────
  # The chart creating its own ServiceAccount is the arrangement we want, with
  # one exception: neither chart 1.10.0 nor 1.11.0 renders imagePullSecrets
  # anywhere, not on the pod spec and not on the ServiceAccount, so a private
  # registry has no way in through chart values. Attaching the secrets to the
  # account the pods already run as is the remaining lever, and the chart
  # supports it: serviceAccount.create = false with an externally managed name
  # is documented in its own values.yaml, naming Terraform as the example.
  #
  # So the module takes the account over, but only when there is something to
  # attach. With the default empty list the chart keeps creating it and nothing
  # about an existing deployment moves.
  n8n_manages_service_account = length(var.n8n_image_pull_secrets) > 0

  # The two owners deliberately use different names, which is not tidiness.
  # helm_release.n8n depends on the ServiceAccount resource, so on the apply
  # that first sets n8n_image_pull_secrets the module creates its account
  # before the upgrade runs. Sharing one name there means creating an object
  # the chart still owns, and the apply stops at "serviceaccounts
  # \"n8n-enterprise\" already exists" with the release untouched. Reversing
  # the dependency does not help either: with create = false the chart drops
  # its account during the upgrade, and the new pods would fail admission
  # looking for a ServiceAccount that Terraform has not created yet.
  #
  # Two names sidestep both. The new account is created alongside the old one,
  # the upgrade points the pods at it and lets Helm delete the chart's, and the
  # same apply works whether or not the deployment already exists.
  #
  # Whichever name is in play has three consumers that must agree: the chart's
  # serviceAccount.name, the Pod Identity association granting S3 access
  # (s3.tf), and the ServiceAccount resource in n8n.tf. Drift between them
  # leaves the pods running as an account with no AWS credentials.
  n8n_service_account_name = local.n8n_manages_service_account ? "n8n-enterprise-pull" : "n8n-enterprise"

  # ── Extra volumes, translated for the chart ────────────────────────────────
  # The inputs are snake_case and typed; the chart wants Kubernetes' camelCase.
  # Doing the translation here rather than asking callers to write chart YAML
  # through a Terraform variable is what makes the inputs checkable at plan
  # time, and keeping it in a local rather than inline in the values map is
  # what makes it assertable: helm_release.n8n.values is unknown at plan time,
  # since it carries the S3 role ARN and the database endpoint among others.
  #
  # default_mode arrives as an octal string and is converted with parseint,
  # because Kubernetes wants the integer. A Terraform number literal cannot do
  # this job: 0644 parses as decimal 644, which is octal 1204.
  n8n_extra_volumes = [
    for volume in var.n8n_extra_volumes : merge(
      { name = volume.name },
      volume.config_map == null ? {} : {
        configMap = merge(
          { name = volume.config_map.name },
          volume.config_map.default_mode == null ? {} : {
            defaultMode = parseint(volume.config_map.default_mode, 8)
          },
        )
      },
      volume.secret == null ? {} : {
        secret = merge(
          { secretName = volume.secret.secret_name },
          volume.secret.default_mode == null ? {} : {
            defaultMode = parseint(volume.secret.default_mode, 8)
          },
        )
      },
      volume.persistent_volume_claim == null ? {} : {
        persistentVolumeClaim = merge(
          { claimName = volume.persistent_volume_claim.claim_name },
          volume.persistent_volume_claim.read_only == null ? {} : {
            readOnly = volume.persistent_volume_claim.read_only
          },
        )
      },
    )
  ]

  n8n_extra_volume_mounts = [
    for mount in var.n8n_extra_volume_mounts : merge(
      {
        name      = mount.name
        mountPath = mount.mount_path
        readOnly  = mount.read_only
      },
      mount.sub_path == null ? {} : { subPath = mount.sub_path },
    )
  ]

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
    "N8N_COMMUNITY_PACKAGES_REGISTRY",
    "N8N_CUSTOM_EXTENSIONS",
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
    # Owned by var.n8n_execution_data_storage_mode. Listed even though the module
    # only emits it in "s3" mode: an extraEnv override would flip execution data
    # onto S3 (or off it) without the input saying so, and in s3 mode without a
    # licensed n8n every pod refuses to start.
    "N8N_EXECUTION_DATA_STORAGE_MODE",
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
