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

  # The EKS cluster every other file reads. Resolves to the module-managed
  # cluster (create_eks = true, the default) or to existing_eks_cluster_name
  # via data.aws_eks_cluster.existing (eks.tf) otherwise, the same pattern
  # local.namespace_name and local.s3_bucket_arn already use. cluster_name
  # above stays a separate thing: it names *this module's own* resources
  # (IAM role suffixes, the generated S3 bucket name), not the EKS cluster
  # itself, and keeps meaning that on both create_eks paths.
  eks_cluster_name     = var.create_eks ? aws_eks_cluster.n8n[0].name : data.aws_eks_cluster.existing[0].name
  eks_cluster_endpoint = var.create_eks ? aws_eks_cluster.n8n[0].endpoint : data.aws_eks_cluster.existing[0].endpoint
  eks_cluster_ca_data  = var.create_eks ? aws_eks_cluster.n8n[0].certificate_authority[0].data : data.aws_eks_cluster.existing[0].certificate_authority[0].data

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
  # Three independent features all require aws_elasticache_replication_group,
  # each for an unrelated reason: automatic failover and auth_token are only
  # available on that resource type, and so is kms_key_id. Naming the
  # disjunction once keeps the two resources in redis.tf provably mutually
  # exclusive. Written inline in both counts, the pair would be two
  # expressions that have to be kept each other's exact negation by hand, and
  # getting that wrong means either two caches or none.
  #
  # None of the three drags in another: a caller who opts into a CMK does not
  # also get a second node or transit encryption, and a caller who asks only
  # for HA does not also get a CMK. See the doc comment above
  # aws_elasticache_replication_group.n8n in redis.tf for every reachable
  # combination.
  redis_needs_replication_group = (
    var.redis_high_availability_enabled
    || var.redis_transit_encryption_enabled
    || var.redis_kms_encryption_enabled
  )

  # Chart fragment carrying QUEUE_BULL_REDIS_TIMEOUT_THRESHOLD, merged into the
  # redis values below rather than set inline. Empty when the input is null,
  # which is the default, so the rendered values stay byte-identical for every
  # existing release and the chart's own 10000 continues to apply. Same reason
  # passwordSecret is merged rather than set to an explicit null.
  redis_timeout_values = (
    var.n8n_redis_timeout_threshold == null
    ? {}
    : { timeout = var.n8n_redis_timeout_threshold }
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
  # modules/controllers/keda.tf installs the chart without overriding those values.
  #
  # The two halves are gated separately because the migration's middle state
  # separates them. In transit_encryption_mode = preferred the endpoint speaks
  # TLS but has no token, so KEDA needs enableTLS and must NOT be told to look
  # for a password: passwordFromEnv naming an environment variable that does not
  # exist resolves to an empty credential, and the trigger then authenticates
  # against a server with no password configured. Once the group reaches
  # required the token exists and both halves apply.
  #
  # username is the exception to the FromEnv treatment above, deliberately. It is
  # not a credential, so there is nothing gained by keeping it out of the
  # manifest, and a literal removes the dependency on KEDA resolving it: the
  # scaler's field is declared
  # `Username string keda:"name=username, order=triggerMetadata;resolvedEnv;authParams"`,
  # so both forms work, and the literal is the one that cannot be broken by the
  # chart changing how it renders QUEUE_BULL_REDIS_USERNAME.
  keda_redis_auth_metadata = merge(
    local.redis_tls_active ? { enableTLS = "true" } : {},
    local.redis_auth_active ? { passwordFromEnv = "QUEUE_BULL_REDIS_PASSWORD" } : {},
    local.redis_username_value != null ? { username = local.redis_username_value } : {},
  )

  # Rolls main, worker and webhook processor pods when the AUTH token changes.
  # Lifted out of the Helm values for the same reason keda_redis_auth_metadata
  # is: helm_release.values is unknown at plan time (it embeds the Redis
  # endpoint), so this is the layer where the contract is assertable. See the
  # long comment at the merge site in n8n.tf for why the chart's own
  # checksum/secret cannot cover a Secret created outside the chart.
  # Also gated on redis_auth_token_secret_ref being null: with a caller-managed
  # Secret the module never reads the token's value (that is the point of the
  # input), so there is nothing here to hash, and local.redis_auth_token_value
  # resolves to null on that path (see below).
  redis_pod_annotations = (local.redis_auth_active && var.redis_auth_token_secret_ref == null) ? {
    "checksum/redis-auth-token" = sha256(local.redis_auth_token_value)
  } : {}

  # The two arguments the staged HA -> HA+TLS migration needs, lifted here for
  # the same testability reason as the two locals above, though the mechanism
  # differs. Both are Optional+Computed on the replication group, so a plan that
  # leaves either unset renders it as "known after apply" rather than null, and
  # `aws_elasticache_replication_group.n8n[0].apply_immediately == null` fails
  # with "Unknown condition value" instead of passing. A concrete value IS
  # assertable on the resource, so the tests read the resource where the value
  # is set and these locals where the contract is that nothing is set at all.
  #
  # That contract is the point: every deployment already on a replication group
  # re-plans against this version of the module, and writing a default onto
  # either argument would show them an in-place Redis update that changes
  # nothing. Gated on redis_managed_tls_active (not redis_tls_active), since
  # transit_encryption_mode is a property of the replication group this module
  # manages and has no meaning against an external Redis.
  redis_transit_encryption_mode = local.redis_managed_tls_active ? var.redis_transit_encryption_mode : null
  redis_apply_immediately       = var.redis_apply_immediately ? true : null

  # Whether the endpoint n8n is being pointed at actually speaks TLS. True on
  # either path now: the module-managed replication group with
  # redis_transit_encryption_enabled, or an external Redis (create_elasticache
  # = false) the caller has flagged as TLS-only via the same variable: the
  # module does not manage that endpoint, so this is a declaration from the
  # caller rather than something the module provisions or verifies.
  redis_tls_active = var.redis_transit_encryption_enabled

  # Narrower than redis_tls_active: true only when the module itself is the one
  # putting TLS on a replication group it manages. Gates the arguments that are
  # properties of THAT resource specifically (transit_encryption_mode) rather
  # than of "is this endpoint encrypted" in general, which redis_tls_active
  # already answers for both paths.
  redis_managed_tls_active = var.create_elasticache && var.redis_transit_encryption_enabled

  # Whether there is an AUTH token to wire up at all, and where it comes from.
  #
  #   create_elasticache = true   gated on redis_managed_tls_active AND
  #                               transit_encryption_mode == "required", because
  #                               AWS returns InvalidParameterValue: The AUTH
  #                               token modification is only supported when
  #                               encryption-in-transit is enabled, and that
  #                               means "required" specifically, not "preferred"
  #                               with TransitEncryptionEnabled already true.
  #                               Confirmed live on a throwaway group, both as a
  #                               standalone modify and bundled into the same
  #                               call as the move to required; both were
  #                               rejected identically. Gating the whole
  #                               credential on this is what makes the staged
  #                               migration expressible as ordinary variable
  #                               changes: the first apply moves the group to
  #                               preferred and rolls the pods onto TLS with no
  #                               credential, which preferred accepts; the
  #                               second moves it to required and lets the token
  #                               land behind it. A first-time create is
  #                               unaffected, since the mode defaults to
  #                               "required".
  #   create_elasticache = false  true whenever the caller supplied
  #                               redis_auth_token OR redis_auth_token_secret_ref.
  #                               The module cannot generate a credential for
  #                               infrastructure it does not provision, and an
  #                               external Redis with AUTH does not carry
  #                               AWS's TLS-before-AUTH constraint, so this is
  #                               a plain presence check either way.
  redis_auth_active = (
    var.create_elasticache
    ? (local.redis_managed_tls_active && var.redis_transit_encryption_mode == "required")
    : (var.redis_auth_token != null || var.redis_auth_token_secret_ref != null)
  )

  # The credential value that actually reaches the Kubernetes Secret this
  # module writes, resolving both module-known sources the same way
  # local.redis_host resolves the endpoint: branching on the variables (known
  # at plan time) rather than try()/coalesce() over the resource, so the
  # unselected branch's [0] is never indexed. null when
  # redis_auth_token_secret_ref is set: the value then lives in the caller's
  # own Secret, which the module never reads, and kubernetes_secret.n8n_redis
  # is not created on that path (n8n.tf), so this local has no consumer there
  # either.
  redis_auth_token_value = (
    var.create_elasticache
    ? try(random_password.redis_auth_token[0].result, null)
    : var.redis_auth_token
  )

  # The ACL username, resolved to null on the module-managed path so "ignored
  # when create_elasticache = true" means the value genuinely never reaches
  # anything, the same treatment local.db_logs_kms_key_arn gives an ignored key.
  # An ElastiCache AUTH token authenticates as Redis's default user and the
  # service has no username concept, so passing one there would break a
  # connection that works.
  redis_username_value = var.create_elasticache ? null : var.redis_username

  # Bull's own default prefix, mirrored here (rather than left as a literal
  # at each of the two KEDA listName call sites) so n8n.tf's env var, the
  # chart's redis.prefix value, and KEDA's listName all read from one
  # resolved value instead of three separately-maintained literals.
  redis_key_prefix_value = coalesce(var.redis_key_prefix, "bull")

  common_tags = merge(
    {
      ManagedBy = "terraform"
      Project   = "n8n"
    },
    var.tags,
  )

  # cluster_name + last 6 digits of the account ID keeps names unique across
  # both clusters in the same account and accounts with the same cluster name.
  # Only used to name aws_s3_bucket.n8n when create_s3_bucket = true.
  s3_bucket_name_generated = "n8n-${local.cluster_name}-${substr(data.aws_caller_identity.current.account_id, 6, 6)}"

  # Name of the bucket actually in use: the module-managed bucket when
  # create_s3_bucket = true (the default), or the caller-supplied existing
  # bucket otherwise. n8n.tf and the s3_bucket_name output read this rather
  # than aws_s3_bucket.n8n directly, so both resolve correctly whichever
  # bucket is in play.
  s3_bucket_name = var.create_s3_bucket ? local.s3_bucket_name_generated : var.existing_s3_bucket_name

  # ARN of the bucket actually in use. aws_iam_policy.s3 (s3.tf) grants access
  # to this ARN regardless of who created the bucket.
  s3_bucket_arn = var.create_s3_bucket ? aws_s3_bucket.n8n[0].arn : "arn:aws:s3:::${var.existing_s3_bucket_name}"

  # KMS key actually protecting the bucket in use, or null when it is not
  # SSE-KMS encrypted. On the caller-supplied bucket path (create_s3_bucket =
  # false) s3_kms_key_arn passes straight through regardless of
  # s3_kms_encryption_enabled, since that toggle only governs a bucket
  # encryption configuration this module never creates there, and an explicit
  # ARN is the only way the pod role can be granted key access to a bucket
  # this module does not create. On the module-managed path, which key
  # protects the bucket is create_s3_kms_key's call, not s3_kms_key_arn's:
  # true means the module's own CMK (aws_kms_key.s3), false means the
  # caller's s3_kms_key_arn is the one actually in use. Either way this
  # resolves to null when s3_kms_encryption_enabled is false, so the IAM
  # grant never names a key that is not actually the bucket's default
  # encryption key.
  s3_kms_key_arn = (
    !var.create_s3_bucket ? var.s3_kms_key_arn :
    var.s3_kms_encryption_enabled ? (var.create_s3_kms_key ? try(aws_kms_key.s3[0].arn, null) : var.s3_kms_key_arn) : null
  )

  # ── n8n multi-main topology ────────────────────────────────────────────────
  # n8n gates multiMain behind the feat:multipleMainInstances license
  # entitlement (Business tier doesn't carry it; Startup/Enterprise do).
  # Enabling it unconditionally makes this module unrunnable on a Business
  # license even at 1 main replica. At or below 1 replica there is nothing to
  # elect a leader among, so multi-main brings no benefit and needs no
  # entitlement; above 1 it is required for correctness, which is also
  # today's default (2). n8n.tf's multiMain.enabled reads this.
  n8n_multi_main_enabled = var.n8n_main_hpa_min_replicas > 1

  # multiMain.enabled being false does not, on its own, stop n8n.tf's main-pod
  # HPA (hpa.main) from scaling main replicas past 1: that HPA reads
  # var.n8n_main_hpa_max_replicas directly, independent of multi-main. Without
  # this clamp, single-main mode (n8n_main_hpa_min_replicas = 1) would still
  # let the HPA scale a second main pod under CPU load, and with
  # multiMain.enabled false that second pod has no leader-election gate to
  # coordinate with the first, so both would independently run every
  # scheduled/cron trigger. n8n.tf's hpa.main.maxReplicas reads this instead
  # of the variable directly, pinning the ceiling to the floor whenever
  # multi-main is disabled, regardless of the variable's own value.
  n8n_main_hpa_effective_max_replicas = local.n8n_multi_main_enabled ? var.n8n_main_hpa_max_replicas : var.n8n_main_hpa_min_replicas

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
  n8n_managed_env_names = concat([
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
    # Owned by redis_key_prefix, which is the single source of truth for the
    # Redis namespace: it sets this, the chart's redis.prefix (QUEUE_BULL_PREFIX)
    # and the KEDA ScaledObject's listName together. QUEUE_BULL_PREFIX is
    # already covered by the QUEUE_ prefix below; without this entry the two
    # halves could be set independently, leaving n8n's pub/sub channel and
    # Bull's job keys under different namespaces, and KEDA watching a list
    # nothing writes to.
    "N8N_REDIS_KEY_PREFIX",
    # Owned by the four "n8n defaults scheduled to change" inputs. Listed even
    # though three of them are only emitted when set: an extraEnv override would
    # move a limit the module deliberately leaves to n8n, or unpin the task
    # timeout the module deliberately pins, without the input saying so.
    # N8N_RUNNERS_TASK_TIMEOUT is already covered by the N8N_RUNNERS_ prefix
    # below and is not repeated here.
    "N8N_UNVERIFIED_PACKAGES_ENABLED",
    "N8N_COMPRESSION_NODE_MAX_DECOMPRESSED_SIZE_BYTES",
    "N8N_COMPRESSION_NODE_MAX_ZIP_ENTRIES",
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
    # Owned by the module's config.data block. The chart renders all four of its
    # keys unconditionally (_environment-helpers.tpl carries no {{- if }} guard
    # on them, unlike the EXECUTIONS_TIMEOUT and EXECUTIONS_DATA_MAX_AGE entries
    # beside them), so an extraEnv duplicate produces a container env entry
    # listed twice under the same name. Kubernetes' strategic-merge-patch is
    # then ambiguous about which occurrence a later change lands on, and honours
    # the LAST entry at container start, so a stale value can silently win.
    # Observed live 2026-08-24: main and worker pods kept reporting "none" for
    # EXECUTIONS_DATA_SAVE_ON_SUCCESS five minutes after the Helm release's own
    # manifest said "all" in both positions. All four are owned by dedicated
    # inputs (n8n_executions_data_save_on_success / _on_error / _on_progress /
    # _manual_executions), so every guarded name here has a supported knob and
    # none needs the extraEnv path.
    "EXECUTIONS_DATA_SAVE_ON_SUCCESS",
    "EXECUTIONS_DATA_SAVE_ON_ERROR",
    "EXECUTIONS_DATA_SAVE_ON_PROGRESS",
    "EXECUTIONS_DATA_SAVE_MANUAL_EXECUTIONS",
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
    "N8N_DISABLED_MODULES",
    "N8N_EXTERNAL_SECRETS_UPDATE_INTERVAL",
    ],
    # NODE_OPTIONS is reserved ONLY while n8n_node_max_old_space_size_mb is
    # set, unlike every entry above. The distinction matters because it is a
    # whole flag STRING rather than a single setting: when the module emits it,
    # a caller entry would replace the module's --max-old-space-size wholesale
    # rather than adding to it (extraEnv is appended last, Kubernetes resolves
    # duplicate names last-wins), silently unpinning the ceiling the input says
    # is in force. When the input is null the module emits nothing, there is no
    # value to clobber, and a caller passing NODE_OPTIONS for unrelated flags
    # (--enable-source-maps, --inspect, their own heap flag) is doing something
    # legitimate that this module has no business rejecting. Reserving it
    # unconditionally would break those callers at plan time on upgrade, for a
    # collision that cannot occur.
    var.n8n_node_max_old_space_size_mb != null ? ["NODE_OPTIONS"] : [],
  )

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

  # Modules explicitly disabled via N8N_DISABLED_MODULES. A list rather than a
  # direct string assignment so a later toggle for another module can append
  # to it without touching the join() that renders it. See
  # var.n8n_external_secrets_enabled.
  n8n_disabled_modules = concat(
    var.n8n_external_secrets_enabled ? [] : ["external-secrets"],
  )

  # The chart's redis.worker.* block, assembled once from three independent
  # variables. Built here rather than inline in n8n.tf because the
  # surrounding merge() in that file is SHALLOW: three separate
  # `{ worker = {...} }` entries would silently overwrite one another and
  # only the last would survive, so setting lock duration and stalled
  # interval together would quietly drop one of them. Assembling the inner
  # map first is what makes them composable.
  #
  # All three values are passed through as plain integers. The chart's
  # values.schema.json types every one of them as `{"type": "integer",
  # "minimum": 1000}`, so a quoted string is rejected outright ("got string,
  # want integer") and so is any value below 1000. The matching >= 1000
  # validations on the variables exist to surface that as a plan-time error
  # rather than a Helm schema failure at apply.
  n8n_queue_worker_settings = merge(
    var.n8n_queue_worker_lock_duration != null ? {
      lockDuration = var.n8n_queue_worker_lock_duration
    } : {},
    var.n8n_queue_worker_lock_renew_time != null ? {
      lockRenewTime = var.n8n_queue_worker_lock_renew_time
    } : {},
    var.n8n_queue_worker_stalled_interval != null ? {
      stalledInterval = var.n8n_queue_worker_stalled_interval
    } : {},
  )

  # var.n8n_dns_config with unset keys removed.
  #
  # Necessary because the variable's optional() attributes materialise as null
  # rather than being absent, and the chart renders dnsConfig with a bare
  # `{{- toYaml . }}`. Passing the variable through directly would emit
  # `nameservers: null` / `searches: null` into the pod spec, which the API
  # server rejects (it expects a list, not null) with an error that names the
  # pod rather than the Helm value, so it is slow to trace back to here.
  #
  # `options` is rebuilt element-by-element for the same reason: an option with
  # no value is legal DNS (`options edns0` carries no value) and must render as
  # `{name: edns0}`, not `{name: edns0, value: null}`.
  n8n_dns_config_options = var.n8n_dns_config == null ? [] : [
    for o in coalesce(var.n8n_dns_config.options, []) :
    o.value == null ? { name = o.name } : { name = o.name, value = o.value }
  ]

  n8n_dns_config_stripped = var.n8n_dns_config == null ? {} : {
    for k, v in {
      nameservers = var.n8n_dns_config.nameservers
      searches    = var.n8n_dns_config.searches
      options     = length(local.n8n_dns_config_options) == 0 ? null : local.n8n_dns_config_options
    } : k => v if v != null
  }

  # Collapsed to null when nothing survives the stripping, so a caller passing
  # `n8n_dns_config = {}` (or all-null attributes) omits the dnsConfig key from
  # the Helm values entirely rather than rendering `dnsConfig: {}`, keeping the
  # variable's "null omits the block entirely" promise true for every
  # equivalent-to-unset shape.
  n8n_dns_config = length(local.n8n_dns_config_stripped) == 0 ? null : local.n8n_dns_config_stripped
}
