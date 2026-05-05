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
  description = "Fully-qualified domain name for n8n (e.g. n8n.example.com). Must be a subdomain of godaddy_domain."
  type        = string
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

variable "tags" {
  description = "Additional AWS tags to apply to every resource this example creates."
  type        = map(string)
  default     = {}
}
