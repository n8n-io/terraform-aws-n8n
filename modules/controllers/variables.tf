# ── Cluster context ────────────────────────────────────────────────────────────
# Passed straight through from the root module's locals, so this submodule
# never has to know whether the cluster it targets was created by the root
# module (create_eks = true) or supplied via existing_eks_cluster_name.

variable "cluster_name" {
  description = "Logical name used to derive this submodule's own resource names (IAM role/policy names, tags). Root module's local.cluster_name (var.cluster_name), not necessarily the EKS cluster's own name: the two can differ when create_eks = false and existing_eks_cluster_name is a name this module does not own."
  type        = string
}

variable "eks_cluster_name" {
  description = "Name of the EKS cluster to install controllers into and associate Pod Identity roles against. Root module's local.eks_cluster_name: the module-created cluster's name, or existing_eks_cluster_name on the create_eks = false path."
  type        = string
}

variable "aws_region" {
  description = "AWS region, passed to the Cluster Autoscaler chart's awsRegion value."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID, passed to the AWS Load Balancer Controller chart's vpcId value."
  type        = string
}

variable "create_eks" {
  description = "Whether the EKS cluster named by eks_cluster_name is being created by the same apply that calls this submodule. Root module passes its own var.create_eks straight through. Decides whether the LBC/Cluster Autoscaler Pod Identity associations (iam.tf) are created unconditionally or only when install_lbc/install_cluster_autoscaler is true: see those two variables' descriptions below for why the two toggles alone are not enough to decide this safely. Defaults to true, which reproduces this submodule's original unconditional behavior, so an advanced caller invoking modules/controllers directly (see examples/customer-managed-everything) is not broken by this input's addition. Set it to false when pointing this submodule at a cluster that already existed before this apply, where that ServiceAccount may already carry a Pod Identity association."
  type        = bool
  default     = true
}

variable "iam_permissions_boundary_arn" {
  description = "ARN of an IAM policy to attach as the permissions boundary on every IAM role this submodule creates (LBC, Cluster Autoscaler, EBS CSI driver). Passed straight through from the root module's variable of the same name."
  type        = string
  default     = null
}

variable "common_tags" {
  description = "Tags applied to every resource this submodule creates. Root module's local.common_tags."
  type        = map(string)
  default     = {}
}

# ── Controller toggles ────────────────────────────────────────────────────────
# Same names, defaults and semantics as the root module's variables of the same
# name (variables.tf); the root module passes them straight through so the
# module "n8n" { ... } call-site signature is unaffected by this submodule's
# existence.

variable "install_lbc" {
  description = "When true (the default), installs the AWS Load Balancer Controller via Helm. The IAM role and policy for the aws-load-balancer-controller ServiceAccount are created regardless of this toggle, but the Pod Identity association (iam.tf) is only created when this is true OR var.create_eks is true. On a freshly created cluster (create_eks = true) there is nothing yet bound to that ServiceAccount, so creating the association even with install_lbc = false is what lets a caller whose platform team installs LBC through GitOps still get the IAM binding this module creates. On an existing cluster (create_eks = false), the opposite risk applies: that ServiceAccount may already carry a Pod Identity association, e.g. one this exact module created on a previous invocation against the same cluster, and EKS hard-rejects a second association for a ServiceAccount that already has one (409 ResourceInUseException). install_lbc = false on that path is read as \"an association already exists here, do not create a second one.\" Set this to false only when an identical install already exists in the cluster. See docs/customer-managed-infrastructure.md for the externally-managed-controller pattern."
  type        = bool
  default     = true
}

variable "install_cluster_autoscaler" {
  description = "When true (the default), installs the Kubernetes Cluster Autoscaler via Helm, and creates the IAM role and policy for its ServiceAccount. The Pod Identity association (iam.tf) follows the same create_eks-aware rule as install_lbc's association: created whenever this is true, or whenever var.create_eks is true (a freshly created cluster cannot yet have a conflicting association), and skipped only when both this and var.create_eks are false, since that combination means an existing cluster already carries this ServiceAccount's association and a second one would collide with it (409 ResourceInUseException). Set to false when an identical install already exists in the cluster, e.g. one a platform team manages through GitOps, or when the node group is meant to stay a fixed size."
  type        = bool
  default     = true
}

variable "install_metrics_server" {
  description = "When true (the default), installs metrics-server via Helm. EKS does not ship it by default, and without it every CPU-based HPA target reads \"cpu: <unknown>\" and never scales. Set to false only when an identical install already exists in the cluster, or the caller's own metrics pipeline already serves the metrics.k8s.io API."
  type        = bool
  default     = true
}

variable "install_keda" {
  description = "When true (the default), installs the KEDA operator via Helm into the keda namespace. Set to false only when an identical install already exists in the cluster."
  type        = bool
  default     = true
}

variable "create_ebs_csi" {
  description = "When true (the default), installs the aws-ebs-csi-driver addon, its IAM role/policy attachment, and a default gp3 StorageClass. Set to false when the cluster already runs its own CSI driver and default StorageClass."
  type        = bool
  default     = true
}

# ── Chart repositories and versions ───────────────────────────────────────────

variable "lbc_chart_repository" {
  description = "Helm chart repository for the AWS Load Balancer Controller chart. Ignored when install_lbc = false."
  type        = string
  default     = "https://aws.github.io/eks-charts"
}

variable "lbc_chart_version" {
  description = "AWS Load Balancer Controller Helm chart version. Ignored when install_lbc = false."
  type        = string
  default     = "3.5.0"
}

variable "cluster_autoscaler_chart_repository" {
  description = "Helm chart repository for the Cluster Autoscaler chart. Ignored when install_cluster_autoscaler = false."
  type        = string
  default     = "https://kubernetes.github.io/autoscaler"
}

variable "cluster_autoscaler_chart_version" {
  description = "Cluster Autoscaler Helm chart version. Ignored when install_cluster_autoscaler = false."
  type        = string
  default     = "9.59.0"
}

variable "metrics_server_chart_repository" {
  description = "Helm chart repository for the metrics-server chart. Ignored when install_metrics_server = false."
  type        = string
  default     = "https://kubernetes-sigs.github.io/metrics-server/"
}

variable "metrics_server_chart_version" {
  description = "metrics-server Helm chart version. Ignored when install_metrics_server = false."
  type        = string
  default     = "3.13.1"
}

variable "keda_chart_repository" {
  description = "Helm chart repository for the KEDA chart. Ignored when install_keda = false."
  type        = string
  default     = "https://kedacore.github.io/charts"
}

variable "keda_chart_version" {
  description = "KEDA Helm chart version. Ignored when install_keda = false."
  type        = string
  default     = "2.20.2"
}
