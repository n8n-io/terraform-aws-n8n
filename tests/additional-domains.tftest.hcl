# Plan-time tests for n8n_additional_domains (subject alternative names).
#
# Separate from defaults.tftest.hcl because mock_provider is file-scoped and
# these runs need a different one. The check block in dns.tf compares the
# number of Route 53 validation records against the number of names on the
# certificate, so the mocked domain_validation_options has to mirror the domain
# set each run configures. defaults.tftest.hcl mocks a single-name certificate;
# this file mocks a three-name one.
#
# Run: terraform test
#   (from the module root)

mock_provider "aws" {
  # What ACM returns for a certificate with a primary domain and two SANs: one
  # validation option per name. The module selects the option matching each
  # domain, so a run configuring fewer names simply selects fewer options.
  mock_resource "aws_acm_certificate" {
    defaults = {
      domain_validation_options = [
        {
          domain_name           = "n8n.test.example.com"
          resource_record_name  = "_acme-challenge.n8n.test.example.com."
          resource_record_type  = "CNAME"
          resource_record_value = "_validation.acm-validations.aws."
        },
        {
          domain_name           = "hooks.test.example.com"
          resource_record_name  = "_acme-challenge.hooks.test.example.com."
          resource_record_type  = "CNAME"
          resource_record_value = "_validation2.acm-validations.aws."
        },
        {
          domain_name           = "mcp.test.example.com"
          resource_record_name  = "_acme-challenge.mcp.test.example.com."
          resource_record_type  = "CNAME"
          resource_record_value = "_validation3.acm-validations.aws."
        },
      ]
    }
  }

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/test"
      user_id    = "AIDATESTUSER"
    }
  }

  override_data {
    target = data.aws_iam_policy_document.lbc
    values = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"elasticloadbalancing:*\"],\"Resource\":\"*\"}]}"
    }
  }
}

mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "random" {}
mock_provider "time" {}

variables {
  aws_region      = "us-east-1"
  cluster_name    = "n8n-cluster"
  n8n_domain      = "n8n.test.example.com"
  vpc_id          = "vpc-test12345"
  private_subnets = ["subnet-priv1", "subnet-priv2", "subnet-priv3"]
  public_subnets  = ["subnet-pub1", "subnet-pub2", "subnet-pub3"]
  vpc_cidr_block  = "10.0.0.0/16"

  # The Route 53 path, since that is the only one where the module issues the
  # certificate and can add names to it.
  certificate_arn = null
  route53_zone_id = "Z0TEST123456789"

  n8n_additional_domains = ["hooks.test.example.com", "mcp.test.example.com"]

  n8n_license_key = "test-license-key-not-real"
}

# ── Additional domains (subject alternative names) ────────────────────────────
# local.acm_domain_names feeds four consumers: the certificate's domain_name and
# subject_alternative_names, the Route 53 validation records, the alias records,
# and the Ingress host rules. All four are asserted below. The Route 53 half is
# reachable because the mocked domain_validation_options carries an entry per
# test domain, mirroring what ACM returns for a multi-name certificate.
#
# The consequential one is the validation-record count. A name on the
# certificate with no validation record does not fail the plan: the apply hangs
# in aws_acm_certificate_validation until it times out, which is a slow and
# confusing way to discover a typo.

run "additional_domains_fan_out_across_cert_dns_and_ingress" {
  command = plan

  variables {
    certificate_arn        = null
    route53_zone_id        = "Z0TEST123456789"
    n8n_additional_domains = ["hooks.test.example.com", "mcp.test.example.com"]
  }

  assert {
    condition     = aws_acm_certificate.n8n[0].domain_name == "n8n.test.example.com"
    error_message = "n8n_domain must remain the certificate's primary domain_name"
  }

  assert {
    condition     = toset(aws_acm_certificate.n8n[0].subject_alternative_names) == toset(["hooks.test.example.com", "mcp.test.example.com"])
    error_message = "Every additional domain must be added to the certificate as a subject alternative name"
  }

  # The one that prevents the hanging apply.
  assert {
    condition     = length(aws_route53_record.cert_validation) == 3
    error_message = "Each name on the certificate needs its own Route 53 validation record"
  }

  assert {
    condition = toset(keys(aws_route53_record.cert_validation)) == toset([
      "n8n.test.example.com", "hooks.test.example.com", "mcp.test.example.com",
    ])
    error_message = "Validation records must be keyed by every certificate name, primary included"
  }

  # The record's name/type/records come from the certificate's computed
  # domain_validation_options, so their values stay unknown at plan and cannot
  # be asserted here. The keys above are what matter: they are what determines
  # whether a certificate name gets a record at all.

  assert {
    condition     = length(aws_route53_record.n8n_alias) == 1
    error_message = "The primary domain keeps its own alias record"
  }

  assert {
    condition = toset(keys(aws_route53_record.n8n_alias_additional)) == toset([
      "hooks.test.example.com", "mcp.test.example.com",
    ])
    error_message = "Each additional domain needs an alias A-record pointing at the ALB"
  }

  assert {
    condition     = length(kubernetes_ingress_v1.n8n[0].spec[0].rule) == 3
    error_message = "Each additional domain needs an Ingress rule or the ALB will not route it"
  }
}

# ACM stores certificate names in lowercase, so the validation-record lookups
# in dns.tf match each entry of local.acm_domain_names against a lowercased
# domain_validation_options. A mixed-case input must therefore be normalized
# before it becomes a for_each key, an Ingress host, or a certificate name:
# without lower(), the lookup finds no matching validation option and the
# apply fails pointing at the record rather than the casing. The mocked
# domain_validation_options above is all-lowercase, mirroring ACM.
run "mixed_case_domains_are_normalized_to_lowercase" {
  command = plan

  variables {
    certificate_arn        = null
    route53_zone_id        = "Z0TEST123456789"
    n8n_additional_domains = ["Hooks.Test.Example.com"]
  }

  assert {
    condition     = toset(aws_acm_certificate.n8n[0].subject_alternative_names) == toset(["hooks.test.example.com"])
    error_message = "Subject alternative names must be lowercased before reaching ACM"
  }

  assert {
    condition = toset(keys(aws_route53_record.cert_validation)) == toset([
      "n8n.test.example.com", "hooks.test.example.com",
    ])
    error_message = "Validation records must be keyed by the lowercased names, matching what ACM returns in domain_validation_options"
  }

  assert {
    condition = toset(keys(aws_route53_record.n8n_alias_additional)) == toset([
      "hooks.test.example.com",
    ])
    error_message = "Alias records must be keyed by the lowercased names, aligned with the validation records"
  }

  assert {
    condition     = kubernetes_ingress_v1.n8n[0].spec[0].rule[1].host == "hooks.test.example.com"
    error_message = "Ingress hosts must be lowercased; Kubernetes rejects uppercase hostnames"
  }
}

# Guard the empty case on the Route 53 path specifically: subject_alternative_names
# must be null rather than [], since it is ForceNew and an empty list would show
# a diff on deployments that predate this input.
run "no_additional_domains_leaves_the_certificate_single_named" {
  command = plan

  variables {
    certificate_arn = null
    route53_zone_id = "Z0TEST123456789"

    # Overrides the file-level default; this run is the empty case.
    n8n_additional_domains = []
  }

  # subject_alternative_names itself cannot be asserted here: passing null makes
  # it Optional+Computed, so the plan value is unknown. The observable
  # consequence is asserted instead, and the no-diff behaviour on an existing
  # deployment was confirmed by the live 0.2.0 upgrade.
  assert {
    condition     = length(aws_route53_record.cert_validation) == 1
    error_message = "Only the primary domain should have a validation record by default"
  }

  assert {
    condition     = length(aws_route53_record.n8n_alias_additional) == 0
    error_message = "No additional alias records should exist by default"
  }
}

# The footgun: the module cannot add names to a certificate it did not issue,
# so the Ingress would route a hostname the certificate does not cover.
run "additional_domains_warn_when_the_certificate_is_caller_supplied" {
  command = plan

  variables {
    certificate_arn        = "arn:aws:acm:us-east-1:123456789012:certificate/test-cert"
    route53_zone_id        = null
    n8n_additional_domains = ["hooks.test.example.com"]
  }

  expect_failures = [check.additional_domains_need_a_certificate_that_covers_them]
}

# A caller owning its Ingress resources still gets a usable multi-name
# certificate: every name is on it and every name has a validation record. Only
# routing and the alias records are theirs, which is what create_ingress = false
# means. examples/split-ingress consumes this through the certificate_arn output.
run "additional_domains_still_yield_a_usable_certificate_for_a_caller_owned_ingress" {
  command = plan

  variables {
    certificate_arn        = null
    route53_zone_id        = "Z0TEST123456789"
    create_ingress         = false
    n8n_additional_domains = ["hooks.test.example.com"]
  }

  assert {
    condition     = toset(aws_acm_certificate.n8n[0].subject_alternative_names) == toset(["hooks.test.example.com"])
    error_message = "The certificate must still carry the additional names when the caller owns the Ingress"
  }

  assert {
    condition = toset(keys(aws_route53_record.cert_validation)) == toset([
      "n8n.test.example.com", "hooks.test.example.com",
    ])
    error_message = "Validation records must still be written for every name, or the certificate never validates"
  }

  assert {
    condition     = length(kubernetes_ingress_v1.n8n) == 0
    error_message = "No module Ingress should exist when create_ingress = false"
  }

  assert {
    condition     = length(aws_route53_record.n8n_alias_additional) == 0
    error_message = "Alias records belong to the caller when it owns the load balancers"
  }
}

run "additional_domains_add_an_ingress_rule_each" {
  command = plan

  variables {
    certificate_arn        = null
    route53_zone_id        = "Z0TEST123456789"
    n8n_additional_domains = ["hooks.test.example.com", "mcp.test.example.com"]
  }

  assert {
    condition     = length(kubernetes_ingress_v1.n8n[0].spec[0].rule) == 3
    error_message = "Each additional domain should add an Ingress rule alongside the primary host"
  }

  assert {
    condition     = kubernetes_ingress_v1.n8n[0].spec[0].rule[0].host == "n8n.test.example.com"
    error_message = "n8n_domain must stay first; it is the canonical host n8n advertises"
  }

  assert {
    condition = tolist([
      for r in kubernetes_ingress_v1.n8n[0].spec[0].rule : r.host
    ]) == tolist(["n8n.test.example.com", "hooks.test.example.com", "mcp.test.example.com"])
    error_message = "Ingress hosts should be n8n_domain followed by n8n_additional_domains in order"
  }

  # An extra hostname is useless if it only reaches the editor, so every host
  # must carry the full path set, webhook prefixes included.
  assert {
    condition = alltrue([
      for r in kubernetes_ingress_v1.n8n[0].spec[0].rule :
      length(r.http[0].path) == length(local.n8n_webhook_path_prefixes) + 1
    ])
    error_message = "Every host rule must carry the webhook prefixes plus the catch-all"
  }
}

# Regression guard for the dynamic rule block: with no additional domains the
# Ingress must render exactly what it rendered before the block existed, so
# existing deployments see no diff.
run "no_additional_domains_keeps_a_single_ingress_rule" {
  command = plan

  variables {
    n8n_additional_domains = []
  }

  assert {
    condition     = length(kubernetes_ingress_v1.n8n[0].spec[0].rule) == 1
    error_message = "The default must remain a single host rule"
  }

  assert {
    condition     = kubernetes_ingress_v1.n8n[0].spec[0].rule[0].host == "n8n.test.example.com"
    error_message = "The single rule should be keyed on n8n_domain"
  }
}

run "additional_domains_reject_the_primary_domain" {
  command = plan

  variables {
    n8n_additional_domains = ["n8n.test.example.com"]
  }

  expect_failures = [var.n8n_additional_domains]
}

run "additional_domains_reject_duplicates" {
  command = plan

  variables {
    n8n_additional_domains = ["hooks.test.example.com", "hooks.test.example.com"]
  }

  expect_failures = [var.n8n_additional_domains]
}

run "additional_domains_reject_a_malformed_hostname" {
  command = plan

  variables {
    n8n_additional_domains = ["not a hostname"]
  }

  expect_failures = [var.n8n_additional_domains]
}

# ACM allows 10 names per certificate including the primary, so the tenth
# addition is the one that must be refused.
run "additional_domains_reject_more_than_the_acm_quota" {
  command = plan

  variables {
    n8n_additional_domains = [
      "a.test.example.com", "b.test.example.com", "c.test.example.com",
      "d.test.example.com", "e.test.example.com", "f.test.example.com",
      "g.test.example.com", "h.test.example.com", "i.test.example.com",
      "j.test.example.com",
    ]
  }

  expect_failures = [var.n8n_additional_domains]
}

