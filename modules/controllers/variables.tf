# ── Cluster context ────────────────────────────────────────────────────────────
# Passed straight through from the root module's locals, so this submodule
# never has to know whether the cluster it targets was created by the root
# module (create_eks = true) or supplied via existing_eks_cluster_name.
#
# Every input below that has a non-null default is also `nullable = false`.
# This submodule is documented as directly invocable (see
# examples/customer-managed-everything), which makes its variable block a
# public contract rather than an internal detail: without that, a caller
# wiring an optional value through with `foo = var.maybe_null` gets a null
# where the default is documented, and a null reaches a `count` expression or
# a Helm value instead of the documented default. The intentionally-optional
# inputs (iam_permissions_boundary_arn) keep their null default and stay
# nullable, because null is a meaningful value there.
#
# The validations mirror the root module's own for the same domains. A direct
# caller gets the same plan-time rejection of a malformed region, VPC ID,
# boundary ARN, chart repository or chart version that a caller going through
# the root module already gets, rather than an opaque AWS or Helm failure
# partway through apply.

variable "cluster_name" {
  description = "Logical name used to derive this submodule's own resource names (IAM role/policy names, tags). Root module's local.cluster_name (var.cluster_name), not necessarily the EKS cluster's own name: the two can differ when create_eks = false and existing_eks_cluster_name is a name this module does not own."
  type        = string
  nullable    = false

  # Matches the root module's own cap and adds only a non-empty floor. Not
  # stricter than the root's on anything else, deliberately: a value that
  # plans through module "n8n" must not fail here instead.
  validation {
    condition     = length(var.cluster_name) >= 1 && length(var.cluster_name) <= 14
    error_message = "cluster_name must be 1-14 characters (the root module's own cap, so the ElastiCache cluster ID <cluster_name>-redis stays <= 20 chars)."
  }
}

variable "eks_cluster_name" {
  description = "Name of the EKS cluster to install controllers into and associate Pod Identity roles against. Root module's local.eks_cluster_name: the module-created cluster's name, or existing_eks_cluster_name on the create_eks = false path. Also the name the Cluster Autoscaler auto-discovers node group ASGs by, so its IAM condition key is built from this input rather than cluster_name (iam.tf)."
  type        = string
  nullable    = false

  validation {
    condition     = length(var.eks_cluster_name) >= 1 && length(var.eks_cluster_name) <= 100 && can(regex("^[A-Za-z0-9][A-Za-z0-9_-]*$", var.eks_cluster_name))
    error_message = "eks_cluster_name must be 1-100 characters, start with a letter or digit, and contain only letters, digits, hyphens and underscores, which is EKS's own constraint on a cluster name."
  }
}

variable "aws_region" {
  description = "AWS region, passed to the Cluster Autoscaler chart's awsRegion value."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.aws_region))
    error_message = "aws_region must be a valid AWS region (e.g. us-east-1, eu-west-1)."
  }
}

variable "vpc_id" {
  description = "VPC ID, passed to the AWS Load Balancer Controller chart's vpcId value."
  type        = string
  nullable    = false

  # Deliberately the same permissive shape as the root module's own vpc_id
  # validation, not a stricter hex-and-length rule: this submodule's contract
  # should reject exactly what the root rejects and no more, so a value that
  # plans through module "n8n" cannot fail here instead.
  validation {
    condition     = can(regex("^vpc-[a-zA-Z0-9]+$", var.vpc_id))
    error_message = "vpc_id must be a valid VPC ID (e.g. vpc-0123456789abcdef0). The Load Balancer Controller rejects anything else at startup, long after apply has finished."
  }
}

variable "create_eks" {
  description = "Whether the EKS cluster named by eks_cluster_name is being created by the same apply that calls this submodule. Root module passes its own var.create_eks straight through. Decides whether the LBC/Cluster Autoscaler IAM roles, policies and Pod Identity associations (iam.tf) are created unconditionally or only when install_lbc/install_cluster_autoscaler is true: see those two variables' descriptions below for why the two toggles alone are not enough to decide this safely. Defaults to true, which reproduces this submodule's original unconditional behavior, so an advanced caller invoking modules/controllers directly (see examples/customer-managed-everything) is not broken by this input's addition. Set it to false when pointing this submodule at a cluster that already existed before this apply, where that ServiceAccount may already carry a Pod Identity association."
  type        = bool
  default     = true
  nullable    = false
}

variable "iam_permissions_boundary_arn" {
  description = "ARN of an IAM policy to attach as the permissions boundary on every IAM role this submodule creates (LBC, Cluster Autoscaler, EBS CSI driver). Passed straight through from the root module's variable of the same name. Null (the default) attaches no boundary."
  type        = string
  default     = null

  validation {
    condition     = var.iam_permissions_boundary_arn == null ? true : can(regex("^arn:aws:iam::([0-9]{12}|aws):policy/.+$", var.iam_permissions_boundary_arn))
    error_message = "iam_permissions_boundary_arn must be a valid IAM policy ARN (e.g. arn:aws:iam::123456789012:policy/ExamplePermissionsBoundary, or arn:aws:iam::aws:policy/PowerUserAccess for an AWS managed policy), or null for no boundary."
  }
}

variable "common_tags" {
  description = "Tags applied to every resource this submodule creates. Root module's local.common_tags."
  type        = map(string)
  default     = {}
  nullable    = false
}

# ── Controller toggles ────────────────────────────────────────────────────────
# Same names, defaults and semantics as the root module's variables of the same
# name (variables.tf); the root module passes them straight through so the
# module "n8n" { ... } call-site signature is unaffected by this submodule's
# existence.

variable "install_lbc" {
  description = "When true (the default), installs the AWS Load Balancer Controller via Helm. The IAM role, policy and Pod Identity association for the aws-load-balancer-controller ServiceAccount (iam.tf) are created when this is true OR var.create_eks is true. On a freshly created cluster (create_eks = true) there is nothing yet bound to that ServiceAccount, so creating them even with install_lbc = false is what lets a caller whose platform team installs LBC through GitOps still get the IAM binding this module creates. On an existing cluster (create_eks = false), the opposite risk applies: that ServiceAccount may already carry a Pod Identity association, e.g. one this exact module created on a previous invocation against the same cluster, and EKS hard-rejects a second association for a ServiceAccount that already has one (409 ResourceInUseException). install_lbc = false on that path is read as \"an association already exists here, do not create a second one\", and the role and policy are skipped with it, since nothing would be able to assume a role with no association. Set this to false only when an identical install already exists in the cluster. See docs/customer-managed-infrastructure.md for the externally-managed-controller pattern."
  type        = bool
  default     = true
  nullable    = false
}

variable "install_cluster_autoscaler" {
  description = "When true (the default), installs the Kubernetes Cluster Autoscaler via Helm. Its IAM role, policy and Pod Identity association (iam.tf) follow the same create_eks-aware rule as install_lbc's: created whenever this is true, or whenever var.create_eks is true (a freshly created cluster cannot yet have a conflicting association), and skipped only when both this and var.create_eks are false, since that combination means an existing cluster already carries this ServiceAccount's association and a second one would collide with it (409 ResourceInUseException). Set to false when an identical install already exists in the cluster, e.g. one a platform team manages through GitOps, or when the node group is meant to stay a fixed size."
  type        = bool
  default     = true
  nullable    = false
}

variable "install_metrics_server" {
  description = "When true (the default), installs metrics-server via Helm. EKS does not ship it by default, and without it every CPU-based HPA target reads \"cpu: <unknown>\" and never scales. Set to false only when an identical install already exists in the cluster, or the caller's own metrics pipeline already serves the metrics.k8s.io API."
  type        = bool
  default     = true
  nullable    = false
}

variable "install_keda" {
  description = "When true (the default), installs the KEDA operator via Helm into the keda namespace. Set to false only when an identical install already exists in the cluster. A caller invoking this submodule directly to install KEDA for an n8n deployment must also order that deployment after this module (depends_on = [module.controllers]); see this submodule's keda.tf for why."
  type        = bool
  default     = true
  nullable    = false
}

variable "create_ebs_csi" {
  description = "When true (the default), installs the aws-ebs-csi-driver addon, its IAM role/policy attachment, and a default gp3 StorageClass. Set to false when the cluster already runs its own CSI driver and default StorageClass."
  type        = bool
  default     = true
  nullable    = false
}

# ── Chart repositories and versions ───────────────────────────────────────────
# Repository values accept https:// and oci:// because Helm resolves both, and
# an internal mirror is the common reason to override these at all. Version
# values are exact SemVer, matching the root module's own validation: Helm
# resolves the version literally here, so a range or a floating tag silently
# resolves to nothing rather than to "latest".

variable "lbc_chart_repository" {
  description = "Helm chart repository for the AWS Load Balancer Controller chart. Ignored when install_lbc = false."
  type        = string
  default     = "https://aws.github.io/eks-charts"
  nullable    = false

  validation {
    condition     = can(regex("^(https?|oci)://", var.lbc_chart_repository))
    error_message = "lbc_chart_repository must be an https:// or oci:// URL."
  }
}

variable "lbc_chart_version" {
  description = "AWS Load Balancer Controller Helm chart version. Ignored when install_lbc = false."
  type        = string
  default     = "3.5.0"
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?(\\+[0-9A-Za-z.-]+)?$", var.lbc_chart_version))
    error_message = "lbc_chart_version must be an exact SemVer 2 version such as \"3.5.0\". Helm resolves chart versions literally here, so a range (\">= 3.5\", \"~3.5.0\"), a leading \"v\", or a floating tag is not accepted."
  }
}

variable "cluster_autoscaler_chart_repository" {
  description = "Helm chart repository for the Cluster Autoscaler chart. Ignored when install_cluster_autoscaler = false."
  type        = string
  default     = "https://kubernetes.github.io/autoscaler"
  nullable    = false

  validation {
    condition     = can(regex("^(https?|oci)://", var.cluster_autoscaler_chart_repository))
    error_message = "cluster_autoscaler_chart_repository must be an https:// or oci:// URL."
  }
}

variable "cluster_autoscaler_chart_version" {
  description = "Cluster Autoscaler Helm chart version. Ignored when install_cluster_autoscaler = false."
  type        = string
  default     = "9.59.0"
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?(\\+[0-9A-Za-z.-]+)?$", var.cluster_autoscaler_chart_version))
    error_message = "cluster_autoscaler_chart_version must be an exact SemVer 2 version such as \"9.59.0\"."
  }
}

variable "metrics_server_chart_repository" {
  description = "Helm chart repository for the metrics-server chart. Ignored when install_metrics_server = false."
  type        = string
  default     = "https://kubernetes-sigs.github.io/metrics-server/"
  nullable    = false

  validation {
    condition     = can(regex("^(https?|oci)://", var.metrics_server_chart_repository))
    error_message = "metrics_server_chart_repository must be an https:// or oci:// URL."
  }
}

variable "metrics_server_chart_version" {
  description = "metrics-server Helm chart version. Ignored when install_metrics_server = false."
  type        = string
  default     = "3.13.1"
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?(\\+[0-9A-Za-z.-]+)?$", var.metrics_server_chart_version))
    error_message = "metrics_server_chart_version must be an exact SemVer 2 version such as \"3.13.1\"."
  }
}

variable "keda_chart_repository" {
  description = "Helm chart repository for the KEDA chart. Ignored when install_keda = false."
  type        = string
  default     = "https://kedacore.github.io/charts"
  nullable    = false

  validation {
    condition     = can(regex("^(https?|oci)://", var.keda_chart_repository))
    error_message = "keda_chart_repository must be an https:// or oci:// URL."
  }
}

variable "keda_chart_version" {
  description = "KEDA Helm chart version. Ignored when install_keda = false."
  type        = string
  default     = "2.20.2"
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?(\\+[0-9A-Za-z.-]+)?$", var.keda_chart_version))
    error_message = "keda_chart_version must be an exact SemVer 2 version such as \"2.20.2\"."
  }
}
