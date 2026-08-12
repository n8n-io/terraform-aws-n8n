# Plan-time tests for the customer-managed-cluster example.
#
# Unlike examples/customer-managed-redis and examples/customer-managed-s3,
# this file cannot exercise a normal, succeeding plan of its own wiring.
# Read the section below before adding a run block here.
#
# Run: terraform test
#   (from examples/customer-managed-cluster/, mocks require terraform >= 1.7)

# ── Why most plan-time coverage is not possible here ──────────────────────────
#
# This example's whole point is create_eks = false wired at a stand-in cluster
# created in the same apply. The module's own eks.tf reads that cluster with
# data.aws_eks_cluster.existing, and two check blocks
# (existing_eks_cluster_kubernetes_version_matches in eks.tf,
# existing_eks_cluster_needs_its_own_storage_toggle in storage.tf) both depend
# on that data source's result, which reports "known after apply" under
# `command = plan` with mocked providers no matter what. This was confirmed by
# direct experimentation, not assumed:
#
#   - mock_data "aws_eks_cluster" with fixed defaults (the same technique the
#     root module's own tests/defaults.tftest.hcl uses successfully for this
#     identical data source, un-nested): still unknown once nested one module
#     deep via `module.n8n { source = "../.." }`.
#   - override_data targeting the exact nested address,
#     module.n8n.data.aws_eks_cluster.existing[0]: also still unknown.
#   - override_resource on aws_eks_cluster.customer_managed itself, with
#     override_during = plan, to make its name attribute known for the data
#     source's own query key: no change.
#   - Isolating the variable entirely, by hardcoding
#     existing_eks_cluster_name to a bare string literal with zero dependency
#     on any resource or module output: still unknown, identically.
#
# `command = apply` is not an escape hatch either, the same conclusion
# tests/defaults.tftest.hcl's own Redis AUTH-token comment and
# examples/large/tests/defaults.tftest.hcl's Aurora-reference comment already
# reach for other cases: the mocked AWS provider generates non-ARN-format
# strings for computed attributes, and aws_eks_cluster's role_arn schema
# validation rejects them outright.
#
# A "does the normal path plan cleanly" assertion is therefore not possible.
# It is tempting to conclude no run block can pass at all, but that is too
# broad a claim: `expect_failures` on an example-local variable's own
# `validation` block CAN still pass, if (and only if) that variable's
# validation failure cascades widely enough through the config to prevent
# Terraform from ever reaching the two unresolvable check blocks above. Also
# confirmed by direct experimentation, not assumed:
#
#   - cluster_name is used to derive aws_eks_cluster.customer_managed's own
#     name ("${var.cluster_name}-cm"). An invalid cluster_name therefore blocks
#     evaluation of the stand-in cluster resource itself, which transitively
#     blocks data.aws_eks_cluster.existing and both check blocks from ever
#     being reached, so the run's only reported error is the expected
#     cluster_name validation failure. This run block below passes cleanly.
#   - n8n_image_tag and n8n_execution_data_storage_mode's own validation
#     failures do NOT have this property: nothing about the stand-in cluster
#     resource depends on either variable, so the check blocks still get
#     evaluated independently and still hard-error alongside the expected
#     failure, which fails the run even though the expected failure did also
#     occur (a run fails on ANY unexpected error, not just on missing the
#     expected one). Tested directly: both hit the same two check-block errors
#     as a plain, no-failure plan does, whether run alone or in combination.
#     Do not add run blocks for these, or any other variable whose validation
#     failure does not similarly gate the stand-in cluster resource's own
#     evaluation; they will not pass, and it is not a mocking bug to fix.
#
# What this leaves uncovered: an automated proof that a *successful* plan of
# this example's own create_eks = false wiring reaches the module. The
# module's own create_eks = false logic (data.aws_eks_cluster.existing, the
# VPC-mismatch precondition, the Kubernetes-version check, skipping every
# module-managed cluster resource) is already covered by 400+ run blocks in
# the repo root's tests/defaults.tftest.hcl, tested directly rather than
# through an example wrapper, where this nested-module mocking limitation does
# not apply. This example's own contribution beyond the run blocks below is
# a realistic, tested-by-hand reference configuration: terraform validate,
# terraform fmt, and tflint all pass against it, and terraform plan/apply
# against real AWS credentials is the way to exercise it end to end.

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

run "cluster_name_length_validation_rejects_empty" {
  command = plan

  variables {
    cluster_name = ""
  }

  expect_failures = [var.cluster_name]
}

# The customer_managed_node_* group is reachable here for the same reason
# cluster_name is, and for the reason examples/customer-managed-everything's
# header comment sets out: these feed aws_eks_node_group.customer_managed
# directly rather than passing through module "n8n". Measured, not assumed.

run "customer_managed_node_instance_type_rejects_malformed_type" {
  command = plan

  variables {
    customer_managed_node_instance_type = "NotAnInstanceType"
  }

  expect_failures = [var.customer_managed_node_instance_type]
}

run "customer_managed_node_min_rejects_zero" {
  command = plan

  variables {
    customer_managed_node_min     = 0
    customer_managed_node_desired = 0
  }

  expect_failures = [var.customer_managed_node_min]
}

run "customer_managed_node_desired_rejects_above_max" {
  command = plan

  variables {
    customer_managed_node_desired = 99
  }

  expect_failures = [var.customer_managed_node_desired]
}
