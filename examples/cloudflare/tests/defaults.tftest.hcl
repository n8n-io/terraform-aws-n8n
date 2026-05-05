# Plan-time tests for the cloudflare example using mocked providers.
#
# Run: terraform test
#   (from examples/cloudflare/ — requires terraform >= 1.9)

mock_provider "aws" {
  override_data {
    target = data.aws_availability_zones.available
    values = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }
}

mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "cloudflare" {}

variables {
  n8n_domain           = "n8n.test.example.com"
  n8n_license_key      = "test-license-key-not-real"
  cloudflare_zone_id   = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4"
  cloudflare_api_token = "test-api-token-not-real"
}

# NOTE: A full `command = plan` of the deployment graph isn't feasible here:
# the module's dns_cloudflare.tf uses `for_each` over the ACM certificate's
# `domain_validation_options`, whose keys are unknown at plan time under a
# mocked AWS provider. Variable-validation checks below run before the graph
# walk, so they work. The module itself is exercised by tests/defaults.tftest.hcl
# at the repo root.

run "cluster_name_length_validation_rejects_long_names" {
  command = plan

  variables {
    cluster_name = "this-cluster-name-is-definitely-too-long"
  }

  expect_failures = [var.cluster_name]
}
