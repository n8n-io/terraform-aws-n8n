# ── Foundation inputs ─────────────────────────────────────────────────────────
# Region, cluster naming, and the pre-built VPC + ACM certificate the module
# deploys into. Supply these from a VPC module (e.g. terraform-aws-modules/vpc)
# and an aws_acm_certificate_validation resource — see examples/small/.

variable "aws_region" {
  description = "AWS region to deploy into (e.g. us-east-1, eu-west-1, ap-southeast-1). Must match the region the AWS provider is configured for."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.aws_region))
    error_message = "Value must be a valid AWS region (e.g. us-east-1, eu-west-1)."
  }
}

variable "cluster_name" {
  description = "Name for the EKS cluster. Keep to 14 characters or fewer — the module derives an ElastiCache cluster ID of `<cluster_name>-redis`, and AWS caps ElastiCache IDs at 20 chars."
  type        = string
  default     = "n8n-cluster"

  validation {
    condition     = length(var.cluster_name) <= 14
    error_message = "cluster_name must be 14 characters or fewer (ElastiCache cluster ID <cluster_name>-redis must stay <= 20 chars)."
  }
}

variable "n8n_domain" {
  description = "Fully-qualified domain name for n8n (e.g. n8n.example.com). Must match the CN / SAN on the certificate provided via certificate_arn."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$", var.n8n_domain))
    error_message = "Value must be a valid fully qualified domain name (e.g. n8n.example.com)."
  }
}

variable "n8n_additional_domains" {
  description = "Extra fully-qualified hostnames n8n should answer on, beyond n8n_domain. Added to the module-issued ACM certificate as subject alternative names and given a Route 53 validation record each. Requires the Route 53 path (route53_zone_id set); with a caller-supplied certificate_arn the module cannot add names to a certificate it did not issue, and a plan-time warning says so. With create_ingress = true each name also gets an alias A-record and an Ingress rule, so the module routes it end to end. With create_ingress = false the certificate still covers every name and every name is still validated: consume it through the certificate_arn output and attach it to your own Ingress resources, as examples/split-ingress does. n8n_domain stays canonical: it is what n8n advertises as WEBHOOK_URL and N8N_HOST. Every name must live in the hosted zone given by route53_zone_id, since that is the zone all validation and alias records are written to. A name outside it fails the apply when Route 53 rejects the record as not permitted in the zone. Names in a second hosted zone need their own certificate and records, which the caller owns. Names are normalized to lowercase before use: ACM and Kubernetes both store them that way, and DNS is case-insensitive."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for d in var.n8n_additional_domains : can(regex("^[a-zA-Z0-9][a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$", d))])
    error_message = "Every entry must be a valid fully qualified domain name (e.g. hooks.example.com)."
  }

  validation {
    condition     = !contains(var.n8n_additional_domains, var.n8n_domain)
    error_message = "n8n_domain must not be repeated in n8n_additional_domains; it is always included on the certificate."
  }

  validation {
    condition     = length(distinct(var.n8n_additional_domains)) == length(var.n8n_additional_domains)
    error_message = "n8n_additional_domains must not contain duplicates."
  }

  # ACM's default quota is 10 names per certificate, the primary domain
  # included, so 9 is the most that can be added here.
  validation {
    condition     = length(var.n8n_additional_domains) <= 9
    error_message = "At most 9 additional domains are supported (ACM allows 10 names per certificate including n8n_domain)."
  }
}

variable "vpc_id" {
  description = "ID of the VPC n8n will deploy into. Must contain both public and private subnets with the EKS/ALB subnet tags applied."
  type        = string

  validation {
    condition     = can(regex("^vpc-[a-zA-Z0-9]+$", var.vpc_id))
    error_message = "Value must be a valid VPC ID (e.g. vpc-0123456789abcdef0)."
  }
}

variable "private_subnets" {
  description = "IDs of private subnets (one per AZ, minimum two AZs). RDS, ElastiCache, and EKS nodes attach here."
  type        = list(string)

  validation {
    condition     = length(var.private_subnets) >= 2
    error_message = "At least two private subnets in different AZs are required for RDS Multi-AZ and EKS."
  }
}

variable "public_subnets" {
  description = "IDs of public subnets (one per AZ, minimum two AZs). The ALB attaches here."
  type        = list(string)

  validation {
    condition     = length(var.public_subnets) >= 2
    error_message = "At least two public subnets in different AZs are required for the ALB."
  }
}

variable "vpc_cidr_block" {
  description = "CIDR block of the VPC — used by the RDS and Redis security groups to allow intra-VPC traffic."
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr_block, 0))
    error_message = "Value must be a valid CIDR block (e.g. 10.0.0.0/16)."
  }
}

variable "certificate_arn" {
  description = "ARN of a pre-validated ACM certificate for n8n_domain. Use this for Cloudflare, GoDaddy, or any DNS provider other than Route53 — the respective examples (examples/cloudflare, examples/godaddy) issue the certificate and pass its ARN here. Set exactly one of certificate_arn or route53_zone_id."
  type        = string
  default     = null
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID for the parent of n8n_domain (e.g. the zone for example.com if n8n_domain = n8n.example.com). When set, the module issues a DNS-validated ACM certificate and creates the alias A-record automatically — single terraform apply, no manual DNS steps. Leave null and pass certificate_arn instead. Set exactly one of certificate_arn or route53_zone_id."
  type        = string
  default     = null

  validation {
    condition     = (var.certificate_arn == null) != (var.route53_zone_id == null)
    error_message = "Set exactly one of certificate_arn or route53_zone_id."
  }
}

variable "tags" {
  description = "Additional AWS tags to apply to all resources this module creates. Merged on top of the built-in ManagedBy/Project tags."
  type        = map(string)
  default     = {}
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.35"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+$", var.kubernetes_version))
    error_message = "Value must be a Kubernetes version (e.g. 1.35)."
  }
}

variable "n8n_webhook_url" {
  description = "Public HTTPS base URL used for webhook callbacks (e.g. https://webhooks.example.com). Defaults to https://<n8n_domain> when not set. Override when webhooks are served from a different host than the n8n UI."
  type        = string
  default     = null
}

variable "n8n_license_key" {
  description = "n8n Enterprise license activation key. Get one at https://n8n.io/pricing"
  type        = string
  sensitive   = true
}

variable "n8n_license_detach_floating_on_shutdown" {
  description = "Whether n8n main pods detach their floating license entitlement on shutdown. Maps to N8N_LICENSE_DETACH_FLOATING_ON_SHUTDOWN. n8n's upstream default is true, which is safe for a single main but breaks multi-main (n8n_main_hpa_min_replicas > 1, the module default): the leader main detaches on shutdown and zeroes the shared floating cert in the database, so any fresh main pod that starts as a follower reads the zeroed cert, fails the init-time license gate, and crash-loops — which can push a Helm release with atomic = true into a stuck pending-rollback state (see docs/troubleshooting.md and https://github.com/n8n-io/terraform-aws-n8n/issues/49). The module defaults this to false, overriding n8n's own default, because all mains share the same device fingerprint: a single floating seat is reused across restarts and nothing leaks. Set to true only to restore n8n's upstream behavior, and only for single-main deployments."
  type        = bool
  default     = false
}

variable "namespace" {
  description = "Kubernetes namespace to deploy n8n into"
  type        = string
  default     = "n8n"
}

# ── Ingress ───────────────────────────────────────────────────────────────────

variable "create_ingress" {
  description = "When true (the default), the module creates the ALB Ingress that fronts n8n: a single internet-facing ALB routing /webhook to the webhook processors and / to the mains. Set to false to bring your own Ingress resources, for example the two-ALB split where an internet-facing ALB serves /webhook and a separate internal (VPN-only) ALB serves the admin UI. When false the module also skips the Route 53 alias A-record and the ALB lookup behind it, since there is no module-owned ALB to point at; the ACM certificate is still issued when route53_zone_id is set. Point your own Ingresses at the module-created Services n8n_service_name and n8n_webhook_service_name, both on port 5678. Kept as a static boolean because count expressions cannot depend on values computed at apply time."
  type        = bool
  default     = true
}

variable "ingress_scheme" {
  description = "ALB scheme for the module-managed Ingress: internet-facing (the default) or internal. Use internal to keep n8n reachable only from within the VPC and any peered/VPN networks. Ignored when create_ingress = false. An internal scheme makes the Route 53 alias record resolve to private addresses, which is the intended behavior for a private deployment."
  type        = string
  default     = "internet-facing"

  validation {
    condition     = contains(["internet-facing", "internal"], var.ingress_scheme)
    error_message = "ingress_scheme must be either \"internet-facing\" or \"internal\"."
  }
}

variable "alb_inbound_cidrs" {
  description = "IPv4 CIDR blocks allowed to reach the module-managed ALB, rendered into alb.ingress.kubernetes.io/inbound-cidrs. Empty (the default) omits the annotation, leaving the AWS Load Balancer Controller default of 0.0.0.0/0, so the ALB accepts connections from anywhere. IMPORTANT: the module-managed ALB serves the webhook path prefixes as well as the editor UI, and this restriction applies to the whole load balancer rather than per path, so it blocks inbound production webhooks from third-party senders (Slack, Stripe, GitHub, Telegram) as surely as it blocks a browser. Use it when nothing external needs to call in, or when every sender is on a known range. To lock down the editor while keeping webhooks public, run two load balancers instead: see examples/split-ingress. This narrows an internet-facing ALB; it is not the same as ingress_scheme = \"internal\", which moves the ALB into private subnets and off public DNS. The restriction applies to every listen port, so port 80 (the HTTPS redirect) is filtered too. IPv4 only, matching the ALB this module builds: it leaves the controller's default ipv4 address type in place, so an IPv6 rule would never match a client. A dualstack ALB needs a VPC and subnets with IPv6 CIDRs, which the module does not create; set the whole allow-list on the annotation through ingress_annotations if you run one. LBC ignores this annotation when alb.ingress.kubernetes.io/security-groups is set through ingress_annotations, because the caller then owns the security group. An IngressClassParams setting spec.inboundCIDRs does replace this annotation rather than merging with it, but only for an Ingress the controller classifies through spec.ingressClassName; the module-managed Ingress also carries the legacy kubernetes.io/ingress.class annotation, which the controller matches first, so a populated IngressClassParams cannot override this input. See docs/troubleshooting.md, which has the kubectl commands and covers the caller-owned Ingresses that are exposed. LBC also reverts hand-edits to the security group it manages, so widening the range back after locking yourself out is a terraform apply, not a console fix. Ignored when create_ingress = false."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for c in var.alb_inbound_cidrs : can(cidrnetmask(c))])
    error_message = "Each entry in alb_inbound_cidrs must be a valid IPv4 CIDR block including the prefix length (e.g. 203.0.113.0/24, 198.51.100.7/32). IPv6 is not supported: the module leaves the ALB at the controller's default ipv4 address type, where an IPv6 rule can never match. Set the annotation directly through ingress_annotations if you run a dualstack ALB."
  }

  # A CIDR with host bits set (203.0.113.5/24 instead of 203.0.113.0/24) passes
  # cidrnetmask, and LBC's own net.ParseCIDR accepts it too and forwards the raw
  # string, so EC2 is the first thing to reject it, when it builds the security
  # group rule. That surfaces as a stuck reconcile after an apply that looked
  # clean, which is why it is caught here instead.
  validation {
    condition = alltrue([
      for c in var.alb_inbound_cidrs :
      can(cidrnetmask(c)) ? c == "${cidrhost(c, 0)}/${split("/", c)[1]}" : true
    ])
    error_message = "Each entry in alb_inbound_cidrs must be the network address of its block, with no host bits set (203.0.113.0/24, not 203.0.113.5/24). Use /32 for a single address."
  }
}

variable "alb_inbound_prefix_list_ids" {
  description = "VPC managed prefix list IDs allowed to reach the module-managed ALB, rendered into alb.ingress.kubernetes.io/security-group-prefix-lists. Empty (the default) omits the annotation. Carries the same blast radius as alb_inbound_cidrs: the restriction covers the whole ALB, webhook paths included, so third-party webhook senders outside the lists stop reaching n8n. Preferred over alb_inbound_cidrs when the allowed ranges are already maintained as a prefix list, or shared across load balancers and security groups: the list is edited in one place and every reference follows, instead of re-applying this module for a range change. Combines with alb_inbound_cidrs, which is a union rather than an intersection. Mind the security group quota: a rule referencing a prefix list counts against the rules-per-security-group quota (default 60, quota code L-0EA8095F) by the list's max-entries weight rather than as one rule, once per listen port, and this ALB listens on 80 and 443, so everything counts twice. Keep 2 x (combined list weight + number of alb_inbound_cidrs entries) at or under the quota. A list too heavy to fit, and most AWS-managed lists are (the CloudFront origin-facing list weighs 55, needing 110 rules of the default 60 by itself), takes the ALB offline for every source instead of failing the apply: the controller revokes the existing rules first, then RulesPerSecurityGroupLimitExceeded stops it from authorizing the new ones, and the security group is left with no ingress rules at all, webhooks included, while terraform apply reports success. Verified live against LBC v3.5.0. Recovery is shrinking the lists (or raising the quota) and re-applying; see docs/troubleshooting.md. LBC ignores this annotation when alb.ingress.kubernetes.io/security-groups is set through ingress_annotations. An IngressClassParams setting spec.prefixListsIDs replaces this annotation rather than merging with it, but cannot reach the module-managed Ingress, for the reason given on alb_inbound_cidrs; see docs/troubleshooting.md. Ignored when create_ingress = false."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for id in var.alb_inbound_prefix_list_ids : can(regex("^pl-([0-9a-f]{8}|[0-9a-f]{17})$", id))])
    error_message = "Each entry in alb_inbound_prefix_list_ids must be a managed prefix list ID of the form pl-xxxxxxxx (8 or 17 lowercase hex characters, the two lengths AWS issues), not a prefix list name or ARN."
  }
}

variable "ingress_annotations" {
  description = "Extra annotations for the module-managed Ingress, merged over the module's defaults (last write wins). Use this for AWS Load Balancer Controller features the module has no opinion on: alb.ingress.kubernetes.io/wafv2-acl-arn, subnets, security-groups, load-balancer-name, group.name, access log settings. Overriding alb.ingress.kubernetes.io/target-group-attributes drops the session stickiness that keeps WebSocket connections pinned to one main pod; re-include stickiness.enabled=true if you set it. Prefer ingress_scheme over setting alb.ingress.kubernetes.io/scheme here, alb_ssl_policy over setting alb.ingress.kubernetes.io/ssl-policy here, and alb_inbound_cidrs / alb_inbound_prefix_list_ids over setting alb.ingress.kubernetes.io/inbound-cidrs or security-group-prefix-lists here, because setting both raises a plan-time warning. Ignored when create_ingress = false."
  type        = map(string)
  default     = {}
}

variable "alb_ssl_policy" {
  description = "TLS negotiation policy for the ALB HTTPS listener, wired to alb.ingress.kubernetes.io/ssl-policy. Defaults to a current, modern policy (ELBSecurityPolicy-TLS13-1-2-2021-06) so the negotiated policy is explicit and pinned in Terraform rather than left to whatever the ALB defaults to, which AWS can change without notice. Set this to any AWS-published ELB security policy name (e.g. one of the ELBSecurityPolicy-TLS13-1-2-* or ELBSecurityPolicy-FS-1-2-* families) to match a compliance baseline such as TLS 1.2 minimum or TLS 1.3-only. Ignored when create_ingress = false, or when ingress_annotations sets alb.ingress.kubernetes.io/ssl-policy directly (last write wins; the module warns when that happens)."
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-2021-06"

  validation {
    condition     = can(regex("^ELBSecurityPolicy-", var.alb_ssl_policy))
    error_message = "alb_ssl_policy must be an AWS-published ELB security policy name, beginning with \"ELBSecurityPolicy-\" (e.g. ELBSecurityPolicy-TLS13-1-2-2021-06)."
  }
}

# ── Nodes ─────────────────────────────────────────────────────────────────────
# Multi-main runs 6+ pods (2 main, 2 workers, 2 webhook processors).
# 3 × t3.medium provides enough headroom at startup; HPA scales further.

variable "node_instance_type" {
  description = "EC2 instance type for EKS worker nodes. t3.xlarge (4 vCPU, 16GB) is the recommended minimum for multi-main — the 6 n8n pods (main × 2, worker × 2, webhook × 2) request ~3,600m CPU at minimum replicas, leaving t3.medium nodes with insufficient headroom for HPA to scale."
  type        = string
  default     = "t3.xlarge"
  nullable    = false

  validation {
    condition     = can(regex("^[a-z][a-z0-9]*\\.[a-z0-9]+$", var.node_instance_type))
    error_message = "Value must be a valid EC2 instance type (e.g. t3.xlarge, m5.large)."
  }
}

variable "node_desired" {
  description = "Initial number of worker nodes. Only applies at creation: the node group's desired_size ignores changes afterward so the Cluster Autoscaler can own it without fighting plans/applies."
  type        = number
  default     = 3

  validation {
    condition     = var.node_desired >= 1
    error_message = "Desired node count must be at least 1."
  }
}

variable "node_min" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 3

  validation {
    condition     = var.node_min >= 1
    error_message = "Minimum node count must be at least 1."
  }
}

variable "node_max" {
  description = "Maximum number of worker nodes. This is the ceiling the Cluster Autoscaler scales to, so node_max × node_instance_type is the hard cap on schedulable CPU: the autoscaler maxima (n8n_main_hpa_max_replicas, n8n_webhook_hpa_max_replicas, n8n_worker_keda_max_replicas) and the per-pod CPU requests have to fit inside it. The module warns at plan time when they do not; see README.md → \"Sizing autoscaling against node capacity\"."
  type        = number
  default     = 6
  nullable    = false

  validation {
    condition     = var.node_max >= 1
    error_message = "Maximum node count must be at least 1."
  }
}

# ── n8n chart ─────────────────────────────────────────────────────────────────

variable "n8n_chart_version" {
  description = "n8n Helm chart version to deploy"
  type        = string
  default     = "1.10.0"
}

variable "n8n_image_tag" {
  description = "n8n application image tag to deploy (e.g. \"2.27.4\"). When it is null (the default), the Helm chart's own default applies — currently the floating `stable` tag, which resolves to whatever n8n version is latest at the time each pod starts. Pin this to a concrete version for reproducible, incremental upgrades and to avoid crossing major-version boundaries (e.g. the n8n 2.0 breaking changes) on an unplanned pod reschedule. See https://docs.n8n.io/2-0-breaking-changes/ for the n8n 2.x migration guide."
  type        = string
  default     = null

  validation {
    condition     = var.n8n_image_tag == null ? true : can(regex("^[a-zA-Z0-9_][a-zA-Z0-9._-]{0,127}$", var.n8n_image_tag))
    error_message = "n8n_image_tag must be a non-empty string with no whitespace, containing only alphanumeric characters, dots, underscores, and hyphens (e.g. \"1.2.3\", \"1.2.3-alpine\"). Set to null to use the chart's default (stable)."
  }
}

variable "n8n_image_repository" {
  description = "Container image repository for the n8n application, without a tag (e.g. \"123456789012.dkr.ecr.eu-west-1.amazonaws.com/n8n\"). When it is null (the default), the Helm chart's own repository applies (currently `docker.n8n.io/n8nio/n8n`). Point this at a custom image built from the n8n base image to bake community packages into the image itself, which removes the boot-time npm install that n8n_reinstall_missing_packages performs on every pod start. Set the tag through n8n_image_tag, not here. Two things come with a custom image: the image has to be pullable, which a public registry or an ECR repository in this account already is, while any other private registry needs its credentials listed in n8n_image_pull_secrets (cross-account ECR is the exception, and is better served by naming the node_group_role_arn output in the source repository's policy); and when the tag is not a published n8n version, also set n8n_task_runner_image_tag, because the chart derives the task runner sidecar's tag from this image's tag."
  type        = string
  default     = null

  validation {
    # Docker's own reference grammar (distribution/reference), narrowed to the
    # repository half: no tag, no digest. Reading it in pieces, since it is one
    # long line by necessity (a validation condition cannot reference a local):
    #
    #   label = [A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?
    #   ipv6  = \[[0-9A-Fa-f:]+\]
    #   host  = (label(.label)* | ipv6)(:port)?
    #   sep   = __ | [._] | -+
    #   comp  = [a-z0-9]+(sep[a-z0-9]+)*
    #   ref   = (host/)? comp(/comp)*
    #
    # Every accept and reject below was read off docker's exit code rather than
    # inferred, because two earlier attempts at this validation got the rules
    # backwards in both directions.
    #
    # The host is deliberately permissive about case while path components are
    # not, and that asymmetry is Docker's, not ours. splitDockerDomain treats a
    # first component as a registry host when it contains a dot or a colon, is
    # localhost, *or contains an uppercase letter*, so N8NIO/n8n and MYREG/n8n
    # are pullable while myorg/N8N is not ("repository name must be lowercase")
    # and FOO/BAR is not. Path components may carry doubled separators
    # (my--repo, my__repo, a---b) which an earlier version wrongly rejected.
    #
    # What stays rejected is a reference no registry could serve: a scheme
    # prefix, a second colon, an empty label (a..b, a trailing slash, a doubled
    # slash), a label ending in a hyphen, and an IPv6 zone ID. Each of those
    # otherwise reaches the chart and surfaces as ImagePullBackOff only after
    # the cluster is up, which is the whole point of checking at plan time.
    #
    # The bracketed host is hex and colons only, no dots, which is Docker's
    # grammar exactly: it rejects [....], [a:b.c] and even the IPv4-mapped
    # [::ffff:1.2.3.4], while accepting the structurally meaningless [::::].
    # Matching that is deliberate. Being stricter than docker here would reject
    # an address a registry would have answered on, and this validation has no
    # override.
    condition = var.n8n_image_repository == null ? true : (
      length(var.n8n_image_repository) <= 255 &&
      can(regex("^(?:(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*|\\[[0-9A-Fa-f:]+\\])(?::[0-9]+)?/)?[a-z0-9]+(?:(?:__|[._]|-+)[a-z0-9]+)*(?:/[a-z0-9]+(?:(?:__|[._]|-+)[a-z0-9]+)*)*$", var.n8n_image_repository))
    )
    error_message = "n8n_image_repository must be a bare image repository reference that Docker can pull: an optional registry host with an optional port, then one or more lowercase path components (e.g. \"myregistry.example.com/n8n\", \"registry.internal:5000/n8n\", \"n8nio/n8n\", \"[2001:db8::1]:5000/n8n\"). No scheme (\"https://\"), no whitespace, no uppercase path components, and no empty label anywhere, which rules out a trailing slash, a doubled slash, and a doubled dot. Set to null to use the chart's default (docker.n8n.io/n8nio/n8n)."
  }

  validation {
    # The chart renders `image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"`,
    # so a tag or digest carried in the repository string would render an
    # unpullable reference like "myrepo/n8n:1.2.3:stable". Catch it at plan time
    # and point at the right input instead of failing at pod start.
    condition     = var.n8n_image_repository == null ? true : !can(regex(":", reverse(split("/", var.n8n_image_repository))[0]))
    error_message = "n8n_image_repository must not include a tag or digest, because the chart appends the tag itself. Pass the version via n8n_image_tag instead (e.g. n8n_image_repository = \"myregistry.example.com/n8n\", n8n_image_tag = \"2.27.4\")."
  }
}

variable "n8n_image_pull_secrets" {
  description = "Names of existing Kubernetes secrets of type kubernetes.io/dockerconfigjson, in var.namespace, that the n8n pods authenticate to their image registry with. Leave empty (the default) for a public registry or an ECR repository in this account, which the node group's IAM role already pulls without credentials. Setting this changes who owns the ServiceAccount: the pinned chart renders imagePullSecrets nowhere, so the module creates the account itself, attaches these secrets to it, and passes serviceAccount.create = false, an arrangement the chart documents and supports. The module's account takes a different name from the chart's, so that turning this on for a deployment that already exists does not collide with the account Helm still owns; the S3 Pod Identity association follows whichever name is in play, so it keeps working either way. Creating and rotating the secrets stays the caller's job, because a dockerconfigjson generated here would sit in plaintext in Terraform state; kubectl create secret docker-registry, or an operator like External Secrets, are the usual routes. This is also the wrong tool for cross-account ECR, whose authorization tokens expire after 12 hours: add the node group role to the source registry's repository policy instead and leave this empty. The node_group_role_arn output is the principal to name in that policy."
  type        = list(string)
  default     = []

  validation {
    # A secret name is a DNS-1123 subdomain. Rejecting a malformed one here
    # beats the alternative: the ServiceAccount apply fails partway through,
    # after the cluster and the namespace already exist.
    condition = alltrue([
      for name in var.n8n_image_pull_secrets :
      can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$", name))
    ])
    error_message = "Every n8n_image_pull_secrets entry must be a DNS-1123 subdomain, which is what Kubernetes requires of a secret name: lowercase alphanumerics, hyphens and dots, starting and ending with an alphanumeric, with no empty label (e.g. \"ecr-cross-account\"). Pass the secret's name, not its contents."
  }

  validation {
    condition = alltrue([
      for name in var.n8n_image_pull_secrets : length(name) <= 253
    ])
    error_message = "Every n8n_image_pull_secrets entry must be 253 characters or fewer, the Kubernetes limit on a secret name."
  }

  validation {
    # Kubernetes tolerates a repeated imagePullSecrets entry, but a duplicate
    # here is far more likely to be a copy-paste slip than an intent.
    condition     = length(distinct(var.n8n_image_pull_secrets)) == length(var.n8n_image_pull_secrets)
    error_message = "n8n_image_pull_secrets must not repeat a secret name. Listing one twice adds nothing, since the kubelet tries each entry once."
  }
}

variable "n8n_helm_timeout" {
  description = "Seconds Terraform waits for the n8n Helm release to converge. Increase for large deployments where rolling out 50+ pods (workers + webhook processors + main) exceeds the default. 600s is fine for the default/medium examples; large deployments at 250+ pods need ~1800s."
  type        = number
  default     = 600

  validation {
    condition     = var.n8n_helm_timeout >= 60
    error_message = "n8n_helm_timeout must be at least 60 seconds."
  }
}

variable "n8n_timezone" {
  description = "Timezone for n8n (e.g. UTC, America/New_York, Europe/London)"
  type        = string
  default     = "UTC"
}

variable "n8n_log_level" {
  description = "n8n log level. Maps to the N8N_LOG_LEVEL environment variable. One of: silent, error, warn, info, debug, verbose."
  type        = string
  default     = "info"

  validation {
    condition     = contains(["silent", "error", "warn", "info", "debug", "verbose"], var.n8n_log_level)
    error_message = "n8n_log_level must be one of: silent, error, warn, info, debug, verbose."
  }
}

variable "n8n_log_output" {
  description = "n8n log output destination(s). Maps to the N8N_LOG_OUTPUT environment variable. Comma-separated subset of: console, file (e.g. \"console\", \"file\", \"console,file\"). Note: this variable does NOT control log *format* — setting an invalid value (e.g. \"json\") leaves Winston with no transport and silently drops all logs. To emit JSON-formatted logs, configure n8n's logging block separately; this env var only selects destinations."
  type        = string
  default     = "console"

  validation {
    condition     = alltrue([for v in split(",", var.n8n_log_output) : contains(["console", "file"], trimspace(v))])
    error_message = "n8n_log_output only accepts console and/or file (comma-separated, e.g. \"console\" or \"console,file\")."
  }
}

# ── n8n resource requests and limits ──────────────────────────────────────────

variable "n8n_main_cpu_request" {
  description = "CPU request for n8n main pods (e.g. 1000m, 500m)"
  type        = string
  default     = "1000m"
}

variable "n8n_main_cpu_limit" {
  description = "CPU limit for n8n main pods (e.g. 2000m, 1000m)"
  type        = string
  default     = "2000m"
}

variable "n8n_main_memory_request" {
  description = "Memory request for n8n main pods (e.g. 2Gi, 1Gi)"
  type        = string
  default     = "2Gi"
}

variable "n8n_main_memory_limit" {
  description = "Memory limit for n8n main pods (e.g. 4Gi, 2Gi)"
  type        = string
  default     = "4Gi"
}

variable "n8n_worker_cpu_request" {
  description = "CPU request for n8n worker pods (e.g. 500m, 1000m)"
  type        = string
  default     = "500m"
}

variable "n8n_worker_cpu_limit" {
  description = "CPU limit for n8n worker pods (e.g. 1000m, 2000m)"
  type        = string
  default     = "1000m"
}

variable "n8n_worker_memory_request" {
  description = "Memory request for n8n worker pods (e.g. 1Gi, 2Gi)"
  type        = string
  default     = "1Gi"
}

variable "n8n_worker_memory_limit" {
  description = "Memory limit for n8n worker pods (e.g. 2Gi, 4Gi)"
  type        = string
  default     = "2Gi"
}

variable "n8n_webhook_cpu_request" {
  description = "CPU request for n8n webhook processor pods (e.g. 300m, 500m). This default is sized for typical webhook traffic, not for n8n_reinstall_missing_packages = true: a low request against an npm-install CPU spike is what drives the CPU-based HPA into a scale-up-on-every-rollout loop. Raise to at least 800m when that toggle is on; see n8n_reinstall_missing_packages and docs/troubleshooting.md."
  type        = string
  default     = "300m"
}

variable "n8n_webhook_cpu_limit" {
  description = "CPU limit for n8n webhook processor pods (e.g. 800m, 1000m). Raise to at least 1500m when n8n_reinstall_missing_packages = true; see that variable and docs/troubleshooting.md."
  type        = string
  default     = "800m"
}

variable "n8n_webhook_memory_request" {
  description = "Memory request for n8n webhook processor pods (e.g. 512Mi, 1Gi). Raise to at least 1Gi when n8n_reinstall_missing_packages = true; see that variable and docs/troubleshooting.md."
  type        = string
  default     = "512Mi"
}

variable "n8n_webhook_memory_limit" {
  description = "Memory limit for n8n webhook processor pods (e.g. 1Gi, 2Gi). This default is too low for n8n_reinstall_missing_packages = true: concurrent npm installs plus the n8n baseline can exceed it and OOMKill the pod mid-install into a reinstall/broadcast crash loop. Raise to at least 2Gi when that toggle is on; see that variable and docs/troubleshooting.md."
  type        = string
  default     = "1Gi"
}

# ── Execution settings ────────────────────────────────────────────────────────

variable "n8n_worker_concurrency" {
  description = "Number of jobs each worker pod can process simultaneously"
  type        = number
  default     = 10

  validation {
    condition     = var.n8n_worker_concurrency >= 1
    error_message = "Worker concurrency must be at least 1."
  }
}

variable "n8n_execution_timeout" {
  description = "Default execution timeout in seconds (-1 to disable)"
  type        = number
  default     = 7200
}

variable "n8n_execution_timeout_max" {
  description = "Maximum execution timeout users can configure in seconds"
  type        = number
  default     = 7200
}

variable "n8n_execution_concurrency_limit" {
  description = "Maximum concurrent production executions (-1 to disable)"
  type        = number
  default     = 100
}

variable "n8n_pruning_max_age" {
  description = "Maximum age of execution records to retain, in hours (336 = 14 days)"
  type        = number
  default     = 336
}

variable "n8n_pruning_max_count" {
  description = "Maximum number of execution records to retain (0 = no limit)"
  type        = number
  default     = 10000
}

variable "n8n_execution_data_storage_mode" {
  description = "Where n8n stores the data of each new execution. Maps to N8N_EXECUTION_DATA_STORAGE_MODE. \"database\" (the default) keeps execution data in PostgreSQL, matching n8n's own default, and emits no env var. \"s3\" offloads it to the module's S3 bucket, reusing the same bucket and N8N_EXTERNAL_STORAGE_S3_* connection that binary data mode already uses, so no extra bucket, IAM policy, or credentials are needed. Execution-data writes are usually the dominant write load on the n8n database at volume, so s3 is the main lever for relieving RDS pressure. Requires n8n >= 2.27 (pin n8n_image_tag accordingly) and an Enterprise license carrying the feat:executionDataS3 entitlement, which is a different entitlement from the feat:binaryDataS3 one the always-on binary data offload uses: n8n refuses to start in s3 mode without it. There is no backfill: existing executions stay readable where they were written, and only new executions go to S3, under workflows/{workflowId}/executions/{executionId}/execution_data/bundle.json. n8n prunes those objects itself as part of the executions hard-delete path (see n8n_pruning_max_age / n8n_pruning_max_count), so do NOT add an S3 lifecycle rule that can reach execution_data/ objects (see the S3 lifecycle section in the README). Note the durability trade-off: RDS gets automated backups and point-in-time recovery (db_backup_retention_period, default 7 days) while the bucket has no versioning, no backups, and force_destroy = true, so in s3 mode a terraform destroy takes execution history with it. See the durability section in the README. \"filesystem\" is deliberately not accepted: pod filesystems are ephemeral and unshared in this module's queue-mode topology, so execution data written there would be lost on reschedule and invisible to the other pods. See https://docs.n8n.io/deploy/host-n8n/configure-n8n/scaling/use-external-storage."
  type        = string
  default     = "database"
  nullable    = false

  validation {
    condition     = contains(["database", "s3"], var.n8n_execution_data_storage_mode)
    error_message = "n8n_execution_data_storage_mode must be either \"database\" (n8n's default, execution data in PostgreSQL) or \"s3\" (execution data offloaded to the module's S3 bucket). \"filesystem\" is not supported by this module: pod filesystems are ephemeral and unshared in queue mode."
  }
}

# ── Graceful shutdown ─────────────────────────────────────────────────────────

variable "n8n_termination_grace_period" {
  description = "Seconds Kubernetes waits after SIGTERM before force-killing pods. MINIMUM — do not lower below 60. Workers need time to finish in-flight executions before being terminated."
  type        = number
  default     = 60

  validation {
    condition     = var.n8n_termination_grace_period >= 60
    error_message = "Termination grace period must be at least 60 seconds to allow in-flight executions to complete."
  }
}

variable "n8n_prestop_sleep" {
  description = "Seconds the preStop hook sleeps before SIGTERM is sent, giving the load balancer time to drain the pod. MINIMUM — do not lower below 10."
  type        = number
  default     = 10

  validation {
    condition     = var.n8n_prestop_sleep >= 10
    error_message = "Pre-stop sleep must be at least 10 seconds for load balancer drain."
  }
}

# ── Task runners ──────────────────────────────────────────────────────────────

variable "n8n_task_runners_enabled" {
  description = "Enable task runner sidecars for isolated JavaScript and Python code execution"
  type        = bool
  default     = true
  nullable    = false
}

variable "n8n_task_runner_image_tag" {
  description = "Image tag for the task runner sidecar (`n8nio/runners`). When it is null (the default), the chart falls back to the n8n application image's tag, which is the right behavior as long as that tag is a published n8n version. Set this to the underlying n8n version when running a custom application image whose tag is not one (e.g. n8n_image_tag = \"2.27.4-mypackages\" together with n8n_task_runner_image_tag = \"2.27.4\"); otherwise the sidecar tries to pull `n8nio/runners:2.27.4-mypackages` and every main and worker pod stays in ImagePullBackOff. Reproduced on a live cluster, where kubelet reported `docker.io/n8nio/runners:<tag>: not found`; because the release waits for readiness, the apply blocks and then fails rather than completing with broken pods, and webhook processors are unaffected since they run no runner sidecar. The tag should match the n8n version in the application image, since the runner protocol is versioned with n8n. Ignored when n8n_task_runners_enabled = false."
  type        = string
  default     = null

  validation {
    condition     = var.n8n_task_runner_image_tag == null ? true : can(regex("^[a-zA-Z0-9_][a-zA-Z0-9._-]{0,127}$", var.n8n_task_runner_image_tag))
    error_message = "n8n_task_runner_image_tag must be a non-empty string with no whitespace, containing only alphanumeric characters, dots, underscores, and hyphens (e.g. \"2.27.4\"). Set to null to inherit the n8n application image's tag."
  }
}

variable "n8n_task_runner_cpu_request" {
  description = "CPU request for task runner sidecar containers (e.g. 200m, 500m)"
  type        = string
  default     = "200m"
}

variable "n8n_task_runner_cpu_limit" {
  description = "CPU limit for task runner sidecar containers (e.g. 1, 2000m)"
  type        = string
  default     = "1"
}

variable "n8n_task_runner_memory_request" {
  description = "Memory request for task runner sidecar containers (e.g. 512Mi, 1Gi)"
  type        = string
  default     = "512Mi"
}

variable "n8n_task_runner_memory_limit" {
  description = "Memory limit for task runner sidecar containers (e.g. 1Gi, 2Gi)"
  type        = string
  default     = "1Gi"
}

variable "n8n_task_runner_auto_shutdown_timeout" {
  description = "Seconds of inactivity before the runner process shuts down. Set to 0 to disable."
  type        = number
  default     = 15
}

variable "n8n_task_runner_python_enabled" {
  description = "Enable the native Python runner (beta). Required for Python code execution in workflows."
  type        = bool
  default     = true
}

# ── RDS PostgreSQL ─────────────────────────────────────────────────────────────

variable "db_instance_class" {
  description = "RDS instance class (db.t3.small ~$25/month, db.t3.medium for higher load)"
  type        = string
  default     = "db.t3.small"

  validation {
    condition     = can(regex("^db\\.", var.db_instance_class))
    error_message = "Value must be a valid RDS instance class (e.g. db.t3.small, db.r6g.large)."
  }
}

variable "db_engine_version" {
  description = "PostgreSQL engine version for the RDS instance. Must be a version available from `aws rds describe-db-engine-versions --engine postgres` in the target region — RDS deprecates and removes minor versions over time, and supported versions vary by region. Bump as needed without forking."
  type        = string
  default     = "18.4"
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+$", var.db_engine_version))
    error_message = "db_engine_version must be of the form MAJOR.MINOR (e.g. 18.4)."
  }
}

variable "db_multi_az" {
  description = "Deploy RDS in Multi-AZ mode for automatic failover (recommended for production)"
  type        = bool
  default     = true
}

variable "db_storage_encrypted" {
  description = "When true (the default), encrypt the RDS instance's storage, Performance Insights data, and the postgresql CloudWatch log group with a module-created Customer Managed KMS Key (aws_kms_key.db). Clears Checkov findings CKV_AWS_16, CKV_AWS_354, and CKV_AWS_158. Flipping this from false to true on an existing RDS instance forces a replacement — AWS does not support enabling storage encryption in place, so the upgrade path is snapshot → restore into a new encrypted instance. Set to false in your tfvars to preserve current behavior on pre-existing unencrypted deployments. The CMK rotates annually and uses a 7-day deletion window (AWS minimum). Ignored when create_database = false."
  type        = bool
  default     = true
}

variable "db_allocated_storage" {
  description = "Allocated storage for RDS in GB"
  type        = number
  default     = 50

  validation {
    condition     = var.db_allocated_storage >= 20
    error_message = "RDS allocated storage must be at least 20 GB."
  }
}

variable "db_backup_retention_period" {
  description = "Number of days to retain automated RDS backups. 0 disables automated backups (not recommended, and it also disables point-in-time recovery). AWS allows up to 35 days. Ignored when create_database = false."
  type        = number
  default     = 7

  validation {
    condition     = var.db_backup_retention_period >= 0 && var.db_backup_retention_period <= 35
    error_message = "db_backup_retention_period must be between 0 and 35 days."
  }

  # RDS counts retention in whole days. Without this the fractional value
  # reaches the provider, which does reject it, but blames
  # aws_db_instance.n8n inside the module: the caller sees a file they do not
  # own and an attribute name (backup_retention_period) that is not the input
  # they set. terraform validate does not catch it at all. Failing here names
  # the variable and the line the caller actually wrote.
  validation {
    condition     = var.db_backup_retention_period == floor(var.db_backup_retention_period)
    error_message = "db_backup_retention_period must be a whole number of days."
  }
}

variable "db_allowed_cidr_blocks" {
  description = "Additional CIDR blocks allowed to reach the module-managed RDS instance on port 5432, appended to the VPC CIDR (which is always allowed so nodes and pods can connect). Use this for a corporate network, VPN pool, or peered VPC rather than attaching a standalone aws_security_group_rule at the root, because a root-level rule is not tracked by the module's inline ingress block and gets stripped on the next plan. Duplicates, including a repeat of the VPC CIDR, are collapsed. With create_database = false the security group is still created and carries these rules, but nothing is attached to it."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.db_allowed_cidr_blocks : can(cidrnetmask(c))])
    error_message = "Each entry in db_allowed_cidr_blocks must be a valid IPv4 CIDR block (e.g. 10.20.0.0/16)."
  }
}

variable "db_allowed_security_group_ids" {
  description = "Security group IDs allowed to reach the module-managed RDS instance on port 5432, in addition to the always-allowed VPC CIDR. Preferred over db_allowed_cidr_blocks for sources inside the VPC: membership follows the instances rather than their addresses, so the rule survives subnet changes and IP reuse. Use it for a bastion, a migration runner, or an app tier that already has its own group. No rule is created when the list is empty. With create_database = false the security group is still created and carries this rule, but nothing is attached to it."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for id in var.db_allowed_security_group_ids : can(regex("^sg-[0-9a-f]{8,17}$", id))])
    error_message = "Each entry in db_allowed_security_group_ids must be a security group ID of the form sg-xxxxxxxx."
  }
}

variable "create_database" {
  description = "When true (the default), the module creates and manages an Amazon RDS PostgreSQL instance. Set to false to use an external database (e.g. Amazon Aurora created by the caller) — db_host and db_password must then be supplied. Kept as a static boolean rather than `db_host == null` because count expressions cannot depend on values computed at apply time."
  type        = bool
  default     = true
}

variable "db_host" {
  description = "External database host. Required when create_database = false. Ignored otherwise. Use this to pass in an Amazon Aurora cluster endpoint or any external PostgreSQL host."
  type        = string
  default     = null

  validation {
    condition     = var.create_database || var.db_host != null
    error_message = "db_host is required when create_database = false."
  }
}

variable "db_password" {
  description = "Password for the external database specified by db_host. Required when create_database = false. Ignored otherwise (the module generates a random password for its managed RDS instance)."
  type        = string
  default     = null
  sensitive   = true

  validation {
    condition     = var.create_database || var.db_password != null
    error_message = "db_password is required when create_database = false."
  }
}

variable "db_postgresdb_pool_size" {
  description = "Number of TypeORM connection pool slots per n8n pod. Each pod holds this many persistent PostgreSQL connections. Rule of thumb: pool_size >= worker_concurrency / 4. With PgBouncer in transaction mode a lower value (5) is sufficient; without PgBouncer use a value matching concurrency (10-20)."
  type        = number
  default     = 10

  validation {
    condition     = var.db_postgresdb_pool_size >= 1
    error_message = "db_postgresdb_pool_size must be at least 1."
  }
}

variable "db_postgresdb_ssl_enabled" {
  description = "Whether n8n connects to the database over SSL. Set to true (the default) for direct connections to RDS or Aurora — they use the AWS CA which Node.js doesn't trust by default, so the connection still negotiates SSL but skips certificate verification. Set to false when n8n connects to an in-cluster connection pooler (e.g. PgBouncer) that handles SSL on its upstream leg — the pod-to-pod traffic stays inside the cluster network."
  type        = bool
  default     = true
}

# ── ElastiCache Redis ──────────────────────────────────────────────────────────

variable "redis_node_type" {
  description = "ElastiCache node type (cache.t3.medium ~$25/month). Sizes the single node when redis_high_availability_enabled = false, and every node in the replication group when it is true, so the Redis line of the bill scales with the node count, not just the type. Ignored when create_elasticache = false."
  type        = string
  default     = "cache.t3.medium"

  validation {
    condition     = can(regex("^cache\\.", var.redis_node_type))
    error_message = "Value must be a valid ElastiCache node type (e.g. cache.t3.medium)."
  }
}

variable "redis_high_availability_enabled" {
  description = "When true, provision Redis as a two-node aws_elasticache_replication_group (one primary, one replica) with automatic_failover_enabled and multi_az_enabled, instead of the default single-node aws_elasticache_cluster. Redis backs the Bull queue that distributes executions across workers and the multi-main leader election, so the default single node is a single point of failure: a node or AZ event stalls both until ElastiCache replaces it. Both nodes use redis_node_type, so the Redis cost roughly doubles. What this buys is that the QUEUE SURVIVES the node loss, not that n8n rides the failover out: measured on a live cluster, ElastiCache promotes the replica in about 20 seconds and every main, worker and webhook pod exits and restarts during that window (n8n's RedisClientService calls process.exit once Redis has been unreachable for QUEUE_BULL_REDIS_TIMEOUT_THRESHOLD, and raising that threshold to 30s only delays the exit). Recovery is automatic and takes well under a minute, and the queued executions are still there on the promoted node. Compare that with the single-node default, where a lost node means waiting for AWS to build a new one and the queue is gone with it. FLIPPING THIS ON AN EXISTING DEPLOYMENT REPLACES REDIS: the two topologies are different resource types, so no `moved` block can bridge them and Terraform destroys the cluster before creating the replication group. Every queued and in-flight execution in Redis at that moment is lost. See README → \"Redis high availability\" for the drain-first procedure."
  type        = bool
  default     = false

  # null is not meaningful here: a caller writing `x = null` in a module block
  # would otherwise propagate null into the count expressions in redis.tf and
  # die with an opaque "Invalid count argument". See AGENTS.md on nullable.
  nullable = false
}

variable "create_elasticache" {
  description = "When true (the default), the module creates and manages the ElastiCache Redis that the Bull queue and multi-main leader election run on. Set to false to point n8n at an external Redis. redis_host must then be supplied, and the module creates no ElastiCache cluster, replication group, subnet group, or security group. Mirrors create_database, and is the hook the cross-region HA/DR design uses to share one replication-capable Redis between regions. Kept as a static boolean rather than `redis_host == null` because count expressions cannot depend on values computed at apply time. The module wires host and port only: an external Redis that requires AUTH or TLS is not supported yet."
  type        = bool
  default     = true

  # null is not meaningful here: a caller writing `x = null` in a module block
  # would otherwise propagate null into every Redis-tier count expression and
  # die with an opaque "Invalid count argument". See AGENTS.md on nullable.
  nullable = false
}

variable "redis_host" {
  description = "External Redis host. Required when create_elasticache = false. Ignored otherwise. Must be reachable from the EKS node subnets on redis_port, and must accept unauthenticated, non-TLS connections, because the module wires neither a Redis password nor TLS. For a replication group the caller manages, use its primary endpoint rather than a node address, so the name follows the primary across a failover."
  type        = string
  default     = null

  # Blank is rejected as well as null. An empty string satisfies "is set" but
  # reaches n8n and KEDA as an empty host, so the apply succeeds and the queue
  # has nowhere to connect: the same succeeds-then-fails-at-runtime shape the
  # check blocks in redis.tf exist to prevent.
  #
  # Written as nested ternaries rather than `||` and `&&` because Terraform 1.9,
  # which CI pins, does not short-circuit either operator. trimspace(null) is a
  # hard error, so the null test has to gate the blank test structurally rather
  # than by evaluation order. See AGENTS.md.
  validation {
    condition = var.create_elasticache ? true : (
      var.redis_host != null ? trimspace(var.redis_host) != "" : false
    )
    error_message = "redis_host is required, and must not be blank, when create_elasticache = false."
  }

  # A padded host such as " redis.internal.example.com " survives the blank test
  # above, because that one only inspects the trimmed value. The module consumes
  # the RAW value: local.redis_host feeds n8n's host field and is interpolated
  # into KEDA's "${local.redis_host}:${local.redis_port}", so the padding is
  # emitted literally and the address never resolves. Rejected rather than
  # trimmed in locals.tf, so that the value the caller sets is the value that
  # gets deployed and a stray space is corrected at its source instead of being
  # silently swallowed. Split from the blank test rather than folded into it so
  # the two mistakes get their own error message.
  #
  # null passes here; the validation above owns that case.
  validation {
    condition = var.create_elasticache ? true : (
      var.redis_host != null ? var.redis_host == trimspace(var.redis_host) : true
    )
    error_message = "redis_host must not have leading or trailing whitespace, because the module wires it into n8n and KEDA verbatim."
  }
}

variable "redis_port" {
  description = "Port of the external Redis specified by redis_host. Ignored when create_elasticache = true, because module-managed ElastiCache always listens on 6379."
  type        = number
  default     = 6379

  # null is not meaningful here: a caller writing `x = null` in a module block
  # would otherwise reach `null >= 1` in the validation below and die with an
  # opaque comparison error instead of a clean message. See AGENTS.md.
  nullable = false

  validation {
    condition     = var.redis_port >= 1 && var.redis_port <= 65535
    error_message = "redis_port must be a TCP port between 1 and 65535."
  }

  validation {
    condition     = var.redis_port == floor(var.redis_port)
    error_message = "redis_port must be a whole number."
  }
}

variable "n8n_task_runner_request_timeout" {
  description = "Seconds n8n waits for a task runner to accept a Code node task. Wired to the N8N_RUNNERS_TASK_REQUEST_TIMEOUT env var on the main pod. Increase if Code nodes fail with 'task request timed out' under high concurrency (many parallel Code nodes competing for the single runner sidecar)."
  type        = number
  default     = 300
}

# ── HPA: main pods ────────────────────────────────────────────────────────────

variable "n8n_main_hpa_min_replicas" {
  description = "Minimum replicas for n8n main pods. HPA will not scale below this. Also becomes the deployment's own replica count: the Helm chart renders spec.replicas unconditionally, so leaving it below the autoscaler floor would make every helm upgrade scale down and then wait for the autoscaler to climb back. Keep at 2 or more for availability: mains serve the editor and REST API, and the module's PodDisruptionBudget only guarantees one during a node drain."
  type        = number
  default     = 2
  nullable    = false

  validation {
    condition     = var.n8n_main_hpa_min_replicas <= var.n8n_main_hpa_max_replicas
    error_message = "n8n_main_hpa_min_replicas must not exceed n8n_main_hpa_max_replicas; Kubernetes rejects an HPA whose minReplicas is above its maxReplicas."
  }
}

variable "n8n_main_hpa_max_replicas" {
  description = "Maximum replicas for n8n main pods. HPA will not scale above this. The default of 6 is sized to the default node group (node_max × node_instance_type): at the default CPU requests, 6 main pods plus their task runner sidecars, the worker ceiling, and the webhook ceiling all fit in what 6 t3.xlarge nodes can schedule. Raise this together with node_max or node_instance_type. An HPA ceiling the node group cannot hold leaves pods Pending with \"Insufficient cpu\" once the Cluster Autoscaler reaches node_max, which also slows rollouts. The module warns at plan time when the three groups are out of step; see README.md → \"Sizing autoscaling against node capacity\"."
  type        = number
  default     = 6
  nullable    = false
}

variable "n8n_main_hpa_cpu_threshold" {
  description = "Target average CPU utilization (%) that triggers scaling of n8n main pods."
  type        = number
  default     = 60
}

# ── HPA: webhook processor pods ───────────────────────────────────────────────

variable "n8n_webhook_hpa_min_replicas" {
  description = "Minimum replicas for n8n webhook processor pods. HPA will not scale below this. Also becomes the deployment's own replica count: the Helm chart renders spec.replicas unconditionally, so leaving it below the autoscaler floor would make every helm upgrade scale down and then wait for the autoscaler to climb back. Webhook processors take production webhook traffic, so a warm floor is what keeps a traffic ramp from queueing behind pod startup."
  type        = number
  default     = 2
  nullable    = false

  validation {
    condition     = var.n8n_webhook_hpa_min_replicas <= var.n8n_webhook_hpa_max_replicas
    error_message = "n8n_webhook_hpa_min_replicas must not exceed n8n_webhook_hpa_max_replicas; Kubernetes rejects an HPA whose minReplicas is above its maxReplicas."
  }
}

variable "n8n_webhook_hpa_max_replicas" {
  description = "Maximum replicas for n8n webhook processor pods. HPA will not scale above this. The default of 8 is sized to the default node group (node_max × node_instance_type), alongside the main and worker ceilings. Webhook processors are the cheapest pod family to scale (no task runner sidecar, 300m by default), so this is usually the first ceiling to raise once node_max goes up. See n8n_main_hpa_max_replicas and README.md → \"Sizing autoscaling against node capacity\"."
  type        = number
  default     = 8
  nullable    = false
}

variable "n8n_webhook_hpa_cpu_threshold" {
  description = "Target average CPU utilization (%) that triggers scaling of n8n webhook pods."
  type        = number
  default     = 65
}

variable "n8n_webhook_hpa_scale_up_stabilization_window_seconds" {
  description = "Seconds the webhook processor HPA looks back before scaling up, via the HPA's behavior.scaleUp.stabilizationWindowSeconds. Kubernetes' own default is 0 (scale up immediately), which this module preserves by default. A short CPU spike right after a pod boots (e.g. from N8N_REINSTALL_MISSING_PACKAGES=true reinstalling community packages, see n8n_reinstall_missing_packages) can read as sustained high utilization and trigger a scale-up that a slightly longer window would absorb. Raise this (e.g. to 300) to require CPU to stay above threshold for that long before adding pods. Must be between 0 and 3600, the range the Kubernetes API enforces."
  type        = number
  default     = 0

  validation {
    condition     = var.n8n_webhook_hpa_scale_up_stabilization_window_seconds >= 0 && var.n8n_webhook_hpa_scale_up_stabilization_window_seconds <= 3600
    error_message = "n8n_webhook_hpa_scale_up_stabilization_window_seconds must be between 0 and 3600 seconds, the range the Kubernetes HPA API enforces."
  }
}

# ── Observability ─────────────────────────────────────────────────────────────

variable "n8n_metrics_enabled" {
  description = "Enable n8n's built-in Prometheus metrics endpoint. When true, the module appends N8N_METRICS=true to the n8n Helm release's config.extraEnv, which the chart applies to every n8n container (main, worker, webhook processor). n8n exposes /metrics on its existing HTTP port (5678) — the same port and service the chart already publishes for the UI/API. The n8n Helm chart at the currently pinned version (see n8n_chart_version) exposes no top-level metrics / serviceMonitor block of its own, so this toggle is intentionally env-var-only. Scrape configuration (Prometheus scrape annotations or a ServiceMonitor CR) is left to the caller's monitoring stack — in practice the main pod's Service is the meaningful scrape target. Defaults to false; when false the env var is omitted entirely so n8n's own defaults apply."
  type        = bool
  default     = false
}

variable "n8n_templates_enabled" {
  description = "Enable n8n's workflow templates and template suggestions. Maps to N8N_TEMPLATES_ENABLED. When false, sets N8N_TEMPLATES_ENABLED=false on all n8n pods (main, worker, webhook processor) via config.extraEnv. Defaults to true, matching n8n's own default — note that explicitly setting true emits no env var (n8n's default already applies). Set to false to hide the templates library, e.g. when enforcing curated internal workflows."
  type        = bool
  default     = true
}

variable "n8n_personalization_enabled" {
  description = "Whether n8n asks users personalization survey questions and tailors content/recommendations based on the answers. Maps to N8N_PERSONALIZATION_ENABLED. When false, sets N8N_PERSONALIZATION_ENABLED=false on all n8n pods (main, worker, webhook processor) via config.extraEnv. Defaults to true, matching n8n's own default — note that explicitly setting true emits no env var (n8n's default already applies). Set to false to skip the personalization survey, e.g. on shared or ephemeral instances."
  type        = bool
  default     = true
}

# ── Community packages ────────────────────────────────────────────────────────

variable "n8n_reinstall_missing_packages" {
  description = "Reinstall community packages that are recorded in the database but missing from a pod's local filesystem at startup. Maps to N8N_REINSTALL_MISSING_PACKAGES. n8n stores installed community packages on the pod's filesystem, which is ephemeral in EKS, so a rescheduled or newly scaled-up worker comes up without them and nodes installed via the UI fail to load on that pod. Enabling this makes every pod (main, worker, and webhook-processor) reinstall the recorded packages on boot, which is what lets community nodes work reliably in queue mode. n8n defaults this to false; when false the env var is omitted entirely so n8n's own default applies. When true, size the webhook processor above this module's defaults: every pod runs npm installs at boot and n8n rebroadcasts installs to all pods via pubsub, so a rolling restart makes every webhook pod install repeatedly at once. Against low CPU/memory this causes CPU-based HPA thrash and OOMKilled crash loops; see n8n_webhook_cpu_request, n8n_webhook_memory_limit, and docs/troubleshooting.md."
  type        = bool
  default     = false
}

variable "n8n_community_packages_registry" {
  description = "npm registry community packages are installed from (e.g. https://npm.internal.example.com). Maps to N8N_COMMUNITY_PACKAGES_REGISTRY, which n8n gates behind a specific licensed feature rather than a license key alone: any value other than https://registry.npmjs.org makes installs throw FeatureNotLicensedError unless the instance is entitled to COMMUNITY_NODES_CUSTOM_REGISTRY (`getNpmRegistry` in community-packages.service.ts). Confirm that entitlement before setting this, since an unentitled instance breaks community-package installs instead of falling back to the public registry. Point this at a private mirror to install community nodes from an internal registry instead of the public npm one, e.g. when egress to registry.npmjs.org is blocked or packages are vendored. n8n defaults to https://registry.npmjs.org; when this is null (the default) the env var is omitted entirely so n8n's own default applies. A mirror that requires authentication also needs N8N_COMMUNITY_PACKAGES_AUTH_TOKEN, which this module does not manage; pass it via n8n_extra_env, keeping in mind that n8n_extra_env values are stored in plaintext in the Helm release and Terraform state. Baking packages into a custom image via n8n_image_repository avoids registry access at pod start entirely."
  type        = string
  default     = null

  validation {
    # A scheme check alone accepted a bare "https://", which n8n only rejects
    # when it first tries to install a package. Require a host, and a numeric
    # port if one is given, so a truncated value fails at plan instead.
    condition     = var.n8n_community_packages_registry == null ? true : can(regex("^https?://[A-Za-z0-9._~-]+(:[0-9]+)?(/[^[:space:]]*)?$", var.n8n_community_packages_registry))
    error_message = "n8n_community_packages_registry must be a registry URL with a host, starting with http:// or https://, with an optional numeric port and path, and no whitespace (e.g. https://npm.internal.example.com, https://npm.internal.example.com:4873/repository/npm-group). Set to null to use n8n's default (https://registry.npmjs.org)."
  }
}

variable "n8n_custom_extensions_path" {
  description = "Absolute path inside the n8n container that n8n scans for custom nodes at startup (e.g. \"/opt/n8n-nodes\"). Maps to N8N_CUSTOM_EXTENSIONS, and is set on every pod type (main, worker, webhook processor). This is the supported way to ship nodes baked into a custom image: since n8n 1.0 the loader no longer picks up nodes from the image's global node_modules, so a plain npm install into the image is never seen (n8n v10 migration guide, and packages/cli/src/load-nodes-and-credentials.ts). Something has to put files at this path, so either set n8n_image_repository to an image that baked them in, or mount a volume that carries them with n8n_extra_volumes and n8n_extra_volume_mounts; a path with neither behind it warns at plan time. The path must be outside /home/node/.n8n, which the chart mounts over on main pods (see the validation below). Two caveats that no Terraform input can fix. First, nodes loaded this way are registered under the package name CUSTOM, so a node whose type was n8n-nodes-example.myNode when installed from npm becomes CUSTOM.myNode, and existing workflows referencing the npm-qualified type will not resolve. Second, only one directory is exposed even though n8n accepts a semicolon-separated list, because every custom directory is registered under the same CUSTOM key and each one overwrites the last, so all but the final directory are silently dropped. Leave null (the default) to omit the env var entirely."
  type        = string
  default     = null

  validation {
    condition     = var.n8n_custom_extensions_path == null ? true : can(regex("^/[^[:space:];]*$", var.n8n_custom_extensions_path))
    error_message = "n8n_custom_extensions_path must be an absolute container path with no whitespace and no semicolon (e.g. \"/opt/n8n-nodes\"). n8n splits N8N_CUSTOM_EXTENSIONS on \";\", so a semicolon here would be parsed as two directories and silently drop all but the last."
  }

  validation {
    # The shadowing check below is a string comparison, so it only holds if the
    # mounted directory has a single spelling. /home/node//.n8n/custom,
    # /home/node/./.n8n/custom and /opt/../home/node/.n8n/custom all resolve
    # inside the mount in the container while slipping past a startswith() on
    # the raw value. Requiring a canonical path is the sound fix: abspath()
    # would normalize against the machine running Terraform rather than the
    # container filesystem, and rewrites separators on Windows.
    condition     = var.n8n_custom_extensions_path == null ? true : !can(regex("//|/\\.\\.?(/|$)", var.n8n_custom_extensions_path))
    error_message = "n8n_custom_extensions_path must be a canonical path: no repeated slashes and no \".\" or \"..\" components (e.g. \"/opt/n8n-nodes\"). Those spellings resolve to the same directory inside the container but would slip past the /home/node/.n8n shadowing check."
  }

  validation {
    # The chart mounts the `data` volume at /home/node/.n8n on the main
    # deployment only (templates/deployment-main.yaml), and the module leaves
    # persistence.enabled at the chart default, so that volume is an emptyDir.
    # Anything the image placed under that path is therefore hidden on mains
    # while still present on workers and webhook processors: the nodes load on
    # some pod types and not others, which surfaces as workflows that run on a
    # worker but fail to open in the editor.
    condition = var.n8n_custom_extensions_path == null ? true : !(
      var.n8n_custom_extensions_path == "/home/node/.n8n" ||
      startswith(var.n8n_custom_extensions_path, "/home/node/.n8n/")
    )
    error_message = "n8n_custom_extensions_path must not be inside /home/node/.n8n. The chart mounts an emptyDir there on main pods, which hides whatever the image baked in, so the nodes would load on workers and webhook processors but not on mains. Use a path outside it, for example /opt/n8n-nodes."
  }
}

variable "n8n_extra_volumes" {
  description = "Volumes to add to the main, worker and webhook-processor pods, mapped to the chart's extraVolumes. Each entry needs a name and exactly one source: config_map, secret, or persistent_volume_claim. Those three are the sources that can carry files into a pod on their own, which is the point of the input: paired with n8n_extra_volume_mounts and n8n_custom_extensions_path, they load community nodes from a ConfigMap or a shared ReadWriteMany claim instead of from a custom image, which is the alternative to rebuilding an image for every package change. Other uses fit too, a CA bundle from a secret being the common one. default_mode is an octal string (\"0644\"), not a number, because Terraform reads a leading zero as decimal and would silently apply the wrong permissions. Volume sources beyond those three (csi, nfs, projected) are not exposed. Names must be unique, and \"data\" and \"task-runner-config\" are reserved by the chart."
  type = list(object({
    name = string
    config_map = optional(object({
      name         = string
      default_mode = optional(string)
    }))
    secret = optional(object({
      secret_name  = string
      default_mode = optional(string)
    }))
    persistent_volume_claim = optional(object({
      claim_name = string
      read_only  = optional(bool)
    }))
  }))
  default = []

  validation {
    condition = alltrue([
      for volume in var.n8n_extra_volumes :
      can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", volume.name)) && length(volume.name) <= 63
    ])
    error_message = "Every n8n_extra_volumes name must be a DNS-1123 label, which is what Kubernetes requires of a volume name: 63 characters or fewer of lowercase alphanumerics and hyphens, starting and ending with an alphanumeric (e.g. \"custom-nodes\")."
  }

  validation {
    condition     = length(distinct([for volume in var.n8n_extra_volumes : volume.name])) == length(var.n8n_extra_volumes)
    error_message = "n8n_extra_volumes names must be unique. Kubernetes rejects a pod spec with two volumes of the same name, so the whole release fails to render rather than one entry losing out."
  }

  validation {
    # `data` is the chart's own volume, mounted at /home/node/.n8n on main pods.
    # `task-runner-config` appears when taskRunners.customConfig is enabled.
    # Reusing either name collides inside the rendered pod spec.
    condition = alltrue([
      for volume in var.n8n_extra_volumes :
      !contains(["data", "task-runner-config"], volume.name)
    ])
    error_message = "n8n_extra_volumes must not use the names \"data\" or \"task-runner-config\". The chart declares both itself (data is the n8n home volume on main pods), and a duplicate volume name makes Kubernetes reject the whole pod spec. Pick another name."
  }

  validation {
    condition = alltrue([
      for volume in var.n8n_extra_volumes :
      length([
        for source in [volume.config_map, volume.secret, volume.persistent_volume_claim] :
        source if source != null
      ]) == 1
    ])
    error_message = "Every n8n_extra_volumes entry must set exactly one of config_map, secret or persistent_volume_claim. A volume with no source, or with two, is not a thing Kubernetes can mount."
  }

  validation {
    # The `if` filters run before the mode is read, so an entry whose source is
    # a persistent_volume_claim never has default_mode looked up on a null.
    condition = alltrue([
      for mode in concat(
        [for volume in var.n8n_extra_volumes : volume.config_map.default_mode if volume.config_map != null],
        [for volume in var.n8n_extra_volumes : volume.secret.default_mode if volume.secret != null],
      ) : mode == null ? true : can(regex("^0?[0-7]{3}$", mode))
    ])
    error_message = "Every default_mode in n8n_extra_volumes must be a three-digit octal string, optionally with a leading zero (e.g. \"0644\" or \"755\"). It is a string on purpose: Terraform reads the number 0644 as decimal 644, which is octal 1204, so the files would land with permissions nobody asked for."
  }
}

variable "n8n_extra_volume_mounts" {
  description = "Where the n8n container mounts the volumes declared in n8n_extra_volumes, mapped to the chart's extraVolumeMounts. Applies to the main, worker and webhook-processor pods alike, and to the n8n container only, not the task runner sidecar. Every name here must match a name in n8n_extra_volumes, which is checked at plan time rather than left to fail at pod start. read_only defaults to true, so a mount that has to be written needs to say so. Use this with n8n_custom_extensions_path to load community nodes from a volume rather than from a custom image; when a mount covers that path, the module stops warning that the path has nothing behind it."
  type = list(object({
    name       = string
    mount_path = string
    sub_path   = optional(string)
    read_only  = optional(bool, true)
  }))
  default = []

  validation {
    condition = alltrue([
      for mount in var.n8n_extra_volume_mounts :
      contains([for volume in var.n8n_extra_volumes : volume.name], mount.name)
    ])
    error_message = "Every n8n_extra_volume_mounts name must match a volume declared in n8n_extra_volumes. A mount referring to a volume that does not exist leaves the pods stuck in CreateContainerConfigError, which is a slow way to learn about a typo."
  }

  validation {
    condition = alltrue([
      for mount in var.n8n_extra_volume_mounts :
      can(regex("^/[^[:space:]]*$", mount.mount_path)) && !can(regex("//|/\\.\\.?(/|$)", mount.mount_path))
    ])
    error_message = "Every n8n_extra_volume_mounts mount_path must be a canonical absolute path with no whitespace: no repeated slashes and no \".\" or \"..\" components (e.g. \"/opt/n8n-nodes\"). The canonical form is what makes the collision checks below comparisons rather than guesses."
  }

  validation {
    # Every other rule here is a string comparison, so one directory has to have
    # one spelling. "/home/node/.n8n/" is the same mount target as
    # "/home/node/.n8n" and would slip past the check below it, and a trailing
    # slash also breaks the prefix test that decides whether a mount covers
    # n8n_custom_extensions_path, turning a working config into a warning.
    condition = alltrue([
      for mount in var.n8n_extra_volume_mounts :
      !endswith(mount.mount_path, "/")
    ])
    error_message = "No n8n_extra_volume_mounts mount_path may end in a slash: write \"/opt/n8n-nodes\", not \"/opt/n8n-nodes/\". The two name the same directory, so allowing both would let a mount collide with one the chart already declares while comparing as different, and would break the test for whether a mount covers n8n_custom_extensions_path. Mounting at \"/\" is rejected by the same rule, which is intended."
  }

  validation {
    condition = alltrue([
      for mount in var.n8n_extra_volume_mounts :
      mount.mount_path != "/home/node/.n8n"
    ])
    error_message = "n8n_extra_volume_mounts must not mount at /home/node/.n8n exactly. The chart already mounts its own `data` volume there on main pods, and Kubernetes rejects a container with two mounts on the same path, so the release would fail to apply. A path underneath it is fine, as is any path outside it."
  }

  validation {
    condition     = length(distinct([for mount in var.n8n_extra_volume_mounts : mount.mount_path])) == length(var.n8n_extra_volume_mounts)
    error_message = "n8n_extra_volume_mounts mount_path values must be unique. Two mounts on one path is a pod spec Kubernetes rejects outright."
  }
}

variable "n8n_community_packages_prevent_loading" {
  description = "Prevent installed community packages from being loaded at runtime. Maps to N8N_COMMUNITY_PACKAGES_PREVENT_LOADING. When true, n8n leaves the community-packages management surface in place but skips loading the package code, which is useful for locking an instance down without uninstalling. Leave false (the default) for community nodes to load and execute. n8n defaults this to false; when false the env var is omitted entirely so n8n's own default applies."
  type        = bool
  default     = false
}

# OpenTelemetry tracing
# Wired to N8N_OTEL_* env vars on the n8n Helm release's config.extraEnv block,
# which the chart applies to every n8n container (main, worker, webhook
# processor). This matches the n8n OpenTelemetry docs' queue-mode requirement:
# https://docs.n8n.io/hosting/logging-monitoring/opentelemetry/
#
# The collector / Jaeger receiver itself is intentionally out of scope for this
# module — deploy it via a separate Terraform module (or directly) and point
# n8n_otel_exporter_otlp_endpoint at it.
#
# When n8n_otel_enabled = false (the default), no N8N_OTEL_* env vars are
# emitted at all and the OpenTelemetry SDK is not loaded. The individual tuning
# variables (endpoint, headers, service name, sample rate, span inclusion,
# outbound injection, production-only filtering) default to null — when an
# individual value is null the corresponding env var is omitted entirely so
# n8n's own default applies. Only set the values you actually need to override.

variable "n8n_otel_enabled" {
  description = "Master switch for n8n's OpenTelemetry workflow + node tracing. When true, the module sets N8N_OTEL_ENABLED=true on all n8n containers (main, worker, webhook processor) via the Helm release's config.extraEnv block. When false (the default), no OpenTelemetry env vars are emitted and the SDK is not loaded. The OpenTelemetry collector / Jaeger receiver is out of scope for this module — deploy it separately and point n8n_otel_exporter_otlp_endpoint at it. See https://docs.n8n.io/hosting/logging-monitoring/opentelemetry/ for the underlying n8n contract."
  type        = bool
  default     = false
}

variable "n8n_otel_exporter_otlp_endpoint" {
  description = "Base URL of the OTLP HTTP endpoint to export traces to (e.g. http://otel-collector.observability.svc.cluster.local:4318 for an in-cluster collector). When set, maps to N8N_OTEL_EXPORTER_OTLP_ENDPOINT. n8n appends /v1/traces to this value internally, so point at the base URL, not the traces path. Leave null to use n8n's default (http://localhost:4318), which only works if a sidecar collector is colocated in each n8n pod (this module does not deploy one). Ignored when n8n_otel_enabled = false."
  type        = string
  default     = null

  # Null-safe ternary (see n8n_otel_traces_sample_rate for the Terraform 1.9.x
  # short-circuit rationale): only validate the scheme when a value is set.
  validation {
    condition = var.n8n_otel_exporter_otlp_endpoint == null ? true : (
      startswith(var.n8n_otel_exporter_otlp_endpoint, "http://") ||
      startswith(var.n8n_otel_exporter_otlp_endpoint, "https://")
    )
    error_message = "n8n_otel_exporter_otlp_endpoint must be a base URL starting with http:// or https:// (n8n appends /v1/traces itself), or null to use n8n's default."
  }
}

variable "n8n_otel_exporter_otlp_headers" {
  description = "Comma-separated list of key=value pairs sent as HTTP headers with each OTLP request (e.g. 'authorization=Bearer <token>,x-tenant=acme'). Use this for collector authentication or multi-tenant routing. Maps to N8N_OTEL_EXPORTER_OTLP_HEADERS. Leave null to send no extra headers. Marked sensitive so the value is redacted from CLI and plan output, but note it is still injected as a literal env var: it is persisted in plaintext in Terraform state and visible in the pod environment (kubectl describe / printenv). The chart's config.extraEnv does not support secretKeyRef, so restrict access to state and the n8n namespace accordingly. Ignored when n8n_otel_enabled = false."
  type        = string
  default     = null
  sensitive   = true
}

variable "n8n_otel_exporter_service_name" {
  description = "Value of the service.name resource attribute on exported spans. Maps to N8N_OTEL_EXPORTER_SERVICE_NAME. Leave null to use n8n's default ('n8n'). Set this to differentiate multiple n8n deployments sending traces to the same collector (e.g. 'n8n-prod', 'n8n-staging'). Ignored when n8n_otel_enabled = false."
  type        = string
  default     = null
}

variable "n8n_otel_traces_sample_rate" {
  description = "Fraction of traces to export, between 0 and 1 inclusive. Maps to N8N_OTEL_TRACES_SAMPLE_RATE. n8n uses a trace-ID-ratio sampler, so the same trace ID is either fully sampled or fully dropped across all spans. Leave null to use n8n's default (1.0 — every trace exported). Lower for high-volume installs where the collector or backend can't handle every workflow execution as a trace. Ignored when n8n_otel_enabled = false."
  type        = number
  default     = null

  # Use a ternary rather than `null || numeric_op` here: Terraform 1.9.x
  # eagerly evaluates both sides of the logical OR during validation, so the
  # `null >= 0` branch errors with 'argument must not be null.' even when
  # the variable is null. Ternaries DO short-circuit, so wrapping the numeric
  # comparison in `var == null ? true : (...)` keeps the null path entirely
  # off the numeric-op branch.
  validation {
    condition = var.n8n_otel_traces_sample_rate == null ? true : (
      var.n8n_otel_traces_sample_rate >= 0 && var.n8n_otel_traces_sample_rate <= 1
    )
    error_message = "n8n_otel_traces_sample_rate must be between 0 and 1 inclusive, or null to use n8n's default."
  }
}

variable "n8n_otel_traces_include_node_spans" {
  description = "Whether to emit a node.execute span for each node execution. Maps to N8N_OTEL_TRACES_INCLUDE_NODE_SPANS. Leave null to use n8n's default (true — one span per node per execution). Set to false to export workflow-level spans only — a common volume-reduction lever for workflows with many small nodes. Ignored when n8n_otel_enabled = false."
  type        = bool
  default     = null
}

variable "n8n_otel_traces_inject_outbound" {
  description = "Whether n8n's HTTP-helper-based nodes (HTTP Request and similar) inject W3C traceparent / tracestate headers into outbound requests. Maps to N8N_OTEL_TRACES_INJECT_OUTBOUND. Leave null to use n8n's default (true — propagate context to downstream services). Set to false when calling external systems that misbehave on unexpected headers, or when you don't want trace context leaving your boundary. Ignored when n8n_otel_enabled = false."
  type        = bool
  default     = null
}

variable "n8n_otel_traces_production_only" {
  description = "Whether to export traces for production workflow executions only. Maps to N8N_OTEL_TRACES_PRODUCTION_ONLY. Leave null to use n8n's default (true — only production executions are traced). Set to false to also trace manual/test executions run from the editor, which helps while developing instrumentation but is noisy in production. Ignored when n8n_otel_enabled = false."
  type        = bool
  default     = null
}

# Log streaming (n8n Enterprise)
# Declaratively provisions log streaming destinations from environment
# variables using n8n's settings-env-vars activation pattern (n8n >= 2.19.0):
# https://docs.n8n.io/hosting/configuration/settings-env-vars/
#
# When n8n_log_streaming_managed_by_env = true, n8n reapplies the destinations
# from N8N_LOG_STREAMING_DESTINATIONS on every startup and locks the Log
# Streaming UI read-only. When false (the default), n8n ignores the env vars
# entirely and destinations are managed in the UI as usual. The feature itself
# is gated by the n8n Enterprise license (var.n8n_license_key) — the license
# must include the log streaming entitlement.

variable "n8n_log_streaming_managed_by_env" {
  description = "Manage n8n's Enterprise log streaming destinations from environment variables instead of the UI. Maps to N8N_LOG_STREAMING_MANAGED_BY_ENV. When true, n8n applies n8n_log_streaming_destinations on every startup and locks the Log Streaming UI controls read-only. When false (the default), no log streaming env vars are emitted and destinations stay UI-managed; flipping back to false keeps the last applied destinations but restores UI write access. Requires n8n >= 2.19.0 and an Enterprise license that includes log streaming. See https://docs.n8n.io/log-streaming/ for the underlying n8n contract."
  type        = bool
  default     = false
}

variable "n8n_log_streaming_destinations" {
  description = "List of log streaming destination objects, JSON-encoded into N8N_LOG_STREAMING_DESTINATIONS. Each entry must set type to webhook, syslog, or sentry, plus the type-specific fields documented at https://docs.n8n.io/log-streaming/#configure-using-environment-variables (common fields: label, enabled, subscribedEvents, anonymizeAuditMessages, circuitBreaker). Typed as any because the three destination shapes differ structurally. Marked sensitive because webhook headers and Sentry DSNs typically carry credentials — note the value is still injected as a literal env var: it is persisted in plaintext in Terraform state and visible in the pod environment (kubectl describe / printenv). Ignored when n8n_log_streaming_managed_by_env = false."
  type        = any
  default     = []
  nullable    = false
  sensitive   = true

  validation {
    condition     = can([for d in var.n8n_log_streaming_destinations : d]) && !can(tostring(var.n8n_log_streaming_destinations))
    error_message = "n8n_log_streaming_destinations must be a list of destination objects (not a string — the module JSON-encodes it for you)."
  }

  validation {
    # Guarded with can() so a non-list value fails this validation cleanly
    # (via the list-shape validation above) instead of hard-erroring the
    # `for` expression during evaluation.
    condition = can([for d in var.n8n_log_streaming_destinations : d]) ? alltrue([
      for d in var.n8n_log_streaming_destinations :
      contains(["webhook", "syslog", "sentry"], try(d.type, "missing"))
    ]) : false
    error_message = "Each n8n_log_streaming_destinations entry must be an object with type set to one of: webhook, syslog, sentry."
  }
}

variable "n8n_extra_env" {
  description = "Additional environment variables to inject into all n8n pods (main, worker, and webhook-processor) via the Helm chart's config.extraEnv list. Each entry is an object with name and value string attributes. config.extraEnv is appended last in every container's env list, so by Kubernetes' last-wins rule any name here overrides the chart's value for that name. To prevent silently breaking the deployment, an entry is rejected at plan time when its name collides with a connection, identity, storage, license, or topology variable the module manages: any name starting with DB_, QUEUE_, N8N_RUNNERS_, N8N_EXTERNAL_STORAGE_S3_, N8N_MULTI_MAIN_, or AWS_, plus names like N8N_ENCRYPTION_KEY, N8N_LICENSE_ACTIVATION_KEY, N8N_HOST, WEBHOOK_URL, and EXECUTIONS_MODE. Use the dedicated module inputs for those. Do not put secret values here, because they render into the Helm release and are stored in plaintext in Terraform state; instead pass a *_FILE companion (e.g. a name ending in _FILE) pointing at a mounted Kubernetes secret, or use n8n credentials. Example: [{name = \"N8N_DEFAULT_LOCALE\", value = \"de\"}]."
  type = list(object({
    name  = string
    value = string
  }))
  default  = []
  nullable = false

  validation {
    condition     = alltrue([for e in var.n8n_extra_env : e.name != "" && e.name == trimspace(e.name)])
    error_message = "Each n8n_extra_env entry must have a non-empty name with no leading or trailing whitespace. Whitespace-padded names would bypass the duplicate and module-managed guards while rendering as a distinct, ignored env var."
  }

  validation {
    condition     = length(distinct([for e in var.n8n_extra_env : e.name])) == length(var.n8n_extra_env)
    error_message = "n8n_extra_env contains duplicate names; each environment variable may be set only once."
  }

  validation {
    condition = alltrue([
      for e in var.n8n_extra_env : !(
        contains(local.n8n_managed_env_names, e.name) ||
        anytrue([for p in local.n8n_managed_env_prefixes : startswith(e.name, p)])
      )
    ])
    error_message = "n8n_extra_env must not set module-managed variables. Reserved: any name starting with one of ${join(", ", local.n8n_managed_env_prefixes)} (connection/queue/runner/storage/topology/AWS families), plus the exact names ${join(", ", local.n8n_managed_env_names)}. config.extraEnv is appended last and would otherwise silently override these (Kubernetes last-wins). Use the dedicated module inputs (e.g. n8n_log_level, n8n_metrics_enabled) instead."
  }
}

# ── KEDA: worker pods ─────────────────────────────────────────────────────────

variable "n8n_worker_keda_min_replicas" {
  description = "Minimum worker replicas. KEDA keeps at least this many workers running even when the queue is empty. Also becomes the deployment's own replica count: the Helm chart renders spec.replicas unconditionally, so leaving it below the autoscaler floor would make every helm upgrade scale down and then wait for the autoscaler to climb back."
  type        = number
  default     = 1
  nullable    = false

  validation {
    condition     = var.n8n_worker_keda_min_replicas <= var.n8n_worker_keda_max_replicas
    error_message = "n8n_worker_keda_min_replicas must not exceed n8n_worker_keda_max_replicas; KEDA rejects a ScaledObject whose minReplicaCount is above its maxReplicaCount."
  }
}

variable "n8n_worker_keda_max_replicas" {
  description = "Maximum worker replicas KEDA may scale to. Workers compete for the same nodes as the main and webhook pods, and each carries a task runner sidecar, so this ceiling counts against the same node group budget as the two HPA maxima. See README.md → \"Sizing autoscaling against node capacity\"."
  type        = number
  default     = 10
  nullable    = false
}

variable "n8n_worker_keda_jobs_per_replica" {
  description = "Number of waiting jobs per worker replica used as the KEDA scaling threshold. KEDA targets ceil(queue_depth / jobs_per_replica) replicas."
  type        = number
  default     = 5
}
