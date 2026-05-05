# Plan-time tests for the complete example using mocked providers.
#
# Exercises the VPC + ACM + module wiring without contacting AWS.
#
# Run: terraform test
#   (from examples/complete/ — mocks require terraform >= 1.7)

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

variables {
  n8n_domain      = "n8n.test.example.com"
  n8n_license_key = "test-license-key-not-real"
  route53_zone_id = "Z00000000000000000000"
}

# NOTE: A `command = plan` smoke test of the full example currently isn't
# feasible: the module's dns.tf uses `for_each` over the ACM certificate's
# `domain_validation_options`, whose keys are unknown at plan time under a
# mocked AWS provider (the real provider returns them, but mocks don't).
# Variable-validation checks below run before the graph walk, so they work.
# The module itself is exercised via tests/defaults.tftest.hcl at the repo
# root, which mocks the lower-level resources directly.

run "cluster_name_length_validation_rejects_long_names" {
  command = plan

  variables {
    cluster_name = "this-cluster-name-is-definitely-too-long"
  }

  expect_failures = [var.cluster_name]
}
