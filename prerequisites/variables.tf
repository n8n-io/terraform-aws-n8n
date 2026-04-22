variable "aws_region" {
  description = "AWS region to deploy into (e.g. us-east-1, eu-west-1, ap-southeast-1). Must match the region the root module is applied in."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name for the EKS cluster that will consume this VPC. Keep to 14 characters or fewer so the root module (which derives an ElastiCache cluster ID of `<cluster_name>-redis`, capped at 20 chars) stays within AWS limits."
  type        = string
  default     = "n8n-cluster"

  validation {
    condition     = length(var.cluster_name) <= 14
    error_message = "cluster_name must be 14 characters or fewer so the root module can derive a valid ElastiCache cluster ID (cluster_name + '-redis' <= 20 chars)."
  }
}

variable "n8n_domain" {
  description = "Fully-qualified domain name for n8n (e.g. n8n.example.com). You must own this domain and be able to edit its DNS records — the ACM certificate is DNS-validated."
  type        = string
}

variable "tags" {
  description = "Additional AWS tags to apply to all resources created by this workspace. Merged on top of the built-in ManagedBy/Project tags."
  type        = map(string)
  default     = {}
}
