variable "aws_region" {
  description = "AWS region to deploy into (e.g. us-east-1, eu-west-1, ap-southeast-1)."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name for the EKS cluster. Keep to 14 characters or fewer, because the module derives an ElastiCache cluster ID of `<cluster_name>-redis`, and AWS caps ElastiCache IDs at 20 chars."
  type        = string
  default     = "n8n-cluster"

  validation {
    condition     = length(var.cluster_name) <= 14
    error_message = "cluster_name must be 14 characters or fewer."
  }
}

variable "n8n_domain" {
  description = "Fully-qualified domain name for the n8n editor UI and REST API (e.g. n8n.example.com). Served by the internal Istio gateway's NLB, so it resolves to private addresses and is reachable only from inside the VPC or over VPN. The parent zone must be hosted in Route53."
  type        = string
}

variable "webhook_subdomain" {
  description = "Label prepended to n8n_domain to form the public webhook hostname. With the default and n8n_domain = n8n.example.com, webhooks are served from hooks.n8n.example.com by the internet-facing Istio gateway's NLB. A separate hostname is required because a DNS name can alias only one load balancer."
  type        = string
  default     = "hooks"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", var.webhook_subdomain))
    error_message = "webhook_subdomain must be a single lowercase DNS label: letters, digits and hyphens, not starting or ending with a hyphen."
  }
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID for the parent of n8n_domain (e.g. the zone for example.com if n8n_domain = n8n.example.com). Passed through to the module, which issues the ACM certificate covering both hostnames and writes its validation records here. This example writes both alias A-records in the same zone, since it owns the two load balancers. Consumed by gateways.tf only when istio_tls_mode = \"nlb\" (the default); still required in \"gateway\" mode because the module always issues this certificate regardless of who terminates TLS with it."
  type        = string
}

variable "n8n_license_key" {
  description = "n8n Enterprise license activation key. Get one at https://n8n.io/pricing"
  type        = string
  sensitive   = true
}

variable "n8n_image_repository" {
  description = "Container image repository for the n8n application, without a tag (e.g. \"123456789012.dkr.ecr.eu-west-1.amazonaws.com/n8n\"). Leave null to use the Helm chart's own repository (docker.n8n.io/n8nio/n8n). Set this to run a custom image, for example one with community packages baked in so they are not reinstalled on every pod boot. The image must be pullable by the node group's IAM role (ECR in the same account is) or be public, otherwise name a dockerconfigjson secret in n8n_image_pull_secrets, and n8n_task_runner_image_tag usually has to be set alongside it."
  type        = string
  default     = null

  validation {
    # Keep this validation in sync with the module root's variables.tf; the
    # grammar is duplicated in every example.
    condition = var.n8n_image_repository == null ? true : (
      length(var.n8n_image_repository) <= 255 &&
      can(regex("^(?:(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*|\\[[0-9A-Fa-f:]+\\])(?::[0-9]+)?/)?[a-z0-9]+(?:(?:__|[._]|-+)[a-z0-9]+)*(?:/[a-z0-9]+(?:(?:__|[._]|-+)[a-z0-9]+)*)*$", var.n8n_image_repository))
    )
    error_message = "n8n_image_repository must be a bare image repository reference that Docker can pull: an optional registry host with an optional port, then one or more lowercase path components (e.g. \"myregistry.example.com/n8n\", \"n8nio/n8n\", \"[2001:db8::1]:5000/n8n\"). No scheme (\"https://\"), no whitespace, no uppercase path components, and no empty label anywhere, which rules out a trailing slash, a doubled slash, and a doubled dot. Set to null to use the chart's default (docker.n8n.io/n8nio/n8n)."
  }

  validation {
    condition     = var.n8n_image_repository == null ? true : !can(regex(":", reverse(split("/", var.n8n_image_repository))[0]))
    error_message = "n8n_image_repository must not include a tag or digest, because the chart appends the tag itself. Pass the version via n8n_image_tag instead."
  }
}

variable "n8n_image_pull_secrets" {
  description = "Names of existing Kubernetes secrets of type kubernetes.io/dockerconfigjson, in the n8n namespace, that the pods authenticate to their image registry with. Leave empty (the default) unless n8n_image_repository points somewhere the node group's IAM role cannot already reach. See the module root's variables.tf for the full rationale; unchanged here."
  type        = list(string)
  default     = []

  validation {
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
    condition     = length(distinct(var.n8n_image_pull_secrets)) == length(var.n8n_image_pull_secrets)
    error_message = "n8n_image_pull_secrets must not repeat a secret name. Listing one twice adds nothing, since the kubelet tries each entry once."
  }
}

variable "n8n_image_tag" {
  description = "n8n application image tag to deploy (e.g. \"2.27.4\"). Leave null to use the Helm chart's floating `stable` tag. Pin a concrete version for reproducible upgrades and to avoid crossing major-version boundaries on an unplanned pod reschedule."
  type        = string
  default     = null

  validation {
    condition     = var.n8n_image_tag == null ? true : can(regex("^[a-zA-Z0-9_][a-zA-Z0-9._-]{0,127}$", var.n8n_image_tag))
    error_message = "n8n_image_tag must be a non-empty string with no whitespace, containing only alphanumeric characters, dots, underscores, and hyphens (e.g. \"1.2.3\", \"1.2.3-alpine\"). Set to null to use the chart's default (stable)."
  }
}

variable "n8n_task_runner_image_tag" {
  description = "Image tag for the task runner sidecar (`n8nio/runners`). Leave null to inherit the n8n application image's tag. See the module root's variables.tf for the full rationale; unchanged here."
  type        = string
  default     = null

  validation {
    condition     = var.n8n_task_runner_image_tag == null ? true : can(regex("^[a-zA-Z0-9_][a-zA-Z0-9._-]{0,127}$", var.n8n_task_runner_image_tag))
    error_message = "n8n_task_runner_image_tag must be a non-empty string with no whitespace, containing only alphanumeric characters, dots, underscores, and hyphens (e.g. \"2.27.4\"). Set to null to inherit the n8n application image's tag."
  }
}

variable "n8n_custom_extensions_path" {
  description = "Absolute path inside the n8n container that n8n scans for custom nodes at startup (e.g. \"/opt/n8n-nodes\"). See the module root's variables.tf for the full rationale; unchanged here."
  type        = string
  default     = null

  # Keep these validations in sync with the module root's variables.tf; they
  # are duplicated in every example.
  validation {
    condition     = var.n8n_custom_extensions_path == null ? true : can(regex("^/[^[:space:];]*$", var.n8n_custom_extensions_path))
    error_message = "n8n_custom_extensions_path must be an absolute container path with no whitespace and no semicolon (e.g. \"/opt/n8n-nodes\"). n8n splits N8N_CUSTOM_EXTENSIONS on \";\", so a semicolon here would be parsed as two directories and silently drop all but the last."
  }

  validation {
    condition     = var.n8n_custom_extensions_path == null ? true : !can(regex("//|/\\.\\.?(/|$)", var.n8n_custom_extensions_path))
    error_message = "n8n_custom_extensions_path must be a canonical path: no repeated slashes and no \".\" or \"..\" components (e.g. \"/opt/n8n-nodes\"). Those spellings resolve to the same directory inside the container but would slip past the /home/node/.n8n shadowing check."
  }

  validation {
    condition = var.n8n_custom_extensions_path == null ? true : !(
      var.n8n_custom_extensions_path == "/home/node/.n8n" ||
      startswith(var.n8n_custom_extensions_path, "/home/node/.n8n/")
    )
    error_message = "n8n_custom_extensions_path must not be inside /home/node/.n8n. The chart mounts an emptyDir there on main pods, which hides whatever the image baked in, so the nodes would load on workers and webhook processors but not on mains. Use a path outside it, for example /opt/n8n-nodes."
  }
}

# ── Istio ─────────────────────────────────────────────────────────────────────

variable "istio_chart_version" {
  description = "Version pin for the istio/base, istio/istiod and istio/gateway Helm charts (all three must match). Versions 1.23.x through at least 1.25.1 of the gateway chart fail every install with \"additional properties 'service', 'labels', '_internal_defaults_do_not_set' not allowed\": the chart's own shipped values.yaml does not validate against its own values.schema.json, which rejects even a bare `helm template` with zero overrides. Confirmed against 1.20.0 through 1.30.3 directly (helm lint / helm template): the regression spans roughly 1.23-1.25 and is fixed by 1.28.10; 1.30.3 is the newest verified-working release as of this writing and is the default here. Re-verify with `helm lint` before bumping, and separately verify against Istio's published Kubernetes support matrix (istio.io) and the AWS Load Balancer Controller version helm_release.lbc (module root controllers.tf) resolves to, since this example relies on LBC's Service (NLB) reconciler."
  type        = string
  default     = "1.30.3"
  nullable    = false
}

variable "istio_tls_mode" {
  description = "Where TLS terminates for both Istio ingress gateways. \"nlb\" (the default) mirrors examples/split-ingress most closely: each Network Load Balancer terminates TLS using module.n8n.certificate_arn (the module's Route53-validated ACM certificate), and Envoy receives plain HTTP, the same trust model as this module's ALB-to-pod hop. \"gateway\" instead has Envoy terminate TLS itself (Istio SIMPLE mode) from a Kubernetes Secret built from gateway_tls_*_cert_pem / gateway_tls_*_key_pem. Gateway mode exists because an ACM public certificate's private key cannot be exported, so it needs its own, independent BYO PEM certificate rather than reusing module.n8n.certificate_arn."
  type        = string
  default     = "nlb"
  nullable    = false

  validation {
    condition     = contains(["nlb", "gateway"], var.istio_tls_mode)
    error_message = "istio_tls_mode must be either \"nlb\" or \"gateway\"."
  }

  # Cross-variable validation referencing sibling variables is supported since
  # Terraform 1.9 (the module root's required_version floor), same feature
  # var.route53_zone_id's own validation already relies on.
  validation {
    condition = var.istio_tls_mode == "gateway" ? (
      var.gateway_tls_public_cert_pem != null && var.gateway_tls_public_key_pem != null &&
      var.gateway_tls_internal_cert_pem != null && var.gateway_tls_internal_key_pem != null
    ) : true
    error_message = "When istio_tls_mode = \"gateway\", all four of gateway_tls_public_cert_pem, gateway_tls_public_key_pem, gateway_tls_internal_cert_pem and gateway_tls_internal_key_pem must be set. Envoy terminates TLS itself in this mode and needs a real cert/key pair for each hostname; there is no ACM fallback because ACM public certificates cannot export a private key."
  }
}

variable "gateway_tls_public_cert_pem" {
  description = "PEM-encoded certificate (leaf plus any intermediate chain) for the public webhook hostname, used only when istio_tls_mode = \"gateway\". Independent of module.n8n.certificate_arn: an ACM public certificate's private key cannot be exported, so Gateway-terminated TLS needs its own BYO cert, analogous to examples/cloudflare and examples/godaddy's BYO-cert precedent but as raw PEM material rather than an ACM ARN. Ignored when istio_tls_mode = \"nlb\"."
  type        = string
  default     = null
  sensitive   = true
}

variable "gateway_tls_public_key_pem" {
  description = "PEM-encoded private key matching gateway_tls_public_cert_pem. Required when istio_tls_mode = \"gateway\", ignored otherwise."
  type        = string
  default     = null
  sensitive   = true
}

variable "gateway_tls_internal_cert_pem" {
  description = "PEM-encoded certificate for the admin hostname, used only when istio_tls_mode = \"gateway\". See gateway_tls_public_cert_pem for why this cannot be sourced from module.n8n.certificate_arn."
  type        = string
  default     = null
  sensitive   = true
}

variable "gateway_tls_internal_key_pem" {
  description = "PEM-encoded private key matching gateway_tls_internal_cert_pem. Required when istio_tls_mode = \"gateway\", ignored otherwise."
  type        = string
  default     = null
  sensitive   = true
}

variable "nlb_ssl_negotiation_policy" {
  description = "TLS negotiation policy for both NLBs' TLS listeners, wired to service.beta.kubernetes.io/aws-load-balancer-ssl-negotiation-policy. Only meaningful when istio_tls_mode = \"nlb\" (ignored in \"gateway\" mode, where Envoy negotiates TLS itself). Defaults to a current, modern policy so the negotiated policy is explicit and pinned in Terraform rather than left to whatever the load balancer defaults to. This is the NLB equivalent of examples/split-ingress's ssl_policy; the annotation name differs between the two load balancer types."
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-2021-06"
}

# Deliberately unused beyond its own validation block below: this variable's
# entire purpose is to fail fast for a caller migrating from examples/
# split-ingress with waf_acl_arn already set. There is nothing for it to wire
# into, since AWS WAFv2 cannot attach to a Network Load Balancer at all.
# tflint-ignore: terraform_unused_declarations
variable "waf_acl_arn" {
  description = "Not supported in this example. AWS WAFv2 web ACLs attach to Application Load Balancers, CloudFront, and API Gateway, but NOT to Network Load Balancers, which is what fronts both Istio ingress gateways here. examples/split-ingress accepts this input and attaches it to its public ALB; this variable exists here only so a caller migrating from that example gets a clear Terraform validation error instead of the setting silently doing nothing. Must be left null. See the README's \"WAF gap\" section for the CloudFront-in-front-of-the-public-NLB workaround, which this example does not implement."
  type        = string
  default     = null

  validation {
    condition     = var.waf_acl_arn == null
    error_message = "waf_acl_arn is not supported in examples/istio-split-ingress: AWS WAFv2 cannot attach to a Network Load Balancer. Leave this null. See the README's WAF gap section for the CloudFront-based workaround (not implemented in this example)."
  }
}

variable "admin_allowed_cidr_blocks" {
  description = "IPv4 CIDR blocks allowed to reach the internal NLB, enforced by aws_security_group.internal_gateway (security.tf) rather than an Ingress annotation: NLBs have no inbound-cidrs-style annotation, so this example creates a real security group and attaches it to the internal gateway's Service via service.beta.kubernetes.io/aws-load-balancer-security-groups, the AWS Load Balancer Controller's documented BYO-security-group mechanism. The NLB is already private (internal scheme), so this is defence in depth: narrow it to your VPN pool or bastion range. Empty (the default) allows any source that can route to the private subnets, the same default-open-but-already-private posture as examples/split-ingress's equivalent input."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.admin_allowed_cidr_blocks : can(cidrnetmask(c))])
    error_message = "Each entry in admin_allowed_cidr_blocks must be a valid IPv4 CIDR block including the prefix length (e.g. 10.20.0.0/16, 192.168.100.7/32)."
  }

  # Same guard as the module's alb_inbound_cidrs, for the same reason: a CIDR
  # with host bits set passes cidrnetmask, and a security group rule built
  # from it is the first thing to reject it, at apply time, which surfaces as
  # a confusing AWS API error rather than a fast, local validation failure.
  validation {
    condition = alltrue([
      for c in var.admin_allowed_cidr_blocks :
      can(cidrnetmask(c)) ? c == "${cidrhost(c, 0)}/${split("/", c)[1]}" : true
    ])
    error_message = "Each entry in admin_allowed_cidr_blocks must be the network address of its block, with no host bits set (10.20.0.0/16, not 10.20.0.5/16). Use /32 for a single address."
  }
}

variable "n8n_execution_data_storage_mode" {
  description = "Where n8n stores the data of each new execution. Passed to the module's n8n_execution_data_storage_mode. See the module root's variables.tf for the full rationale; unchanged here."
  type        = string
  default     = "database"
  nullable    = false

  validation {
    condition     = contains(["database", "s3"], var.n8n_execution_data_storage_mode)
    error_message = "n8n_execution_data_storage_mode must be either \"database\" or \"s3\"."
  }
}

variable "tags" {
  description = "Additional AWS tags to apply to every resource this example creates."
  type        = map(string)
  default     = {}
}
