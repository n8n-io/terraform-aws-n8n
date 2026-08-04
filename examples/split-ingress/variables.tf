variable "aws_region" {
  description = "AWS region to deploy into (e.g. us-east-1, eu-west-1, ap-southeast-1)."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name for the EKS cluster. Keep to 14 characters or fewer, because the module derives an ElastiCache cluster ID of `<cluster_name>-redis`, and AWS caps ElastiCache IDs at 20 chars."
  type        = string
  default     = "n8n-cluster"

  validation {
    condition     = length(var.cluster_name) <= 14
    error_message = "cluster_name must be 14 characters or fewer."
  }
}

variable "n8n_domain" {
  description = "Fully-qualified domain name for the n8n editor UI and REST API (e.g. n8n.example.com). Served by the internal ALB, so it resolves to private addresses and is reachable only from inside the VPC or over VPN. The parent zone must be hosted in Route53."
  type        = string
}

variable "webhook_subdomain" {
  description = "Label prepended to n8n_domain to form the public webhook hostname. With the default and n8n_domain = n8n.example.com, webhooks are served from hooks.n8n.example.com by the internet-facing ALB. A separate hostname is required because a DNS name can alias only one load balancer."
  type        = string
  default     = "hooks"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", var.webhook_subdomain))
    error_message = "webhook_subdomain must be a single lowercase DNS label: letters, digits and hyphens, not starting or ending with a hyphen."
  }
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID for the parent of n8n_domain (e.g. the zone for example.com if n8n_domain = n8n.example.com). Passed through to the module, which issues the ACM certificate covering both hostnames and writes its validation records here. This example writes both alias A-records in the same zone, since it owns the two load balancers."
  type        = string
}

variable "n8n_license_key" {
  description = "n8n Enterprise license activation key. Get one at https://n8n.io/pricing"
  type        = string
  sensitive   = true
}

variable "n8n_image_tag" {
  description = "n8n application image tag to deploy (e.g. \"2.33.1\"). Leave null to use the Helm chart's floating `stable` tag. Pin a concrete version when the n8n version is part of what you are testing."
  type        = string
  default     = null
}

variable "waf_acl_arn" {
  description = "ARN of a WAFv2 web ACL to attach to the public webhook ALB. Isolating untrusted traffic on its own load balancer is what makes this practical: rate limiting and managed rule groups apply to webhook senders without touching the editor UI. Leave null to skip the association. The ACL must be regional (scope = REGIONAL) and in the same region as the ALB."
  type        = string
  default     = null
}

variable "admin_allowed_cidr_blocks" {
  description = "CIDR blocks allowed to reach the internal admin ALB, applied as alb.ingress.kubernetes.io/inbound-cidrs. The ALB is already private, so this is defence in depth: narrow it to your VPN pool or bastion range. Empty (the default) allows any source that can route to the private subnets."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.admin_allowed_cidr_blocks : can(cidrnetmask(c))])
    error_message = "Each entry in admin_allowed_cidr_blocks must be a valid IPv4 CIDR block (e.g. 10.20.0.0/16)."
  }
}

variable "ssl_policy" {
  description = "TLS negotiation policy for both ALB HTTPS listeners. The default is TLS 1.3 with a 1.2 fallback, which AWS recommends for new deployments. Loosen it only if you must support clients that predate TLS 1.2."
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-2021-06"
}

variable "n8n_execution_data_storage_mode" {
  description = "Where n8n stores the data of each new execution. Passed to the module's n8n_execution_data_storage_mode. \"database\" keeps execution data in PostgreSQL; \"s3\" offloads it to the S3 bucket the module already creates for binary data. This example runs the module's default database (db.t3.small on 50 GB of gp2, a 150 IOPS baseline), which has the least room of any sizing this module ships to absorb execution-data growth, so reaching for this is often cheaper than resizing the database. Requires n8n >= 2.27 (pin n8n_image_tag accordingly) and an Enterprise license carrying the feat:executionDataS3 entitlement, which is not the same one binary data offload uses. There is no backfill: existing executions stay readable where they were written. Read the execution data section of the root README before enabling it, in particular the durability trade-off and the S3 lifecycle constraint."
  type        = string
  default     = "database"
  nullable    = false

  validation {
    condition     = contains(["database", "s3"], var.n8n_execution_data_storage_mode)
    error_message = "n8n_execution_data_storage_mode must be either \"database\" or \"s3\"."
  }
}

variable "tags" {
  description = "Additional AWS tags to apply to every resource this example creates."
  type        = map(string)
  default     = {}
}
