# ── Terraform & provider requirements ──────────────────────────────────────
# Declares the minimum Terraform CLI and the providers this module needs.
# Provider configuration (region, auth, kube/helm wiring) is the caller's job
# — see examples/small/providers.tf.

terraform {
  # Two features set this floor, and the higher one wins:
  #
  #   1.9:  cross-variable references in validation blocks, e.g.
  #          var.route53_zone_id's validation referencing var.certificate_arn.
  #          Used throughout variables.tf.
  #   1.11: override_resource's override_during attribute, which
  #          examples/customer-managed-redis, -s3 and -cluster need to assert a
  #          plan-time value on a resource the same configuration creates.
  #          Silently ignored before 1.11 rather than rejected, so a caller
  #          below this floor gets a confusing assertion failure from
  #          `terraform test` instead of a version error.
  #
  # 1.10 is also load-bearing in passing: it added short-circuit evaluation of
  # && and ||, which this module's `check` blocks used to have to work around
  # by hand (see AGENTS.md). Declared as >= 1.11 in every versions.tf in the
  # repo and matched by CI's TF_VERSION pin, so the floor is a claim CI
  # actually exercises rather than one nobody checks.
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
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
      version = "~> 0.12"
    }
  }
}
