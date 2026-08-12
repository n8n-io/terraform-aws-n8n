terraform {
  # Matches the module's own floor. Worth knowing that this example cannot go
  # below it even if the module ever did: its test suite
  # (tests/defaults.tftest.hcl) uses override_resource's override_during
  # attribute, which Terraform only gained in 1.11 and silently ignores
  # before it, turning the documented `terraform test` command into a
  # confusing assertion failure rather than a clear version error.
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
