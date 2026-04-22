terraform {
  required_version = ">= 1.7"

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
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }

  # To move this workspace to HCP Terraform / Terraform Cloud later, uncomment
  # and fill in the block below, then run `terraform init -migrate-state`.
  # Also swap remote_state.tf's data source to `backend = "remote"`.
  #
  # backend "remote" {
  #   organization = "your-org"
  #   workspaces { name = "n8n-eks-multi" }
  # }
}

provider "aws" {
  region = local.aws_region
}

provider "kubernetes" {
  host                   = aws_eks_cluster.n8n.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.n8n.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.n8n.name, "--region", local.aws_region]
  }
}

provider "helm" {
  kubernetes {
    host                   = aws_eks_cluster.n8n.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.n8n.certificate_authority[0].data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.n8n.name, "--region", local.aws_region]
    }
  }
}
