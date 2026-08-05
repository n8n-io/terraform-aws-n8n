variable "aws_region" {
  description = "AWS region to deploy into (e.g. us-east-1, eu-west-1, ap-southeast-1)."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name for the EKS cluster. Keep to 14 characters or fewer — the module derives an ElastiCache cluster ID of `<cluster_name>-redis`, and AWS caps ElastiCache IDs at 20 chars."
  type        = string
  default     = "n8n-cluster"

  validation {
    condition     = length(var.cluster_name) <= 14
    error_message = "cluster_name must be 14 characters or fewer."
  }
}

variable "n8n_domain" {
  description = "Fully-qualified domain name for n8n (e.g. n8n.example.com). Must be a single label below godaddy_domain (e.g. 'n8n' below 'example.com'). Deeper nesting like 'n8n.prod.example.com' under 'example.com' is not supported by this example's name-stripping logic — host such records under godaddy_domain = 'prod.example.com' instead."
  type        = string

  validation {
    condition     = endswith(var.n8n_domain, ".${var.godaddy_domain}") && length(split(".", trimsuffix(var.n8n_domain, ".${var.godaddy_domain}"))) == 1
    error_message = "n8n_domain must be a single label directly below godaddy_domain (e.g. n8n.example.com when godaddy_domain = example.com)."
  }
}

variable "godaddy_domain" {
  description = "GoDaddy domain name that contains n8n_domain (e.g. example.com if n8n_domain = n8n.example.com). The module creates ACM certificate validation records and a CNAME record in this domain."
  type        = string
}

variable "godaddy_api_key" {
  description = "GoDaddy API key with DNS write permissions. Create one at https://developer.godaddy.com/keys. Can also be supplied via the GODADDY_API_KEY environment variable."
  type        = string
  sensitive   = true
}

variable "godaddy_api_secret" {
  description = "GoDaddy API secret corresponding to godaddy_api_key. Can also be supplied via the GODADDY_API_SECRET environment variable."
  type        = string
  sensitive   = true
}

variable "n8n_license_key" {
  description = "n8n Enterprise license activation key. Get one at https://n8n.io/pricing"
  type        = string
  sensitive   = true
}

variable "n8n_image_tag" {
  description = "n8n application image tag to deploy (e.g. \"2.27.4\"). Leave null to use the Helm chart's floating `stable` tag. Pin a concrete version for reproducible upgrades and to avoid crossing major-version boundaries on an unplanned pod reschedule."
  type        = string
  default     = null

  validation {
    condition     = var.n8n_image_tag == null ? true : can(regex("^[a-zA-Z0-9_][a-zA-Z0-9._-]{0,127}$", var.n8n_image_tag))
    error_message = "n8n_image_tag must be a non-empty string with no whitespace, containing only alphanumeric characters, dots, underscores, and hyphens (e.g. \"1.2.3\", \"1.2.3-alpine\"). Set to null to use the chart's default (stable)."
  }
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
  description = "Additional AWS tags to apply to all resources this example creates. Merged on top of the built-in ManagedBy/Project tags."
  type        = map(string)
  default     = {}
}
