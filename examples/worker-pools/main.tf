locals {
  common_tags = merge(
    {
      ManagedBy = "terraform"
      Project   = "n8n"
    },
    var.tags,
  )
}

# ── VPC ───────────────────────────────────────────────────────────────────────
# EKS requires subnets in at least two availability zones. The VPC module
# handles the subnet tagging EKS and the AWS Load Balancer Controller need.
#
# A single NAT Gateway keeps costs low. For production HA, set
# single_nat_gateway = false and one_nat_gateway_per_az = true.

data "aws_availability_zones" "available" {
  state = "available"
}

module "vpc" {
  # checkov:skip=CKV_TF_1:A commit hash cannot be expressed for a Terraform Registry source: this address takes a `version` constraint, and pinning a SHA would mean switching to a `git::` source, which is the weaker supply-chain posture the check exists to discourage. Registry releases are immutable per published version. Annotated per call rather than suppressed repo-wide, so the check still fires if a genuinely mutable git:: source is ever added.
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = "10.0.0.0/16"

  azs             = slice(data.aws_availability_zones.available.names, 0, 2)
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.10.0/24", "10.0.11.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  tags = local.common_tags
}

# ── n8n ───────────────────────────────────────────────────────────────────────
# The module issues the ACM certificate and creates the Route53 alias record
# itself when route53_zone_id is set: single terraform apply, no manual DNS.

module "n8n" {
  source = "../.."

  aws_region      = var.aws_region
  cluster_name    = var.cluster_name
  n8n_domain      = var.n8n_domain
  vpc_id          = module.vpc.vpc_id
  private_subnets = module.vpc.private_subnets
  public_subnets  = module.vpc.public_subnets
  vpc_cidr_block  = module.vpc.vpc_cidr_block
  route53_zone_id = var.route53_zone_id

  n8n_license_key            = var.n8n_license_key
  n8n_image_repository       = var.n8n_image_repository
  n8n_image_tag              = var.n8n_image_tag
  n8n_task_runner_image_tag  = var.n8n_task_runner_image_tag
  n8n_custom_extensions_path = var.n8n_custom_extensions_path
  n8n_image_pull_secrets     = var.n8n_image_pull_secrets

  n8n_additional_domains = var.n8n_additional_domains

  n8n_extra_env = var.n8n_extra_env

  # ── Node capacity ───────────────────────────────────────────────────────────
  # The one place this example is not sizing-equivalent to examples/small.
  # Pools are additional autoscalers on the same node group, and each can reach
  # its own ceiling independently, so their pods have to fit alongside the main,
  # default-worker and webhook ceilings rather than instead of them. The three
  # pools below add 9,000m of CPU requests at their maxima (4 x 1200m for gpu,
  # 3 x 700m each for secteam and itop, every pool pod carrying a task runner
  # sidecar), which takes the peak from small's 16,600m to 25,600m. The default
  # node_max of 6 t3.xlarge only schedules about 21,720m, so it needs 8.
  #
  # The module warns at plan time when these fall out of step; see
  # check "autoscaling_maxima_fit_node_group_capacity" in scaling.tf and
  # README.md → "Sizing autoscaling against node capacity".
  node_max = 8

  # ── Worker pools ────────────────────────────────────────────────────────────
  # The chart's own unlabelled worker deployment keeps serving the default
  # `jobs` queue for every project that is not pinned to a pool. Size it here.
  n8n_worker_keda_min_replicas = var.n8n_worker_keda_min_replicas
  n8n_worker_keda_max_replicas = var.n8n_worker_keda_max_replicas

  # Each entry below becomes its own worker Deployment plus its own KEDA
  # ScaledObject watching that pool's `jobs-<name>` queue. Assign a project to
  # a pool in the n8n UI under Project, Settings, Worker Pools; its executions
  # then run only on that pool's workers.
  #
  # Declaring any pool switches N8N_WORKER_POOLS_ENABLED on across mains,
  # workers and webhook pods, which the feature needs in order to route at all.
  #
  # A pool with no live workers is not an error: projects pinned to it fall
  # back to the default queue until it scales up again.
  n8n_worker_pools = [
    # Heavier executions, given more CPU and memory and a lower concurrency so
    # each worker takes fewer jobs at once.
    {
      name           = "gpu"
      min_replicas   = 1
      max_replicas   = 4
      concurrency    = 5
      cpu_request    = "1"
      cpu_limit      = "2"
      memory_request = "2Gi"
      memory_limit   = "4Gi"
    },

    # An isolated set for one team's projects, at the module's default worker
    # sizing.
    {
      name         = "secteam"
      min_replicas = 1
      max_replicas = 3
    },

    # Scales to zero when idle. Cheap to leave declared: with no live workers
    # its projects fall back to the default queue, and KEDA scales it up again
    # as soon as work is routed to it.
    {
      name         = "itop"
      min_replicas = 0
      max_replicas = 3
    },
  ]

  # ── Execution data ──────────────────────────────────────────────────────────
  # Left at "database" so this example applies without the feat:executionDataS3
  # entitlement. This sizing sees the least traffic but has the least database
  # headroom to absorb it: db.t3.small with 50 GB of gp2 and a 150 IOPS
  # baseline, where sustained execution-data writes burn burst credits and the
  # volume fills. "s3" moves those payloads out of PostgreSQL entirely, reusing
  # the bucket and Pod Identity role the module already creates for binary data,
  # so nothing else changes. Read the execution data section of the root README
  # first: it needs n8n >= 2.27 and an Enterprise license with that entitlement,
  # it does not backfill, and it changes the durability posture of execution
  # history.
  n8n_execution_data_storage_mode = var.n8n_execution_data_storage_mode

  tags = local.common_tags

  # Explicit module-level dependency ensures the ENTIRE VPC (including NAT
  # gateway routes, IGW, etc.) stays up until n8n is fully destroyed. Without
  # this, Terraform may delete NAT routes in parallel, leaving nodes in private
  # subnets lose API-server connectivity, LBC pods die, and the Ingress
  # finalizer can never be removed.
  depends_on = [module.vpc]
}
