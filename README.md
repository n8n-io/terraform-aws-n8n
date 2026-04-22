# terraform-aws-n8n

Terraform module for deploying [n8n](https://n8n.io) on AWS.

This Terraform configuration deploys the production-grade multi-main setup from Part B of `EKS.md`: multiple n8n main instances, dedicated worker pods, external PostgreSQL (RDS), Redis (ElastiCache), and S3 for shared file storage. An **n8n Enterprise license is required**.

Foundation resources (VPC, ACM certificate) live in the sibling [`./prerequisites/`](./prerequisites/) workspace so the one human-in-the-loop step (adding a DNS record at your registrar) is isolated from the application stack.

## Goals

### Phase 1 - Internal baseline

A minimal, lean Terraform module that is ready for publishing and validated through n8n-internal testing.

### Phase 2 - Lighthouse rollout

Publish the module and evaluate it through lighthouse customer engagements, iterating early on real-world feedback.

### Phase 3 - Multi-cloud expansion

Apply the learnings from the AWS module to sibling modules for deploying n8n on Azure and GCP, reusing shared patterns.

### Candidate features

Features we may want to address along the way:

- Custom ENV variables via templates (SSO, Owner, etc.)
- Install community packages via API
- Bring your own Secrets Manager
- Bring your own Certificates
- Bring your own Networking

## Usage

```hcl
module "n8n" {
  source = "github.com/n8n-io/terraform-aws-n8n"
}
```

## Requirements

| Name      | Version |
|-----------|---------|
| terraform | >= 1.5  |
| aws       | >= 5.0  |

## Inputs

_None yet._

## Outputs

_None yet._
