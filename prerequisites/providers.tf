terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # To move this workspace to HCP Terraform / Terraform Cloud later, uncomment
  # and fill in the block below, then run `terraform init -migrate-state`.
  # The installation workspace (terraform_single or terraform_multi) also
  # needs its data.terraform_remote_state.prerequisites block updated to
  # point at the remote workspace — see that workspace's remote_state.tf.
  #
  # backend "remote" {
  #   organization = "your-org"
  #   workspaces { name = "n8n-eks-prerequisites" }
  # }
}

provider "aws" {
  region = var.aws_region
}
