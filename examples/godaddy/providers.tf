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
    godaddy-dns = {
      source = "veksh/godaddy-dns"
      # Pinned to the 0.3.x line: veksh/godaddy-dns is a community provider on
      # a 0.x release train, so minor bumps may be breaking. Re-evaluate when
      # 1.0 ships.
      version = "~> 0.3"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Credentials are read from GODADDY_API_KEY and GODADDY_API_SECRET environment
# variables. Create an API key at https://developer.godaddy.com/keys.
provider "godaddy-dns" {
  api_key    = var.godaddy_api_key
  api_secret = var.godaddy_api_secret
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
