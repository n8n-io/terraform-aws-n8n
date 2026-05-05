# Plan-time tests for the godaddy example using mocked providers.
#
# Run: terraform test
#   (from examples/godaddy/ — requires terraform >= 1.9)

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
# mock_provider does not support hyphenated provider names (godaddy-dns). Set
# GODADDY_API_KEY and GODADDY_API_SECRET to any non-empty value before running
# terraform test locally — no real API calls are made in plan-time tests.

variables {
  n8n_domain         = "n8n.test.example.com"
  n8n_license_key    = "test-license-key-not-real"
  godaddy_domain     = "test.example.com"
  godaddy_api_key    = "test-api-key-not-real"
  godaddy_api_secret = "test-api-secret-not-real"
}

# NOTE: A full `command = plan` is not feasible for this example.
# dns.tf issues an aws_acm_certificate and then uses `for_each` over its
# `domain_validation_options` to create GoDaddy validation records.
# That attribute is computed and unknown at plan time under a mocked AWS
# provider, so any plan-level test would fail before reaching the graph walk.
#
# Validation and wiring are covered by tests/defaults.tftest.hcl at the
# repo root (which uses certificate_arn to bypass the cert/DNS path) and by
# a real deployment smoke test (tests/scripts/smoke-test.sh).
