# Plan-time tests for the cloudflare example using mocked providers.
#
# Exercises the VPC + ACM + Cloudflare-DNS + module wiring without contacting
# AWS or Cloudflare.
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

run "defaults_produce_valid_plan" {
  command = plan

  assert {
    condition     = aws_acm_certificate.n8n.domain_name == "n8n.test.example.com"
    error_message = "ACM certificate domain_name must track var.n8n_domain"
  }

  assert {
    condition     = aws_acm_certificate.n8n.validation_method == "DNS"
    error_message = "ACM certificate must use DNS validation in the cloudflare path"
  }

  # The for_each is keyed on var.n8n_domain (static) so this is testable.
  assert {
    condition     = contains(keys(cloudflare_record.cert_validation), "n8n.test.example.com")
    error_message = "cert_validation record must be created for n8n_domain"
  }

  assert {
    condition     = cloudflare_record.cert_validation["n8n.test.example.com"].zone_id == "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4"
    error_message = "cert_validation record must target var.cloudflare_zone_id"
  }

  assert {
    condition     = cloudflare_record.cert_validation["n8n.test.example.com"].proxied == false
    error_message = "cert_validation record must NOT be proxied (ACM resolves it directly)"
  }

  assert {
    condition     = cloudflare_record.n8n_cname.type == "CNAME"
    error_message = "n8n record must be a CNAME pointing at the ALB"
  }

  assert {
    condition     = cloudflare_record.n8n_cname.proxied == false
    error_message = "n8n CNAME defaults to proxied=false; flip explicitly with Full (strict) SSL/TLS"
  }
}

run "cluster_name_length_validation_rejects_long_names" {
  command = plan

  variables {
    cluster_name = "this-cluster-name-is-definitely-too-long"
  }

  expect_failures = [var.cluster_name]
}
