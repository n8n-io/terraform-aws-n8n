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
    # Declared so `mock_provider "cloudflare"` in tests/ can resolve the correct
    # source. This example uses Route53 only — no provider block is configured.
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = ">= 4.0.0, < 4.52.7"
    }
  }
}
