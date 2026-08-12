terraform {
  # Matches the module's own floor: this example calls module "n8n" directly
  # (main.tf), so it cannot run on a Terraform version the module itself
  # rejects. Unlike examples/customer-managed-redis and -s3, this example's
  # own tests/defaults.tftest.hcl does not use override_resource's
  # override_during: that approach was tried, for the
  # data.aws_eks_cluster.existing "known after apply" problem the header
  # comment there documents, and it did not work. Its only run blocks are
  # expect_failures ones, which need no version above the module's floor.
  required_version = ">= 1.11"

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
  }
}
