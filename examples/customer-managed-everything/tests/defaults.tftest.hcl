# Plan-time tests for the customer-managed-everything example.
#
# Same structural limitation as examples/customer-managed-cluster, worse
# here: read that example's tests/defaults.tftest.hcl header comment first for
# the full investigation (mock_data, override_data, override_resource, a
# zero-dependency literal, all tried against data.aws_eks_cluster.existing;
# none resolve it under `command = plan`). This example adds more check
# blocks that hit the same unresolvable-value problem once create_database
# and create_elasticache are also false (install_metrics_server's HPA check
# in scaling.tf, in addition to eks.tf's and storage.tf's), so a normal
# successful-plan assertion is even further out of reach than it was there.
#
# Run: terraform test
#   (from examples/customer-managed-everything/, mocks require terraform >= 1.7)

# ── Which variable-validation run blocks can pass, and why ────────────────────
#
# examples/customer-managed-cluster found that expect_failures on an
# example-local variable's own validation block can still pass, if that
# variable's failure cascades widely enough to prevent Terraform from ever
# reaching the unresolvable check blocks. That example attributed this to
# cluster_name specifically: it derives the stand-in cluster resource's own
# name. This example tested that same variable, plus three more, directly
# (not assumed) and found a broader, empirically consistent pattern:
#
#   - cluster_name, customer_managed_redis_auth_token, and
#     customer_managed_db_password ALL pass cleanly as expect_failures runs.
#     What the three have in common: each feeds a root-level stand-in
#     resource's argument DIRECTLY (aws_eks_cluster.customer_managed.name,
#     aws_elasticache_replication_group.customer_managed.auth_token,
#     aws_db_instance.customer_managed.password), not only a pass-through
#     into module.n8n's own identically-named input.
#   - n8n_image_tag does NOT have this property, tested directly the same
#     way examples/customer-managed-cluster tested it: it is consumed only
#     as a module.n8n argument in this example (nothing at the root level
#     reads it directly), and its failure still surfaces alongside the same
#     "known after apply" check-block errors as a plain, no-failure plan
#     does, which fails the run even though the expected failure also
#     occurred.
#
# The mechanism behind this split was not traced further than these four data
# points; treat it as an empirical rule for this file, not a general claim
# about Terraform. Do not add a run block for n8n_execution_data_storage_mode,
# customer_managed_node_instance_type/desired/min/max, or any other variable
# whose only consumer is a module.n8n argument (not also a root-level
# resource argument) without testing it directly first, the same way these
# four were tested, via `terraform test -filter=...` against a throwaway
# probe file. Assume it will fail until proven otherwise.
#
# What this leaves uncovered: an automated proof that a *successful* plan of
# this example's own wiring, across every customer-managed toggle at once,
# reaches the module. Each individual toggle's own logic
# (create_eks/create_database/create_elasticache/create_s3_bucket = false,
# and install_lbc/install_cluster_autoscaler/install_metrics_server/
# install_keda/create_ebs_csi = false) is already covered by 400+ run blocks
# in the repo root's tests/defaults.tftest.hcl, tested directly rather than
# through an example wrapper, where this nested-module mocking limitation
# does not apply. This example's own contribution beyond the run blocks below
# is a realistic, tested-by-hand reference configuration combining every
# toggle at once, including a direct modules/controllers invocation:
# terraform validate, terraform fmt, and tflint all pass against it, and
# terraform plan/apply against real AWS credentials is the way to exercise it
# end to end.

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

run "customer_managed_redis_auth_token_rejects_too_short" {
  command = plan

  variables {
    customer_managed_redis_auth_token = "short"
  }

  expect_failures = [var.customer_managed_redis_auth_token]
}

run "customer_managed_db_password_rejects_too_short" {
  command = plan

  variables {
    customer_managed_db_password = "short"
  }

  expect_failures = [var.customer_managed_db_password]
}
