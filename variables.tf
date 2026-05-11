# ── Foundation inputs ─────────────────────────────────────────────────────────
# Region, cluster naming, and the pre-built VPC + ACM certificate the module
# deploys into. Supply these from a VPC module (e.g. terraform-aws-modules/vpc)
# and an aws_acm_certificate_validation resource — see examples/complete/.

variable "aws_region" {
  description = "AWS region to deploy into (e.g. us-east-1, eu-west-1, ap-southeast-1). Must match the region the AWS provider is configured for."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.aws_region))
    error_message = "Value must be a valid AWS region (e.g. us-east-1, eu-west-1)."
  }
}

variable "cluster_name" {
  description = "Name for the EKS cluster. Keep to 14 characters or fewer — the module derives an ElastiCache cluster ID of `<cluster_name>-redis`, and AWS caps ElastiCache IDs at 20 chars."
  type        = string
  default     = "n8n-cluster"

  validation {
    condition     = length(var.cluster_name) <= 14
    error_message = "cluster_name must be 14 characters or fewer (ElastiCache cluster ID <cluster_name>-redis must stay <= 20 chars)."
  }
}

variable "n8n_domain" {
  description = "Fully-qualified domain name for n8n (e.g. n8n.example.com). Must match the CN / SAN on the certificate provided via certificate_arn."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$", var.n8n_domain))
    error_message = "Value must be a valid fully qualified domain name (e.g. n8n.example.com)."
  }
}

variable "vpc_id" {
  description = "ID of the VPC n8n will deploy into. Must contain both public and private subnets with the EKS/ALB subnet tags applied."
  type        = string

  validation {
    condition     = can(regex("^vpc-[a-zA-Z0-9]+$", var.vpc_id))
    error_message = "Value must be a valid VPC ID (e.g. vpc-0123456789abcdef0)."
  }
}

variable "private_subnets" {
  description = "IDs of private subnets (one per AZ, minimum two AZs). RDS, ElastiCache, and EKS nodes attach here."
  type        = list(string)

  validation {
    condition     = length(var.private_subnets) >= 2
    error_message = "At least two private subnets in different AZs are required for RDS Multi-AZ and EKS."
  }
}

variable "public_subnets" {
  description = "IDs of public subnets (one per AZ, minimum two AZs). The ALB attaches here."
  type        = list(string)

  validation {
    condition     = length(var.public_subnets) >= 2
    error_message = "At least two public subnets in different AZs are required for the ALB."
  }
}

variable "vpc_cidr_block" {
  description = "CIDR block of the VPC — used by the RDS and Redis security groups to allow intra-VPC traffic."
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr_block, 0))
    error_message = "Value must be a valid CIDR block (e.g. 10.0.0.0/16)."
  }
}

variable "certificate_arn" {
  description = "ARN of a pre-validated ACM certificate for n8n_domain. Use this for Cloudflare, GoDaddy, or any DNS provider other than Route53 — the respective examples (examples/cloudflare, examples/godaddy) issue the certificate and pass its ARN here. Set exactly one of certificate_arn or route53_zone_id."
  type        = string
  default     = null
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID for the parent of n8n_domain (e.g. the zone for example.com if n8n_domain = n8n.example.com). When set, the module issues a DNS-validated ACM certificate and creates the alias A-record automatically — single terraform apply, no manual DNS steps. Leave null and pass certificate_arn instead. Set exactly one of certificate_arn or route53_zone_id."
  type        = string
  default     = null

  validation {
    condition     = (var.certificate_arn == null) != (var.route53_zone_id == null)
    error_message = "Set exactly one of certificate_arn or route53_zone_id."
  }
}

variable "tags" {
  description = "Additional AWS tags to apply to all resources this module creates. Merged on top of the built-in ManagedBy/Project tags."
  type        = map(string)
  default     = {}
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.35"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+$", var.kubernetes_version))
    error_message = "Value must be a Kubernetes version (e.g. 1.35)."
  }
}

variable "n8n_webhook_url" {
  description = "Public HTTPS base URL used for webhook callbacks (e.g. https://webhooks.example.com). Defaults to https://<n8n_domain> when not set. Override when webhooks are served from a different host than the n8n UI."
  type        = string
  default     = null
}

variable "n8n_license_key" {
  description = "n8n Enterprise license activation key. Get one at https://n8n.io/pricing"
  type        = string
  sensitive   = true
}

variable "namespace" {
  description = "Kubernetes namespace to deploy n8n into"
  type        = string
  default     = "n8n"
}

# ── Nodes ─────────────────────────────────────────────────────────────────────
# Multi-main runs 6+ pods (2 main, 2 workers, 2 webhook processors).
# 3 × t3.medium provides enough headroom at startup; HPA scales further.

variable "node_instance_type" {
  description = "EC2 instance type for EKS worker nodes. t3.xlarge (4 vCPU, 16GB) is the recommended minimum for multi-main — the 6 n8n pods (main × 2, worker × 2, webhook × 2) request ~3,600m CPU at minimum replicas, leaving t3.medium nodes with insufficient headroom for HPA to scale."
  type        = string
  default     = "t3.xlarge"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]*\\.[a-z0-9]+$", var.node_instance_type))
    error_message = "Value must be a valid EC2 instance type (e.g. t3.xlarge, m5.large)."
  }
}

variable "node_desired" {
  description = "Desired number of worker nodes at startup"
  type        = number
  default     = 3

  validation {
    condition     = var.node_desired >= 1
    error_message = "Desired node count must be at least 1."
  }
}

variable "node_min" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 3

  validation {
    condition     = var.node_min >= 1
    error_message = "Minimum node count must be at least 1."
  }
}

variable "node_max" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 6

  validation {
    condition     = var.node_max >= 1
    error_message = "Maximum node count must be at least 1."
  }
}

# ── n8n chart ─────────────────────────────────────────────────────────────────

variable "n8n_chart_version" {
  description = "n8n Helm chart version to deploy"
  type        = string
  default     = "1.4.0"
}

variable "n8n_helm_timeout" {
  description = "Seconds Terraform waits for the n8n Helm release to converge. Increase for large deployments where rolling out 50+ pods (workers + webhook processors + main) exceeds the default. 600s is fine for the default/medium examples; large deployments at 250+ pods need ~1800s."
  type        = number
  default     = 600

  validation {
    condition     = var.n8n_helm_timeout >= 60
    error_message = "n8n_helm_timeout must be at least 60 seconds."
  }
}

variable "n8n_timezone" {
  description = "Timezone for n8n (e.g. UTC, America/New_York, Europe/London)"
  type        = string
  default     = "UTC"
}

# ── n8n resource requests and limits ──────────────────────────────────────────

variable "n8n_main_cpu_request" {
  description = "CPU request for n8n main pods (e.g. 1000m, 500m)"
  type        = string
  default     = "1000m"
}

variable "n8n_main_cpu_limit" {
  description = "CPU limit for n8n main pods (e.g. 2000m, 1000m)"
  type        = string
  default     = "2000m"
}

variable "n8n_main_memory_request" {
  description = "Memory request for n8n main pods (e.g. 2Gi, 1Gi)"
  type        = string
  default     = "2Gi"
}

variable "n8n_main_memory_limit" {
  description = "Memory limit for n8n main pods (e.g. 4Gi, 2Gi)"
  type        = string
  default     = "4Gi"
}

variable "n8n_worker_cpu_request" {
  description = "CPU request for n8n worker pods (e.g. 500m, 1000m)"
  type        = string
  default     = "500m"
}

variable "n8n_worker_cpu_limit" {
  description = "CPU limit for n8n worker pods (e.g. 1000m, 2000m)"
  type        = string
  default     = "1000m"
}

variable "n8n_worker_memory_request" {
  description = "Memory request for n8n worker pods (e.g. 1Gi, 2Gi)"
  type        = string
  default     = "1Gi"
}

variable "n8n_worker_memory_limit" {
  description = "Memory limit for n8n worker pods (e.g. 2Gi, 4Gi)"
  type        = string
  default     = "2Gi"
}

variable "n8n_webhook_cpu_request" {
  description = "CPU request for n8n webhook processor pods (e.g. 300m, 500m)"
  type        = string
  default     = "300m"
}

variable "n8n_webhook_cpu_limit" {
  description = "CPU limit for n8n webhook processor pods (e.g. 800m, 1000m)"
  type        = string
  default     = "800m"
}

variable "n8n_webhook_memory_request" {
  description = "Memory request for n8n webhook processor pods (e.g. 512Mi, 1Gi)"
  type        = string
  default     = "512Mi"
}

variable "n8n_webhook_memory_limit" {
  description = "Memory limit for n8n webhook processor pods (e.g. 1Gi, 2Gi)"
  type        = string
  default     = "1Gi"
}

# ── Execution settings ────────────────────────────────────────────────────────

variable "n8n_worker_concurrency" {
  description = "Number of jobs each worker pod can process simultaneously"
  type        = number
  default     = 10

  validation {
    condition     = var.n8n_worker_concurrency >= 1
    error_message = "Worker concurrency must be at least 1."
  }
}

variable "n8n_execution_timeout" {
  description = "Default execution timeout in seconds (-1 to disable)"
  type        = number
  default     = 7200
}

variable "n8n_execution_timeout_max" {
  description = "Maximum execution timeout users can configure in seconds"
  type        = number
  default     = 7200
}

variable "n8n_execution_concurrency_limit" {
  description = "Maximum concurrent production executions (-1 to disable)"
  type        = number
  default     = 100
}

variable "n8n_pruning_max_age" {
  description = "Maximum age of execution records to retain, in hours (336 = 14 days)"
  type        = number
  default     = 336
}

variable "n8n_pruning_max_count" {
  description = "Maximum number of execution records to retain (0 = no limit)"
  type        = number
  default     = 10000
}

# ── Graceful shutdown ─────────────────────────────────────────────────────────

variable "n8n_termination_grace_period" {
  description = "Seconds Kubernetes waits after SIGTERM before force-killing pods. MINIMUM — do not lower below 60. Workers need time to finish in-flight executions before being terminated."
  type        = number
  default     = 60

  validation {
    condition     = var.n8n_termination_grace_period >= 60
    error_message = "Termination grace period must be at least 60 seconds to allow in-flight executions to complete."
  }
}

variable "n8n_prestop_sleep" {
  description = "Seconds the preStop hook sleeps before SIGTERM is sent, giving the load balancer time to drain the pod. MINIMUM — do not lower below 10."
  type        = number
  default     = 10

  validation {
    condition     = var.n8n_prestop_sleep >= 10
    error_message = "Pre-stop sleep must be at least 10 seconds for load balancer drain."
  }
}

# ── Task runners ──────────────────────────────────────────────────────────────

variable "n8n_task_runners_enabled" {
  description = "Enable task runner sidecars for isolated JavaScript and Python code execution"
  type        = bool
  default     = true
}

variable "n8n_task_runner_cpu_request" {
  description = "CPU request for task runner sidecar containers (e.g. 200m, 500m)"
  type        = string
  default     = "200m"
}

variable "n8n_task_runner_cpu_limit" {
  description = "CPU limit for task runner sidecar containers (e.g. 1, 2000m)"
  type        = string
  default     = "1"
}

variable "n8n_task_runner_memory_request" {
  description = "Memory request for task runner sidecar containers (e.g. 512Mi, 1Gi)"
  type        = string
  default     = "512Mi"
}

variable "n8n_task_runner_memory_limit" {
  description = "Memory limit for task runner sidecar containers (e.g. 1Gi, 2Gi)"
  type        = string
  default     = "1Gi"
}

variable "n8n_task_runner_auto_shutdown_timeout" {
  description = "Seconds of inactivity before the runner process shuts down. Set to 0 to disable."
  type        = number
  default     = 15
}

variable "n8n_task_runner_python_enabled" {
  description = "Enable the native Python runner (beta). Required for Python code execution in workflows."
  type        = bool
  default     = true
}

# ── RDS PostgreSQL ─────────────────────────────────────────────────────────────

variable "db_instance_class" {
  description = "RDS instance class (db.t3.small ~$25/month, db.t3.medium for higher load)"
  type        = string
  default     = "db.t3.small"

  validation {
    condition     = can(regex("^db\\.", var.db_instance_class))
    error_message = "Value must be a valid RDS instance class (e.g. db.t3.small, db.r6g.large)."
  }
}

variable "db_multi_az" {
  description = "Deploy RDS in Multi-AZ mode for automatic failover (recommended for production)"
  type        = bool
  default     = true
}

variable "db_allocated_storage" {
  description = "Allocated storage for RDS in GB"
  type        = number
  default     = 50

  validation {
    condition     = var.db_allocated_storage >= 20
    error_message = "RDS allocated storage must be at least 20 GB."
  }
}

variable "create_database" {
  description = "When true (the default), the module creates and manages an Amazon RDS PostgreSQL instance. Set to false to use an external database (e.g. Amazon Aurora created by the caller) — db_host and db_password must then be supplied. Kept as a static boolean rather than `db_host == null` because count expressions cannot depend on values computed at apply time."
  type        = bool
  default     = true
}

variable "db_host" {
  description = "External database host. Required when create_database = false. Ignored otherwise. Use this to pass in an Amazon Aurora cluster endpoint or any external PostgreSQL host."
  type        = string
  default     = null
}

variable "db_password" {
  description = "Password for the external database specified by db_host. Required when create_database = false. Ignored otherwise (the module generates a random password for its managed RDS instance)."
  type        = string
  default     = null
  sensitive   = true
}

variable "db_postgresdb_pool_size" {
  description = "Number of TypeORM connection pool slots per n8n pod. Each pod holds this many persistent PostgreSQL connections. Rule of thumb: pool_size >= worker_concurrency / 4. With PgBouncer in transaction mode a lower value (5) is sufficient; without PgBouncer use a value matching concurrency (10-20)."
  type        = number
  default     = 10

  validation {
    condition     = var.db_postgresdb_pool_size >= 1
    error_message = "db_postgresdb_pool_size must be at least 1."
  }
}

variable "db_postgresdb_ssl_enabled" {
  description = "Whether n8n connects to the database over SSL. Set to true (the default) for direct connections to RDS or Aurora — they use the AWS CA which Node.js doesn't trust by default, so the connection still negotiates SSL but skips certificate verification. Set to false when n8n connects to an in-cluster connection pooler (e.g. PgBouncer) that handles SSL on its upstream leg — the pod-to-pod traffic stays inside the cluster network."
  type        = bool
  default     = true
}

# ── ElastiCache Redis ──────────────────────────────────────────────────────────

variable "redis_node_type" {
  description = "ElastiCache node type (cache.t3.medium ~$25/month)"
  type        = string
  default     = "cache.t3.medium"

  validation {
    condition     = can(regex("^cache\\.", var.redis_node_type))
    error_message = "Value must be a valid ElastiCache node type (e.g. cache.t3.medium)."
  }
}

variable "n8n_runners_task_request_timeout" {
  description = "Seconds n8n waits for a task runner to accept a Code node task. Increase if Code nodes fail with 'task request timed out' under high concurrency (many parallel Code nodes competing for the single runner sidecar)."
  type        = number
  default     = 300
}

# ── HPA: main pods ────────────────────────────────────────────────────────────

variable "n8n_main_hpa_min_replicas" {
  description = "Minimum replicas for n8n main pods. HPA will not scale below this."
  type        = number
  default     = 2
}

variable "n8n_main_hpa_max_replicas" {
  description = "Maximum replicas for n8n main pods. HPA will not scale above this."
  type        = number
  default     = 20
}

variable "n8n_main_hpa_cpu_threshold" {
  description = "Target average CPU utilization (%) that triggers scaling of n8n main pods."
  type        = number
  default     = 60
}

# ── HPA: webhook processor pods ───────────────────────────────────────────────

variable "n8n_webhook_hpa_min_replicas" {
  description = "Minimum replicas for n8n webhook processor pods. HPA will not scale below this."
  type        = number
  default     = 2
}

variable "n8n_webhook_hpa_max_replicas" {
  description = "Maximum replicas for n8n webhook processor pods. HPA will not scale above this."
  type        = number
  default     = 50
}

variable "n8n_webhook_hpa_cpu_threshold" {
  description = "Target average CPU utilization (%) that triggers scaling of n8n webhook pods."
  type        = number
  default     = 65
}

# ── KEDA: worker pods ─────────────────────────────────────────────────────────

variable "n8n_worker_keda_min_replicas" {
  description = "Minimum worker replicas. KEDA keeps at least this many workers running even when the queue is empty."
  type        = number
  default     = 1
}

variable "n8n_worker_keda_max_replicas" {
  description = "Maximum worker replicas KEDA may scale to."
  type        = number
  default     = 10
}

variable "n8n_worker_keda_jobs_per_replica" {
  description = "Number of waiting jobs per worker replica used as the KEDA scaling threshold. KEDA targets ceil(queue_depth / jobs_per_replica) replicas."
  type        = number
  default     = 5
}
