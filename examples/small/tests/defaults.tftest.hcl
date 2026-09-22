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
# Most runs here are variable-validation only, but a full `command = plan`
# over this example already succeeds without the BYO-cert workaround: dns.tf's
# aws_route53_record.cert_validation for_each is keyed off
# local.acm_domain_names (input-derived), not the certificate's own
# domain_validation_options, so the for_each itself is known at plan time even
# with route53_zone_id set (see dns.tf's own comment on that resource). That
# is enough to plan cleanly and assert on plain input variables, like the run
# below. Asserting on the values dns.tf computes from domain_validation_options
# (the validation record's name, type, and value) still needs the BYO-cert
# workaround used by examples/large/tests/defaults.tftest.hcl, because those
# individual attributes stay unknown at plan time regardless of the for_each
# keys, tracked as a separate follow-up. The module itself is already
# exercised by tests/defaults.tftest.hcl at the repo root, which mocks the
# lower-level resources directly.

run "cluster_name_length_validation_rejects_long_names" {
  command = plan

  variables {
    cluster_name = "this-cluster-name-is-definitely-too-long"
  }

  expect_failures = [var.cluster_name]
}

run "n8n_main_hpa_min_replicas_defaults_to_null" {
  command = plan

  assert {
    condition     = var.n8n_main_hpa_min_replicas == null
    error_message = "Example must not override the main-replica count by default; the module's own default of 2 should apply."
  }
}

# The custom-image inputs added alongside n8n_image_tag (n8n_image_repository,
# n8n_task_runner_image_tag, n8n_custom_extensions_path,
# n8n_image_pull_secrets) are intentionally untested here; their variable
# contracts (default, format validation) are covered by
# tests/defaults.tftest.hcl at the repo root, and the passthrough is verified
# manually with a real `terraform plan`.

run "n8n_image_tag_defaults_to_null" {
  command = plan

  assert {
    condition     = var.n8n_image_tag == null
    error_message = "Example must not pin an image tag by default; the module's selected chart default should apply."
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

# ── Data-resource deletion controls ───────────────────────────────────────────
# The small example passes these through to the module unchanged. Verify the
# wiring by setting non-default values and reading the module outputs.

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
    condition     = module.n8n.s3_force_destroy == true
    error_message = "s3_force_destroy should pass through as true when the example leaves it at null"
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
    db_final_snapshot_identifier = "small-example-final"
    db_delete_automated_backups  = false
    s3_force_destroy             = false
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
    condition     = module.n8n.rds_final_snapshot_identifier == "small-example-final"
    error_message = "db_final_snapshot_identifier must pass from the example to the module"
  }

  assert {
    condition     = module.n8n.rds_delete_automated_backups == false
    error_message = "db_delete_automated_backups must pass from the example to the module"
  }

  assert {
    condition     = module.n8n.s3_force_destroy == false
    error_message = "s3_force_destroy must pass from the example to the module"
  }
}
