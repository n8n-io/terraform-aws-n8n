variable "aws_region" {
  description = "AWS region to deploy into (e.g. us-east-1, eu-west-1, ap-southeast-1)."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name for the EKS cluster. Keep to 14 characters or fewer — the module derives an ElastiCache cluster ID of `<cluster_name>-redis`, and AWS caps ElastiCache IDs at 20 chars."
  type        = string
  default     = "n8n-large"

  validation {
    condition     = length(var.cluster_name) <= 14
    error_message = "cluster_name must be 14 characters or fewer."
  }
}

variable "n8n_domain" {
  description = "Fully-qualified domain name for n8n (e.g. n8n.example.com). The parent zone must be hosted in Route53 (pass its ID via route53_zone_id)."
  type        = string
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID for the parent of n8n_domain."
  type        = string
}

variable "n8n_license_key" {
  description = "n8n Enterprise license activation key. Get one at https://n8n.io/pricing"
  type        = string
  sensitive   = true
}

variable "aurora_instance_class" {
  description = "Aurora PostgreSQL instance class for both the writer and reader. db.r6g.8xlarge (32 vCPU, 256 GB) is validated for this example's target throughput of ~50–60+M executions/day. Scale down for lower throughput targets or Reserved Instance pricing."
  type        = string
  default     = "db.r6g.8xlarge"

  validation {
    condition     = can(regex("^db\\.", var.aurora_instance_class))
    error_message = "Value must be a valid RDS instance class (e.g. db.r6g.8xlarge)."
  }
}

variable "tags" {
  description = "Additional AWS tags to apply to every resource this example creates."
  type        = map(string)
  default     = {}
}
