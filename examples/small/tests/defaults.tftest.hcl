# Plan-time tests for the small example using mocked providers.
#
# Exercises the VPC + ACM + module wiring without contacting AWS.
#
# Run: terraform test
#   (from examples/small/ — mocks require terraform >= 1.7)

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

# NOTE on test coverage:
#
# Only variable-validation tests run here today. Architecture asserts that
# would require a full `command = plan` over the example are doable via the
# same BYO-cert workaround used by examples/large/tests/defaults.tftest.hcl
# (plumb certificate_arn through, set it to a stub in tests, leave
# route53_zone_id null so the module's dns.tf for_each over
# domain_validation_options never instantiates) — tracked as a separate
# follow-up. The module itself is already exercised by tests/defaults.tftest.hcl
# at the repo root, which mocks the lower-level resources directly.

run "cluster_name_length_validation_rejects_long_names" {
  command = plan

  variables {
    cluster_name = "this-cluster-name-is-definitely-too-long"
  }

  expect_failures = [var.cluster_name]
}
