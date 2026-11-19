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

variables {
  n8n_domain      = "n8n.test.example.com"
  route53_zone_id = "Z00000000000000000000"
}

run "cluster_name_length_validation_rejects_long_names" {
  command = plan

  variables {
    cluster_name = "this-cluster-name-is-definitely-too-long"
  }

  expect_failures = [var.cluster_name]
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
}

run "n8n_main_hpa_min_replicas_defaults_to_null" {
  command = plan

  assert {
    condition     = var.n8n_main_hpa_min_replicas == null
    error_message = "Example must not override the main-replica count by default; the module's own default of 2 should apply."
  }
}

# The custom-image inputs are passed through because they shape the Helm values
# the operator installs with. Their variable contracts are covered by
# tests/defaults.tftest.hcl at the repo root.

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
# still lets the module create RDS and S3.

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
}

run "deletion_controls_pass_through_to_module" {
  command = plan

  variables {
    db_deletion_protection       = true
    db_skip_final_snapshot       = false
    db_final_snapshot_identifier = "n8n-final-snapshot"
    s3_force_destroy             = false
  }

  assert {
    condition     = module.n8n.rds_deletion_protection == true
    error_message = "db_deletion_protection = true must reach the module"
  }

  assert {
    condition     = module.n8n.rds_skip_final_snapshot == false
    error_message = "db_skip_final_snapshot = false must reach the module"
  }

  assert {
    condition     = module.n8n.s3_force_destroy == false
    error_message = "s3_force_destroy = false must reach the module"
  }
}
