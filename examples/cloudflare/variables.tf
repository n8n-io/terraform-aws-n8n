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
  description = "Fully-qualified domain name for n8n (e.g. n8n.example.com). Must be a subdomain of the zone identified by cloudflare_zone_id."
  type        = string
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID for the domain that contains n8n_domain. Find it on the Overview page of your zone in the Cloudflare dashboard."
  type        = string
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token with Zone:DNS:Edit permission for the zone. Create one at https://dash.cloudflare.com/profile/api-tokens. Can also be supplied via the CLOUDFLARE_API_TOKEN environment variable."
  type        = string
  sensitive   = true
}

variable "n8n_license_key" {
  description = "n8n Enterprise license activation key. Get one at https://n8n.io/pricing"
  type        = string
  sensitive   = true
}

variable "tags" {
  description = "Additional AWS tags to apply to every resource this example creates."
  type        = map(string)
  default     = {}
}
