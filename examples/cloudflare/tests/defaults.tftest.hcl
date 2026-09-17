# Plan-time tests for the cloudflare example using mocked providers.
#
# Exercises the VPC + ACM + Cloudflare-DNS + module wiring without contacting
# AWS or Cloudflare.
#
# Run: terraform test
#   (from examples/cloudflare/, requires terraform >= 1.11)

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

# This example issues the ACM certificate itself, so the module's Common Name
# precondition never evaluates here; the example's own validation has to catch it.
run "n8n_domain_over_64_characters_is_rejected_as_the_acm_common_name" {
  command = plan

  variables {
    # 53-character label + ".example.com" = 65 characters: within every DNS
    # limit the module enforces, so only the example's CN validation rejects it.
    n8n_domain = "${join("", [for i in range(53) : "a"])}.example.com"
  }

  expect_failures = [var.n8n_domain]
}

# The validation is inclusive: 64 characters is the longest Common Name ACM
# accepts and must plan.
run "n8n_domain_at_64_characters_is_accepted_as_the_acm_common_name" {
  command = plan

  variables {
    # 52-character label + ".example.com" = 64 characters.
    n8n_domain = "${join("", [for i in range(52) : "a"])}.example.com"
  }

  assert {
    condition     = length(var.n8n_domain) == 64
    error_message = "test fixture must actually hit the 64-character Common Name boundary"
  }

  assert {
    condition     = aws_acm_certificate.n8n.domain_name == var.n8n_domain
    error_message = "the example-issued certificate must carry the 64-character n8n_domain as its Common Name"
  }
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

run "n8n_image_repository_defaults_to_null" {
  command = plan

  assert {
    condition     = var.n8n_image_repository == null
    error_message = "Example must not pin an image repository by default; the module's chart default (docker.n8n.io/n8nio/n8n) should apply."
  }
}

run "n8n_image_repository_rejects_inline_tag" {
  command = plan

  variables {
    n8n_image_repository = "myregistry.example.com/n8n:2.27.4"
  }

  expect_failures = [var.n8n_image_repository]
}

run "n8n_task_runner_image_tag_defaults_to_null" {
  command = plan

  assert {
    condition     = var.n8n_task_runner_image_tag == null
    error_message = "Example must not pin a task runner image tag by default; the chart should keep inheriting the n8n application image's tag."
  }
}

run "n8n_task_runner_image_tag_rejects_whitespace" {
  command = plan

  variables {
    n8n_task_runner_image_tag = " 2.27.4 "
  }

  expect_failures = [var.n8n_task_runner_image_tag]
}

run "n8n_custom_extensions_path_defaults_to_null" {
  command = plan

  assert {
    condition     = var.n8n_custom_extensions_path == null
    error_message = "Example must not set a custom extensions path by default; N8N_CUSTOM_EXTENSIONS should be omitted unless a custom image supplies nodes at that path."
  }
}

run "n8n_custom_extensions_path_rejects_a_relative_path" {
  command = plan

  variables {
    n8n_custom_extensions_path = "opt/n8n-nodes"
  }

  expect_failures = [var.n8n_custom_extensions_path]
}

run "n8n_custom_extensions_path_rejects_the_chart_mounted_data_dir" {
  command = plan

  variables {
    n8n_custom_extensions_path = "/home/node/.n8n/custom"
  }

  expect_failures = [var.n8n_custom_extensions_path]
}

run "n8n_custom_extensions_path_rejects_a_non_canonical_path" {
  command = plan

  variables {
    n8n_custom_extensions_path = "/home/node/./.n8n/custom"
  }

  expect_failures = [var.n8n_custom_extensions_path]
}

run "n8n_image_pull_secrets_defaults_to_empty" {
  command = plan

  assert {
    condition     = length(var.n8n_image_pull_secrets) == 0
    error_message = "Example must not attach image pull secrets by default; the Helm chart should keep creating the n8n ServiceAccount."
  }
}

run "n8n_image_pull_secrets_rejects_a_non_dns_name" {
  command = plan

  variables {
    n8n_image_pull_secrets = ["Not_A_Secret_Name"]
  }

  expect_failures = [var.n8n_image_pull_secrets]
}

run "n8n_image_pull_secrets_rejects_an_overlong_label" {
  command = plan

  variables {
    # 64 characters, one past the Kubernetes per-label limit, though well
    # under the 253-character total-length limit.
    n8n_image_pull_secrets = ["a${join("", [for i in range(63) : "a"])}"]
  }

  expect_failures = [var.n8n_image_pull_secrets]
}

run "execution_data_storage_mode_defaults_to_database" {
  command = plan

  assert {
    condition     = var.n8n_execution_data_storage_mode == "database"
    error_message = "Example must default to database storage; s3 needs an n8n >= 2.27 image and the feat:executionDataS3 entitlement, so it cannot be the default."
  }
}

run "execution_data_storage_mode_rejects_filesystem" {
  command = plan

  variables {
    n8n_execution_data_storage_mode = "filesystem"
  }

  expect_failures = [var.n8n_execution_data_storage_mode]
}

# ── Data-resource deletion controls ───────────────────────────────────────────
# The cloudflare example passes these through to the module unchanged, the same way
# examples/small does. Verify the wiring by reading the module outputs at their
# defaults and again after setting non-default values.

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
    db_final_snapshot_identifier = "cloudflare-example-final"
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
    condition     = module.n8n.rds_final_snapshot_identifier == "cloudflare-example-final"
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
