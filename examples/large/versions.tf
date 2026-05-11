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
    # random is declared at the example level (not just inherited from the
    # module) because aurora.tf uses random_password.aurora directly to
    # generate the Aurora master password before passing it to the module
    # via var.db_password.
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}
