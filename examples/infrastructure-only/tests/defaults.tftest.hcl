# Plan-time tests for the infrastructure-only example using mocked providers.
#
# Exercises the VPC + module wiring with create_kubernetes_resources = false,
# without contacting AWS.
#
# The kubernetes and helm providers are mocked here even though this example
# configures neither. terraform test must not start a real provider, and the
# mocks are what keep it from doing so. That also means these runs say nothing
# about whether an unconfigured kubernetes or helm provider plans cleanly: only
# a real `terraform plan` from this directory, with no kubeconfig and no
# cluster access, answers that.
#
# Run: terraform test
#   (from examples/infrastructure-only/)

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

# No n8n_license_key, unlike examples/small: this example has no such input.
variables {
  n8n_domain      = "n8n.test.example.com"
  route53_zone_id = "Z00000000000000000000"
}

# The one deliberate difference from examples/small. The module's own counts
# are asserted in tests/infrastructure-only.tftest.hcl at the repo root; a
# child module's resources are not addressable from here, so this run reads
# the outputs that change with the mode. It also proves the example plans with
# no license input, which the module requires on the default path.
run "module_runs_in_infrastructure_only_mode" {
  command = plan

  assert {
    condition     = module.n8n.alb_hostname == null
    error_message = "The module must report no ALB hostname: it creates no Ingress in this example"
  }

  assert {
    condition     = module.n8n.n8n_encryption_key == null
    error_message = "The module must generate no encryption key in this example: the operator owns it"
  }

  assert {
    condition     = output.namespace == "n8n"
    error_message = "The namespace output must carry the name the operator installs n8n into"
  }

  # The README's helm command reads these two outputs.
  assert {
    condition     = output.n8n_chart_repository == module.n8n.n8n_chart_repository && output.n8n_chart_version == module.n8n.n8n_chart_version
    error_message = "The example must re-export the chart repository and version the README installs from"
  }

  assert {
    condition     = startswith(output.n8n_chart_repository, "oci://")
    error_message = "The README's helm command assumes an OCI chart repository by default"
  }
}

# EKS accepts only letters, digits and hyphens in a cluster name, and the
# module's own validation still lets a period through for the bucket name.
run "cluster_name_rejects_a_period" {
  command = plan

  variables {
    cluster_name = "n8n.cluster"
  }

  expect_failures = [var.cluster_name]
}

run "cluster_name_rejects_an_empty_value" {
  command = plan

  variables {
    cluster_name = ""
  }

  expect_failures = [var.cluster_name]
}

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
# n8n_task_runner_image_tag, n8n_task_runner_image_repository,
# n8n_custom_extensions_path,
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
# Passed through to the module unchanged, as in examples/small: this example
# still lets the module create RDS and S3. Verify the wiring by setting
# non-default values and reading the module outputs.

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
    db_final_snapshot_identifier = "infra-only-example-final"
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
    condition     = module.n8n.rds_final_snapshot_identifier == "infra-only-example-final"
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
