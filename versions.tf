# ── Terraform & provider requirements ──────────────────────────────────────
# Declares the minimum Terraform CLI and the providers this module needs.
# Provider configuration (region, auth, kube/helm wiring) is the caller's job
# — see examples/small/providers.tf.

terraform {
  # Four features set this floor, and the highest one wins:
  #
  #   1.9:  cross-variable references in validation blocks, e.g.
  #          var.route53_zone_id's validation referencing var.certificate_arn.
  #          Used throughout variables.tf.
  #   1.11: override_resource's override_during attribute, which
  #          examples/customer-managed-redis and -s3 need to assert a
  #          plan-time value on a resource the same configuration creates.
  #          Silently ignored before 1.11 rather than rejected, so a caller
  #          below this floor gets a confusing assertion failure from
  #          `terraform test` instead of a version error.
  #          examples/customer-managed-cluster tried the same technique for a
  #          different problem (see its own versions.tf) and it did not work
  #          there; that example's floor is inherited from the module's,
  #          not from override_during.
  #   1.12: short-circuit evaluation of && and || (hashicorp/terraform#36224):
  #          errors and unknowns on the side the left operand already
  #          decides are discarded. On 1.11 both sides were evaluated, so a
  #          `var.x == null || <expression on var.x>` validation aborted the
  #          plan instead of passing or failing cleanly (#167, #175).
  #   1.13: a `terraform test` that can run this repo's own suites. On 1.12.x
  #          and older (also seen on 1.9.8 and 1.11.4) it leaves about one
  #          provider plugin process (~70 MB) running per run block;
  #          measured locally, 1.12.0 reached 199 provider processes and
  #          14 GB after ~185 runs (1.12.2 leaks the same way), so the
  #          806-run tests/defaults.tftest.hcl is killed on a 16 GB CI
  #          runner. 1.13.0 stays at 5 processes and runs the whole root
  #          suite in about 80 seconds. The leak is specific to
  #          `terraform test`, not to the module code, but this floor now
  #          makes init reject 1.12 as well.
  #
  # Declared as >= 1.13 in all thirteen required_version declarations in the
  # repo. CI's test-floor job runs every test suite on TF_FLOOR_VERSION
  # (1.13.0), and tests/scripts/check-terraform-floor.sh keeps the two
  # equal, so the floor is a claim CI actually exercises rather than one
  # nobody checks.
  required_version = ">= 1.13"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.14"
    }
  }
}
