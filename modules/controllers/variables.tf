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
  description = "When true (the default), installs the AWS Load Balancer Controller via Helm. The IAM role, policy and Pod Identity association for the aws-load-balancer-controller ServiceAccount are created regardless of this toggle: an unattached Pod Identity association is inert, not a live attack surface, and leaving it in place is what lets a caller whose platform team installs LBC through GitOps still get the IAM binding this module creates, without a second Helm release racing the first one for the same ServiceAccount. Set this to false only when an identical install already exists in the cluster. See docs/customer-managed-infrastructure.md for the externally-managed-controller pattern."
  type        = bool
  default     = true
}

variable "install_cluster_autoscaler" {
  description = "When true (the default), installs the Kubernetes Cluster Autoscaler via Helm, and creates the IAM role, policy and Pod Identity association for its ServiceAccount. Set to false when an identical install already exists in the cluster, e.g. one a platform team manages through GitOps, or when the node group is meant to stay a fixed size."
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
