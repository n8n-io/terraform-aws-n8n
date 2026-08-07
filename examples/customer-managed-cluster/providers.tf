provider "aws" {
  region = var.aws_region
}

# The kubernetes and helm providers are configured against the EKS cluster the
# module deploys onto. On the create_eks = false path that is the stand-in
# cluster above, resolved through module.n8n.cluster_endpoint /
# cluster_certificate_authority_data exactly the same way it would be for a
# module-created cluster: those outputs read through local.eks_cluster_endpoint
# / local.eks_cluster_ca_data, which are not gated on create_eks.

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
  kubernetes = {
    host                   = module.n8n.cluster_endpoint
    cluster_ca_certificate = base64decode(module.n8n.cluster_certificate_authority_data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.n8n.cluster_name, "--region", var.aws_region]
    }
  }
}
