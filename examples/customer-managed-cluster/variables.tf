variable "aws_region" {
  description = "AWS region to deploy into (e.g. us-east-1, eu-west-1, ap-southeast-1)."
  type        = string
  default     = "us-east-1"
  nullable    = false
}

variable "cluster_name" {
  description = "Name for the EKS cluster. Keep to 14 characters or fewer: the module derives an ElastiCache cluster ID of `<cluster_name>-redis`, and AWS caps ElastiCache IDs at 20 chars."
  type        = string
  default     = "n8n-cluster"
  nullable    = false

  # The lower bound is not decoration. Empty passes a bare "<= 14" check, and
  # then every identifier this example derives from it, the stand-in cluster's
  # own name and the module's ElastiCache cluster ID among them, is malformed,
  # so the failure lands mid-apply on AWS's own naming rules instead of here.
  validation {
    condition     = length(var.cluster_name) >= 1 && length(var.cluster_name) <= 14
    error_message = "cluster_name must be 1-14 characters."
  }
}

variable "n8n_domain" {
  description = "Fully-qualified domain name for n8n (e.g. n8n.example.com). The parent zone must be hosted in Route53 (pass its ID via route53_zone_id)."
  type        = string
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID for the parent of n8n_domain (e.g. the zone for example.com if n8n_domain = n8n.example.com). The module creates the ACM certificate, validation records, and alias A-record inside this zone."
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
  description = "Names of existing Kubernetes secrets of type kubernetes.io/dockerconfigjson, in the n8n namespace, that the pods authenticate to their image registry with. Leave empty (the default) unless n8n_image_repository points somewhere the node group's IAM role cannot already reach: a public registry and an ECR repository in this account both pull without credentials. Setting it hands ownership of the n8n ServiceAccount from the Helm chart to the module, which is how the secrets reach the pods at all, since the pinned chart renders imagePullSecrets nowhere. Create and rotate the secrets yourself; the module takes names, not credentials, so none of them land in Terraform state. Cross-account ECR is the exception and should not use this: its authorization tokens expire after 12 hours, so add the node group role to the source repository's policy instead."
  type        = list(string)
  default     = []
  nullable    = false

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
  description = "Image tag for the task runner sidecar (`n8nio/runners`). Leave null to inherit the n8n application image's tag, which is correct as long as that tag is a published n8n version. Set it to the underlying n8n version when running a custom image whose tag is not one (e.g. n8n_image_tag = \"2.27.4-mypackages\" together with n8n_task_runner_image_tag = \"2.27.4\"); otherwise the sidecar image cannot be pulled and every main and worker pod stays in ImagePullBackOff."
  type        = string
  default     = null

  validation {
    condition     = var.n8n_task_runner_image_tag == null ? true : can(regex("^[a-zA-Z0-9_][a-zA-Z0-9._-]{0,127}$", var.n8n_task_runner_image_tag))
    error_message = "n8n_task_runner_image_tag must be a non-empty string with no whitespace, containing only alphanumeric characters, dots, underscores, and hyphens (e.g. \"2.27.4\"). Set to null to inherit the n8n application image's tag."
  }
}

variable "n8n_custom_extensions_path" {
  description = "Absolute path inside the n8n container that n8n scans for custom nodes at startup (e.g. \"/opt/n8n-nodes\"). Maps to N8N_CUSTOM_EXTENSIONS, and is set on main, worker and webhook processor pods alike. Set this alongside n8n_image_repository when the custom image bakes community packages in: since n8n 1.0 the loader no longer reads the image's global node_modules, so a plain npm install into the image is never scanned and the packages ship but never load. Nodes found here register under the package name CUSTOM, so a node installed from npm as n8n-nodes-example.myNode becomes CUSTOM.myNode and existing workflows referencing the npm-qualified type will not resolve. Leave null (the default) to omit the env var."
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
    condition     = var.n8n_custom_extensions_path == null ? true : (var.n8n_custom_extensions_path == "/" || !endswith(var.n8n_custom_extensions_path, "/"))
    error_message = "n8n_custom_extensions_path must not end in a trailing slash (e.g. \"/opt/n8n-nodes\", not \"/opt/n8n-nodes/\"). Same reason as the canonical-path rule above: the two spellings are the same directory to the container but different strings to the coverage check in n8n.tf, which compares this path against n8n_extra_volume_mounts entries literally."
  }

  validation {
    condition = var.n8n_custom_extensions_path == null ? true : !(
      var.n8n_custom_extensions_path == "/home/node/.n8n" ||
      startswith(var.n8n_custom_extensions_path, "/home/node/.n8n/")
    )
    error_message = "n8n_custom_extensions_path must not be inside /home/node/.n8n. The chart mounts an emptyDir there on main pods, which hides whatever the image baked in, so the nodes would load on workers and webhook processors but not on mains. Use a path outside it, for example /opt/n8n-nodes."
  }
}

variable "n8n_additional_domains" {
  description = "Extra hostnames n8n should answer on, beyond n8n_domain. Each is added to the module-issued ACM certificate as a subject alternative name, given a Route 53 validation record and alias A-record, and routed by the module's Ingress. Leave empty for a single hostname."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "n8n_execution_data_storage_mode" {
  description = "Where n8n stores the data of each new execution. Passed to the module's n8n_execution_data_storage_mode. \"database\" keeps execution data in PostgreSQL; \"s3\" offloads it to the S3 bucket the module already creates for binary data. Requires n8n >= 2.27 (pin n8n_image_tag accordingly) and an Enterprise license carrying the feat:executionDataS3 entitlement, which is not the same one binary data offload uses. There is no backfill: existing executions stay readable where they were written."
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
  nullable    = false
}

# ── Customer-managed EKS cluster stand-in ────────────────────────────────────
# These describe the aws_eks_cluster and aws_eks_node_group this example
# creates to play the part of a platform team's already-existing cluster. In
# a real deployment these variables, and the resources they size, would not
# exist here at all: the cluster would already be running, owned by whatever
# created it, and you would only need its name to fill in the module's
# existing_eks_cluster_name input directly. See "Adapting to your real
# infrastructure" in this example's README.

variable "kubernetes_version" {
  description = "Kubernetes version for the stand-in cluster this example creates, and the value passed to the module's own kubernetes_version input (which the module uses only to warn if it does not match the existing cluster's actual version on the create_eks = false path). Matches the module's own default so the two agree with no extra configuration."
  type        = string
  default     = "1.35"
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+$", var.kubernetes_version))
    error_message = "kubernetes_version must be a MAJOR.MINOR version string (e.g. \"1.35\")."
  }
}

variable "customer_managed_node_instance_type" {
  description = "EC2 instance type for the stand-in cluster's node group. Matches the module's own node_instance_type default (t3.xlarge), not a cheaper demo size: the module's own variable description warns that a full multi-main n8n workload (main x2, worker x2, webhook x2 pods at minimum replicas) needs at least this much headroom for HPA to have room to scale. A real customer-managed cluster would be sized for its own broader workload, which may already be larger than this."
  type        = string
  default     = "t3.xlarge"
  nullable    = false

  # Mirrors the module's own node_instance_type validation. These four inputs
  # feed aws_eks_node_group.customer_managed directly rather than going through
  # module "n8n", so nothing else in this configuration checks them: without
  # these, a typo or an out-of-bounds desired/min/max combination is only
  # rejected by AWS, on the first apply, after the cluster is already up.
  validation {
    condition     = can(regex("^[a-z][a-z0-9]*(-[a-z0-9]+)*\\.[a-z0-9]+(-[a-z0-9]+)*$", var.customer_managed_node_instance_type))
    error_message = "customer_managed_node_instance_type must be a valid EC2 instance type (e.g. t3.xlarge, m5.large)."
  }
}

variable "customer_managed_node_desired" {
  description = "Initial number of worker nodes in the stand-in node group. Matches examples/small's implicit sizing (the module's own node_desired default). Only applies at creation: the node group's desired_size ignores changes afterward so the Cluster Autoscaler this example installs can own it without fighting plans/applies."
  type        = number
  default     = 3
  nullable    = false

  validation {
    condition     = var.customer_managed_node_desired == floor(var.customer_managed_node_desired) && var.customer_managed_node_desired >= var.customer_managed_node_min && var.customer_managed_node_desired <= var.customer_managed_node_max
    error_message = "customer_managed_node_desired must be a whole number of nodes within [customer_managed_node_min, customer_managed_node_max]. AWS rejects a managed node group whose desiredSize sits outside its own scaling bounds, and because desired_size only applies at creation, getting it wrong fails the first apply rather than a later one."
  }
}

variable "customer_managed_node_min" {
  description = "Minimum number of worker nodes in the stand-in node group. Matches examples/small's implicit sizing (the module's own node_min default)."
  type        = number
  default     = 3
  nullable    = false

  validation {
    condition     = var.customer_managed_node_min == floor(var.customer_managed_node_min) && var.customer_managed_node_min >= 1
    error_message = "customer_managed_node_min must be a whole number of nodes, 1 or greater."
  }
}

variable "customer_managed_node_max" {
  description = "Maximum number of worker nodes the Cluster Autoscaler can scale the stand-in node group to. Matches examples/small's implicit sizing (the module's own node_max default)."
  type        = number
  default     = 6
  nullable    = false

  validation {
    condition     = var.customer_managed_node_max == floor(var.customer_managed_node_max) && var.customer_managed_node_max >= var.customer_managed_node_min
    error_message = "customer_managed_node_max must be a whole number of nodes, and at least customer_managed_node_min."
  }
}
