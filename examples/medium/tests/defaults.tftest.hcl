# Plan-time tests for the medium example using mocked providers.
#
# Run: terraform test
#   (from examples/medium/ — requires terraform >= 1.7)

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

# The n8n image inputs (n8n_image_tag, n8n_image_repository,
# n8n_task_runner_image_tag, n8n_custom_extensions_path) are intentionally
# untested here. Asserting the null default needs a successful full plan, and
# even an expect_failures rejection run fails: unlike cluster_name, they do not
# feed the module's DNS resources, so the dns.tf for_each error described in
# the NOTE in examples/small/tests/defaults.tftest.hcl still surfaces as an
# unexpected diagnostic alongside the expected validation failure. Their
# variable contracts (default, format validation) are covered by
# tests/defaults.tftest.hcl at the repo root; verify the passthrough manually
# with a real `terraform plan`.

run "execution_data_storage_mode_rejects_filesystem" {
  command = plan

  variables {
    n8n_execution_data_storage_mode = "filesystem"
  }

  expect_failures = [var.n8n_execution_data_storage_mode]
}
