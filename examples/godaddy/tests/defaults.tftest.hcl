# Plan-time tests for the godaddy example using mocked providers.
#
# Exercises the VPC + ACM + GoDaddy-DNS + module wiring without contacting
# AWS or GoDaddy.
#
# Run: terraform test
#   (from examples/godaddy/, requires terraform >= 1.11)

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
