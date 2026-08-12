# Plan-time tests for the customer-managed-s3 example using mocked providers.
#
# Exercises the VPC + stand-in bucket + module wiring without contacting AWS.
#
# Run: terraform test
#   (from examples/customer-managed-s3/, mocks require terraform >= 1.7,
#   and the override_resource block below needs terraform >= 1.11
#   specifically; see the comment on that block)

mock_provider "aws" {
  override_data {
    target = data.aws_availability_zones.available
    values = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "123456789012"
    }
  }

  # aws_s3_bucket.customer_managed.id is unknown at plan time for a
  # not-yet-created bucket, same as any computed AWS attribute under mocking,
  # and this run's own assertion compares module.n8n.s3_bucket_name against it
  # directly, which a `command = plan` run can't do with an unknown value.
  # override_during = plan is required: without it, an override_resource
  # block only applies during apply (the default), and silently has no effect
  # on a plan-only run. override_during needs Terraform >= 1.11: the
  # attribute was added by hashicorp/terraform#36227 and shipped in v1.11
  # (#36312 is only the docs update for it, and is the wrong thing to cite
  # when tracing the requirement). This example's own versions.tf declares
  # that floor, and CI's single pinned Terraform version sits above it (see
  # terraform-tests.yml). command = apply is not a substitute at
  # any Terraform version: this example still creates a real EKS cluster
  # (create_eks defaults to true here), and a full mocked apply makes every
  # computed AWS attribute in that graph, not just this one, come back as a
  # non-ARN-shaped mock string, which fails the Pod Identity association's
  # own role_arn/policy_arn validation elsewhere in the same plan. Confirmed
  # by direct experimentation, not assumed.
  override_resource {
    target          = aws_s3_bucket.customer_managed
    override_during = plan
    values = {
      id = "customer-managed-n8n-mock-bucket"
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
# apply-shaped assertions. The module itself, including create_s3_bucket =
# false, is exercised by tests/defaults.tftest.hcl at the repo root.

run "plan_succeeds_with_customer_managed_s3_wiring" {
  command = plan

  assert {
    condition     = module.n8n.s3_bucket_name == aws_s3_bucket.customer_managed.id
    error_message = "The module's s3_bucket_name output must echo the stand-in bucket's id, proving create_s3_bucket = false wiring reached the module."
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
