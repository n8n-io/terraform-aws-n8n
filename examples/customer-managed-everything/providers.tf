provider "aws" {
  region = var.aws_region
}

# The kubernetes and helm providers are configured against the stand-in cluster
# resource in main.tf directly, NOT against module.n8n's cluster_endpoint /
# cluster_certificate_authority_data outputs (which is what examples/small and
# examples/split-ingress do).
#
# The distinction matters here and nowhere else. This example invokes
# modules/controllers directly to install KEDA, and the n8n Helm release
# renders a KEDA ScaledObject unconditionally, so module.n8n must be ordered
# after module.controllers (see main.tf's depends_on, and modules/controllers/
# keda.tf for the full contract). Sourcing the provider config from module.n8n
# outputs would make every resource using these providers, module.controllers
# included, depend on module.n8n, and that depends_on would then be a genuine
# cycle. Reading the same values off aws_eks_cluster.customer_managed, a
# resource this configuration owns outright, breaks that: the providers depend
# only on the cluster, and the controllers-then-n8n ordering is free to exist.
#
# The values are identical either way. module.n8n's outputs resolve through its
# own create_eks = false path, which is a data.aws_eks_cluster read of this
# very cluster.

provider "kubernetes" {
  host                   = aws_eks_cluster.customer_managed.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.customer_managed.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.customer_managed.name, "--region", var.aws_region]
  }
}

provider "helm" {
  kubernetes = {
    host                   = aws_eks_cluster.customer_managed.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.customer_managed.certificate_authority[0].data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.customer_managed.name, "--region", var.aws_region]
    }
  }
}
