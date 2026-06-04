# Roadmap

This roadmap captures intent, not commitments. Items here are not on a
fixed timeline. See [`CHANGELOG.md`](./CHANGELOG.md) for what has
actually shipped.

## Phases

### Phase 1 — Internal baseline

A minimal, lean Terraform module that is ready for publishing and
validated through n8n-internal testing.

### Phase 2 — Lighthouse rollout

Publish the module and evaluate it through lighthouse customer
engagements, iterating early on real-world feedback.

### Phase 3 — Multi-cloud expansion

Apply the learnings from the AWS module to sibling modules for deploying
n8n on Azure and GCP, reusing shared patterns.

## Candidate features

Features we may want to address along the way:

- Custom ENV variables via templates (SSO, Owner, etc.)
- Install community packages via API
- Bring your own Secrets Manager
- Bring your own Certificates
- Bring your own Networking
