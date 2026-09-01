# Plan-time tests for the worker-pools example using mocked providers.
#
# Exercises the VPC + ACM + module wiring without contacting AWS.
#
# Run: terraform test
#   (from examples/worker-pools/, mocks require terraform >= 1.7)

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
# Only variable-validation tests run here today. Architecture asserts that
# would require a full `command = plan` over the example are doable via the
# same BYO-cert workaround used by examples/large/tests/defaults.tftest.hcl
# (plumb certificate_arn through, set it to a stub in tests, leave
# route53_zone_id null so the module's dns.tf for_each over
# domain_validation_options never instantiates), tracked as a separate
# follow-up. The module itself is already exercised by tests/defaults.tftest.hcl
# at the repo root, which mocks the lower-level resources directly.

run "cluster_name_length_validation_rejects_long_names" {
  command = plan

  variables {
    cluster_name = "this-cluster-name-is-definitely-too-long"
  }

  expect_failures = [var.cluster_name]
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

# The pool topology is what this example is for, so it is asserted rather than
# left to the plan alone. local.worker_pools in main.tf is the declaration
# these read; a literal at the module call site would not be reachable here.

run "example_declares_the_three_documented_pools" {
  command = plan

  assert {
    condition     = [for p in local.worker_pools : p.name] == ["gpu", "secteam", "itop"]
    error_message = "The example's pools drifted from the three the README documents: got ${join(", ", [for p in local.worker_pools : p.name])}."
  }

  # Every name has to satisfy the module's own rule, which is tighter than it
  # looks: 1-53 characters, lowercase alphanumerics and hyphens, and both ends
  # alphanumeric, because the chart uses this value for a group name capped at
  # 53. Asserted here so the example cannot ship a name that plans clean at the
  # example layer and fails helm schema validation at apply.
  assert {
    condition = alltrue([
      for p in local.worker_pools :
      can(regex("^[a-z0-9]([a-z0-9-]{0,51}[a-z0-9])?$", p.name))
    ])
    error_message = "An example pool name does not satisfy the module's pool-name rule."
  }

  assert {
    condition     = length(distinct([for p in local.worker_pools : p.name])) == length(local.worker_pools)
    error_message = "The example declares two pools with the same name; each pool is one Deployment and one queue, so they would collide."
  }
}

run "example_keeps_a_scale_to_zero_pool_and_a_resized_pool" {
  command = plan

  # itop exists to show min_replicas = 0 is legal. If it stops being 0 the
  # example silently stops demonstrating scale-to-zero.
  assert {
    condition     = one([for p in local.worker_pools : p.min_replicas if p.name == "itop"]) == 0
    error_message = "The itop pool is the example's scale-to-zero case and must keep min_replicas = 0."
  }

  # gpu is the one pool that overrides sizing; the other two exist to show the
  # fallback to the module-wide worker defaults. Asserted on the values the
  # README's topology table quotes, so the two cannot drift apart silently.
  assert {
    condition     = one([for p in local.worker_pools : p.concurrency if p.name == "gpu"]) == 5
    error_message = "The gpu pool is the example's lower-concurrency case and must keep concurrency = 5, which is the value the README table quotes."
  }

  assert {
    condition     = one([for p in local.worker_pools : p.cpu_request if p.name == "gpu"]) == "1"
    error_message = "The gpu pool is the example's resized case and must keep cpu_request = \"1\"; the node_max arithmetic in main.tf is derived from it."
  }
}

run "example_pool_ceilings_match_the_node_max_arithmetic" {
  command = plan

  # node_max is a literal 8 in main.tf, raised from small's 6 purely to hold
  # these pools at their maxima. node_max is not reachable from here, so this
  # guards the other half: if the pool ceilings grow, the arithmetic behind that
  # 8 no longer holds and the module's capacity check starts warning on the
  # example this repo ships.
  assert {
    condition     = sum([for p in local.worker_pools : p.max_replicas]) == 10
    error_message = "The example's pool maxima changed (now ${sum([for p in local.worker_pools : p.max_replicas])} pods). Re-check node_max against the arithmetic in main.tf before updating this assertion."
  }
}
