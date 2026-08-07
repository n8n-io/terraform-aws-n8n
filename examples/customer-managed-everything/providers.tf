provider "aws" {
  region = var.aws_region
}

# The kubernetes and helm providers are configured against the stand-in
# cluster this example creates (main.tf), not one module.n8n creates: unlike
# examples/small, create_eks = false here, so module.n8n.cluster_endpoint /
# cluster_certificate_authority_data resolve through the module's
# create_eks = false path (a data.aws_eks_cluster.existing read of the
# stand-in cluster below) rather than a resource it manages itself. Either
# way the outputs are the right thing to configure these providers against.

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
