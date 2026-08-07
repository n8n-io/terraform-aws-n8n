# Roadmap

This roadmap captures intent, not commitments. Items here are not on a
fixed timeline. See [`CHANGELOG.md`](./CHANGELOG.md) for what has
actually shipped.

## Phases

### Phase 1: Internal baseline

A minimal, lean Terraform module that is ready for publishing and
validated through n8n-internal testing.

### Phase 2: Lighthouse rollout

Publish the module and evaluate it through lighthouse customer
engagements, iterating early on real-world feedback.

### Phase 3: Multi-cloud expansion

Apply the learnings from the AWS module to sibling modules for deploying
n8n on Azure and GCP, reusing shared patterns.

## Candidate features

Features we may want to address along the way:

- Custom ENV variables via templates (SSO, Owner, etc.). The variables
  themselves are documented; what is missing is a worked example in
  `examples/`, so this stays open until one lands.
- Bring your own Secrets Manager. Scoped on 2026-08-05 to n8n's own External
  Secrets feature: workflow credentials resolved from a vault at runtime, which
  is Enterprise-gated and inert on Community. The module's part is the IAM
  policy and the Pod Identity wiring that let n8n reach AWS Secrets Manager
  without a static access key, plus a boundary that keeps the module's own
  credentials out of reach. The vault connection itself is created in the n8n
  UI and cannot be set from Terraform. Sourcing the module's own credentials
  (encryption key, DB password, Redis token, licence key) from Secrets Manager
  is a separate question and is not part of this item.

## Already shipped

Previously listed as candidates, now covered by the module or by n8n itself:

- **Install community packages via API.** `n8n_reinstall_missing_packages`,
  `n8n_community_packages_registry` and
  `n8n_community_packages_prevent_loading` expose the relevant n8n settings,
  and the API surface itself is n8n's, documented in the n8n docs.
- **Bring your own Certificates.** `certificate_arn` takes a pre-validated ACM
  certificate for any DNS provider; `examples/cloudflare` and
  `examples/godaddy` issue one outside Route53. `route53_zone_id` is the
  automated alternative, and exactly one of the two is required.
- **Bring your own Networking.** `vpc_id`, `private_subnets`, `public_subnets`
  and `vpc_cidr_block` are all required inputs, and the module creates no VPC,
  subnet, or NAT gateway. Bring-your-own is the only networking mode it has.
