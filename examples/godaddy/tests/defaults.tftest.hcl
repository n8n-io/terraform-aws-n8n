# Plan-time tests for the godaddy example using mocked providers.
#
# Exercises the VPC + ACM + GoDaddy-DNS + module wiring without contacting
# AWS or GoDaddy.
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
# terraform test locally — no real API calls are made.

variables {
  n8n_domain         = "n8n.test.example.com"
  n8n_license_key    = "test-license-key-not-real"
  godaddy_domain     = "test.example.com"
  godaddy_api_key    = "test-api-key-not-real"
  godaddy_api_secret = "test-api-secret-not-real"
}

run "defaults_produce_valid_plan" {
  command = plan

  assert {
    condition     = aws_acm_certificate.n8n.domain_name == "n8n.test.example.com"
    error_message = "ACM certificate domain_name must track var.n8n_domain"
  }

  assert {
    condition     = aws_acm_certificate.n8n.validation_method == "DNS"
    error_message = "ACM certificate must use DNS validation in the godaddy path"
  }

  # The for_each is keyed on var.n8n_domain (static) so this is testable.
  assert {
    condition     = contains(keys(godaddy-dns_record.cert_validation), "n8n.test.example.com")
    error_message = "cert_validation record must be created for n8n_domain"
  }

  assert {
    condition     = godaddy-dns_record.cert_validation["n8n.test.example.com"].domain == "test.example.com"
    error_message = "cert_validation record must target var.godaddy_domain"
  }

  assert {
    condition     = godaddy-dns_record.n8n_cname.name == "n8n"
    error_message = "n8n CNAME name must be the relative label below godaddy_domain"
  }

  assert {
    condition     = godaddy-dns_record.n8n_cname.type == "CNAME"
    error_message = "n8n record must be a CNAME pointing at the ALB"
  }
}

run "cluster_name_length_validation_rejects_long_names" {
  command = plan

  variables {
    cluster_name = "this-cluster-name-is-definitely-too-long"
  }

  expect_failures = [var.cluster_name]
}

run "n8n_domain_must_be_single_label_below_godaddy_domain" {
  command = plan

  variables {
    n8n_domain = "n8n.prod.test.example.com"
  }

  expect_failures = [var.n8n_domain]
}
