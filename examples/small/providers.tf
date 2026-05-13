provider "aws" {
  region = var.aws_region
}

# The kubernetes and helm providers are configured against the EKS cluster the
# module creates. They can't be resolved until after the cluster exists — on
# the first apply, Terraform creates the cluster before any kubernetes_* or
# helm_release resource is evaluated.

provider "kubernetes" {
  host                   = module.n8n.cluster_endpoint
  cluster_ca_certificate = base64decode(module.n8n.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.n8n.cluster_name, "--region", var.aws_region]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.n8n.cluster_endpoint
    cluster_ca_certificate = base64decode(module.n8n.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.n8n.cluster_name, "--region", var.aws_region]
    }
  }
}
