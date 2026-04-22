# NOTE: aws_region, cluster_name, and n8n_domain are defined in the
# prerequisites workspace. This workspace reads them via
# data.terraform_remote_state.prerequisites (see remote_state.tf).

variable "tags" {
  description = "Additional AWS tags to apply to all resources created by this workspace. Merged on top of the built-in ManagedBy/Project tags."
  type        = map(string)
  default     = {}
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.35"
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
}

variable "node_desired" {
  description = "Desired number of worker nodes at startup"
  type        = number
  default     = 3
}

variable "node_min" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 3
}

variable "node_max" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 6
}

# ── n8n chart ─────────────────────────────────────────────────────────────────

variable "n8n_chart_version" {
  description = "n8n Helm chart version to deploy"
  type        = string
  default     = "1.4.0"
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
}

variable "n8n_prestop_sleep" {
  description = "Seconds the preStop hook sleeps before SIGTERM is sent, giving the load balancer time to drain the pod. MINIMUM — do not lower below 10."
  type        = number
  default     = 10
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
}

# ── ElastiCache Redis ──────────────────────────────────────────────────────────

variable "redis_node_type" {
  description = "ElastiCache node type (cache.t3.medium ~$25/month)"
  type        = string
  default     = "cache.t3.medium"
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
