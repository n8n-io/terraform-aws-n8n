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
  description = "Fully-qualified domain name for n8n (e.g. n8n.example.com). The parent zone must either be hosted in Route53 (pass its ID via route53_zone_id) or covered by a pre-validated ACM certificate (pass its ARN via certificate_arn)."
  type        = string
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID for the parent of n8n_domain. Set this when you want the example to issue the ACM certificate and create the alias record automatically. Set exactly one of route53_zone_id or certificate_arn."
  type        = string
  default     = null
}

variable "certificate_arn" {
  description = "ARN of a pre-validated ACM certificate covering n8n_domain. Set this when you already manage your certificate lifecycle outside this example (for example a wildcard cert reused across multiple deployments). Set exactly one of route53_zone_id or certificate_arn."
  type        = string
  default     = null

  validation {
    condition     = (var.route53_zone_id == null) != (var.certificate_arn == null)
    error_message = "Set exactly one of route53_zone_id or certificate_arn (not both, not neither)."
  }
}

variable "n8n_license_key" {
  description = "n8n Enterprise license activation key. Get one at https://n8n.io/pricing"
  type        = string
  sensitive   = true
}

variable "n8n_image_repository" {
  description = "Container image repository for the n8n application, without a tag (e.g. \"123456789012.dkr.ecr.eu-west-1.amazonaws.com/n8n\"). Leave null to use the Helm chart's own repository (docker.n8n.io/n8nio/n8n). Set this to run a custom image, for example one with community packages baked in so they are not reinstalled on every pod boot. The image must be pullable by the node group's IAM role (ECR in the same account is) or be public, and n8n_task_runner_image_tag usually has to be set alongside it."
  type        = string
  default     = null

  validation {
    condition     = var.n8n_image_repository == null ? true : can(regex("^[a-zA-Z0-9][a-zA-Z0-9._:/-]{0,254}$", var.n8n_image_repository))
    error_message = "n8n_image_repository must be a non-empty image repository reference with no whitespace, containing only alphanumeric characters, dots, underscores, hyphens, slashes, and a colon for a registry port (e.g. \"myregistry.example.com/n8n\"). Set to null to use the chart's default (docker.n8n.io/n8nio/n8n)."
  }

  validation {
    condition     = var.n8n_image_repository == null ? true : !can(regex(":", reverse(split("/", var.n8n_image_repository))[0]))
    error_message = "n8n_image_repository must not include a tag or digest, because the chart appends the tag itself. Pass the version via n8n_image_tag instead."
  }
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

variable "n8n_task_runner_image_tag" {
  description = "Image tag for the task runner sidecar (`n8nio/runners`). Leave null to inherit the n8n application image's tag, which is correct as long as that tag is a published n8n version. Set it to the underlying n8n version when running a custom image whose tag is not one (e.g. n8n_image_tag = \"2.27.4-mypackages\" together with n8n_task_runner_image_tag = \"2.27.4\"); otherwise the sidecar image cannot be pulled and every main and worker pod stays in ImagePullBackOff."
  type        = string
  default     = null

  validation {
    condition     = var.n8n_task_runner_image_tag == null ? true : can(regex("^[a-zA-Z0-9_][a-zA-Z0-9._-]{0,127}$", var.n8n_task_runner_image_tag))
    error_message = "n8n_task_runner_image_tag must be a non-empty string with no whitespace, containing only alphanumeric characters, dots, underscores, and hyphens (e.g. \"2.27.4\"). Set to null to inherit the n8n application image's tag."
  }
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

variable "n8n_execution_data_storage_mode" {
  description = "Where n8n stores the data of each new execution. Passed to the module's n8n_execution_data_storage_mode. \"database\" keeps execution data in PostgreSQL; \"s3\" offloads it to the S3 bucket the module already creates for binary data, which is the main lever for relieving write pressure on the database at this tier's volume. Requires n8n >= 2.27 (pin n8n_image_tag accordingly) and an Enterprise license carrying the feat:executionDataS3 entitlement, which is not the same one binary data offload uses. There is no backfill: existing executions stay readable where they were written. Read the execution data section of the root README before enabling it, in particular the durability trade-off and the S3 lifecycle constraint."
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
