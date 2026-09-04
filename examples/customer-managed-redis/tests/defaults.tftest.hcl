# Plan-time tests for the customer-managed-redis example using mocked
# providers.
#
# Exercises the VPC + stand-in Redis + module wiring without contacting AWS.
#
# Run: terraform test
#   (from examples/customer-managed-redis/, mocks require terraform >= 1.7,
#   and the override_resource block below needs terraform >= 1.11
#   specifically; see the comment on that block)

mock_provider "aws" {
  override_data {
    target = data.aws_availability_zones.available
    values = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }

  # The stand-in replication group's primary_endpoint_address is unknown at
  # plan time, same as every other computed AWS attribute under mocking, and
  # this run's own assertion compares module.n8n.redis_endpoint against it
  # directly, which a `command = plan` run can't do with an unknown value
  # ("Unknown condition value"). override_resource fixes this, but only with
  # override_during = plan set explicitly: without it, an override_resource
  # block applies during apply only (the default), and silently has no effect
  # on a plan-only run, which is why this was unknown the first time this test
  # was written despite the override being present. override_during needs
  # Terraform >= 1.11: the attribute was added by hashicorp/terraform#36227
  # and shipped in v1.11 (#36312 is only the docs update for it, and is the
  # wrong thing to cite when tracing the requirement). This example's own
  # versions.tf declares that floor, and CI's single pinned Terraform version
  # sits above it (see terraform-tests.yml).
  # command = apply is not a substitute at any Terraform version: this
  # example still creates a real EKS cluster (create_eks defaults to true
  # here), and a full mocked apply makes every computed AWS attribute in
  # that graph, not just this one, come back as a non-ARN-shaped mock
  # string, which fails the Pod Identity association's own
  # role_arn/policy_arn validation elsewhere in the same plan. Confirmed by
  # direct experimentation, not assumed.
  override_resource {
    target          = aws_elasticache_replication_group.customer_managed
    override_during = plan
    values = {
      primary_endpoint_address = "customer-managed-redis.mock.cache.amazonaws.com"
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

# NOTE on test coverage: same limitation as examples/small/tests/defaults.tftest.hcl
# Only variable-validation and plan-time wiring tests run here, not
# apply-shaped assertions. The module itself, including create_elasticache =
# false, is exercised by tests/defaults.tftest.hcl at the repo root.

run "plan_succeeds_with_customer_managed_redis_wiring" {
  command = plan

  assert {
    condition     = module.n8n.redis_endpoint == aws_elasticache_replication_group.customer_managed.primary_endpoint_address
    error_message = "The module's redis_endpoint output must echo the stand-in replication group's primary endpoint, proving create_elasticache = false wiring reached the module."
  }

  assert {
    condition     = aws_elasticache_replication_group.customer_managed.transit_encryption_enabled == true
    error_message = "The stand-in replication group must have transit encryption enabled, since this example exists to exercise the AUTH+TLS customer-managed Redis path."
  }
}

run "cluster_name_length_validation_rejects_long_names" {
  command = plan

  variables {
    cluster_name = "this-cluster-name-is-definitely-too-long"
  }

  expect_failures = [var.cluster_name]
}

run "n8n_image_tag_defaults_to_null" {
  command = plan

  assert {
    condition     = var.n8n_image_tag == null
    error_message = "Example must not pin an image tag by default; the module's chart default (stable) should apply."
  }
}

run "n8n_main_hpa_min_replicas_defaults_to_null" {
  command = plan

  assert {
    condition     = var.n8n_main_hpa_min_replicas == null
    error_message = "Example must not override the main-replica count by default; the module's own default of 2 should apply."
  }
}

run "n8n_image_tag_rejects_whitespace" {
  command = plan

  variables {
    n8n_image_tag = " 1.2.3 "
  }

  expect_failures = [var.n8n_image_tag]
}

run "execution_data_storage_mode_rejects_filesystem" {
  command = plan

  variables {
    n8n_execution_data_storage_mode = "filesystem"
  }

  expect_failures = [var.n8n_execution_data_storage_mode]
}
