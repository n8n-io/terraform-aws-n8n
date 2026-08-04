terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    cloudflare = {
      source = "cloudflare/cloudflare"
      # 4.52.7 introduced a credential-sensitivity change that breaks api_token
      # when the value comes from a sensitive Terraform variable. Pin below that.
      # TODO: drop the upper bound once the upstream regression is fixed and
      # bump to ~> 5.0 when the v5 provider stabilizes.
      version = ">= 4.0.0, < 4.52.7"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Authenticate with an API token scoped to Zone:DNS:Edit for your zone.
# Pass it via the CLOUDFLARE_API_TOKEN environment variable or the
# cloudflare_api_token variable below.
provider "cloudflare" {
  api_token = var.cloudflare_api_token
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
