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
# Identical to examples/small: EKS requires subnets in at least two
# availability zones, and the VPC module handles the subnet tagging EKS and
# the AWS Load Balancer Controller need.

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

# ── Customer-managed EKS cluster (stand-in) ──────────────────────────────────
# Everything in this section is playing the part of a platform team's already
# existing EKS cluster, provisioned before anyone ever pointed this module at
# it. It is plain Terraform, entirely independent of the n8n module: nothing
# here is created by, or known to, module "n8n" below except through the
# reference variable it's wired to (existing_eks_cluster_name).
#
# A real customer-managed cluster exercises the same module inputs without
# any of this: delete this whole section, and set the module's
# existing_eks_cluster_name to your existing cluster's own name. See
# "Adapting to your real infrastructure" in this example's README.
#
# Sized the same as examples/small's module-created cluster (t3.xlarge nodes,
# desired/min 3, max 6), not a cheaper demo tier: the module's own
# node_instance_type description warns that anything smaller leaves
# insufficient headroom for HPA to scale the full multi-main n8n workload
# (main x2, worker x2, webhook x2 at minimum replicas). A stand-in this
# example expects someone to actually apply should not silently under-provision
# the cluster it is standing in for.

resource "aws_iam_role" "customer_managed_cluster" {
  name = "${var.cluster_name}-cm-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "customer_managed_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.customer_managed_cluster.name
}

resource "aws_iam_role" "customer_managed_nodes" {
  name = "${var.cluster_name}-cm-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "customer_managed_nodes_worker" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.customer_managed_nodes.name
}

resource "aws_iam_role_policy_attachment" "customer_managed_nodes_cni" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.customer_managed_nodes.name
}

resource "aws_iam_role_policy_attachment" "customer_managed_nodes_ecr" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.customer_managed_nodes.name
}

resource "aws_eks_cluster" "customer_managed" {
  # checkov:skip=CKV_AWS_38:Unrestricted public endpoint access matches this stand-in's minimum-viable posture, the same default this module's own aws_eks_cluster.n8n (eks.tf) ships with for zero-friction kubectl access. A real customer-managed cluster's actual posture is whatever its owning platform team already chose; this section models the least-configured plausible case, not a hardening recommendation.
  # checkov:skip=CKV_AWS_39:Same rationale as CKV_AWS_38 above.
  # checkov:skip=CKV_AWS_58:Secrets encryption is intentionally left off this minimal stand-in: adding it means a KMS key this section would then also have to own and document, which is exactly the complexity a "pre-existing cluster" section should not be modeling. A real customer-managed cluster's actual encryption posture is the platform team's decision, not this example's.
  name     = "${var.cluster_name}-cm"
  role_arn = aws_iam_role.customer_managed_cluster.arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids = concat(module.vpc.public_subnets, module.vpc.private_subnets)
  }

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  # All five control-plane log types, matching this module's own
  # aws_eks_cluster.n8n default (eks.tf): free to enable, and there is no
  # reason a stand-in should model a worse observability posture than the
  # module itself defaults to.
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  tags = local.common_tags

  depends_on = [aws_iam_role_policy_attachment.customer_managed_cluster_policy]
}

resource "aws_eks_node_group" "customer_managed" {
  cluster_name    = aws_eks_cluster.customer_managed.name
  node_group_name = "n8n-nodes"
  node_role_arn   = aws_iam_role.customer_managed_nodes.arn
  subnet_ids      = module.vpc.private_subnets
  instance_types  = [var.customer_managed_node_instance_type]

  scaling_config {
    desired_size = var.customer_managed_node_desired
    min_size     = var.customer_managed_node_min
    max_size     = var.customer_managed_node_max
  }

  # Prerequisite (2) of existing_eks_cluster_prerequisites_confirmed: the
  # module's own Cluster Autoscaler (installed via module.controllers,
  # install_cluster_autoscaler = true by default) auto-discovers node groups
  # by these two tags. The module cannot apply them to infrastructure it does
  # not own, so a real customer-managed cluster's node group needs its own
  # platform team to have set them; this stand-in sets them itself so the
  # example's autoscaler actually works end to end.
  tags = merge(local.common_tags, {
    "k8s.io/cluster-autoscaler/${aws_eks_cluster.customer_managed.name}" = "owned"
    "k8s.io/cluster-autoscaler/enabled"                                  = "true"
  })

  depends_on = [
    aws_iam_role_policy_attachment.customer_managed_nodes_worker,
    aws_iam_role_policy_attachment.customer_managed_nodes_cni,
    aws_iam_role_policy_attachment.customer_managed_nodes_ecr,
  ]

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }
}

# Hard prerequisite, not an attestation item: the root module's
# existing_eks_cluster_name variable description says the AWS provider itself
# fails the plan (a ResourceNotFoundException reading
# data.aws_eks_addon.existing_pod_identity_agent) if this addon is not already
# installed on the named cluster, before any Pod Identity association is
# attempted. Named and versioned to match how the module installs it on the
# create_eks = true path (eks.tf), for consistency.
resource "aws_eks_addon" "customer_managed_pod_identity" {
  cluster_name = aws_eks_cluster.customer_managed.name
  addon_name   = "eks-pod-identity-agent"

  tags = local.common_tags

  depends_on = [aws_eks_node_group.customer_managed]
}

# ── n8n ───────────────────────────────────────────────────────────────────────
# create_eks = false: the module creates no EKS cluster, node group, cluster
# IAM role, node IAM role, or Pod Identity Agent addon of its own, and instead
# reads the stand-in cluster above by name. Everything else (RDS, Redis, S3,
# the cluster controllers, n8n itself) is still created and wired exactly as
# it would be at examples/small.
#
# existing_eks_cluster_prerequisites_confirmed = true is an attestation the
# caller makes, not something Terraform can verify; here is why each of the
# four items its description enumerates actually holds for this stand-in
# cluster specifically, not just asserted:
#
#   (1) Node capacity: sized identically to examples/small's module-created
#       cluster (t3.xlarge, desired/min 3, max 6), so the same HPA/KEDA maxima
#       this module computes fit the same way they do there.
#   (2) Cluster Autoscaler auto-discovery tags: set explicitly on
#       aws_eks_node_group.customer_managed above.
#   (3) API server reachability: the stand-in cluster's endpoint is public
#       (access_config above sets no private-only restriction), and this
#       example applies from wherever terraform apply runs, same as
#       examples/small.
#   (4) Naming and identity collisions: this is a fresh, single-purpose
#       cluster created for this example alone, so there is nothing else on
#       it for the module's IAM role names, ServiceAccount names, or Pod
#       Identity associations to collide with.

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

  n8n_additional_domains          = var.n8n_additional_domains
  n8n_execution_data_storage_mode = var.n8n_execution_data_storage_mode

  # ── Customer-managed EKS cluster wiring ─────────────────────────────────────
  create_eks                                   = false
  existing_eks_cluster_name                    = aws_eks_cluster.customer_managed.name
  existing_eks_cluster_prerequisites_confirmed = true
  kubernetes_version                           = var.kubernetes_version

  tags = local.common_tags

  # Explicit module-level dependency ensures the ENTIRE VPC (including NAT
  # gateway routes, IGW, etc.) and the stand-in cluster both stay up until
  # n8n is fully destroyed. Without this, Terraform may tear down the VPC or
  # the cluster before n8n's own destroy is done with them.
  depends_on = [
    module.vpc,
    aws_eks_node_group.customer_managed,
    aws_eks_addon.customer_managed_pod_identity,
  ]
}
