# ── Common ─────────────────────────────────────────────────────────────────────
# Naming and tagging inputs threaded through every resource this module
# creates, ahead of the product-specific settings below. The analog of the
# friendly_name_prefix/common_tags block HVD modules lead with; ours is named
# and shaped for this module's own resource-naming and tagging needs rather
# than mirroring HVD's variable names, since renaming cluster_name/tags to
# match would be a breaking change with no functional benefit (see #81).

variable "cluster_name" {
  description = "Name for the EKS cluster. Keep to 14 characters or fewer — the module derives an ElastiCache cluster ID of `<cluster_name>-redis`, and AWS caps ElastiCache IDs at 20 chars."
  type        = string
  default     = "n8n-cluster"

  validation {
    condition     = length(var.cluster_name) <= 14
    error_message = "cluster_name must be 14 characters or fewer (ElastiCache cluster ID <cluster_name>-redis must stay <= 20 chars)."
  }
}

variable "tags" {
  description = "Additional AWS tags to apply to all resources this module creates. Merged on top of the built-in ManagedBy/Project tags."
  type        = map(string)
  default     = {}
}

variable "namespace" {
  description = "Kubernetes namespace to deploy n8n into. Names the namespace the module creates when create_namespace = true (the default), or the existing namespace the module deploys into when create_namespace = false."
  type        = string
  default     = "n8n"

  validation {
    # DNS-1123 label, which is what Kubernetes requires of a namespace name and
    # what every resource this module creates in it inherits. Checked here
    # rather than left to the API server because the name also reaches the Pod
    # Identity association (s3.tf), where a rejection surfaces as an AWS error
    # that does not mention the namespace at all.
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.namespace)) && length(var.namespace) <= 63
    error_message = "namespace must be a DNS-1123 label, which is what Kubernetes requires of a namespace: 63 characters or fewer, lowercase alphanumerics and hyphens only, starting and ending with an alphanumeric (e.g. \"n8n\", \"n8n-prod\"). Underscores, dots and uppercase are rejected."
  }
}

# ── Foundation inputs ─────────────────────────────────────────────────────────
# Region and the pre-built VPC + ACM certificate the module deploys into.
# Supply these from a VPC module (e.g. terraform-aws-modules/vpc)
# and an aws_acm_certificate_validation resource — see examples/small/.

variable "aws_region" {
  description = "AWS region to deploy into (e.g. us-east-1, eu-west-1, ap-southeast-1). Must match the region the AWS provider is configured for."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.aws_region))
    error_message = "Value must be a valid AWS region (e.g. us-east-1, eu-west-1)."
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

  validation {
    condition     = var.certificate_arn == null ? true : can(regex("^arn:aws:acm:[a-z0-9-]+:[0-9]{12}:certificate/[A-Za-z0-9-]+$", var.certificate_arn))
    error_message = "certificate_arn must be an ACM certificate ARN (arn:aws:acm:<region>:<account>:certificate/<id>). An IAM server certificate ARN, a bare certificate ID, or a certificate ARN from another service is not accepted."
  }

  validation {
    # ACM certificates are regional and an Application Load Balancer can only
    # use one issued in its own region. Reaching for us-east-1 is a common
    # reflex, because that is where CloudFront requires them, and the mistake
    # otherwise survives the whole plan: the ARN is well-formed, nothing in
    # Terraform resolves it, and the Ingress annotation renders. The AWS Load
    # Balancer Controller then fails to attach it and the HTTPS listener never
    # comes up.
    #
    # A hard failure rather than the check block s3_kms_key_arn_region_matches
    # uses for the analogous KMS case, because the outcomes differ in kind: a
    # wrong-region KMS key leaves a working stack that returns AccessDenied on
    # binary data, while a wrong-region certificate means the listener the whole
    # deployment is reached through does not exist.
    #
    # Written as a variable validation rather than a check block for a reason
    # that is easy to trip over: examples/cloudflare and examples/godaddy pass
    # an ARN straight from aws_acm_certificate_validation, which is unknown at
    # plan time. A check block on an unknown condition reports "known after
    # apply" and fails terraform test; Terraform defers a variable validation
    # it cannot evaluate instead, so a literal ARN in tfvars is still checked
    # and a computed one simply passes through.
    #
    # Account is deliberately not compared: a certificate shared into this
    # account from a central one is legitimate.
    condition     = var.certificate_arn == null ? true : split(":", var.certificate_arn)[3] == var.aws_region
    error_message = "certificate_arn is in a different region from aws_region. ACM certificates are regional and an Application Load Balancer can only use one issued in its own region, so the HTTPS listener would fail to come up and the ALB would answer on port 80 only. Reissue or import the certificate in the deployment region. A us-east-1 certificate is only required for CloudFront, not for an ALB."
  }
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

variable "iam_permissions_boundary_arn" {
  description = "ARN of an IAM policy to attach as the permissions boundary on every IAM role this module creates: the EKS cluster role, the EKS node role, the S3 Pod Identity role, the AWS Load Balancer Controller role, the Cluster Autoscaler role, the EBS CSI driver role, and the RDS Enhanced Monitoring role (that last one only exists when create_database = true). Many organizations enforce an SCP or IAM policy that requires every role created in-account to carry a permissions boundary; set this to satisfy that control. Missing even one role is enough for the apply to fail in such an account, so the propagation test asserts on all seven by name rather than on a hand-kept list. Leave null (the default) and every role is created without a boundary, exactly as before this input existed."
  type        = string
  default     = null

  validation {
    # Commercial partition only, matching db_kms_key_arn and s3_kms_key_arn and
    # the AWS managed policy ARNs this module attaches elsewhere.
    #
    # The account field accepts the literal `aws` as well as a 12-digit account
    # ID: AWS permits an AWS managed policy to be used as a permissions
    # boundary, and those carry arn:aws:iam::aws:policy/... . Rejecting that
    # shape would fail the plan on a configuration AWS itself accepts.
    condition     = var.iam_permissions_boundary_arn == null ? true : can(regex("^arn:aws:iam::([0-9]{12}|aws):policy/.+$", var.iam_permissions_boundary_arn))
    error_message = "iam_permissions_boundary_arn must be a valid IAM policy ARN (e.g. arn:aws:iam::123456789012:policy/ExamplePermissionsBoundary, or arn:aws:iam::aws:policy/PowerUserAccess for an AWS managed policy)."
  }
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

variable "create_eks" {
  description = "When true (the default), the module creates its own EKS cluster, node group, node IAM role, and Pod Identity Agent addon. Set to false to deploy onto an existing cluster named by existing_eks_cluster_name instead, e.g. one a platform team already provisions and runs company-wide. On that path the module still creates everything it always has around n8n itself (RDS, Redis, S3, the namespace, IAM roles and Pod Identity associations for n8n and the controllers it installs), it just stops owning the cluster and node group underneath all of that. Gated with count and a moved block, same pattern as create_database and create_s3_bucket. The EBS CSI driver addon and default gp3 StorageClass (modules/controllers/storage.tf) are gated separately, on their own create_ebs_csi input, since a shared existing cluster may already run a CSI driver while a freshly created one never does."
  type        = bool
  default     = true
  nullable    = false
}

variable "existing_eks_cluster_name" {
  description = "Name of the existing EKS cluster to deploy onto. Required, and read with data.aws_eks_cluster, when create_eks = false; ignored when create_eks = true (the default), which check.existing_eks_cluster_name_requires_create_eks_false warns about, since that combination applies cleanly and builds a whole new cluster beside the one you named. The cluster must be in var.vpc_id (enforced with a hard plan-time failure) and must already have the eks-pod-identity-agent addon installed (the AWS provider itself fails the plan if it does not, reading data.aws_eks_addon.existing_pod_identity_agent). Everything else this module cannot verify about the cluster is listed on existing_eks_cluster_prerequisites_confirmed."
  type        = string
  default     = null

  validation {
    condition     = var.create_eks ? true : var.existing_eks_cluster_name != null
    error_message = "existing_eks_cluster_name is required when create_eks = false: the module needs a cluster name to read with data.aws_eks_cluster."
  }
}

# Read only by its own validation block below, which is the whole point: this
# input has no effect on any resource, it exists purely as a plan-time
# attestation gate.
# tflint-ignore: terraform_unused_declarations
variable "existing_eks_cluster_prerequisites_confirmed" {
  description = "Required to be true when create_eks = false. An explicit attestation, not a rubber stamp: setting it to true is a claim that you have personally verified every item below, because none of them is checkable at plan time the way the cluster's Kubernetes version and VPC are. (1) Node capacity: the HPA/KEDA maxima this module computes (scaling.tf) assume the node group it creates itself; on an existing cluster running Karpenter, self-managed ASGs, Fargate, or any topology other than a plain EKS-managed node group, this module cannot see or validate schedulable capacity at all. (2) Cluster Autoscaler auto-discovery tags: aws_eks_node_group.n8n normally carries k8s.io/cluster-autoscaler/<cluster>=owned and k8s.io/cluster-autoscaler/enabled=true; an existing node group has no guarantee of carrying them, and this module cannot tag infrastructure it does not own. (3) API server reachability: this module sets no endpoint_private_access or endpoint_public_access, so it cannot tell you whether the existing cluster's API is reachable from wherever `terraform apply` runs, e.g. a private-only endpoint reachable only from inside the VPC or over a VPN. (4) Naming and identity collisions: the IAM role names, kube-system ServiceAccount names, and Pod Identity associations this module creates for n8n and any install_* controller it installs are not checked against what may already exist on a shared cluster. Storage is deliberately not on this list: create_ebs_csi (default true) lets you opt the EBS CSI addon and gp3 StorageClass out entirely if the existing cluster already provides its own, rather than asking you to merely attest to the risk. Ingress is also not on this list, for the opposite reason: there is currently no toggle that lets create_ingress = true trust an already-working LBC on the existing cluster the way create_ebs_csi trusts an already-working CSI driver -- install_lbc = false is hard-rejected whenever create_ingress = true, full stop, regardless of this attestation. See docs/customer-managed-infrastructure.md's \"create_eks = false + create_ingress = true\" section."
  type        = bool
  default     = false
  nullable    = false

  validation {
    condition     = var.create_eks ? true : var.existing_eks_cluster_prerequisites_confirmed
    error_message = "existing_eks_cluster_prerequisites_confirmed must be true when create_eks = false. Read its full description first: it enumerates four specific things this module cannot verify on infrastructure it does not own."
  }
}

variable "create_ebs_csi" {
  description = "When true (the default), the module installs the aws-ebs-csi-driver addon and a default gp3 StorageClass (modules/controllers/storage.tf), so any PVC-using workload deployed beside n8n has working persistence out of the box. Set to false to skip both, e.g. when create_eks = false and the existing cluster you are deploying onto already runs its own CSI driver and default StorageClass: installing a second aws-ebs-csi-driver addon on a cluster that already has one fails outright rather than degrading gracefully. Also gates the CSI driver's IAM role and its AmazonEBSCSIDriverPolicy attachment (modules/controllers/iam.tf), whose only consumer is the addon's Pod Identity association, so false leaves behind no role that nothing can assume. Independent of create_eks; a freshly created cluster (create_eks = true, the default) never has a CSI driver of its own, so leave this at its default in that case. check.existing_eks_cluster_needs_its_own_storage_toggle warns if create_eks = false and this is still left at its default."
  type        = bool
  default     = true
  nullable    = false
}

variable "n8n_webhook_url" {
  description = "Public HTTPS base URL used for webhook callbacks (e.g. <https://webhooks.example.com>). Defaults to https://<n8n_domain> when not set. Override when webhooks are served from a different host than the n8n UI."
  type        = string
  default     = null

  validation {
    condition     = var.n8n_webhook_url == null ? true : can(regex("^https://[A-Za-z0-9._~-]+(:[0-9]+)?(/[^[:space:]]*)?$", var.n8n_webhook_url))
    error_message = "n8n_webhook_url must be an https:// base URL with a host and no whitespace (e.g. \"https://webhooks.example.com\"). n8n hands this value to callers as the address to POST to, so a bare hostname, an http:// URL, or a trailing newline produces webhook URLs that external systems cannot reach, with nothing failing on this side."
  }
}

variable "n8n_license_key" {
  description = "n8n Enterprise license activation key. Get one at https://n8n.io/pricing. Required unless n8n_license_key_secret_ref points at an existing Kubernetes Secret that already carries it, in which case leave this null. Setting both is rejected at plan time; see n8n_license_key_secret_ref, which owns that validation to avoid a variable-validation dependency cycle between the two."
  type        = string
  sensitive   = true
  default     = null
}

variable "n8n_license_key_secret_ref" {
  description = "Existing Kubernetes Secret carrying the n8n Enterprise license key, instead of supplying the value through n8n_license_key. name is the Secret's name in var.namespace; key defaults to \"license-key\", matching the chart's own license.existingSecret.key default, and can be overridden if the Secret you already sync uses a different key name. Null (the default) changes nothing: the module keeps writing the value from n8n_license_key into kubernetes_secret.n8n as it always has. The module does not verify that the named Secret exists or carries this key: a typo surfaces only as a pod stuck in CreateContainerConfigError naming the missing key, not as a Terraform error, because reading the Secret's data to check would put the credential back in Terraform state, which defeats the reason this input exists. Setting this alongside n8n_license_key is rejected at plan time, so one can never silently win over the other; so is setting neither, since n8n_license_key is otherwise required. Both checks live here rather than split across both variables, which would form a validation dependency cycle. Also see n8n_encryption_key_secret_ref: setting that input replaces kubernetes_secret.n8n entirely, and this input becomes required (not merely allowed) whenever it is set, since there is then no module-managed Secret left for the license key to live in."
  type = object({
    name = string
    key  = optional(string)
  })
  default = null

  validation {
    condition     = var.n8n_license_key_secret_ref == null || var.n8n_license_key == null
    error_message = "Both n8n_license_key and n8n_license_key_secret_ref are set. Only one may supply the license key: remove n8n_license_key to consume the referenced Secret, or remove n8n_license_key_secret_ref to keep passing the value directly."
  }

  validation {
    condition     = var.n8n_license_key_secret_ref != null || var.n8n_license_key != null
    error_message = "n8n_license_key is required unless n8n_license_key_secret_ref is set. Supply the license key directly, or point n8n_license_key_secret_ref at an existing Kubernetes Secret that already carries it."
  }
}

variable "n8n_encryption_key" {
  description = "N8N_ENCRYPTION_KEY value. Leave null (the default) to let the module generate one with random_id (32 bytes, rendered as 64 hex characters), matching every deployment's behavior before this input existed. THIS IS NOT A ROTATION MECHANISM. n8n's own docs describe this as the instance's master key, set once at deployment time, and state plainly that it never changes; a second, distinct key (the data encryption key, stored in the database and itself encrypted by this one) is what n8n's own key-rotation feature (N8N_ENV_FEAT_ENCRYPTION_KEY_ROTATION, a one-way operation with no rollback) actually rotates, unrelated to this input. Setting this variable to a NEW value against a database that already holds credentials encrypted under a DIFFERENT key does not migrate or re-encrypt anything: n8n reads the new key, the stored credentials were written under the old one, and every one of them becomes permanently unreadable with no n8n-side recovery path. The only supported uses of a non-null value are (1) the first deployment against a brand-new, empty database, where there is nothing yet encrypted to mismatch, and (2) restoring the EXACT ORIGINAL key into a rebuilt stack pointed at a database that already holds credentials encrypted under that same original key: a rebuilt cluster, a cross-region standby, or any fresh terraform apply reattaching to an existing RDS instance or snapshot. Retrieve that original value beforehand with `terraform output -raw n8n_encryption_key` (or wherever it was backed up per that output's own warning); never invent a new one for an existing database. Must be exactly 64 hexadecimal characters (32 bytes) to match the shape n8n and the chart expect and what random_id has always produced; a shorter or non-hex value is rejected at plan time rather than reaching n8n and failing less legibly there. Kept as a static input compared at plan time (`== null`) rather than left to a resource distinction, because gating `random_id.n8n_encryption_key`'s `count` on it is what lets Terraform decide at plan time whether to generate a key at all, and a `moved` block in refactoring.tf absorbs the resulting address change for every deployment that leaves this null, so upgrading onto this input is a no-op as long as the value is not set. Leave this null as well when n8n_encryption_key_secret_ref is set instead; setting both is rejected at plan time."
  type        = string
  sensitive   = true
  default     = null

  validation {
    condition     = var.n8n_encryption_key == null || can(regex("^[0-9a-fA-F]{64}$", var.n8n_encryption_key))
    error_message = "n8n_encryption_key must be exactly 64 hexadecimal characters (32 bytes), the shape random_id.n8n_encryption_key (byte_length = 32) has always produced, or null to let the module generate one."
  }
}

variable "n8n_encryption_key_secret_ref" {
  description = "Existing Kubernetes Secret carrying N8N_ENCRYPTION_KEY, instead of supplying the value through n8n_encryption_key. Different in shape from the other three secret-reference inputs below: the chart's secretRefs.existingSecret (n8n.tf) names a single Secret that n8n.coreSecretsEnv reads FOUR keys from, N8N_ENCRYPTION_KEY, N8N_HOST, N8N_PORT and N8N_PROTOCOL, so setting this input points the chart at your Secret for all four, not just the encryption key, and your Secret must carry every one of them: N8N_HOST is var.n8n_domain, N8N_PORT is \"5678\", N8N_PROTOCOL is \"http\". See README.md -> \"Where credentials live\" for a worked ExternalSecret example with a template block supplying those three literals alongside the fetched key. key defaults to \"N8N_ENCRYPTION_KEY\" and exists only for shape parity with the other three secret-reference inputs: the chart hardcodes the key name it reads on this path, so this module rejects any other value at plan time rather than silently ignoring it. Setting this input also gates kubernetes_secret.n8n to zero, since secretRefs.existingSecret replaces that whole Secret rather than one key inside it, which leaves the license key with nowhere to live: it otherwise rides in kubernetes_secret.n8n too. The task runner auth token is unaffected, since it is never in a Secret at all: it reaches the chart as a literal Helm value regardless of this input. n8n_license_key_secret_ref must therefore also be set whenever this is; the module rejects the plan rather than pointing a chart value at a Secret that no longer exists. Setting this alongside n8n_encryption_key is rejected at plan time. The module does not verify that the referenced Secret exists or carries the required keys: a missing key surfaces only as a pod stuck in CreateContainerConfigError, not as a Terraform error."
  type = object({
    name = string
    key  = optional(string)
  })
  default = null

  validation {
    condition     = var.n8n_encryption_key_secret_ref == null || var.n8n_encryption_key == null
    error_message = "Both n8n_encryption_key and n8n_encryption_key_secret_ref are set. Only one may supply the encryption key: remove n8n_encryption_key to consume the referenced Secret, or remove n8n_encryption_key_secret_ref to keep passing the value directly."
  }

  # Written as a nested ternary rather than `== null ||`, per AGENTS.md's
  # consistency rule for guard-style conditions: the null guard gates the
  # `.key` access structurally rather than relying on short-circuit
  # evaluation.
  validation {
    condition     = var.n8n_encryption_key_secret_ref == null ? true : coalesce(var.n8n_encryption_key_secret_ref.key, "N8N_ENCRYPTION_KEY") == "N8N_ENCRYPTION_KEY"
    error_message = "n8n_encryption_key_secret_ref.key must be \"N8N_ENCRYPTION_KEY\" or unset. The chart's coreSecretsEnv helper reads this exact key name from secretRefs.existingSecret and takes no override, unlike the other three secret-reference inputs, whose key the chart does honor."
  }

  validation {
    condition     = var.n8n_encryption_key_secret_ref == null || var.n8n_license_key_secret_ref != null
    error_message = "n8n_encryption_key_secret_ref replaces kubernetes_secret.n8n entirely, so n8n_license_key_secret_ref must also be set: the license key has no module-managed Secret left to live in otherwise."
  }
}

variable "n8n_license_detach_floating_on_shutdown" {
  description = "Whether n8n main pods detach their floating license entitlement on shutdown. Maps to N8N_LICENSE_DETACH_FLOATING_ON_SHUTDOWN. n8n's upstream default is true, which is safe for a single main but breaks multi-main (n8n_main_hpa_min_replicas > 1, the module default): the leader main detaches on shutdown and zeroes the shared floating cert in the database, so any fresh main pod that starts as a follower reads the zeroed cert, fails the init-time license gate, and crash-loops — which can push a Helm release with atomic = true into a stuck pending-rollback state (see docs/troubleshooting.md and <https://github.com/n8n-io/terraform-aws-n8n/issues/49>). The module defaults this to false, overriding n8n's own default, because all mains share the same device fingerprint: a single floating seat is reused across restarts and nothing leaks. Set to true only to restore n8n's upstream behavior, and only for single-main deployments."
  type        = bool
  default     = false
}

# ── EKS cluster ───────────────────────────────────────────────────────────────

variable "eks_secrets_encryption_enabled" {
  description = "When true (the default), envelope-encrypt Kubernetes Secrets and the EKS control-plane CloudWatch log group with a module-created Customer Managed KMS Key (aws_kms_key.eks). Clears Checkov findings CKV_AWS_58 and CKV_AWS_158. The supported AWS provider associates encryption with an existing unencrypted cluster in place; disabling it again is irreversible in EKS and therefore forces cluster replacement. Set to false before the first apply to preserve current behavior on a pre-existing cluster without secrets encryption. The CMK rotates annually and uses a 7-day deletion window (AWS minimum)."
  type        = bool
  default     = true
  nullable    = false
}

variable "cluster_endpoint_public_access" {
  description = "Whether the EKS API server endpoint is reachable from outside the VPC. Defaults to true so kubectl works immediately after apply. Set to false (with cluster_endpoint_private_access = true) to require VPN/peering/bastion access to the control plane."
  type        = bool
  default     = true
  nullable    = false
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDR blocks allowed to reach the EKS API server's public endpoint. Defaults to 0.0.0.0/0 (unrestricted) to preserve current behavior. Restrict to your office/VPN CIDRs to clear Checkov findings CKV_AWS_38/CKV_AWS_39 without disabling public access outright. Ignored when cluster_endpoint_public_access = false."
  type        = list(string)
  default     = ["0.0.0.0/0"]
  nullable    = false

  validation {
    condition     = alltrue([for c in var.cluster_endpoint_public_access_cidrs : can(cidrhost(c, 0))])
    error_message = "Every entry must be a valid CIDR block (e.g. 203.0.113.0/24)."
  }

  # An empty list is not "deny all": with the public endpoint enabled and no
  # CIDRs specified, EKS falls back to its own 0.0.0.0/0 default, which is the
  # opposite of what an empty list looks like it does. The input is genuinely
  # ignored when public access is disabled, so a private-only caller may pass an
  # empty list explicitly.
  validation {
    condition     = var.cluster_endpoint_public_access ? length(var.cluster_endpoint_public_access_cidrs) > 0 : true
    error_message = "cluster_endpoint_public_access_cidrs must contain at least one CIDR while cluster_endpoint_public_access = true. To close the public endpoint entirely, set cluster_endpoint_public_access = false (with cluster_endpoint_private_access = true) rather than passing an empty list."
  }
}

variable "cluster_endpoint_private_access" {
  description = "Whether the EKS API server endpoint is also reachable from inside the VPC. Defaults to false, matching the module's existing behavior. When false, in-VPC traffic (worker nodes' kubelet connections included) reaches the control plane over the public endpoint via NAT; when true, the endpoint resolves to private IPs inside the VPC and that traffic stays in the VPC. Set to true to keep kubectl working from inside the VPC/VPN while restricting or disabling public access. At least one of cluster_endpoint_public_access or cluster_endpoint_private_access must be true."
  type        = bool
  default     = false
  nullable    = false

  # EKS requires at least one endpoint access mode. Caught here rather than
  # letting the apply fail against the AWS API several minutes in, or (worse)
  # producing a cluster nothing can reach.
  validation {
    condition     = var.cluster_endpoint_public_access || var.cluster_endpoint_private_access
    error_message = "At least one of cluster_endpoint_public_access or cluster_endpoint_private_access must be true; EKS requires the API server endpoint to be reachable by at least one path."
  }
}

variable "create_namespace" {
  description = "When true (the default), the module creates the Kubernetes namespace named by var.namespace. Set to false to deploy into a namespace that already exists, e.g. one a platform team created with its own resource quotas, labels, or network policies. The module does not validate that the namespace exists; the apply fails on the first resource that references it if it does not. Kept as a static boolean rather than checking for the namespace's existence because count expressions cannot depend on values computed at apply time."
  type        = bool
  default     = true
  nullable    = false
}

# ── Ingress ───────────────────────────────────────────────────────────────────

variable "create_ingress" {
  description = "When true (the default), the module creates the ALB Ingress that fronts n8n: a single internet-facing ALB routing /webhook to the webhook processors and / to the mains. Set to false to supply your own, customer-managed Ingress resources instead, for example the two-ALB split where an internet-facing ALB serves /webhook and a separate internal (VPN-only) ALB serves the admin UI. When false the module also skips the Route 53 alias A-record and the ALB lookup behind it, since there is no module-owned ALB to point at; the ACM certificate is still issued when route53_zone_id is set. Point your own Ingresses at the module-created Services n8n_service_name and n8n_webhook_service_name, both on port 5678. Kept as a static boolean because count expressions cannot depend on values computed at apply time."
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
  description = "Extra annotations for the module-managed Ingress, merged over the module's defaults (last write wins). Use this for AWS Load Balancer Controller features the module has no opinion on: alb.ingress.kubernetes.io/wafv2-acl-arn, subnets, security-groups, load-balancer-name, group.name, access log settings. Overriding alb.ingress.kubernetes.io/target-group-attributes drops the session stickiness that keeps WebSocket connections pinned to one main pod; re-include stickiness.enabled=true if you set it. Prefer ingress_scheme over setting alb.ingress.kubernetes.io/scheme here, alb_ssl_policy over setting alb.ingress.kubernetes.io/ssl-policy here, and alb_inbound_cidrs / alb_inbound_prefix_list_ids over setting alb.ingress.kubernetes.io/inbound-cidrs or security-group-prefix-lists here, because setting both raises a plan-time warning. Ignored when create_ingress = false. Also the fix for a real subnet auto-discovery gap when two deployments of this module share one VPC (e.g. redis_host / db_host / existing_s3_bucket_name pointed at another deployment's real infrastructure, per docs/customer-managed-infrastructure.md): the Load Balancer Controller's own auto-discovery treats a subnet already tagged kubernetes.io/cluster/<other-name>=shared as ineligible for THIS cluster, not shareable, even though the same subnet still carries the kubernetes.io/role/elb / role/internal-elb tags LBC's docs describe as sufficient -- confirmed live (\"couldn't auto-discover subnets: ... N are tagged for other clusters\"). Set alb.ingress.kubernetes.io/subnets = \"<id>,<id>\" here to bypass auto-discovery entirely rather than re-tagging the other deployment's already-running subnets."
  type        = map(string)
  default     = {}
}

variable "alb_ssl_policy" {
  description = "TLS negotiation policy for the ALB HTTPS listener, wired to alb.ingress.kubernetes.io/ssl-policy. Defaults to a current, modern policy (ELBSecurityPolicy-TLS13-1-2-2021-06) so the negotiated policy is explicit and pinned in Terraform rather than left to whatever the ALB defaults to, which AWS can change without notice. Set this to any AWS-published ELB security policy name (e.g. one of the `ELBSecurityPolicy-TLS13-1-2-*` or `ELBSecurityPolicy-FS-1-2-*` families) to match a compliance baseline such as TLS 1.2 minimum or TLS 1.3-only. Ignored when create_ingress = false, or when ingress_annotations sets alb.ingress.kubernetes.io/ssl-policy directly (last write wins; the module warns when that happens)."
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

variable "node_disk_size" {
  description = <<-EOT
    Root EBS volume size in GiB for the EKS worker nodes. Leave null for the EKS
    managed-node-group default, which is 20 GiB. Previously unsettable: the node
    group set no disk_size at all and the module exposed no input, so every
    deployment silently took the 20 GiB default regardless of pod density.

    20 GiB is not much once the node's own baseline is accounted for. Measured on
    a 42-node m7i.4xlarge cluster running n8n at load, about 7.7 GiB per node is
    consumed before any workload growth, of which roughly 2.3 GiB is OS files
    under /usr and 3.5 to 3.8 GiB is container images and layers under
    /var/lib/containerd. The kubelet begins evicting pods at around 2.1 GiB
    available. That leaves roughly 11 GiB of usable headroom on a 20 GiB volume,
    which is a good deal less than the volume size suggests.

    Size it for TRANSIENT SPIKES, not for steady-state growth. The same cluster
    was observed sitting flat for an hour and then consuming 13 to 14 GiB per node
    within about four minutes, across 40 of 42 nodes simultaneously, before
    releasing it again just as quickly. A volume sized to the steady state has no
    margin for that and the kubelet evicts, which on this workload took out 279
    pods in one episode.

    NOTE: changing this on an existing cluster replaces every node in the group.
    Plan for the rollout, and do not change it during a measurement run.
  EOT
  type        = number
  default     = null

  validation {
    condition     = var.node_disk_size == null ? true : var.node_disk_size >= 20
    error_message = "node_disk_size must be at least 20 GiB (the EKS default), or null to use that default."
  }

  validation {
    condition     = var.node_disk_size == null || try(var.node_disk_size == floor(var.node_disk_size), false)
    error_message = "node_disk_size must be a whole number of GiB."
  }
}

variable "node_instance_type" {
  description = "EC2 instance type for EKS worker nodes. t3.xlarge (4 vCPU, 16GB) is the recommended minimum for multi-main — the 6 n8n pods (main × 2, worker × 2, webhook × 2) request ~3,600m CPU at minimum replicas, leaving t3.medium nodes with insufficient headroom for HPA to scale."
  type        = string
  default     = "t3.xlarge"
  nullable    = false

  validation {
    condition     = can(regex("^[a-z][a-z0-9]*(-[a-z0-9]+)*\\.[a-z0-9]+(-[a-z0-9]+)*$", var.node_instance_type))
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

  validation {
    condition     = var.node_desired == floor(var.node_desired) && var.node_desired >= var.node_min && var.node_desired <= var.node_max
    error_message = "node_desired must be a whole number of nodes within [node_min, node_max]. AWS rejects a managed node group whose desiredSize sits outside its own scaling bounds; this only applied at creation, so getting it wrong failed the first apply rather than a later one."
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

  validation {
    condition     = var.node_min == floor(var.node_min) && var.node_min >= 1
    error_message = "node_min must be a whole number of nodes, 1 or greater."
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

  validation {
    condition     = var.node_max == floor(var.node_max) && var.node_max >= var.node_min
    error_message = "node_max must be a whole number of nodes and must not be below node_min. AWS rejects a managed node group whose scaling config has maxSize below minSize, and nothing before this said so."
  }
}

# ── Cluster controllers ────────────────────────────────────────────────────────
# Four Helm-installed controllers run alongside n8n in kube-system (LBC, Cluster
# Autoscaler, metrics-server) and its own keda namespace. All four default to
# installed, matching every module version before these inputs existed.
#
# Each toggle skips only the helm_release. The IAM role, policy and Pod
# Identity association for LBC and Cluster Autoscaler (modules/controllers/iam.tf) are left
# unconditional on purpose: a Pod Identity association does nothing on its own
# until a ServiceAccount matching its namespace and name actually exists, so an
# association with no controller installed is inert, not a live attack surface
# the way, say, an unattached security group rule would be. Leaving IAM in
# place is also what makes the toggle useful for its main purpose: a caller
# whose platform team installs these same charts through GitOps rather than
# Terraform still needs the IAM binding this module creates, just not a second
# Helm release racing the first one for the same ServiceAccount.
#
# Terraform cannot see whether that external install actually exists at plan
# time, so setting any of these to false is a claim only the caller can make.
# Getting it wrong fails at apply, not plan: helm_release.n8n's dependency on
# install_lbc / install_keda (n8n.tf) becomes a no-op, so nothing here blocks
# an apply with no controller behind it. See each variable for what actually
# breaks and how.

variable "install_lbc" {
  description = "When true (the default), the module installs the AWS Load Balancer Controller via Helm. Set to false only when an identical install already exists in the cluster, e.g. one a platform team manages through GitOps. The IAM role, policy and Pod Identity association this module creates for the aws-load-balancer-controller ServiceAccount in kube-system are all created whenever this is true OR create_eks is true, and all skipped when both are false, so this toggle never strands an IAM role nothing can assume. On create_eks = true (a freshly created cluster), nothing can already be bound to that ServiceAccount, so the association is created regardless of this toggle, which is what lets an externally-installed LBC on the new cluster still get its IAM binding. On create_eks = false (an existing cluster), that assumption doesn't hold: the ServiceAccount may already carry an association, e.g. one from a previous invocation of this exact module against the same cluster, and EKS hard-rejects a second association for a ServiceAccount that already has one. Setting this to false on that path is read as an attestation that an association already exists there. Must stay true whenever create_ingress = true: kubernetes_ingress_v1.n8n waits for LBC to provision an ALB (wait_for_load_balancer = true) and that wait times out the apply if no controller is running to service it. Disabling this while an external LBC is not yet Ready can also race helm_release.keda; see the ordering note in modules/controllers/keda.tf."
  type        = bool
  default     = true

  validation {
    condition     = var.install_lbc || !var.create_ingress
    error_message = "install_lbc = false is incompatible with create_ingress = true: the module-managed Ingress waits for the Load Balancer Controller to provision an ALB, and with no controller installed that wait times out the apply. Either leave install_lbc = true, or set create_ingress = false and point your own Ingress resources at an LBC you install another way. There is no exception for create_eks = false against a cluster whose LBC already works: see docs/customer-managed-infrastructure.md's \"create_eks = false + create_ingress = true\" section for why, and what the two supported options are."
  }
}

variable "install_cluster_autoscaler" {
  description = "When true (the default), the module installs the Kubernetes Cluster Autoscaler via Helm. Set to false only when an identical install already exists in the cluster, e.g. one a platform team manages through GitOps, or when node_desired = node_max and the node group is meant to stay a fixed size. The IAM role, policy and Pod Identity association for the cluster-autoscaler ServiceAccount all follow the same create_eks-aware rule as install_lbc's (see that variable's description): created when this is true or create_eks is true, skipped only when both are false, since an existing cluster may already carry this ServiceAccount's association from elsewhere and a second one would collide with it. With no autoscaler running at all, node_max is not enforced automatically: nodes stay at whatever desired_size last converged to, and the autoscaling capacity check in scaling.tf still assumes an autoscaler will eventually add nodes up to node_max, so a caller relying on this toggle to go without one entirely should also lower the HPA/KEDA maxima to what the fixed node count can actually schedule."
  type        = bool
  default     = true
}

variable "install_metrics_server" {
  description = "When true (the default), the module installs metrics-server via Helm. EKS does not ship it by default, and without it every CPU-based HPA target reads \"cpu: <unknown>\" and never scales. Set to false only when an identical install already exists in the cluster, e.g. one a platform team manages through GitOps, or the caller's own metrics pipeline already serves the metrics.k8s.io API. kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook (scaling.tf) is a CPU-resource HPA and depends on metrics-server existing somewhere; disabling this with no equivalent running leaves that HPA permanently unable to read CPU and stuck at its minimum replica count. That failure is silent: it does not fail the apply, only the autoscaling."
  type        = bool
  default     = true
}

variable "install_keda" {
  description = "When true (the default), the module installs the KEDA operator via Helm into the keda namespace. Set to false only when an identical install already exists in the cluster, e.g. one a platform team manages through GitOps. The n8n Helm release always sets keda.enabled = true in its values (n8n.tf), which makes the chart emit a ScaledObject for the worker deployment regardless of this variable; if no KEDA operator and CRDs are registered anywhere in the cluster when that manifest applies, helm_release.n8n fails outright with an unrecognized-kind error, not a silent misbehavior like install_metrics_server's failure mode. Disabling this while an external KEDA is not yet Ready can also race helm_release.lbc; see the ordering note in modules/controllers/keda.tf. Flipping this from true to false on an already-applied stack (rather than a full terraform destroy) can hang the apply indefinitely: nothing in this toggle touches helm_release.n8n, so its live ScaledObject is never removed, and Helm's own uninstall of the KEDA chart deletes the operator before the scaledobjects.keda.sh CRD, whose deletion then blocks forever on that still-live instance's finalizer with no operator left running to clear it. Delete the n8n-rendered ScaledObject(s) by hand before disabling this on a live cluster, or expect to break the deadlock manually (patch the ScaledObject's finalizers to empty)."
  type        = bool
  default     = true
}

# ── Chart repositories ─────────────────────────────────────────────────────────
# Each helm_release's repository argument, exposed so any of the five charts
# can be pulled from a private mirror instead of its public upstream. Every
# default reproduces the module's own hardcoded value exactly, so leaving all
# five unset is a no-op for every existing deployment. This is the other half
# of air-gapped support: n8n_image_repository already lets the n8n container
# image itself be mirrored, but until these existed the five charts had no
# such input, so a cluster with no egress to their public repositories could
# not come up regardless of what the image pointed at.
#
# A mirror must carry the exact version each chart is pinned to in "Chart
# versions" below, since all five versions are now explicit. Mirroring a
# subset of upstream's versions is the common case, so expect to set the
# matching *_chart_version alongside the repository rather than only the
# repository.

variable "n8n_chart_repository" {
  description = "Helm chart repository for the n8n chart. Defaults to the public upstream (oci://ghcr.io/n8n-io/n8n-helm-chart). Point this at a private mirror, e.g. an ECR OCI repository in this account, for a cluster with no egress to ghcr.io. The mirror must serve the exact chart version named by n8n_chart_version; this module does not verify that a mirrored repository actually carries it."
  type        = string
  default     = "oci://ghcr.io/n8n-io/n8n-helm-chart"

  validation {
    condition     = can(regex("^(https://|oci://)[A-Za-z0-9._~-]+(:[0-9]+)?(/[^[:space:]]*)?$", var.n8n_chart_repository))
    error_message = "n8n_chart_repository must be a URL starting with https:// or oci://, with a host and no whitespace."
  }
}

variable "lbc_chart_repository" {
  description = "Helm chart repository for the AWS Load Balancer Controller chart. Defaults to the public upstream (https://aws.github.io/eks-charts). Point this at a private mirror for a cluster with no egress to that repository. Ignored when install_lbc = false."
  type        = string
  default     = "https://aws.github.io/eks-charts"

  validation {
    condition     = can(regex("^(https://|oci://)[A-Za-z0-9._~-]+(:[0-9]+)?(/[^[:space:]]*)?$", var.lbc_chart_repository))
    error_message = "lbc_chart_repository must be a URL starting with https:// or oci://, with a host and no whitespace."
  }
}

variable "cluster_autoscaler_chart_repository" {
  description = "Helm chart repository for the Cluster Autoscaler chart. Defaults to the public upstream (https://kubernetes.github.io/autoscaler). Point this at a private mirror for a cluster with no egress to that repository. Ignored when install_cluster_autoscaler = false."
  type        = string
  default     = "https://kubernetes.github.io/autoscaler"

  validation {
    condition     = can(regex("^(https://|oci://)[A-Za-z0-9._~-]+(:[0-9]+)?(/[^[:space:]]*)?$", var.cluster_autoscaler_chart_repository))
    error_message = "cluster_autoscaler_chart_repository must be a URL starting with https:// or oci://, with a host and no whitespace."
  }
}

variable "metrics_server_chart_repository" {
  description = "Helm chart repository for the metrics-server chart. Defaults to the public upstream (https://kubernetes-sigs.github.io/metrics-server/). Point this at a private mirror for a cluster with no egress to that repository. Ignored when install_metrics_server = false."
  type        = string
  default     = "https://kubernetes-sigs.github.io/metrics-server/"

  validation {
    condition     = can(regex("^(https://|oci://)[A-Za-z0-9._~-]+(:[0-9]+)?(/[^[:space:]]*)?$", var.metrics_server_chart_repository))
    error_message = "metrics_server_chart_repository must be a URL starting with https:// or oci://, with a host and no whitespace."
  }
}

variable "keda_chart_repository" {
  description = "Helm chart repository for the KEDA chart. Defaults to the public upstream (https://kedacore.github.io/charts). Point this at a private mirror for a cluster with no egress to that repository. Ignored when install_keda = false."
  type        = string
  default     = "https://kedacore.github.io/charts"

  validation {
    condition     = can(regex("^(https://|oci://)[A-Za-z0-9._~-]+(:[0-9]+)?(/[^[:space:]]*)?$", var.keda_chart_repository))
    error_message = "keda_chart_repository must be a URL starting with https:// or oci://, with a host and no whitespace."
  }
}

# ── Chart versions ────────────────────────────────────────────────────────────
# The four controller charts alongside n8n's own. n8n_chart_version has always
# been pinned; these four were not passed a `version` at all, which meant the
# installed version was whatever each repository's index happened to serve at
# the moment of the first apply. Two deployments of the same module commit
# could therefore be running different controller versions, and neither the
# plan nor the state made that visible until something broke.
#
# Every default is the version the public repository serves as latest as of
# 2026-08-05, so a fresh apply installs exactly what it would have installed
# unpinned. A deployment that first applied earlier and is still on an older
# chart plans an in-place Helm upgrade to the pinned version on its next apply.
# That is the intended cost: a deliberate, reviewable upgrade in a plan beats a
# version nobody chose. Override any of these to stay where you are.
#
# Bumping a default here is a module change worth its own CHANGELOG entry,
# because it upgrades a cluster-scoped controller for every consumer who has
# not pinned. See AGENTS.md → "When adding a new input".

variable "n8n_chart_version" {
  description = "n8n Helm chart version to deploy. Must be an exact version, not a constraint: the Helm provider resolves this literally."
  type        = string
  default     = "1.10.0"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?(\\+[0-9A-Za-z.-]+)?$", var.n8n_chart_version))
    error_message = "n8n_chart_version must be an exact SemVer 2 version such as \"1.10.0\" or \"1.11.0-rc.1\". Helm resolves chart versions literally here, so a range (\">= 1.10\", \"~1.10.0\"), a leading \"v\", or a floating tag is not accepted."
  }
}

variable "lbc_chart_version" {
  description = "AWS Load Balancer Controller Helm chart version. Defaults to 3.5.0, the version the module's documented ALB behaviour (source restrictions, IngressClassParams precedence, the failurePolicy override) was verified against on a live cluster. Ignored when install_lbc = false."
  type        = string
  default     = "3.5.0"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?(\\+[0-9A-Za-z.-]+)?$", var.lbc_chart_version))
    error_message = "lbc_chart_version must be an exact SemVer 2 version such as \"3.5.0\". Helm resolves chart versions literally here, so a range (\">= 3.5\", \"~3.5.0\"), a leading \"v\", or a floating tag is not accepted."
  }
}

variable "cluster_autoscaler_chart_version" {
  description = "Cluster Autoscaler Helm chart version. Defaults to 9.59.0. The chart version and the autoscaler's own app version move independently, so read the chart's release notes rather than assuming this tracks a Kubernetes minor. Ignored when install_cluster_autoscaler = false."
  type        = string
  default     = "9.59.0"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?(\\+[0-9A-Za-z.-]+)?$", var.cluster_autoscaler_chart_version))
    error_message = "cluster_autoscaler_chart_version must be an exact SemVer 2 version such as \"9.59.0\". Helm resolves chart versions literally here, so a range (\">= 9.59\", \"~9.59.0\"), a leading \"v\", or a floating tag is not accepted."
  }
}

variable "metrics_server_chart_version" {
  description = "metrics-server Helm chart version. Defaults to 3.13.1. Ignored when install_metrics_server = false."
  type        = string
  default     = "3.13.1"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?(\\+[0-9A-Za-z.-]+)?$", var.metrics_server_chart_version))
    error_message = "metrics_server_chart_version must be an exact SemVer 2 version such as \"3.13.1\". Helm resolves chart versions literally here, so a range (\">= 3.13\", \"~3.13.0\"), a leading \"v\", or a floating tag is not accepted."
  }
}

variable "keda_chart_version" {
  description = "KEDA Helm chart version. Defaults to 2.20.2. KEDA ships its CRDs in this chart, and the n8n chart always emits a ScaledObject (n8n.tf sets keda.enabled = true unconditionally), so a downgrade far enough to drop the ScaledObject API version the n8n chart renders fails helm_release.n8n outright rather than degrading. Ignored when install_keda = false."
  type        = string
  default     = "2.20.2"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?(\\+[0-9A-Za-z.-]+)?$", var.keda_chart_version))
    error_message = "keda_chart_version must be an exact SemVer 2 version such as \"2.20.2\". Helm resolves chart versions literally here, so a range (\">= 2.20\", \"~2.20.0\"), a leading \"v\", or a floating tag is not accepted."
  }
}

variable "n8n_image_tag" {
  description = "n8n application image tag to deploy (e.g. \"2.27.4\"). When it is null (the default), the Helm chart's own default applies — currently the floating `stable` tag, which resolves to whatever n8n version is latest at the time each pod starts. Pin this to a concrete version for reproducible, incremental upgrades and to avoid crossing major-version boundaries (e.g. the n8n 2.0 breaking changes) on an unplanned pod reschedule. See <https://docs.n8n.io/2-0-breaking-changes/> for the n8n 2.x migration guide."
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

  validation {
    # The subset of Kubernetes' quantity grammar that scaling.tf's capacity
    # model can read. Restricting to it is the point: an unreadable quantity
    # makes local.n8n_cpu_requests_readable false, which collapses the peak-CPU
    # figure to zero and lets check.autoscaling_maxima_fit_node_capacity pass
    # vacuously. Kubernetes would still reject the value at apply, but only
    # after a plan that claimed the maxima fit.
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?m?$", var.n8n_main_cpu_request))
    error_message = "n8n_main_cpu_request must be a CPU quantity: a plain number of cores (\"1\", \"0.5\") or millicores with an m suffix (\"1000m\"). Memory suffixes (Mi, Gi), units (\"1 core\"), and whitespace are not accepted."
  }
}

variable "n8n_main_cpu_limit" {
  description = "CPU limit for n8n main pods (e.g. 2000m, 1000m)"
  type        = string
  default     = "2000m"

  validation {
    # The subset of Kubernetes' quantity grammar that scaling.tf's capacity
    # model can read. Restricting to it is the point: an unreadable quantity
    # makes local.n8n_cpu_requests_readable false, which collapses the peak-CPU
    # figure to zero and lets check.autoscaling_maxima_fit_node_capacity pass
    # vacuously. Kubernetes would still reject the value at apply, but only
    # after a plan that claimed the maxima fit.
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?m?$", var.n8n_main_cpu_limit))
    error_message = "n8n_main_cpu_limit must be a CPU quantity: a plain number of cores (\"1\", \"0.5\") or millicores with an m suffix (\"1000m\"). Memory suffixes (Mi, Gi), units (\"1 core\"), and whitespace are not accepted."
  }
}

variable "n8n_main_memory_request" {
  description = "Memory request for n8n main pods (e.g. 2Gi, 1Gi)"
  type        = string
  default     = "2Gi"

  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?(Ki|Mi|Gi|Ti|k|M|G|T)?$", var.n8n_main_memory_request))
    error_message = "n8n_main_memory_request must be a memory quantity: a number with an optional Kubernetes suffix (\"512Mi\", \"2Gi\", \"1G\", or plain bytes). \"GB\"/\"MB\", whitespace, and CPU-style m suffixes are not accepted. Prefer the binary suffixes (Mi, Gi): 2G is 2,000,000,000 bytes while 2Gi is 2,147,483,648."
  }
}

variable "n8n_main_memory_limit" {
  description = "Memory limit for n8n main pods (e.g. 4Gi, 2Gi)"
  type        = string
  default     = "4Gi"

  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?(Ki|Mi|Gi|Ti|k|M|G|T)?$", var.n8n_main_memory_limit))
    error_message = "n8n_main_memory_limit must be a memory quantity: a number with an optional Kubernetes suffix (\"512Mi\", \"2Gi\", \"1G\", or plain bytes). \"GB\"/\"MB\", whitespace, and CPU-style m suffixes are not accepted. Prefer the binary suffixes (Mi, Gi): 2G is 2,000,000,000 bytes while 2Gi is 2,147,483,648."
  }
}

variable "n8n_worker_cpu_request" {
  description = "CPU request for n8n worker pods (e.g. 500m, 1000m)"
  type        = string
  default     = "500m"

  validation {
    # The subset of Kubernetes' quantity grammar that scaling.tf's capacity
    # model can read. Restricting to it is the point: an unreadable quantity
    # makes local.n8n_cpu_requests_readable false, which collapses the peak-CPU
    # figure to zero and lets check.autoscaling_maxima_fit_node_capacity pass
    # vacuously. Kubernetes would still reject the value at apply, but only
    # after a plan that claimed the maxima fit.
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?m?$", var.n8n_worker_cpu_request))
    error_message = "n8n_worker_cpu_request must be a CPU quantity: a plain number of cores (\"1\", \"0.5\") or millicores with an m suffix (\"1000m\"). Memory suffixes (Mi, Gi), units (\"1 core\"), and whitespace are not accepted."
  }
}

variable "n8n_worker_cpu_limit" {
  description = "CPU limit for n8n worker pods (e.g. 1000m, 2000m)"
  type        = string
  default     = "1000m"

  validation {
    # The subset of Kubernetes' quantity grammar that scaling.tf's capacity
    # model can read. Restricting to it is the point: an unreadable quantity
    # makes local.n8n_cpu_requests_readable false, which collapses the peak-CPU
    # figure to zero and lets check.autoscaling_maxima_fit_node_capacity pass
    # vacuously. Kubernetes would still reject the value at apply, but only
    # after a plan that claimed the maxima fit.
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?m?$", var.n8n_worker_cpu_limit))
    error_message = "n8n_worker_cpu_limit must be a CPU quantity: a plain number of cores (\"1\", \"0.5\") or millicores with an m suffix (\"1000m\"). Memory suffixes (Mi, Gi), units (\"1 core\"), and whitespace are not accepted."
  }
}

variable "n8n_worker_memory_request" {
  description = "Memory request for n8n worker pods (e.g. 1Gi, 2Gi)"
  type        = string
  default     = "1Gi"

  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?(Ki|Mi|Gi|Ti|k|M|G|T)?$", var.n8n_worker_memory_request))
    error_message = "n8n_worker_memory_request must be a memory quantity: a number with an optional Kubernetes suffix (\"512Mi\", \"2Gi\", \"1G\", or plain bytes). \"GB\"/\"MB\", whitespace, and CPU-style m suffixes are not accepted. Prefer the binary suffixes (Mi, Gi): 2G is 2,000,000,000 bytes while 2Gi is 2,147,483,648."
  }
}

variable "n8n_worker_memory_limit" {
  description = "Memory limit for n8n worker pods (e.g. 2Gi, 4Gi)"
  type        = string
  default     = "2Gi"

  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?(Ki|Mi|Gi|Ti|k|M|G|T)?$", var.n8n_worker_memory_limit))
    error_message = "n8n_worker_memory_limit must be a memory quantity: a number with an optional Kubernetes suffix (\"512Mi\", \"2Gi\", \"1G\", or plain bytes). \"GB\"/\"MB\", whitespace, and CPU-style m suffixes are not accepted. Prefer the binary suffixes (Mi, Gi): 2G is 2,000,000,000 bytes while 2Gi is 2,147,483,648."
  }
}

variable "n8n_webhook_cpu_request" {
  description = "CPU request for n8n webhook processor pods (e.g. 300m, 500m). This default is sized for typical webhook traffic, not for n8n_reinstall_missing_packages = true: a low request against an npm-install CPU spike is what drives the CPU-based HPA into a scale-up-on-every-rollout loop. Raise to at least 800m when that toggle is on; see n8n_reinstall_missing_packages and docs/troubleshooting.md."
  type        = string
  default     = "300m"

  validation {
    # The subset of Kubernetes' quantity grammar that scaling.tf's capacity
    # model can read. Restricting to it is the point: an unreadable quantity
    # makes local.n8n_cpu_requests_readable false, which collapses the peak-CPU
    # figure to zero and lets check.autoscaling_maxima_fit_node_capacity pass
    # vacuously. Kubernetes would still reject the value at apply, but only
    # after a plan that claimed the maxima fit.
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?m?$", var.n8n_webhook_cpu_request))
    error_message = "n8n_webhook_cpu_request must be a CPU quantity: a plain number of cores (\"1\", \"0.5\") or millicores with an m suffix (\"1000m\"). Memory suffixes (Mi, Gi), units (\"1 core\"), and whitespace are not accepted."
  }
}

variable "n8n_webhook_cpu_limit" {
  description = "CPU limit for n8n webhook processor pods (e.g. 800m, 1000m). Raise to at least 1500m when n8n_reinstall_missing_packages = true; see that variable and docs/troubleshooting.md."
  type        = string
  default     = "800m"

  validation {
    # The subset of Kubernetes' quantity grammar that scaling.tf's capacity
    # model can read. Restricting to it is the point: an unreadable quantity
    # makes local.n8n_cpu_requests_readable false, which collapses the peak-CPU
    # figure to zero and lets check.autoscaling_maxima_fit_node_capacity pass
    # vacuously. Kubernetes would still reject the value at apply, but only
    # after a plan that claimed the maxima fit.
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?m?$", var.n8n_webhook_cpu_limit))
    error_message = "n8n_webhook_cpu_limit must be a CPU quantity: a plain number of cores (\"1\", \"0.5\") or millicores with an m suffix (\"1000m\"). Memory suffixes (Mi, Gi), units (\"1 core\"), and whitespace are not accepted."
  }
}

variable "n8n_webhook_memory_request" {
  description = "Memory request for n8n webhook processor pods (e.g. 512Mi, 1Gi). Raise to at least 1Gi when n8n_reinstall_missing_packages = true; see that variable and docs/troubleshooting.md."
  type        = string
  default     = "512Mi"

  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?(Ki|Mi|Gi|Ti|k|M|G|T)?$", var.n8n_webhook_memory_request))
    error_message = "n8n_webhook_memory_request must be a memory quantity: a number with an optional Kubernetes suffix (\"512Mi\", \"2Gi\", \"1G\", or plain bytes). \"GB\"/\"MB\", whitespace, and CPU-style m suffixes are not accepted. Prefer the binary suffixes (Mi, Gi): 2G is 2,000,000,000 bytes while 2Gi is 2,147,483,648."
  }
}

variable "n8n_webhook_memory_limit" {
  description = "Memory limit for n8n webhook processor pods (e.g. 1Gi, 2Gi). This default is too low for n8n_reinstall_missing_packages = true: concurrent npm installs plus the n8n baseline can exceed it and OOMKill the pod mid-install into a reinstall/broadcast crash loop. Raise to at least 2Gi when that toggle is on; see that variable and docs/troubleshooting.md."
  type        = string
  default     = "1Gi"

  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?(Ki|Mi|Gi|Ti|k|M|G|T)?$", var.n8n_webhook_memory_limit))
    error_message = "n8n_webhook_memory_limit must be a memory quantity: a number with an optional Kubernetes suffix (\"512Mi\", \"2Gi\", \"1G\", or plain bytes). \"GB\"/\"MB\", whitespace, and CPU-style m suffixes are not accepted. Prefer the binary suffixes (Mi, Gi): 2G is 2,000,000,000 bytes while 2Gi is 2,147,483,648."
  }
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

variable "n8n_queue_worker_lock_duration" {
  description = "Milliseconds a worker holds a Bull job lock before it must renew it. Maps to the chart's redis.worker.lockDuration value (QUEUE_WORKER_LOCK_DURATION on the pods); must go through this chart value rather than config.extraEnv, because the chart's ConfigMap entry for this key renders unconditionally and a duplicate produces a container env entry carrying both value and valueFrom, which the Kubernetes API rejects. Leave null for n8n's own default (60000ms). Lowering it to 10000ms or less additionally requires setting n8n_queue_worker_lock_renew_time explicitly below it: the chart's renewal default is 10000ms, so an unset renewal interval would otherwise outlast the lock. That pairing is validated on n8n_queue_worker_lock_renew_time, because Terraform forbids two variables' validations from referencing each other, so a violation is reported against that variable."
  type        = number
  default     = null

  validation {
    condition     = var.n8n_queue_worker_lock_duration == null ? true : var.n8n_queue_worker_lock_duration >= 1000
    error_message = "n8n_queue_worker_lock_duration must be at least 1000 milliseconds, or null to use n8n's own default. The chart's values.schema.json enforces a minimum of 1000 on redis.worker.lockDuration, so lower values are rejected during Helm schema validation."
  }

  validation {
    condition     = var.n8n_queue_worker_lock_duration == null ? true : var.n8n_queue_worker_lock_duration == floor(var.n8n_queue_worker_lock_duration)
    error_message = "n8n_queue_worker_lock_duration must be a whole number of milliseconds, so this value is rejected at plan time. The chart's values.schema.json declares redis.worker.lockDuration as {\"type\": \"integer\"}, so a fractional value that slipped past this check would only fail later, during Helm schema validation at apply time."
  }
}

variable "n8n_queue_worker_lock_renew_time" {
  description = "Milliseconds between a worker's renewals of its Bull job lock. Maps to the chart's redis.worker.lockRenewTime value (QUEUE_WORKER_LOCK_RENEW_TIME on the pods); like n8n_queue_worker_lock_duration it must go through the chart value rather than config.extraEnv, because the chart's ConfigMap entry for this key renders unconditionally and a duplicate produces a container env entry carrying both value and valueFrom, which the Kubernetes API rejects. Leave null for n8n's own default (10000ms). This must stay comfortably below n8n_queue_worker_lock_duration: the worker renews on a timer, so a renew interval at or above the lock duration guarantees the lock expires before the next renewal ever fires, and every job then looks stalled to Bull's stalled-job check no matter how healthy the worker is. Lowering it increases Redis command volume proportionally to in-flight jobs, which is a real cost on a single-threaded Redis near saturation, so it is a diagnostic knob as much as a tuning one: if stalls get WORSE when you shorten it, the constraint is Redis throughput rather than missed timers on a busy worker event loop."
  type        = number
  default     = null

  validation {
    condition     = var.n8n_queue_worker_lock_renew_time == null ? true : var.n8n_queue_worker_lock_renew_time >= 1000
    error_message = "n8n_queue_worker_lock_renew_time must be at least 1000 milliseconds, or null to use n8n's own default. The chart's values.schema.json enforces a minimum of 1000 on redis.worker.lockRenewTime, so lower values are rejected during Helm schema validation."
  }

  # Compared against effective values rather than literal ones, so this single
  # check also covers a lock duration lowered to 10000ms or below while this
  # variable is left null, where the chart would keep its own 10000ms renewal
  # default. Terraform forbids two variables' validations from referencing each
  # other (it reports a cycle), so the whole invariant is hosted here instead of
  # being split across both variables.
  validation {
    condition     = coalesce(var.n8n_queue_worker_lock_renew_time, 10000) < coalesce(var.n8n_queue_worker_lock_duration, 60000)
    error_message = "The effective Bull lock renewal interval must stay strictly below the effective lock duration, otherwise the lock expires at or before the first renewal ever fires and Bull treats every job as stalled however healthy the worker is. Unset values fall back to the chart's own defaults, 10000ms for n8n_queue_worker_lock_renew_time and 60000ms for n8n_queue_worker_lock_duration, so lowering n8n_queue_worker_lock_duration to 10000ms or less requires setting n8n_queue_worker_lock_renew_time explicitly below it."
  }

  validation {
    condition     = var.n8n_queue_worker_lock_renew_time == null ? true : var.n8n_queue_worker_lock_renew_time == floor(var.n8n_queue_worker_lock_renew_time)
    error_message = "n8n_queue_worker_lock_renew_time must be a whole number of milliseconds, so this value is rejected at plan time. The chart's values.schema.json declares redis.worker.lockRenewTime as {\"type\": \"integer\"}, so a fractional value that slipped past this check would only fail later, during Helm schema validation at apply time."
  }
}

variable "n8n_queue_worker_stalled_interval" {
  description = <<-EOT
    Milliseconds between Bull's checks for stalled jobs. Maps to the chart's
    redis.worker.stalledInterval value (QUEUE_WORKER_STALLED_INTERVAL on the
    pods), not to config.extraEnv, for the same unconditional-ConfigMap-render
    reason as the two lock variables. Leave null for n8n's own default (30000ms).

    n8n itself documents 0 as "disable stall checking", but THAT IS NOT REACHABLE
    THROUGH THIS CHART and this variable cannot offer it. The chart's
    values.schema.json declares redis.worker.stalledInterval as
    `{"type": "integer", "minimum": 1000}`, so 0 is rejected during schema
    validation ("minimum: got 0, want 1,000") and a quoted "0" is rejected as the
    wrong type ("got string, want integer"). The minimum of 1000 is enforced by
    the validation below so the failure lands at plan time with this
    explanation, rather than as a Helm schema error at apply time that names a
    values path and not a reason.

    Disabling stall checking on this chart therefore requires a chart change, and
    it is worth raising upstream, because of what stall detection actually does in
    n8n v2, which is less than the name suggests. n8n hardcodes Bull's
    `maxStalledCount` to 0 (packages/cli/src/scaling/scaling.service.ts), so a job
    detected as stalled is failed PERMANENTLY rather than retried, and n8n's own
    queue recovery only marks such executions `crashed` without re-running them.
    Stall detection therefore never recovers work: it converts a stalled job into
    a failure sooner. Disabling it means a slow-but-alive worker finishes its job
    instead of having it killed, at the cost of a genuinely dead worker's job
    sitting in the active list until queue recovery notices.

    Note the related QUEUE_WORKER_MAX_STALLED_COUNT is deliberately NOT exposed
    here. The chart still sets it (redis.worker.maxStalledCount, default 1) but
    n8n v2 removed the environment variable and ships a breaking-change rule
    stating it is ignored, so exposing it would offer control that does not exist.
  EOT
  type        = number
  default     = null

  validation {
    condition     = var.n8n_queue_worker_stalled_interval == null ? true : var.n8n_queue_worker_stalled_interval >= 1000
    error_message = "n8n_queue_worker_stalled_interval must be at least 1000 milliseconds, or null to use n8n's own default. The chart's values.schema.json enforces a minimum of 1000 on redis.worker.stalledInterval, so lower values (including 0 to disable stall checking) are rejected during Helm schema validation and cannot be set through this module."
  }

  validation {
    condition     = var.n8n_queue_worker_stalled_interval == null ? true : var.n8n_queue_worker_stalled_interval == floor(var.n8n_queue_worker_stalled_interval)
    error_message = "n8n_queue_worker_stalled_interval must be a whole number of milliseconds, so this value is rejected at plan time. The chart's values.schema.json declares redis.worker.stalledInterval as {\"type\": \"integer\"}, so a fractional value that slipped past this check would only fail later, during Helm schema validation at apply time."
  }
}

variable "n8n_executions_data_save_on_success" {
  description = <<-EOT
    Whether n8n persists execution data for SUCCESSFUL executions: "all" or "none".
    Verified against n8n source (packages/@n8n/config/src/configs/executions.config.ts:149,
    `saveDataOnSuccess: 'all' | 'none' = 'all'`): there is no "first" on 2.35.7, and
    the n8n default when the variable is unset is "all".

    THE REASON THIS EXISTS AS A VARIABLE. The chart renders
    `EXECUTIONS_DATA_SAVE_ON_SUCCESS` from this values path unconditionally. If a
    caller ALSO sets the same key through `n8n_extra_env`, the main and worker
    Deployments end up with the key listed twice in one container's env list.
    That is not merely untidy, it silently breaks updates: the merge key for a
    container `env` list is `name`, so a duplicated name makes Kubernetes'
    strategic-merge-patch ambiguous, and a later change can land on one
    occurrence while leaving the other stale. Kubernetes then honours the LAST
    entry at container start, so the stale value wins and the pod runs a
    configuration nobody selected.

    Observed on a live cluster 2026-08-24: after flipping the value to "all", the
    webhook-processor (which rendered the key once) correctly reported "all",
    while main and worker (which rendered it twice) both still reported "none"
    five minutes and three rollout checks later. The Helm release's own manifest
    said "all" in both positions; only the live Deployment objects disagreed.

    Set the value HERE. `n8n_extra_env` now rejects every EXECUTIONS_DATA_SAVE_*
    key the chart renders from config.data outright at plan time (see
    local.n8n_managed_env_names), so the failure mode above can no longer be
    reproduced through this module.
  EOT
  type        = string
  default     = "all"
  nullable    = false
  validation {
    condition     = contains(["all", "none"], var.n8n_executions_data_save_on_success)
    error_message = "n8n_executions_data_save_on_success must be \"all\" or \"none\"."
  }
}

variable "n8n_executions_data_save_on_error" {
  description = <<-EOT
    Whether n8n persists execution data for FAILED executions: "all" or "none".
    Verified against n8n source (packages/@n8n/config/src/configs/executions.config.ts:145,
    `saveDataOnError: 'all' | 'none' = 'all'`): there is no "first", and the n8n
    default when the variable is unset is "all".

    Same duplicate-key hazard as `n8n_executions_data_save_on_success`: set it
    here, never through `n8n_extra_env`, which now rejects this exact name
    outright at plan time (see local.n8n_managed_env_names).
  EOT
  type        = string
  default     = "all"
  nullable    = false
  validation {
    condition     = contains(["all", "none"], var.n8n_executions_data_save_on_error)
    error_message = "n8n_executions_data_save_on_error must be \"all\" or \"none\"."
  }
}

variable "n8n_executions_data_save_on_progress" {
  description = <<-EOT
    Whether n8n saves execution data as each node executes, not just at the end
    of the run. Maps to the chart's `executions.data.saveOnProgress`
    (`EXECUTIONS_DATA_SAVE_ON_PROGRESS` on the pods). Verified against n8n
    source (packages/@n8n/config/src/configs/executions.config.ts:153,
    `saveExecutionProgress: boolean = false`): n8n's own default is false, and
    this variable defaults to the same, matching the literal it replaces, so no
    existing deployment's rendered values change. Enabling it adds a database
    write per node execution, which is a real cost at high throughput; it earns
    that cost when you need mid-run progress to survive a crash.

    Same duplicate-key hazard as `n8n_executions_data_save_on_success`: the
    chart renders this key unconditionally, so set it here, never through
    `n8n_extra_env`, which rejects this exact name outright at plan time (see
    local.n8n_managed_env_names).
  EOT
  type        = bool
  default     = false
  nullable    = false
}

variable "n8n_executions_data_save_manual_executions" {
  description = <<-EOT
    Whether n8n persists execution data for MANUAL executions (runs started
    from the editor). Maps to the chart's
    `executions.data.saveManualExecutions`
    (`EXECUTIONS_DATA_SAVE_MANUAL_EXECUTIONS` on the pods). Verified against
    n8n source (packages/@n8n/config/src/configs/executions.config.ts:157,
    `saveDataManualExecutions: boolean = true`): n8n's own default is true, and
    this variable defaults to the same, matching the literal it replaces, so no
    existing deployment's rendered values change.

    Same duplicate-key hazard as `n8n_executions_data_save_on_success`: the
    chart renders this key unconditionally, so set it here, never through
    `n8n_extra_env`, which rejects this exact name outright at plan time (see
    local.n8n_managed_env_names).
  EOT
  type        = bool
  default     = true
  nullable    = false
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
  description = "Where n8n stores the data of each new execution. Maps to N8N_EXECUTION_DATA_STORAGE_MODE. \"database\" (the default) keeps execution data in PostgreSQL, matching n8n's own default, and emits no env var. \"s3\" offloads it to the module's S3 bucket, reusing the same bucket and N8N_EXTERNAL_STORAGE_S3_* connection that binary data mode already uses, so no extra bucket, IAM policy, or credentials are needed. Execution-data writes are usually the dominant write load on the n8n database at volume, so s3 is the main lever for relieving RDS pressure. Requires n8n >= 2.27 (pin n8n_image_tag accordingly) and an Enterprise license carrying the feat:executionDataS3 entitlement, which is a different entitlement from the feat:binaryDataS3 one the always-on binary data offload uses: n8n refuses to start in s3 mode without it. There is no backfill: existing executions stay readable where they were written, and only new executions go to S3, under workflows/{workflowId}/executions/{executionId}/execution_data/bundle.json. n8n prunes those objects itself as part of the executions hard-delete path (see n8n_pruning_max_age / n8n_pruning_max_count), so do NOT add an S3 lifecycle rule that can reach execution_data/ objects (see the S3 lifecycle section in the README). Note the durability trade-off: RDS gets automated backups and point-in-time recovery (db_backup_retention_period, default 7 days) while the bucket has no versioning, no backups, and force_destroy = true, so in s3 mode a terraform destroy takes execution history with it. See the durability section in the README. \"filesystem\" is deliberately not accepted: pod filesystems are ephemeral and unshared in this module's queue-mode topology, so execution data written there would be lost on reschedule and invisible to the other pods. See <https://docs.n8n.io/deploy/host-n8n/configure-n8n/scaling/use-external-storage>."
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

  validation {
    # The subset of Kubernetes' quantity grammar that scaling.tf's capacity
    # model can read. Restricting to it is the point: an unreadable quantity
    # makes local.n8n_cpu_requests_readable false, which collapses the peak-CPU
    # figure to zero and lets check.autoscaling_maxima_fit_node_capacity pass
    # vacuously. Kubernetes would still reject the value at apply, but only
    # after a plan that claimed the maxima fit.
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?m?$", var.n8n_task_runner_cpu_request))
    error_message = "n8n_task_runner_cpu_request must be a CPU quantity: a plain number of cores (\"1\", \"0.5\") or millicores with an m suffix (\"1000m\"). Memory suffixes (Mi, Gi), units (\"1 core\"), and whitespace are not accepted."
  }
}

variable "n8n_task_runner_cpu_limit" {
  description = "CPU limit for task runner sidecar containers (e.g. 1, 2000m)"
  type        = string
  default     = "1"

  validation {
    # The subset of Kubernetes' quantity grammar that scaling.tf's capacity
    # model can read. Restricting to it is the point: an unreadable quantity
    # makes local.n8n_cpu_requests_readable false, which collapses the peak-CPU
    # figure to zero and lets check.autoscaling_maxima_fit_node_capacity pass
    # vacuously. Kubernetes would still reject the value at apply, but only
    # after a plan that claimed the maxima fit.
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?m?$", var.n8n_task_runner_cpu_limit))
    error_message = "n8n_task_runner_cpu_limit must be a CPU quantity: a plain number of cores (\"1\", \"0.5\") or millicores with an m suffix (\"1000m\"). Memory suffixes (Mi, Gi), units (\"1 core\"), and whitespace are not accepted."
  }
}

variable "n8n_task_runner_memory_request" {
  description = "Memory request for task runner sidecar containers (e.g. 512Mi, 1Gi)"
  type        = string
  default     = "512Mi"

  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?(Ki|Mi|Gi|Ti|k|M|G|T)?$", var.n8n_task_runner_memory_request))
    error_message = "n8n_task_runner_memory_request must be a memory quantity: a number with an optional Kubernetes suffix (\"512Mi\", \"2Gi\", \"1G\", or plain bytes). \"GB\"/\"MB\", whitespace, and CPU-style m suffixes are not accepted. Prefer the binary suffixes (Mi, Gi): 2G is 2,000,000,000 bytes while 2Gi is 2,147,483,648."
  }
}

variable "n8n_task_runner_memory_limit" {
  description = "Memory limit for task runner sidecar containers (e.g. 1Gi, 2Gi)"
  type        = string
  default     = "1Gi"

  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?(Ki|Mi|Gi|Ti|k|M|G|T)?$", var.n8n_task_runner_memory_limit))
    error_message = "n8n_task_runner_memory_limit must be a memory quantity: a number with an optional Kubernetes suffix (\"512Mi\", \"2Gi\", \"1G\", or plain bytes). \"GB\"/\"MB\", whitespace, and CPU-style m suffixes are not accepted. Prefer the binary suffixes (Mi, Gi): 2G is 2,000,000,000 bytes while 2Gi is 2,147,483,648."
  }
}

variable "n8n_task_runner_auto_shutdown_timeout" {
  description = "Seconds of inactivity before the runner process shuts down. Set to 0 to disable."
  type        = number
  default     = 15
}

variable "n8n_task_runner_request_timeout" {
  description = "Seconds n8n waits for a task runner to accept a Code node task. Wired to the N8N_RUNNERS_TASK_REQUEST_TIMEOUT env var on the main pod. Increase if Code nodes fail with 'task request timed out' under high concurrency (many parallel Code nodes competing for the single runner sidecar). This governs the wait for a runner to pick the task up; n8n_task_runner_timeout governs how long the task may then run."
  type        = number
  default     = 300
}

variable "n8n_task_runner_python_enabled" {
  description = "Enable the native Python runner (beta). Required for Python code execution in workflows."
  type        = bool
  default     = true
}

variable "n8n_task_runner_custom_config" {
  description = <<-EOT
    Mount a custom task-runner launcher config (`n8n-task-runners.json`) over the
    one baked into the runner image, from a ConfigMap you create separately. Wires
    the chart's `taskRunners.customConfig`; leave null to use the image default.

    The launcher config is the ONLY way to set the runner allow-lists, most
    notably `N8N_RUNNERS_STDLIB_ALLOW` for the native Python runner. The runner
    image ships that as an empty string, which refuses every stdlib import
    including `time` and `math`, so Python Code nodes that import anything fail
    with "Import of standard library module 'x' is disallowed".

    There is no env-var route to the same result, for two independent reasons:
    the allow-list names are absent from each runner's `allowed-env` list, so the
    launcher never forwards a pod-level env var to the runner process, and the
    file's own `env-overrides` block is applied regardless and would win anyway.

    The ConfigMap replaces the whole file, not one key, so derive it from the
    running image rather than writing it from scratch, and re-derive it when the
    runner image changes:

      kubectl exec deploy/<release>-worker -c task-runner -- \
        cat /etc/n8n-task-runners.json > n8n-task-runners.json
      # edit the python runner's env-overrides, then:
      kubectl create configmap n8n-task-runners-custom -n <namespace> \
        --from-file=n8n-task-runners.json

    `config_map_key` defaults to the chart's own default, `n8n-task-runners.json`.

    Editing the ConfigMap afterwards does not restart anything, and the running
    pods keep the old file until you roll them yourself. The chart mounts this
    key with `subPath`, and a subPath mount never receives later updates to its
    ConfigMap, so the file on disk does not change even after kubelet's usual
    refresh. The module cannot roll the pods for you here: it is given the
    ConfigMap's name, never its contents, so it has nothing to hash into a pod
    annotation, exactly as with `redis_auth_token_secret_ref`. Restart the
    deployments after every launcher-config change:

      kubectl rollout restart deploy/n8n-main deploy/n8n-worker -n <namespace>

    The names are literal: the module pins the Helm release name to "n8n", and
    the chart's only Deployments mounting this config are <fullname>-main and
    <fullname>-worker (the webhook processor runs no task runners).
  EOT

  type = object({
    config_map_name = string
    config_map_key  = optional(string, "n8n-task-runners.json")
  })
  default = null

  validation {
    condition     = var.n8n_task_runner_custom_config == null ? true : length(trimspace(var.n8n_task_runner_custom_config.config_map_name)) > 0
    error_message = "n8n_task_runner_custom_config.config_map_name must be a non-empty ConfigMap name. The chart mounts by name and does not create the ConfigMap, so an empty value renders a broken volume and the task-runner sidecar fails to start."
  }

  validation {
    # A ConfigMap name is a DNS-1123 subdomain, the same rule the image pull
    # secret names above are held to. Catching a malformed one here beats the
    # alternative: Helm renders a volume Kubernetes rejects, and the sidecar
    # never starts.
    condition = (
      var.n8n_task_runner_custom_config == null ? true :
      can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$", var.n8n_task_runner_custom_config.config_map_name))
      && length(var.n8n_task_runner_custom_config.config_map_name) <= 253
    )
    error_message = "n8n_task_runner_custom_config.config_map_name must be a DNS-1123 subdomain of 253 characters or fewer, which is what Kubernetes requires of a ConfigMap name: lowercase alphanumerics, hyphens and dots, starting and ending with an alphanumeric, with no empty label (e.g. \"n8n-task-runners-custom\"). Surrounding whitespace is not trimmed for you."
  }

  validation {
    # A ConfigMap key is NOT a DNS-1123 subdomain: it is case-sensitive and
    # allows underscores, so the name rule above would reject valid filenames
    # like n8n-task-runners.json only by luck and Foo_Bar.json wrongly. These
    # are Kubernetes' own key rules, including the "." and ".." carve-outs.
    # The chart passes this value straight into subPath, where an empty string
    # mounts the whole ConfigMap directory over the file and the launcher finds
    # no config at all.
    condition = (
      var.n8n_task_runner_custom_config == null ? true :
      can(regex("^[-._a-zA-Z0-9]+$", var.n8n_task_runner_custom_config.config_map_key))
      && length(var.n8n_task_runner_custom_config.config_map_key) <= 253
      && !contains([".", ".."], var.n8n_task_runner_custom_config.config_map_key)
      && !startswith(var.n8n_task_runner_custom_config.config_map_key, "..")
    )
    error_message = "n8n_task_runner_custom_config.config_map_key must be a valid ConfigMap key of 253 characters or fewer: alphanumerics, '-', '_' and '.' only, and not \".\", \"..\" or a name starting with \"..\". The chart renders this as the volume mount's subPath, so an empty or malformed key leaves the launcher without its config."
  }

  validation {
    condition     = var.n8n_task_runner_custom_config == null ? true : var.n8n_task_runners_enabled
    error_message = "n8n_task_runner_custom_config requires n8n_task_runners_enabled = true. Without task runners there is no launcher and no sidecar to mount the config into."
  }
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

variable "db_query_logging_enabled" {
  description = "Create and attach a custom RDS parameter group that logs DDL and queries slower than 1 second and enforces rds.force_ssl = 1. Defaults to false to preserve upgrade compatibility: aws_db_instance.n8n ignores engine_version drift, so an existing instance may still run an older PostgreSQL major than db_engine_version, and RDS rejects a parameter group from the wrong major family. Enable this for a new deployment, or only after confirming the live instance major matches db_engine_version. Changing the attached parameter group takes effect on reboot. Ignored when create_database = false."
  type        = bool
  default     = false
  nullable    = false
}

variable "db_multi_az" {
  description = "Deploy RDS in Multi-AZ mode for automatic failover (recommended for production)"
  type        = bool
  default     = true
}

variable "db_storage_encrypted" {
  description = "When true (the default), encrypt the RDS instance's storage, Performance Insights data, and the postgresql CloudWatch log group with a KMS key: a module-created Customer Managed KMS Key (aws_kms_key.db) unless db_kms_key_arn supplies an existing one, in which case the log group also needs db_logs_kms_key_arn before it is encrypted with that key rather than with CloudWatch's AWS-managed one. Clears Checkov findings CKV_AWS_16, CKV_AWS_354, and CKV_AWS_158. Flipping this from false to true on an existing RDS instance forces a replacement, because AWS does not support enabling storage encryption in place, so the upgrade path is snapshot then restore into a new encrypted instance. Set to false in your tfvars to preserve current behavior on pre-existing unencrypted deployments. The module-created CMK rotates annually and uses a 7-day deletion window (AWS minimum). Ignored when create_database = false."
  type        = bool
  default     = true
}

variable "create_db_kms_key" {
  description = "When true (the default), the module creates and manages its own Customer Managed KMS Key for the RDS instance's storage, Performance Insights data and postgresql log group. Set to false to encrypt with a key you already own, which db_kms_key_arn must then supply. A static boolean rather than inferring the same thing from db_kms_key_arn being null, for the reason docs/customer-managed-infrastructure.md gives: the module gates aws_kms_key.db on this, a count cannot depend on a value Terraform only learns during apply, and inferring from the ARN would mean a key created in the same configuration (aws_kms_key.mine.arn) fails the plan outright. With this boolean the ARN is free to be computed. Ignored when db_storage_encrypted = false or create_database = false, where no CMK is used at all."
  type        = bool
  default     = true
  nullable    = false

  validation {
    # Gated on create_database && db_storage_encrypted, matching the
    # description's own "ignored when" clause: a BYO-database or
    # storage-unencrypted deployment uses no CMK of any kind, module-managed
    # or otherwise, so create_db_kms_key = false is a genuine no-op there and
    # should not demand an ARN it will never read.
    condition     = (var.create_database && var.db_storage_encrypted) ? (var.create_db_kms_key || var.db_kms_key_arn != null) : true
    error_message = "create_db_kms_key = false requires db_kms_key_arn: with the module not creating a key and no key supplied, there is nothing to encrypt the RDS instance with. Either leave create_db_kms_key = true, or set db_kms_key_arn to a key you own."
  }
}

variable "db_kms_key_arn" {
  description = "ARN of an existing KMS key to use for RDS storage encryption and Performance Insights data, instead of the module provisioning its own Customer Managed Key (aws_kms_key.db). Set this together with create_db_kms_key = false, which is the input that actually stops the module minting its own key; supplying the ARN alone changes nothing and raises the db_kms_key_arn_requires_module_managed_encrypted_database check. Set both when a central security team owns all KMS keys and Terraform modules are not permitted to create new ones. Left at its null default with create_db_kms_key = true, the module creates and manages its own CMK exactly as before, so the pair is a purely additive escape hatch with no change to current behavior. Because the module gates on the boolean and never on this value, the ARN itself may be computed, e.g. a KMS key created in the same configuration. This key is deliberately NOT used for the postgresql CloudWatch log group: CloudWatch Logs rejects a key whose policy does not grant the regional service principal (logs.<region>.amazonaws.com) kms:Encrypt, kms:Decrypt, kms:ReEncrypt*, kms:GenerateDataKey* and kms:DescribeKey, no AWS provider data source exposes a key policy, so the module cannot verify yours does, and the resulting failure lands while creating the log group before the RDS instance exists. The log group therefore falls back to CloudWatch's AWS-managed encryption, and a plan-time check says so; add that statement to your key policy and set db_logs_kms_key_arn to put the log group on your key too. RDS itself needs nothing beyond the default root statement, because it reaches the key through a grant. The module describes the key while planning, which requires kms:DescribeKey (already required of anyone creating an encrypted RDS instance, alongside kms:CreateGrant), so a key that is missing, disabled, pending deletion, asymmetric or not an encryption key fails the plan instead of the apply. The key must be in the same region this module deploys into; a key in another account is fine. Must be a KMS key ARN (arn:aws:kms:<region>:<account-id>:key/<key-id>), not an alias ARN. Ignored when db_storage_encrypted = false (nothing is encrypted with a CMK) or create_database = false (no module-managed RDS instance exists to encrypt); see the db_kms_key_arn_requires_module_managed_encrypted_database check for that footgun."
  type        = string
  default     = null

  validation {
    # Commercial partition only, like every other ARN this module builds or
    # accepts. Broadening this to arn:aws-us-gov / arn:aws-cn would advertise
    # support the module does not have: the AWS managed policy ARNs in
    # modules/controllers/iam.tf and eks.tf are commercial-partition literals, so an apply in GovCloud
    # fails there regardless of what key was passed in here.
    condition     = var.db_kms_key_arn == null ? true : can(regex("^arn:aws:kms:[a-z0-9-]+:[0-9]{12}:key/[a-zA-Z0-9-]+$", var.db_kms_key_arn))
    error_message = "db_kms_key_arn must be a valid KMS key ARN of the form arn:aws:kms:<region>:<account-id>:key/<key-id>."
  }
}

variable "db_logs_kms_key_enabled" {
  description = "When true, the postgresql CloudWatch log group is encrypted with db_logs_kms_key_arn, which must then be set. Only meaningful alongside create_db_kms_key = false: on the module-managed key path the module's own CMK already carries the CloudWatch Logs statement and already encrypts the log group, so there is nothing to opt into. Defaults to false, which is what leaves the log group on CloudWatch's AWS-managed key on the bring-your-own-key path, still encrypted at rest but not with your CMK, and the db_kms_key_arn_does_not_encrypt_postgresql_logs check says so on every plan. A static boolean for the same reason as create_db_kms_key: data.aws_kms_key.db_logs_byo is gated on it, and a count cannot depend on an ARN computed during apply."
  type        = bool
  default     = false
  nullable    = false

  validation {
    condition     = !var.db_logs_kms_key_enabled || var.db_logs_kms_key_arn != null
    error_message = "db_logs_kms_key_enabled = true requires db_logs_kms_key_arn: there is no key to put the postgresql log group on otherwise."
  }

  validation {
    condition     = !var.db_logs_kms_key_enabled || !var.create_db_kms_key
    error_message = "db_logs_kms_key_enabled = true requires create_db_kms_key = false. On the module-managed key path the module's own CMK already carries the AllowCloudWatchLogsEncrypt statement and already encrypts the postgresql log group, so there is nothing this toggle could add."
  }
}

variable "db_logs_kms_key_arn" {
  description = "ARN of an existing KMS key to encrypt the postgresql CloudWatch log group with, on the bring-your-own-key path only. Setting this is your assertion that the key's policy grants logs.<region>.amazonaws.com kms:Encrypt, kms:Decrypt, kms:ReEncrypt*, kms:GenerateDataKey* and kms:DescribeKey; CloudWatch Logs rejects a key without that statement (InvalidParameterException on CreateLogGroup) and no AWS provider data source exposes a key policy, so the module cannot check on your behalf. See README.md -> \"Bring your own KMS key for RDS\" for the exact statement. Set this to the same ARN as db_kms_key_arn once that statement is in place, together with db_logs_kms_key_enabled = true, which is the input that actually opts the log group onto it; supplying the ARN alone changes nothing and raises the db_logs_kms_key_arn_requires_db_logs_kms_key_enabled check. Or point it at a different key your organization has already blessed for CloudWatch Logs. Left off (the default) while create_db_kms_key = false, the log group is encrypted with CloudWatch's AWS-managed key instead: still encrypted at rest, just not with your CMK, and the db_kms_key_arn_does_not_encrypt_postgresql_logs check states that out loud on every plan. Ignored when create_db_kms_key = true, because the module's own CMK already carries the statement and already encrypts the log group, and ignored when create_database = false or db_storage_encrypted = false for the same reasons db_kms_key_arn is. Subject to the same plan-time checks as db_kms_key_arn: same region, key usage ENCRYPT_DECRYPT, spec SYMMETRIC_DEFAULT, Enabled state, and a key ARN rather than an alias ARN."
  type        = string
  default     = null

  validation {
    # Same shape and same commercial-partition-only reasoning as
    # db_kms_key_arn above; see the comment there.
    condition     = var.db_logs_kms_key_arn == null ? true : can(regex("^arn:aws:kms:[a-z0-9-]+:[0-9]{12}:key/[a-zA-Z0-9-]+$", var.db_logs_kms_key_arn))
    error_message = "db_logs_kms_key_arn must be a valid KMS key ARN of the form arn:aws:kms:<region>:<account-id>:key/<key-id>."
  }
}

variable "db_snapshot_identifier" {
  description = "Identifier (or ARN, which is required for a snapshot shared from another account) of an RDS snapshot to restore the module-managed database from, instead of creating an empty one. This is the missing half of n8n_encryption_key: that input exists so a rebuilt stack can decrypt credentials an existing database already holds, and until this input existed the only way to reach that state was to restore outside the module and point at it with create_database = false, giving up the module's management of the subnet group, security group, CMK, log group retention, Enhanced Monitoring and Performance Insights. Restore and encryption key go together: restoring a database without also supplying the original n8n_encryption_key leaves every stored credential in it permanently unreadable. Four things behave differently on this path, all verified against the RestoreDBInstanceFromDBSnapshot API and the AWS provider rather than assumed. (1) This forces a replacement. snapshot_identifier is ForceNew, so setting it on a deployment that already has a database destroys that database and restores this snapshot in its place; it is meant for a fresh stack, not as a way to reload an existing one. (2) The master password still applies: RestoreDBInstanceFromDBSnapshot takes no password parameter, but the provider issues a ModifyDBInstance immediately after the restore, so the module's generated password becomes the restored instance's master password. (3) Encryption comes from the snapshot and cannot be changed while restoring. Both db_storage_encrypted and the KMS key must therefore describe what the snapshot already is: an encrypted snapshot needs db_storage_encrypted = true and db_kms_key_arn set to that snapshot's own key, and an unencrypted one needs db_storage_encrypted = false. Get it wrong and Terraform wants to replace the instance on every apply, because both arguments are ForceNew and neither can be satisfied in place; re-encrypt by copying the snapshot to a new key first. Plan-time checks catch all three of those combinations. (4) RDS ignores the database name when restoring a PostgreSQL snapshot, so the restored instance keeps its own, while this module hardcodes n8n_enterprise and db_name is ForceNew too. A snapshot whose database is named anything else therefore produces a permanent replacement diff, and nothing can check it: no data source exposes a snapshot's database name. Use a snapshot taken from a module-managed instance. Ignored when create_database = false, where the module manages no instance to restore into."
  type        = string
  default     = null

  validation {
    condition     = var.db_snapshot_identifier != null ? trimspace(var.db_snapshot_identifier) != "" : true
    error_message = "db_snapshot_identifier must not be blank. Leave it null to create an empty database."
  }
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
  description = "Additional CIDR blocks allowed to reach the module-managed RDS instance on port 5432, appended to the VPC CIDR (which is always allowed so nodes and pods can connect). Use this for a corporate network, VPN pool, or peered VPC rather than attaching a standalone aws_security_group_rule at the root, because a root-level rule is not tracked by the module's inline ingress block and gets stripped on the next plan. Duplicates, including a repeat of the VPC CIDR, are collapsed. Ignored when create_database = false: the module creates no RDS instance to attach a security group to, so this rule would front nothing."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.db_allowed_cidr_blocks : can(cidrnetmask(c))])
    error_message = "Each entry in db_allowed_cidr_blocks must be a valid IPv4 CIDR block (e.g. 10.20.0.0/16)."
  }
}

variable "db_allowed_security_group_ids" {
  description = "Security group IDs allowed to reach the module-managed RDS instance on port 5432, in addition to the always-allowed VPC CIDR. Preferred over db_allowed_cidr_blocks for sources inside the VPC: membership follows the instances rather than their addresses, so the rule survives subnet changes and IP reuse. Use it for a bastion, a migration runner, or an app tier that already has its own group. No rule is created when the list is empty. Ignored when create_database = false: the module creates no RDS instance to attach a security group to, so this rule would front nothing."
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
  description = "External database host. Required when create_database = false. Ignored otherwise. Use this to pass in an Amazon Aurora cluster endpoint or any external PostgreSQL host. The database name n8n connects to on this host is not configurable -- it is hardcoded to \"n8n_enterprise\" on both the create_database = true and = false paths (n8n.tf), so pointing this at a host that already runs an n8n deployment from this module shares the exact database and tables, not merely the RDS instance. This is the supported \"migrate to a new stack, keep the same RDS instance\" pattern (stop the old writer first, then cut over) confirmed live for this PR -- it is not true concurrent multi-tenant sharing of one instance across logically separate deployments, which this module does not support today."
  type        = string
  default     = null

  validation {
    condition     = var.create_database || var.db_host != null
    error_message = "db_host is required when create_database = false."
  }
}

variable "db_password" {
  description = "Password for the external database specified by db_host. Required when create_database = false, unless db_password_secret_ref supplies it instead; see that variable, which owns the combined validation to avoid a variable-validation dependency cycle between the two. Ignored otherwise (the module generates a random password for its managed RDS instance)."
  type        = string
  default     = null
  sensitive   = true
}

variable "db_password_secret_ref" {
  description = "Existing Kubernetes Secret carrying the external database password, instead of supplying the value through db_password. name is the Secret's name in var.namespace; key defaults to \"password\", matching the chart's database.passwordSecret.key default. External-database path only (create_database = false): aws_db_instance.n8n (database.tf:374) needs the password's actual value to provision the instance, and a Kubernetes Secret name cannot supply that, so setting this while create_database = true is rejected at plan time. On the external path this gates kubernetes_secret.n8n_db to zero and points the chart's database.passwordSecret at your Secret instead. Setting this alongside db_password is rejected at plan time, and so is setting neither while create_database = false, since db_password is otherwise required there; both checks live here rather than split across this variable and db_password, which would form a validation dependency cycle. The module does not verify that the named Secret exists or carries this key: a typo surfaces only as a pod stuck in CreateContainerConfigError, not as a Terraform error, because reading the Secret to check would put the password back in Terraform state, which defeats the reason this input exists."
  type = object({
    name = string
    key  = optional(string)
  })
  default = null

  validation {
    condition     = var.db_password_secret_ref == null || !var.create_database
    error_message = "db_password_secret_ref is set while create_database = true. aws_db_instance.n8n needs the database password's actual value to provision the instance, and a Kubernetes Secret name cannot supply it. Either set create_database = false, or supply the password via db_password instead."
  }

  validation {
    condition     = var.db_password_secret_ref == null || var.db_password == null
    error_message = "Both db_password and db_password_secret_ref are set. Only one may supply the database password: remove db_password to consume the referenced Secret, or remove db_password_secret_ref to keep passing the value directly."
  }

  validation {
    condition     = var.create_database || var.db_password_secret_ref != null || var.db_password != null
    error_message = "db_password or db_password_secret_ref is required when create_database = false."
  }
}

variable "db_ping_timeout_ms" {
  description = <<-EOT
    Milliseconds n8n allows for its database health-check ping before declaring the
    connection down (`DB_PING_TIMEOUT_MS`). Leave null for n8n's own default of
    5000. Neither the chart nor `n8n_extra_env` can set this: the chart has no
    values path for it and `DB_` is a module-managed prefix, so this variable is
    the only way to reach it.

    Raise this when pods return 503s under load while the database itself is idle.
    n8n's ping acquires a connection from the SAME pool that serves request
    traffic (`pool.connect()` in `db-connection-monitor.ts`, raced against this
    timeout), so a pool saturated by ordinary load makes the ping time out even
    though the database is perfectly healthy. One timed-out ping sets
    `connectionState.connected = false`, and a global middleware in
    `abstract-server.ts` then answers every request to that pod with a 503,
    creating no execution row and writing no log line at the failure site.

    Measured on a production deployment with a pool size of 5: 16 to 54 connection
    requests pending per pod, acquire times of 2 to 14 seconds, 91 of 160
    webhook-processor pods affected, roughly two thirds of all requests failing,
    with Aurora and PgBouncer both idle throughout and `cl_waiting` at zero.

    This ping calls `pool.connect()`, so it is also subject to
    db_postgresdb_connection_timeout_ms when that timeout fires first. Raising
    only this value above the connection timeout does not extend the health
    check's acquisition deadline.

    Size the pool from measured concurrent database operations and pool-wait
    time, while keeping aggregate capacity across all replicas within PgBouncer
    and database limits. Raise this timeout when the queue cannot be removed, or
    as defence in depth: it costs a slower reaction to a genuinely dead database,
    which is a far cheaper failure than silently returning 503 for live traffic.
  EOT
  type        = number
  default     = null

  validation {
    condition     = var.db_ping_timeout_ms == null ? true : var.db_ping_timeout_ms > 0
    error_message = "db_ping_timeout_ms must be greater than 0 milliseconds, or null to use n8n's own default of 5000."
  }
}

variable "db_ping_interval_seconds" {
  description = <<-EOT
    Seconds between n8n's database health-check pings
    (`DB_PING_INTERVAL_SECONDS`). Leave null for n8n's own default of 2.
    Unsettable through the chart or `n8n_extra_env`, see db_ping_timeout_ms.

    Each ping consumes a connection from the same pool that serves request
    traffic, so on a saturated pool a shorter interval adds contention to the
    resource already under pressure. Lengthening it reduces that contention at
    the cost of slower detection of a genuinely lost connection.
  EOT
  type        = number
  default     = null

  validation {
    condition     = var.db_ping_interval_seconds == null ? true : var.db_ping_interval_seconds > 0
    error_message = "db_ping_interval_seconds must be greater than 0 seconds, or null to use n8n's own default of 2."
  }
}

variable "db_ping_max_failures_before_recovery" {
  description = <<-EOT
    Consecutive failed database pings before n8n destroys and recreates the
    connection pool (`DB_PING_MAX_FAILURES_BEFORE_RECOVERY`). Leave null for n8n's
    own default of 3. Unsettable through the chart or `n8n_extra_env`, see
    db_ping_timeout_ms.

    n8n waits for the interval before each attempt and schedules the next attempt
    only after the previous one finishes. At the defaults, three failures therefore
    trigger recovery after roughly 6 seconds when each ping fails immediately, but
    after roughly 21 seconds when each ping consumes the full 5-second timeout, as
    happens when pool saturation leaves `pool.connect()` queued. The response is
    destructive: n8n tears down the pool, recreates it, and suspends connection
    acquisition while it does, so every in-flight query on that pod waits. When the
    pings are failing because the pool is saturated rather than because the database
    is unreachable, that is a feedback loop: saturation causes ping failure causes
    teardown causes every query stalling causes more saturation.

    n8n's own source acknowledges this shape. The class comment in
    `db-connection-monitor.ts` notes that a failed ping can mean "a saturated pool
    rather than a lost connection, and destroying the pool would abort every
    pending acquisition", then applies that reasoning only to sqlite and performs
    the destructive recovery on Postgres regardless. Raising this widens the margin
    before that path is taken.
  EOT
  type        = number
  default     = null

  validation {
    condition = var.db_ping_max_failures_before_recovery == null ? true : (
      var.db_ping_max_failures_before_recovery >= 1 &&
      var.db_ping_max_failures_before_recovery == floor(var.db_ping_max_failures_before_recovery)
    )
    error_message = "db_ping_max_failures_before_recovery must be a whole number of at least 1, or null to use n8n's own default of 3."
  }
}

variable "db_postgresdb_connection_timeout_ms" {
  description = <<-EOT
    Milliseconds pg-pool allows for establishing a PostgreSQL connection or
    waiting for the per-process pool to free a slot
    (`DB_POSTGRESDB_CONNECTION_TIMEOUT`). Leave null for n8n's own default of
    20000. Zero disables pg-pool's acquisition timeout. Neither the chart nor
    `n8n_extra_env` can set this: the chart has no values path for it and `DB_`
    is a module-managed prefix.

    This also applies to the database monitor's `pool.connect()` call. The
    monitor separately races that call against `DB_PING_TIMEOUT_MS`, so the two
    settings are configured separately but are not runtime-independent. The
    effective health-check acquisition deadline is whichever timeout fires
    first.

    Raising this is not a fix for pool saturation. Measured on a live
    deployment, acquire time climbed smoothly past 25 seconds over a two-hour
    run, so any fixed value is crossed eventually and only the timing moves.
    Size db_postgresdb_pool_size from measured concurrent database operations
    and pool-wait time, and verify that the aggregate maximum across all main,
    worker, and webhook replicas fits the PgBouncer and database connection
    budgets. Exposed here because the knob governing the failure should be
    settable, including downward for fail-fast behaviour.
  EOT
  type        = number
  default     = null

  validation {
    condition = var.db_postgresdb_connection_timeout_ms == null ? true : (
      var.db_postgresdb_connection_timeout_ms >= 0 &&
      var.db_postgresdb_connection_timeout_ms <= 2147483647
    )
    error_message = "db_postgresdb_connection_timeout_ms must be between 0 and 2147483647 milliseconds, or null to use n8n's own default of 20000. Zero disables the pg-pool acquisition timeout. Values above 2147483647 overflow Node.js's timer and are reduced to 1 millisecond."
  }

  validation {
    condition     = var.db_postgresdb_connection_timeout_ms == null ? true : var.db_postgresdb_connection_timeout_ms == floor(var.db_postgresdb_connection_timeout_ms)
    error_message = "db_postgresdb_connection_timeout_ms must be a whole number of milliseconds, or null to use n8n's own default of 20000."
  }
}

variable "db_postgresdb_pool_size" {
  description = "Maximum TypeORM connection pool slots per n8n process. pg-pool creates connections lazily and checks out a slot only while a database query or transaction is active, so this is not a one-to-one match for concurrent workflows or requests. Size it from measured concurrent database operations and pool-wait time. Multiply it by the maximum main, worker, and webhook replica counts to verify that aggregate capacity fits the PgBouncer and database connection budgets. A waiter is bounded by db_postgresdb_connection_timeout_ms unless that timeout is zero."
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
  description = "When true, provision Redis as a two-node aws_elasticache_replication_group (one primary, one replica) with automatic_failover_enabled and multi_az_enabled, instead of the default single-node aws_elasticache_cluster. Redis backs the Bull queue that distributes executions across workers and the multi-main leader election, so the default single node is a single point of failure: a node or AZ event stalls both until ElastiCache replaces it. Both nodes use redis_node_type, so the Redis cost roughly doubles. What this buys is that the QUEUE SURVIVES the node loss, not that n8n rides the failover out: measured on a live cluster, ElastiCache promotes the replica in about 20 seconds and every main, worker and webhook pod exits and restarts during that window (n8n's RedisClientService calls process.exit once Redis has been unreachable for QUEUE_BULL_REDIS_TIMEOUT_THRESHOLD; raising that threshold to 30s was tried and still fell short of this failover, though a larger reconnect budget can ride one out, and wiring that threshold up is the follow-up in PR #77). Recovery is automatic and takes well under a minute, and the queued executions are still there on the promoted node. Compare that with the single-node default, where a lost node means waiting for AWS to build a new one and the queue is gone with it. FLIPPING THIS ON A DEFAULT DEPLOYMENT REPLACES REDIS: the two topologies are different resource types, so no `moved` block can bridge them and Terraform destroys the cluster before creating the replication group. Every queued and in-flight execution in Redis at that moment is lost. A deployment that already has redis_transit_encryption_enabled = true is on a replication group already, so Terraform modifies that replication group in place rather than replacing it. Live testing confirmed that the provider converges this direction in stages: the first apply raises the node count through ElastiCache's IncreaseReplicaCount API and returns with automatic failover still disabled; rerun plan and apply after the group is available to enable failover. The default redis_apply_immediately = false schedules that second change for the maintenance window; set it to true for the second apply to activate failover immediately, then unset it. Drain first and see README → \"Adding high availability to an encrypted group\" for the measured sequence."
  type        = bool
  default     = false

  # null is not meaningful here: a caller writing `x = null` in a module block
  # would otherwise propagate null into the count expressions in redis.tf and
  # die with an opaque "Invalid count argument". See AGENTS.md on nullable.
  nullable = false
}

variable "redis_snapshot_retention_limit" {
  description = "Number of daily automatic ElastiCache snapshots to retain. 0 disables snapshots. Defaults to 1: this Redis backs n8n's BullMQ queue, not a source of truth, so a snapshot only shortens recovery of in-flight queued executions after a failure. Applies to both Redis topologies, the single-node cluster and the replication group selected by redis_high_availability_enabled, redis_transit_encryption_enabled, or redis_kms_encryption_enabled. Clears Checkov finding CKV_AWS_134."
  type        = number
  default     = 1
  nullable    = false

  validation {
    condition     = var.redis_snapshot_retention_limit >= 0 && var.redis_snapshot_retention_limit <= 35
    error_message = "redis_snapshot_retention_limit must be between 0 and 35 days."
  }

  validation {
    condition     = var.redis_snapshot_retention_limit == floor(var.redis_snapshot_retention_limit)
    error_message = "redis_snapshot_retention_limit must be a whole number of days."
  }
}

variable "n8n_redis_timeout_threshold" {
  description = "Milliseconds n8n will keep trying to reach Redis before it gives up and exits the process, wired to QUEUE_BULL_REDIS_TIMEOUT_THRESHOLD. Leave null (the default) to use the chart's 10000, which is n8n's own default and what every existing deployment already runs. Raise it when redis_high_availability_enabled = true and you would rather n8n rode a failover out than restarted: with the default, an ElastiCache promotion outlasts the budget and every main, worker and webhook pod exits and is restarted by Kubernetes. Pick the value deliberately, because the budget is coarser than it looks. n8n does not set ioredis's connectTimeout, so it stays at 10s, and a connect to a demoted primary hangs for that full 10s before failing. Each failed attempt therefore spends about 11.1s of this budget, making the effective values 11.1s, 33.2s and 66.4s for settings of 10s, 30s and 60s. 30000 was measured failing by 1.1 seconds against a 25 second outage; 60000 survived every case measured. 60000 is also confirmed against a real ElastiCache failover, where no container terminated and the endpoint stayed stale for 48 seconds, leaving about 20 seconds of headroom. That is one observed failover, so treat it as a good default rather than a guarantee. See README → \"Surviving a Redis failover without restarting\" for the measurements."
  type        = number
  default     = null

  # Below about 2s a single connect timeout (10s, see above) blows the entire
  # budget before ioredis has re-resolved DNS even once, so the process exits on
  # any blip rather than reconnecting. The upper bound is a typo guard: values
  # this large mean a genuinely dead Redis goes unnoticed for many minutes.
  validation {
    condition     = var.n8n_redis_timeout_threshold == null || try(var.n8n_redis_timeout_threshold >= 2000 && var.n8n_redis_timeout_threshold <= 600000, false)
    error_message = "n8n_redis_timeout_threshold must be between 2000 and 600000 milliseconds, or null to leave the chart default (10000) in place."
  }

  validation {
    condition     = var.n8n_redis_timeout_threshold == null || try(var.n8n_redis_timeout_threshold == floor(var.n8n_redis_timeout_threshold), false)
    error_message = "n8n_redis_timeout_threshold must be a whole number of milliseconds."
  }
}

variable "redis_transit_encryption_enabled" {
  description = "Whether n8n and KEDA connect to Redis over TLS. Meaning depends on create_elasticache. With create_elasticache = true (the default), this ALSO provisions a generated AUTH token on the ElastiCache the module manages: Redis sits in private subnets behind a security group that admits only VPC traffic by default (isolation by network boundary), and this input adds encryption and credential-based isolation on top of that, worth doing when queue payloads (workflow execution data) crossing the VPC in cleartext, or an unauthenticated Redis after a network-boundary breach, are risks you need closed. Independent of redis_high_availability_enabled: this buys encryption and authentication only, and leaves the cache at one node. CHANGING THIS ON AN EXISTING create_elasticache = true DEPLOYMENT REPLACES REDIS: AWS exposes the AUTH token only on aws_elasticache_replication_group, so enabling it moves a default deployment off aws_elasticache_cluster, which drops every job queued at that moment. Drain workers and pick a maintenance window. Enabling it on a deployment that is ALREADY on a replication group (redis_high_availability_enabled = true) is supported but takes three applies, not one: AWS refuses a direct plaintext-to-encrypted transition and requires the group to pass through transit_encryption_mode = preferred first, and it refuses an AUTH token until the mode is required. Setting this variable on its own therefore plans clean and then fails at apply. Drive the migration with redis_transit_encryption_mode and redis_apply_immediately instead. The full sequence was run against a live cluster with a client connection held open across every step and interrupted service at no point; see README for the three steps, their measured durations, and why the third one is not optional. Retrieve the generated token with `terraform output -raw redis_auth_token`. With create_elasticache = false, this instead declares that the external Redis at redis_host speaks TLS: the module does not verify this, so setting it against a plaintext endpoint is a connection failure, not a security hole, and leaving it false against a TLS-only endpoint fails the same way in reverse. The module does not generate a token for a Redis it does not manage; supply one via redis_auth_token if your external Redis requires AUTH. redis_transit_encryption_mode and redis_apply_immediately describe the module-managed migration lever specifically and do not apply on this path. Worker queue-depth autoscaling picks up TLS (and the AUTH token, when active) on either path via KEDA's Redis triggers."
  type        = bool
  default     = false

  # null is not meaningful here: a caller writing `x = null` in a module block
  # would otherwise propagate null into local.redis_tls_active and the other
  # boolean expressions in locals.tf that key off this variable, and die with
  # an opaque "Invalid value for operand". See AGENTS.md on nullable.
  nullable = false
}

variable "redis_kms_encryption_enabled" {
  description = "When true, encrypt Redis at rest with a module-created Customer Managed KMS Key (aws_kms_key.redis). Defaults to false, which leaves the default standalone aws_elasticache_cluster unencrypted at rest: Redis OSS at-rest encryption is available only on aws_elasticache_replication_group. Existing replication-group paths selected by HA or TLS are encrypted with the ElastiCache-managed key because redis.tf sets at_rest_encryption_enabled = true there. kms_key_id is also replication-group-only, so this is one of three variables (alongside redis_high_availability_enabled and redis_transit_encryption_enabled) that independently select the replication group. Setting this true on a default deployment replaces the standalone cache with a one-node replication group and drops queued work; drain the queue and use a maintenance window. On an existing replication group, changing kms_key_id is also ForceNew. The CMK rotates annually and uses a 7-day deletion window (AWS minimum). Ignored when create_elasticache = false."
  type        = bool
  default     = false

  # null is not meaningful here: a caller writing `x = null` in a module block
  # would otherwise propagate null into the count expressions in redis.tf and
  # die with an opaque "Invalid count argument". See AGENTS.md on nullable.
  nullable = false
}

variable "redis_transit_encryption_mode" {
  description = "Which clients the Redis replication group accepts while transit encryption is on. \"required\" (the default) accepts TLS only, and is where a deployment should end up. \"preferred\" accepts TLS AND plaintext on the same endpoint at the same time, which is the only way AWS allows transit encryption to be turned on for a replication group that already exists: it refuses a direct disabled-to-enabled transition and demands a pass through preferred first. That makes this input the migration lever rather than a tuning knob. A caller creating Redis for the first time should leave it alone; a caller adding redis_transit_encryption_enabled to a deployment already running redis_high_availability_enabled sets it to \"preferred\" for one apply and then back to \"required\", with redis_apply_immediately = true throughout. See README → \"Adding TLS to an existing replication group\" for the full sequence, including where the pods have to roll. Only written when redis_transit_encryption_enabled = true, since it describes a property of transit encryption; ignored otherwise. Sitting on \"preferred\" indefinitely is valid as far as AWS is concerned but leaves the endpoint accepting cleartext, so it defeats the point of enabling the feature."
  type        = string
  default     = "required"

  # null is not meaningful here: a caller writing `x = null` in a module block
  # should receive the documented "required" default rather than failing the
  # enum validation. See AGENTS.md on nullable.
  nullable = false

  validation {
    condition     = contains(["preferred", "required"], var.redis_transit_encryption_mode)
    error_message = "redis_transit_encryption_mode must be either \"preferred\" or \"required\". AWS spells the third state (no encryption) as transit encryption being off, which is redis_transit_encryption_enabled = false, not a mode."
  }
}

variable "redis_apply_immediately" {
  description = "Apply ElastiCache modifications as soon as the apply runs, rather than deferring them to the next maintenance window. Defaults to false, matching the AWS default and leaving every existing deployment's behaviour unchanged. Set true when changing redis_transit_encryption_mode: AWS rejects any transit-encryption modification outright without it, with `InvalidParameterValue: Transit encryption modification should be called with applied immediately option.`, so the migration cannot proceed while this is false. Turning it on makes other modifications immediate too, which for a replication group can mean a node reboot outside the window you picked, so prefer scoping it to the applies that need it rather than leaving it on."
  type        = bool
  default     = false

  # null is not meaningful here: a caller writing `x = null` in a module block
  # would otherwise propagate null into the `var.redis_apply_immediately ?
  # true : null` ternary in locals.tf, which requires a bool condition, and
  # die with an opaque "Invalid conditional condition". See AGENTS.md on
  # nullable.
  nullable = false
}

variable "create_elasticache" {
  description = "When true (the default), the module creates and manages the ElastiCache Redis that the Bull queue and multi-main leader election run on. Set to false to point n8n at a customer-managed Redis. redis_host must then be supplied, and the module creates no ElastiCache cluster, replication group, subnet group, or security group. Mirrors create_database, and is the hook the cross-region HA/DR design uses to share one replication-capable Redis between regions. Kept as a static boolean rather than `redis_host == null` because count expressions cannot depend on values computed at apply time. AUTH and TLS are both supported on this path too: see redis_auth_token, redis_auth_token_secret_ref, and redis_transit_encryption_enabled."
  type        = bool
  default     = true

  # null is not meaningful here: a caller writing `x = null` in a module block
  # would otherwise propagate null into every Redis-tier count expression and
  # die with an opaque "Invalid count argument". See AGENTS.md on nullable.
  nullable = false
}

variable "redis_host" {
  description = "Customer-managed Redis host. Required when create_elasticache = false. Ignored otherwise. Must be reachable from the EKS node subnets on redis_port; the module creates no security group on this path, so the rules that let the nodes in are the caller's to write. AUTH (redis_auth_token / redis_auth_token_secret_ref) and TLS (redis_transit_encryption_enabled) are both optional on this path, matching what the endpoint actually requires: leave both unset if it accepts unauthenticated, non-TLS connections. For a replication group the caller manages, use its primary endpoint rather than a node address, so the name follows the primary across a failover."
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

variable "redis_auth_token" {
  description = "AUTH token for an external Redis supplied via redis_host (create_elasticache = false). Optional even then: leave null if that Redis accepts unauthenticated connections, or supply the token instead through redis_auth_token_secret_ref. Ignored when create_elasticache = true: the module generates and manages its own token on the ElastiCache it provisions (see redis_transit_encryption_enabled), and cannot put a caller-supplied credential on infrastructure it owns and rotates on its own schedule. Wired to n8n and KEDA the same way the module-generated token is: as a Kubernetes Secret referenced by name (QUEUE_BULL_REDIS_PASSWORD), never inlined into the Helm release values or the KEDA ScaledObject manifest."
  type        = string
  sensitive   = true
  default     = null
}

variable "redis_auth_token_secret_ref" {
  description = "Existing Kubernetes Secret carrying the external Redis AUTH token, instead of supplying the value through redis_auth_token. name is the Secret's name in var.namespace; key defaults to \"password\", matching the chart's redis.passwordSecret.key default. External-Redis path only (create_elasticache = false): aws_elasticache_replication_group.n8n's auth_token (redis.tf:190) needs the token's actual value to provision module-managed ElastiCache, and a Kubernetes Secret name cannot supply that, so setting this while create_elasticache = true is rejected at plan time. On the external path this is optional exactly as redis_auth_token is: leave both null if that Redis accepts unauthenticated connections. Points the chart's redis.passwordSecret, and KEDA's queue-depth trigger metadata, at your Secret instead of a module-managed one. Unlike a module-generated token, the module never reads the value inside your Secret, so it cannot roll main/worker/webhook pods when that value changes the way it does for redis_pod_annotations on the module-managed path; rolling pods after you rotate the Secret's contents is your responsibility. Setting this alongside redis_auth_token is rejected at plan time. The module does not verify that the named Secret exists or carries this key."
  type = object({
    name = string
    key  = optional(string)
  })
  default = null

  validation {
    condition     = var.redis_auth_token_secret_ref == null || !var.create_elasticache
    error_message = "redis_auth_token_secret_ref is set while create_elasticache = true. aws_elasticache_replication_group.n8n needs the AUTH token's actual value to provision the module-managed replication group, and a Kubernetes Secret name cannot supply it. Either set create_elasticache = false, or supply the token via redis_auth_token instead."
  }

  validation {
    condition     = var.redis_auth_token_secret_ref == null || var.redis_auth_token == null
    error_message = "Both redis_auth_token and redis_auth_token_secret_ref are set. Only one may supply the Redis AUTH token: remove redis_auth_token to consume the referenced Secret, or remove redis_auth_token_secret_ref to keep passing the value directly."
  }
}

variable "redis_username" {
  description = "ACL username for an external Redis supplied via redis_host (create_elasticache = false). Leave null (the default) and both n8n and KEDA authenticate as Redis's default user, which is what an ElastiCache AUTH token and most self-hosted setups use. Set it when the endpoint authenticates against a named Redis 6+ ACL user, in which case redis_auth_token carries that user's password. Reaches n8n as QUEUE_BULL_REDIS_USERNAME (n8n's own config marks it \"Redis 6.0 or higher required\") and reaches the KEDA worker triggers as the redis scaler's username metadata field, so queue-depth autoscaling authenticates as the same user n8n does. Ignored when create_elasticache = true, and not merely warned about: ElastiCache AUTH has no username concept, its token authenticates as the default user, and sending a username on that path would break a connection that otherwise works. A username is not treated as a secret the way redis_auth_token is: it is a plain value in the Helm release and in the ScaledObject manifest, which is also what lets KEDA read it without resolving anything. The ACL user must be able to run the commands BullMQ uses against the bull:* keyspace, and must be able to run LLEN on bull:jobs:wait and bull:jobs:active for autoscaling to work; an ACL that authenticates but cannot read those keys leaves the HPA reporting <unknown> and the worker count frozen."
  type        = string
  default     = null

  # Blank is rejected as well as null, for the same reason redis_host rejects it:
  # an empty string satisfies "is set" and then reaches n8n and KEDA as an empty
  # username, which authenticates as nobody. Nested ternaries rather than `&&`,
  # per AGENTS.md's consistency rule for guard-style conditions: the null test
  # gates the blank test structurally (trimspace(null) is a hard error) rather
  # than relying on short-circuit evaluation.
  validation {
    condition     = var.redis_username != null ? trimspace(var.redis_username) != "" : true
    error_message = "redis_username must not be blank. Leave it null to authenticate as Redis's default user."
  }

  # Redis ACL usernames cannot contain whitespace, so any is a copy-paste
  # artifact rather than a name. Rejected rather than trimmed, so the value the
  # caller sets is the value that gets deployed.
  validation {
    condition     = var.redis_username != null ? can(regex("^[^[:space:]]+$", var.redis_username)) : true
    error_message = "redis_username must not contain whitespace: Redis ACL usernames cannot, and the module wires this value into n8n and KEDA verbatim."
  }
}

variable "redis_key_prefix" {
  description = "Prefix for every Redis key this n8n deployment uses: both n8n's own key prefix (N8N_REDIS_KEY_PREFIX, n8n's default is \"n8n\") and the Bull queue's own key prefix (QUEUE_BULL_PREFIX, n8n's default is \"bull\"), which this module sets to the same value so a single input keeps both in sync. Leave null (the default) to keep n8n's own defaults on both -- exactly today's behavior. Set this to a value unique per deployment whenever two or more n8n deployments (from this module or otherwise) point at the SAME external Redis (create_elasticache = false with redis_host shared across deployments), which the module cannot itself detect or prevent: without distinct prefixes, n8n's scaling-mode pub/sub command channel (\"<prefix>:n8n.commands\") is not scoped per deployment, and one deployment's workflow-activation broadcast is received by every other deployment sharing that Redis, each of which looks the workflow up in its own database, fails, and publishes an error back onto the same shared channel -- confirmed live, not theoretical. Each module-managed ElastiCache instance (create_elasticache = true, the default) is already dedicated to one deployment, so this has no effect worth setting there. Also updates the KEDA worker ScaledObject's listName metadata (scaling.tf) to \"<prefix>:jobs:wait\" / \"<prefix>:jobs:active\": leaving those at the literal \"bull:jobs:*\" while Bull itself writes under a different prefix would leave KEDA reading an empty list and queue-depth autoscaling permanently frozen at zero."
  type        = string
  default     = null

  validation {
    condition     = var.redis_key_prefix != null ? trimspace(var.redis_key_prefix) != "" : true
    error_message = "redis_key_prefix must not be blank. Leave it null to keep n8n's own default prefixes."
  }

  # n8n and Bull both use ":" as their own internal key-segment delimiter
  # (e.g. "<prefix>:n8n.commands", "<prefix>:jobs:wait"), so a prefix that
  # itself contains ":", whitespace, or other Redis key-pattern metacharacters
  # would produce a technically-valid but confusing key namespace. Restricted
  # to what both n8n's own default ("n8n") and Bull's ("bull") already look
  # like: alphanumerics, hyphens and underscores.
  validation {
    condition     = var.redis_key_prefix != null ? can(regex("^[A-Za-z0-9_-]+$", var.redis_key_prefix)) : true
    error_message = "redis_key_prefix must contain only letters, digits, hyphens and underscores: it becomes a literal Redis key segment (e.g. \"<prefix>:n8n.commands\", \"<prefix>:jobs:wait\"), and \":\" or whitespace in it would produce a confusing or malformed key namespace."
  }
}

# ── S3 ────────────────────────────────────────────────────────────────────────

variable "create_s3_bucket" {
  description = "When true (the default), the module creates and manages an Amazon S3 bucket for n8n binary storage (and execution data, when n8n_execution_data_storage_mode = \"s3\"). Set to false to use an existing bucket you manage yourself: existing_s3_bucket_name must then be supplied. Kept as a static boolean rather than `existing_s3_bucket_name == null` because count expressions cannot depend on values computed at apply time."
  type        = bool
  default     = true
  nullable    = false
}

variable "existing_s3_bucket_name" {
  description = "Name of an existing S3 bucket for n8n to use. Required when create_s3_bucket = false. Ignored otherwise (the module creates its own bucket, named n8n-<cluster_name>-<account_suffix>). The module attaches its IAM policy and Pod Identity role to this bucket's ARN so the n8n service account can read and write it, but creates no public-access block and no server-side encryption configuration on it: how a bucket you own is secured is your decision, not the module's. One thing you do have to tell the module, though, is s3_kms_key_arn, if this bucket is SSE-KMS encrypted with a Customer Managed Key. The pod role needs key permissions to read and write such a bucket at all, and the module cannot see the bucket's encryption configuration to infer them."
  type        = string
  default     = null

  validation {
    condition     = var.create_s3_bucket ? true : var.existing_s3_bucket_name != null
    error_message = "existing_s3_bucket_name is required when create_s3_bucket = false."
  }

  validation {
    condition     = var.existing_s3_bucket_name == null ? true : can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.existing_s3_bucket_name))
    error_message = "existing_s3_bucket_name must be a valid S3 bucket name: 3-63 characters, lowercase letters, numbers, dots, and hyphens only."
  }
}

variable "s3_kms_encryption_enabled" {
  description = "When true (the default), set the S3 bucket's default encryption to SSE-KMS with a KMS key: a module-created Customer Managed KMS Key (aws_kms_key.s3) unless s3_kms_key_arn supplies an existing one, and grant the n8n pod role kms:Decrypt / kms:GenerateDataKey / kms:DescribeKey on it. Clears Checkov finding CKV_AWS_145. This selects which key encrypts objects, not whether they are encrypted: S3 encrypts every object regardless, and setting this to false leaves new objects on SSE-S3 with S3-managed keys. S3 Bucket Keys are enabled alongside it so KMS is called per bucket rather than per object. Ignored when create_s3_bucket = false: the module creates no bucket to set a default encryption configuration on, though s3_kms_key_arn still matters there for the IAM grant. The setting applies only to objects written afterwards: existing objects keep their original encryption. Do not change true to false while any retained object uses the module-created CMK. Terraform immediately schedules that key for deletion, making those objects unreadable while the key is PendingDeletion and permanently unrecoverable after the 7-day window. See README → KMS key after terraform destroy for recovery."
  type        = bool
  default     = true
  nullable    = false
}

variable "create_s3_kms_key" {
  description = "When true (the default), the module creates and manages its own Customer Managed KMS Key for the S3 bucket it creates. Set to false to encrypt that bucket with a key you already own, which s3_kms_key_arn must then supply. A static boolean rather than inferring the same thing from s3_kms_key_arn being null, for the reason docs/customer-managed-infrastructure.md gives: aws_kms_key.s3 is gated on this, and a count cannot depend on a value Terraform only learns during apply. Ignored when s3_kms_encryption_enabled = false (the bucket uses SSE-S3 and no CMK exists) or create_s3_bucket = false (there is no module-managed bucket to encrypt, though s3_kms_key_arn still matters on that path: it is what grants the n8n pod role kms:Decrypt on your bucket's key)."
  type        = bool
  default     = true
  nullable    = false

  validation {
    # Gated on create_s3_bucket && s3_kms_encryption_enabled, matching the
    # description's own "ignored when" clause: an SSE-S3 bucket uses no CMK
    # at all, and a caller-supplied bucket has no module-managed bucket for
    # this toggle to govern, so create_s3_kms_key = false is a genuine no-op
    # on either path and should not demand an ARN it will never read here.
    condition     = (var.create_s3_bucket && var.s3_kms_encryption_enabled) ? (var.create_s3_kms_key || var.s3_kms_key_arn != null) : true
    error_message = "create_s3_kms_key = false requires s3_kms_key_arn: with the module not creating a key and no key supplied, the bucket has no CMK to encrypt with. Either leave create_s3_kms_key = true, or set s3_kms_key_arn to a key you own, or set s3_kms_encryption_enabled = false for SSE-S3."
  }
}

variable "s3_kms_key_arn" {
  description = "ARN of an existing Customer Managed KMS Key to use for S3 bucket encryption, instead of the module provisioning its own CMK (aws_kms_key.s3). Does two things, and which of them apply depends on create_s3_bucket and s3_kms_encryption_enabled. When create_s3_bucket = true and s3_kms_encryption_enabled = true (both defaults), the module encrypts the bucket it creates with this key instead of creating its own CMK, but only alongside create_s3_kms_key = false, which is the input that actually stops the module minting one; supplying the ARN alone changes nothing there and raises the s3_kms_key_arn_requires_create_s3_kms_key_false check. Set both when a central security team owns all KMS keys and Terraform modules are not permitted to create new ones. Because the module gates on the boolean and never on this value, the ARN itself may be computed, e.g. a KMS key created in the same configuration. On both the module-managed and the caller-supplied bucket path it also grants the n8n Pod Identity role kms:Decrypt, kms:GenerateDataKey and kms:DescribeKey on the key, which SSE-KMS requires of the requesting principal: without it every binary-data read and write returns AccessDenied even though the bucket policy and IAM policy both look correct. So set this whenever the bucket n8n uses is SSE-KMS encrypted, including a bucket you supplied yourself via existing_s3_bucket_name. Leave null (the default) and the module-managed bucket is encrypted with a module-created CMK (s3_kms_encryption_enabled = true) or SSE-S3 (s3_kms_encryption_enabled = false); a caller-supplied bucket with no override is assumed to need no key permissions of its own. The create_s3_kms_key toggle is irrelevant on the create_s3_bucket = false path: there is no module-managed bucket to encrypt, and this ARN is read for the IAM grant either way. Must be a KMS key ARN, not an alias ARN: an IAM policy Resource element does not accept an alias, so a grant written against one would silently match nothing."
  type        = string
  default     = null

  validation {
    # Same shape and same commercial-partition-only reasoning as db_kms_key_arn.
    condition     = var.s3_kms_key_arn == null ? true : can(regex("^arn:aws:kms:[a-z0-9-]+:[0-9]{12}:key/[a-zA-Z0-9-]+$", var.s3_kms_key_arn))
    error_message = "s3_kms_key_arn must be a valid KMS key ARN of the form arn:aws:kms:<region>:<account-id>:key/<key-id>. Alias ARNs are not accepted: IAM policy Resource elements cannot reference a KMS alias."
  }
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

  validation {
    condition     = var.n8n_main_hpa_min_replicas == floor(var.n8n_main_hpa_min_replicas) && var.n8n_main_hpa_min_replicas >= 1
    error_message = "n8n_main_hpa_min_replicas must be a whole number of replicas, 1 or greater. Kubernetes rejects an HPA whose minReplicas is below 1 (scale-to-zero needs the HPAScaleToZero feature gate, which EKS does not enable)."
  }
}

variable "n8n_main_hpa_max_replicas" {
  description = "Maximum replicas for n8n main pods. HPA will not scale above this. The default of 6 is sized to the default node group (node_max × node_instance_type): at the default CPU requests, 6 main pods plus their task runner sidecars, the worker ceiling, and the webhook ceiling all fit in what 6 t3.xlarge nodes can schedule. Raise this together with node_max or node_instance_type. An HPA ceiling the node group cannot hold leaves pods Pending with \"Insufficient cpu\" once the Cluster Autoscaler reaches node_max, which also slows rollouts. The module warns at plan time when the three groups are out of step; see README.md → \"Sizing autoscaling against node capacity\"."
  type        = number
  default     = 6
  nullable    = false

  validation {
    condition     = var.n8n_main_hpa_max_replicas == floor(var.n8n_main_hpa_max_replicas) && var.n8n_main_hpa_max_replicas >= 1
    error_message = "n8n_main_hpa_max_replicas must be a whole number of replicas, 1 or greater. Kubernetes rejects an HPA whose maxReplicas is below 1, and a fractional value is not a replica count."
  }
}

variable "n8n_main_hpa_cpu_threshold" {
  description = "Target average CPU utilization (%) that triggers scaling of n8n main pods."
  type        = number
  default     = 60

  validation {
    condition     = var.n8n_main_hpa_cpu_threshold == floor(var.n8n_main_hpa_cpu_threshold) && var.n8n_main_hpa_cpu_threshold >= 1 && var.n8n_main_hpa_cpu_threshold <= 100
    error_message = "n8n_main_hpa_cpu_threshold is a target average CPU utilization percentage, so it must be a whole number between 1 and 100. Values above 100 are accepted by Kubernetes but mean the HPA only scales once pods exceed their own CPU request, which is not what this input is for."
  }
}

# ── HPA: webhook processor pods ───────────────────────────────────────────────

variable "n8n_webhook_hpa_enabled" {
  description = "When true (the default), the module creates kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook, a CPU-based HPA for the webhook processor deployment. The n8n Helm chart skips creating its own webhook HPA whenever keda.enabled is true, which this module always sets, so this module-managed HPA is otherwise the only thing that scales webhook processors at all. Set to false to bring your own autoscaling policy (e.g. a VPA, a custom-metrics HPA, or one managed outside Terraform) for the n8n-webhook-processor Deployment instead. With this false and nothing else targeting that Deployment, it stays fixed at n8n_webhook_hpa_min_replicas: the chart renders webhookProcessor.replicaCount from that same variable unconditionally, so disabling this HPA does not leave the deployment without a replica count, only without anything that changes it."
  type        = bool
  default     = true
  nullable    = false
}

variable "n8n_webhook_hpa_min_replicas" {
  description = "Minimum replicas for n8n webhook processor pods. HPA will not scale below this. Also becomes the deployment's own replica count: the Helm chart renders spec.replicas unconditionally, so leaving it below the autoscaler floor would make every helm upgrade scale down and then wait for the autoscaler to climb back. Webhook processors take production webhook traffic, so a warm floor is what keeps a traffic ramp from queueing behind pod startup."
  type        = number
  default     = 2
  nullable    = false

  validation {
    condition     = var.n8n_webhook_hpa_min_replicas <= var.n8n_webhook_hpa_max_replicas
    error_message = "n8n_webhook_hpa_min_replicas must not exceed n8n_webhook_hpa_max_replicas; Kubernetes rejects an HPA whose minReplicas is above its maxReplicas."
  }

  validation {
    condition     = var.n8n_webhook_hpa_min_replicas == floor(var.n8n_webhook_hpa_min_replicas) && var.n8n_webhook_hpa_min_replicas >= 1
    error_message = "n8n_webhook_hpa_min_replicas must be a whole number of replicas, 1 or greater. Kubernetes rejects an HPA whose minReplicas is below 1 (scale-to-zero needs the HPAScaleToZero feature gate, which EKS does not enable)."
  }
}

variable "n8n_webhook_hpa_max_replicas" {
  description = "Maximum replicas for n8n webhook processor pods. HPA will not scale above this. The default of 8 is sized to the default node group (node_max × node_instance_type), alongside the main and worker ceilings. Webhook processors are the cheapest pod family to scale (no task runner sidecar, 300m by default), so this is usually the first ceiling to raise once node_max goes up. See n8n_main_hpa_max_replicas and README.md → \"Sizing autoscaling against node capacity\"."
  type        = number
  default     = 8
  nullable    = false

  validation {
    condition     = var.n8n_webhook_hpa_max_replicas == floor(var.n8n_webhook_hpa_max_replicas) && var.n8n_webhook_hpa_max_replicas >= 1
    error_message = "n8n_webhook_hpa_max_replicas must be a whole number of replicas, 1 or greater. Kubernetes rejects an HPA whose maxReplicas is below 1, and a fractional value is not a replica count."
  }
}

variable "n8n_webhook_hpa_cpu_threshold" {
  description = "Target average CPU utilization (%) that triggers scaling of n8n webhook pods."
  type        = number
  default     = 65

  validation {
    condition     = var.n8n_webhook_hpa_cpu_threshold == floor(var.n8n_webhook_hpa_cpu_threshold) && var.n8n_webhook_hpa_cpu_threshold >= 1 && var.n8n_webhook_hpa_cpu_threshold <= 100
    error_message = "n8n_webhook_hpa_cpu_threshold is a target average CPU utilization percentage, so it must be a whole number between 1 and 100. Values above 100 are accepted by Kubernetes but mean the HPA only scales once pods exceed their own CPU request, which is not what this input is for."
  }
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
  description = "npm registry community packages are installed from (e.g. <https://npm.internal.example.com>). Maps to N8N_COMMUNITY_PACKAGES_REGISTRY, which n8n gates behind a specific licensed feature rather than a license key alone: any value other than <https://registry.npmjs.org> makes installs throw FeatureNotLicensedError unless the instance is entitled to COMMUNITY_NODES_CUSTOM_REGISTRY (`getNpmRegistry` in community-packages.service.ts). Confirm that entitlement before setting this, since an unentitled instance breaks community-package installs instead of falling back to the public registry. Point this at a private mirror to install community nodes from an internal registry instead of the public npm one, e.g. when egress to registry.npmjs.org is blocked or packages are vendored. n8n defaults to <https://registry.npmjs.org>; when this is null (the default) the env var is omitted entirely so n8n's own default applies. A mirror that requires authentication also needs N8N_COMMUNITY_PACKAGES_AUTH_TOKEN, which this module does not manage; pass it via n8n_extra_env, keeping in mind that n8n_extra_env values are stored in plaintext in the Helm release and Terraform state. Baking packages into a custom image via n8n_image_repository avoids registry access at pod start entirely."
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
    condition     = var.n8n_custom_extensions_path == null ? true : (var.n8n_custom_extensions_path == "/" || !endswith(var.n8n_custom_extensions_path, "/"))
    error_message = "n8n_custom_extensions_path must not end in a trailing slash (e.g. \"/opt/n8n-nodes\", not \"/opt/n8n-nodes/\"). Same reason as the canonical-path rule above: the two spellings are the same directory to the container but different strings to the coverage check in n8n.tf, which compares this path against n8n_extra_volume_mounts entries literally."
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
    # `task-runner-config` appears when taskRunners.customConfig is enabled,
    # i.e. whenever n8n_task_runner_custom_config is set.
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

# n8n defaults scheduled to change
# n8n warns on every pod start that the defaults behind these four variables will
# be reduced or flipped in a future version, and asks operators to set them
# explicitly to keep the current behavior (see DeprecationService in
# packages/cli/src/deprecation/deprecation.service.ts). The warnings fire because
# nothing sets the variables, not because setting them is wrong.
#
# Only the task timeout is pinned by default here. Its change is a pure
# functional regression: nothing about a five-minute Code node task becomes
# unsafe, it simply stops working. The other three are n8n deliberately
# tightening a security posture (unverified packages, and two zip-bomb limits on
# the Compression node), so this module leaves them at whatever n8n decides and
# exposes the lever rather than freezing the weaker value on every deployment's
# behalf. Setting one of them is an operator saying "my workflows need this",
# which is a claim the module cannot make for them.

variable "n8n_task_runner_timeout" {
  description = "Seconds a Code node task may run in a task runner before n8n aborts it. Maps to N8N_RUNNERS_TASK_TIMEOUT, and applies to every pod type. Not to be confused with n8n_task_runner_request_timeout, which is how long n8n waits for a runner to *accept* a task rather than how long the task may then run. Defaults to 300, which is n8n's own current default, and the module sets it explicitly rather than omitting it: n8n has announced this default will drop to 60 in a future version, which would abort any Code node task running longer than a minute after an n8n upgrade that changed nothing else. Pinning it here means an upgrade cannot move it silently. Set it to 60 to adopt n8n's future default early, or raise it for genuinely long-running tasks."
  type        = number
  default     = 300

  validation {
    condition     = var.n8n_task_runner_timeout > 0
    error_message = "n8n_task_runner_timeout must be greater than 0 seconds."
  }
}

variable "n8n_unverified_packages_enabled" {
  description = "Allow installing community packages that n8n has not verified. Maps to N8N_UNVERIFIED_PACKAGES_ENABLED. Null (the default) omits the env var so n8n's own default applies, which is currently true but which n8n has announced will become false in a future version. Set this to true to keep installing unverified packages across that change, or to false to adopt the stricter behavior now. The module does not pin it, because unlike the task timeout this is n8n tightening a security default, and freezing the permissive value on every deployment's behalf is not a decision this module should make."
  type        = bool
  default     = null
}

variable "n8n_compression_max_decompressed_size_bytes" {
  description = "Largest decompressed payload the Compression node will produce, in bytes. Maps to N8N_COMPRESSION_NODE_MAX_DECOMPRESSED_SIZE_BYTES. Null (the default) omits the env var so n8n's own default applies, which is currently 2 GiB (2147483648) and which n8n has announced will drop to 256 MiB (268435456) in a future version. This is a zip-bomb limit, so the reduction is a hardening rather than a regression; set this only if workflows genuinely decompress archives larger than n8n's default allows, and set it to the value those workflows need rather than to the old default."
  type        = number
  default     = null

  validation {
    condition     = var.n8n_compression_max_decompressed_size_bytes == null ? true : var.n8n_compression_max_decompressed_size_bytes > 0
    error_message = "n8n_compression_max_decompressed_size_bytes must be greater than 0 bytes when set."
  }
}

variable "n8n_compression_max_zip_entries" {
  description = "Largest number of entries the Compression node will extract from one archive. Maps to N8N_COMPRESSION_NODE_MAX_ZIP_ENTRIES. Null (the default) omits the env var so n8n's own default applies, which is currently 5000 and which n8n has announced will drop to 1000 in a future version. Like n8n_compression_max_decompressed_size_bytes this is a zip-bomb limit, so the reduction hardens rather than breaks; set it only for workflows that genuinely process archives with more entries than n8n's default allows."
  type        = number
  default     = null

  validation {
    condition     = var.n8n_compression_max_zip_entries == null ? true : var.n8n_compression_max_zip_entries > 0
    error_message = "n8n_compression_max_zip_entries must be greater than 0 entries when set."
  }
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
  description = "Master switch for n8n's OpenTelemetry workflow + node tracing. When true, the module sets N8N_OTEL_ENABLED=true on all n8n containers (main, worker, webhook processor) via the Helm release's config.extraEnv block. When false (the default), no OpenTelemetry env vars are emitted and the SDK is not loaded. The OpenTelemetry collector / Jaeger receiver is out of scope for this module — deploy it separately and point n8n_otel_exporter_otlp_endpoint at it. See <https://docs.n8n.io/hosting/logging-monitoring/opentelemetry/> for the underlying n8n contract."
  type        = bool
  default     = false
}

variable "n8n_otel_exporter_otlp_endpoint" {
  description = "Base URL of the OTLP HTTP endpoint to export traces to (e.g. <http://otel-collector.observability.svc.cluster.local:4318> for an in-cluster collector). When set, maps to N8N_OTEL_EXPORTER_OTLP_ENDPOINT. n8n appends /v1/traces to this value internally, so point at the base URL, not the traces path. Leave null to use n8n's default (<http://localhost:4318>), which only works if a sidecar collector is colocated in each n8n pod (this module does not deploy one). Ignored when n8n_otel_enabled = false."
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
  description = "Comma-separated list of key=value pairs sent as HTTP headers with each OTLP request (e.g. `authorization=Bearer <token>,x-tenant=acme`). Use this for collector authentication or multi-tenant routing. Maps to N8N_OTEL_EXPORTER_OTLP_HEADERS. Leave null to send no extra headers. Marked sensitive so the value is redacted from CLI and plan output, but note it is still injected as a literal env var: it is persisted in plaintext in Terraform state and visible in the pod environment (kubectl describe / printenv). The chart's config.extraEnv does not support secretKeyRef, so restrict access to state and the n8n namespace accordingly. Ignored when n8n_otel_enabled = false."
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
  description = "Manage n8n's Enterprise log streaming destinations from environment variables instead of the UI. Maps to N8N_LOG_STREAMING_MANAGED_BY_ENV. When true, n8n applies n8n_log_streaming_destinations on every startup and locks the Log Streaming UI controls read-only. When false (the default), no log streaming env vars are emitted and destinations stay UI-managed; flipping back to false keeps the last applied destinations but restores UI write access. Requires n8n >= 2.19.0 and an Enterprise license that includes log streaming. See <https://docs.n8n.io/log-streaming/> for the underlying n8n contract."
  type        = bool
  default     = false
}

variable "n8n_log_streaming_destinations" {
  description = "List of log streaming destination objects, JSON-encoded into N8N_LOG_STREAMING_DESTINATIONS. Each entry must set type to webhook, syslog, or sentry, plus the type-specific fields documented at <https://docs.n8n.io/log-streaming/#configure-using-environment-variables> (common fields: label, enabled, subscribedEvents, anonymizeAuditMessages, circuitBreaker). Typed as any because the three destination shapes differ structurally. Marked sensitive because webhook headers and Sentry DSNs typically carry credentials — note the value is still injected as a literal env var: it is persisted in plaintext in Terraform state and visible in the pod environment (kubectl describe / printenv). Ignored when n8n_log_streaming_managed_by_env = false."
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

# ── External Secrets ──────────────────────────────────────────────────────────
# n8n's own External Secrets feature resolves *workflow credential* values from
# an external vault at runtime (Settings -> External Secrets in the n8n UI),
# keeping them out of n8n's Postgres and out from under N8N_ENCRYPTION_KEY.
# This is unrelated to the module's own secrets (DB password, Redis AUTH
# token, encryption key, task runner token, licence key): those stay
# Kubernetes Secrets, unaffected by anything below.
#
# n8n gates the feature behind the feat:externalSecrets licence entitlement
# (@BackendModule in module-registry.ts). Without that entitlement the feature
# is inert regardless of these inputs, so n8n_external_secrets_enabled is an
# explicit opt-out rather than a required guard, and Community-licensed
# deployments can leave both inputs here at their defaults.

variable "n8n_external_secrets_enabled" {
  description = "Whether n8n's own External Secrets module may load. When false, appends \"external-secrets\" to N8N_DISABLED_MODULES, which disables the feature (and its Settings UI) even under a licence that includes it. When true (the default), no env var is emitted and n8n's own default applies: the module stays enabled, but inert on Community licences without the feat:externalSecrets entitlement. This input does not create a vault connection; that remains a manual step in the n8n UI regardless of this setting."
  type        = bool
  default     = true
}

variable "n8n_external_secrets_update_interval" {
  description = "Seconds between n8n re-fetching external secret values from the connected vault, mapped to N8N_EXTERNAL_SECRETS_UPDATE_INTERVAL. Left null (the default) omits the env var so n8n's own default (300 seconds) applies. Ignored while n8n_external_secrets_enabled = false or while no vault connection exists."
  type        = number
  default     = null

  validation {
    condition     = var.n8n_external_secrets_update_interval == null ? true : var.n8n_external_secrets_update_interval > 0
    error_message = "n8n_external_secrets_update_interval must be a positive number of seconds, or null to use n8n's own default."
  }
}

# The AWS grant below is a separate, opt-in layer: it makes n8n's own AWS
# Secrets Manager provider keyless via EKS Pod Identity, so an admin connecting
# that provider in the n8n UI can pick authMethod = autoDetect instead of
# pasting static IAM user keys. It does nothing for the five other providers
# n8n supports (Vault, Infisical, Azure Key Vault, GCP Secrets Manager, 1Password):
# those take their own connection settings the same way, entirely inside n8n,
# and this module has no opinion on them.
#
# n8n's AWS provider calls secretsmanager:ListSecrets with no name, path, or tag
# filter, then reads every name it finds. IAM is therefore the only mechanism
# that limits what a vault connection using this role can read: see the
# GetSecretValue statement and the Deny in aws_iam_policy.external_secrets
# (s3.tf) for how that boundary is enforced.

variable "n8n_external_secrets_aws_enabled" {
  description = "Grants the n8n pod's existing Pod Identity role (aws_iam_role.s3) permission to read AWS Secrets Manager, so n8n's own External Secrets feature can use authMethod = autoDetect with no static AWS keys. Default false: no IAM policy, no attachment, no plan diff for an existing deployment. This only prepares the IAM plumbing; connecting the AWS Secrets Manager provider itself is a manual step in the n8n UI (Settings -> External Secrets), and ingested secrets are also governed by n8n_external_secrets_enabled and the feat:externalSecrets licence entitlement."
  type        = bool
  default     = false
  nullable    = false
}

variable "n8n_external_secrets_aws_secret_names" {
  description = "Secrets Manager secret names (not ARNs) the pod role above may read via secretsmanager:GetSecretValue, resolved with data.aws_secretsmanager_secret and used to build that policy's Resource list. Required, non-empty, when n8n_external_secrets_aws_enabled = true: since n8n's AWS provider enumerates every secret it can see with no server-side filter, an empty or wildcard allow-list would be a silent full-account grant rather than a convenience default. Wildcards (* or ?) are rejected for the same reason: a secret's ARN carries a random six-character suffix Terraform cannot predict, so a caller reaching for a name-?????? pattern to work around that is exactly the case this input exists to prevent. Ignored while n8n_external_secrets_aws_enabled = false."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = var.n8n_external_secrets_aws_enabled ? length(var.n8n_external_secrets_aws_secret_names) > 0 : true
    error_message = "n8n_external_secrets_aws_secret_names must name at least one secret when n8n_external_secrets_aws_enabled = true. n8n's AWS provider has no name, path, or tag filter of its own, so IAM is the only boundary on what it can read; an empty list here would leave that boundary wide open rather than closed."
  }

  validation {
    condition     = alltrue([for n in var.n8n_external_secrets_aws_secret_names : !can(regex("[*?]", n))])
    error_message = "n8n_external_secrets_aws_secret_names must be exact secret names, not wildcard patterns. Each name is resolved with data.aws_secretsmanager_secret and used to build the pod role's GetSecretValue statement; a wildcard cannot be resolved to a concrete ARN, and its presence usually means the actual secret ARN's random suffix is unknown, which is also unprovable to not overlap with a secret this grant must never read."
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

  validation {
    condition     = var.n8n_worker_keda_min_replicas == floor(var.n8n_worker_keda_min_replicas) && var.n8n_worker_keda_min_replicas >= 0
    error_message = "n8n_worker_keda_min_replicas must be a whole number of replicas, 0 or greater. 0 is allowed here, unlike the two HPA floors: KEDA scales a ScaledObject to zero natively."
  }
}

variable "n8n_worker_keda_max_replicas" {
  description = "Maximum worker replicas KEDA may scale to. Workers compete for the same nodes as the main and webhook pods, and each carries a task runner sidecar, so this ceiling counts against the same node group budget as the two HPA maxima. See README.md → \"Sizing autoscaling against node capacity\"."
  type        = number
  default     = 10
  nullable    = false

  validation {
    condition     = var.n8n_worker_keda_max_replicas == floor(var.n8n_worker_keda_max_replicas) && var.n8n_worker_keda_max_replicas >= 1
    error_message = "n8n_worker_keda_max_replicas must be a whole number of replicas, 1 or greater. KEDA rejects a ScaledObject whose maxReplicaCount is below 1, and a fractional value is not a replica count."
  }
}

variable "n8n_worker_keda_jobs_per_replica" {
  description = "Number of waiting jobs per worker replica used as the KEDA scaling threshold. KEDA targets ceil(queue_depth / jobs_per_replica) replicas."
  type        = number
  default     = 5

  validation {
    condition     = var.n8n_worker_keda_jobs_per_replica == floor(var.n8n_worker_keda_jobs_per_replica) && var.n8n_worker_keda_jobs_per_replica >= 1
    error_message = "n8n_worker_keda_jobs_per_replica must be a whole number of jobs, 1 or greater. KEDA divides the queue depth by this value, so 0 is not a threshold it can act on."
  }
}
