# Plan-time tests for the large example using mocked providers.
#
# Run: terraform test
#   (from examples/large/ — requires terraform >= 1.7)

# NOTE on test coverage scope:
#
# The asserts below are deliberately thin (variable-validation only) for the
# same reason documented in examples/cloudflare/tests/defaults.tftest.hcl:
# the module's dns.tf does `for_each` over aws_acm_certificate.n8n[0]
# .domain_validation_options, which is unknown at plan time under a mocked
# AWS provider. mock_resource defaults and override_resource on the cert
# both fail to make this attribute plan-time-known for the for_each
# evaluator (this appears to be a Terraform mock-framework limitation as of
# 1.15.x — verified that override_resource at file scope, inside run blocks,
# and inside mock_provider all silently no-op for this specific case).
#
# Architecture asserts that we *would* like here — PgBouncer required
# anti-affinity, PDB existence, Aurora writer+reader cluster_identifier wiring,
# aws_eks_addon.vpc_cni configuration_values, module.vpc.natgw_ids length —
# all need a complete plan to evaluate. They are validated by the live apply
# instead (see the smoke-test sequence in docs/, and the live verification
# steps in this example's README). Promote to plan-time once Terraform's
# mock framework supports overriding computed attributes used in for_each.

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

run "cluster_name_length_validation_rejects_long_names" {
  command = plan

  variables {
    cluster_name = "this-cluster-name-is-definitely-too-long"
  }

  expect_failures = [var.cluster_name]
}

run "aurora_instance_class_validation_rejects_invalid" {
  command = plan

  variables {
    aurora_instance_class = "r6g.8xlarge"
  }

  expect_failures = [var.aurora_instance_class]
}


