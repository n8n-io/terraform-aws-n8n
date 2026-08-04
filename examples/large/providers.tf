provider "aws" {
  region = var.aws_region
}

# The kubernetes and helm providers are configured against the EKS cluster the
# module creates. They can't be resolved until after the cluster exists — on
# the first apply, Terraform creates the cluster before any kubernetes_* or
# helm_release resource is evaluated.
#
# Authentication uses a short-lived token from the aws_eks_cluster_auth data
# source rather than the exec/"aws eks get-token" pattern, because HCP
# Terraform's hosted remote-run environment does not ship the AWS CLI. Token
# wiring works identically in local and remote runs. Note that with
# authentication_mode = "API" (the module default), an IAM identity other
# than the cluster creator — such as an HCP Terraform run role — needs its
# own EKS access entry; see var.additional_access_entries on the module.

data "aws_eks_cluster_auth" "n8n" {
  name = module.n8n.cluster_name
}

provider "kubernetes" {
  host                   = module.n8n.cluster_endpoint
  cluster_ca_certificate = base64decode(module.n8n.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.n8n.token
}

provider "helm" {
  kubernetes = {
    host                   = module.n8n.cluster_endpoint
    cluster_ca_certificate = base64decode(module.n8n.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.n8n.token
  }
}
