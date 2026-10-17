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
  # when tracing the requirement). This example's own versions.tf declares a
  # floor at or above it, and both CI Terraform versions (TF_VERSION and
  # TF_FLOOR_VERSION) sit above it (see terraform-tests.yml).
  # command = apply is not a substitute at
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

run "cluster_name_rejects_dots" {
  command = plan

  variables {
    cluster_name = "n8n.cluster"
  }

  expect_failures = [var.cluster_name]
}

run "n8n_image_tag_defaults_to_null" {
  command = plan

  assert {
    condition     = var.n8n_image_tag == null
    error_message = "Example must not pin an image tag by default; the module's selected chart default should apply."
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

run "task_runner_image_repository_defaults_to_null" {
  command = plan

  assert {
    condition     = var.n8n_task_runner_image_repository == null
    error_message = "Example must not pin a task runner image repository by default; the module's chart default (n8nio/runners) should apply."
  }
}

run "task_runner_image_repository_rejects_inline_tag" {
  command = plan

  variables {
    n8n_task_runner_image_repository = "myregistry.example.com/runners:2.27.4"
  }

  expect_failures = [var.n8n_task_runner_image_repository]
}

run "execution_data_storage_mode_rejects_filesystem" {
  command = plan

  variables {
    n8n_execution_data_storage_mode = "filesystem"
  }

  expect_failures = [var.n8n_execution_data_storage_mode]
}

# ── Data-resource deletion controls ───────────────────────────────────────────
# This example passes the five RDS deletion controls through to the module
# unchanged, the same way examples/small does. s3_force_destroy is deliberately
# not passed through: the module creates no bucket here (create_s3_bucket =
# false), and the stand-in bucket's force_destroy is its own
# customer_managed_s3_force_destroy variable. Verify the wiring by reading the
# module outputs at their defaults and again after setting non-default values.

run "deletion_controls_default_to_module_teardown_friendly_values" {
  command = plan

  assert {
    condition     = module.n8n.rds_deletion_protection == false
    error_message = "db_deletion_protection should pass through as false when the example leaves it at null"
  }

  assert {
    condition     = module.n8n.rds_skip_final_snapshot == true
    error_message = "db_skip_final_snapshot should pass through as true when the example leaves it at null"
  }

  assert {
    condition     = module.n8n.rds_delete_automated_backups == true
    error_message = "db_delete_automated_backups should pass through as true when the example leaves it at null"
  }

  assert {
    condition     = module.n8n.rds_final_snapshot_identifier == null
    error_message = "db_final_snapshot_identifier should pass through as null when the example leaves it at null"
  }

  assert {
    condition     = module.n8n.rds_backup_retention_period == 7
    error_message = "db_backup_retention_period should pass through as the module's default of 7 when the example leaves it at null"
  }
}

run "deletion_controls_pass_through_to_module" {
  command = plan

  variables {
    db_backup_retention_period   = 14
    db_deletion_protection       = true
    db_skip_final_snapshot       = false
    db_final_snapshot_identifier = "customer-managed-s3-example-final"
    db_delete_automated_backups  = false
  }

  assert {
    condition     = module.n8n.rds_backup_retention_period == 14
    error_message = "db_backup_retention_period must pass from the example to the module"
  }

  assert {
    condition     = module.n8n.rds_deletion_protection == true
    error_message = "db_deletion_protection must pass from the example to the module"
  }

  assert {
    condition     = module.n8n.rds_skip_final_snapshot == false
    error_message = "db_skip_final_snapshot must pass from the example to the module"
  }

  assert {
    condition     = module.n8n.rds_final_snapshot_identifier == "customer-managed-s3-example-final"
    error_message = "db_final_snapshot_identifier must pass from the example to the module"
  }

  assert {
    condition     = module.n8n.rds_delete_automated_backups == false
    error_message = "db_delete_automated_backups must pass from the example to the module"
  }
}

# ── AWS Partner Revenue Measurement tag ───────────────────────────────────────
# The example merges the tag into its own tags (VPC, NAT gateway, stand-in
# infrastructure) and passes the same value to the module. Whether the module
# then tags what it creates is asserted in the root tests/defaults.tftest.hcl.
# local.common_tags is built entirely from known inputs, so it is also known
# at plan time and is asserted here directly: deleting the tag merge from this
# example's own main.tf would leave only the variable-contract assertion
# green, so both are checked.

run "aws_partner_attribution_tag_defaults_to_the_product_code" {
  command = plan

  assert {
    condition     = var.aws_partner_attribution_tag == "pc:26au7o6cdeh7fqdt376h9m9xk"
    error_message = "The example must default to the same product code as the module root"
  }

  assert {
    condition     = local.common_tags["aws-apn-id"] == "pc:26au7o6cdeh7fqdt376h9m9xk"
    error_message = "The example must merge the attribution tag into its own common_tags"
  }
}

run "aws_partner_attribution_tag_rejects_a_value_that_is_not_a_product_code" {
  command = plan

  variables {
    aws_partner_attribution_tag = "26au7o6cdeh7fqdt376h9m9xk"
  }

  expect_failures = [var.aws_partner_attribution_tag]
}

run "aws_partner_attribution_tag_rejects_a_value_over_the_aws_tag_value_limit" {
  command = plan

  variables {
    # "pc:" plus 254 characters is 257, one over the 256-character tag value limit.
    aws_partner_attribution_tag = "pc:${join("", [for i in range(254) : "a"])}"
  }

  expect_failures = [var.aws_partner_attribution_tag]
}

# The TLS proxy pass-throughs (n8n_extra_ca_pem, n8n_proxy_hops, n8n_extra_env)
# are intentionally untested here. The module exposes no output that reflects
# them, and helm_release.n8n.values is unknown at plan time under mocks, so a
# run block could only read back the example's own variable. Their contracts
# (defaults, validations, reserved names) are covered by the repo root's
# tests/defaults.tftest.hcl. `terraform validate` checks only that the
# arguments, references and types line up; confirming the rendered result
# needs a real `terraform plan`.
