terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    cloudflare = {
      source = "cloudflare/cloudflare"
      # 4.52.7 introduced a credential-sensitivity change that breaks api_token
      # when the value comes from a sensitive Terraform variable. Pin below that.
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
