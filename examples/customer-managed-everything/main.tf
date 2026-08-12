locals {
  common_tags = merge(
    {
      ManagedBy = "terraform"
      Project   = "n8n"
    },
    var.tags,
  )
}

data "aws_caller_identity" "current" {}

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
# Everything from here down through the S3 bucket plays the part of a
# platform team's already-existing estate: a cluster, database, cache and
# bucket that all existed before anyone ever pointed this module at them. It
# is plain Terraform, entirely independent of the n8n module: nothing here is
# created by, or known to, module "n8n" below except through the reference
# variables each section is wired to.
#
# A real customer-managed deployment exercises the same module inputs
# without any of this: delete each stand-in section, and set the
# corresponding reference variables to your own infrastructure's own
# coordinates. See "Adapting to your real infrastructure" in this example's
# README.
#
# Sized the same as examples/small's module-created cluster (t3.xlarge nodes,
# desired/min 3, max 6), not a cheaper demo tier, for the same reason
# examples/customer-managed-cluster is: the module's own node_instance_type
# description warns that anything smaller leaves insufficient headroom for
# HPA to scale the full multi-main n8n workload.

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
  # Cluster Autoscaler this example installs directly via module.controllers
  # below auto-discovers node groups by these two tags. A real
  # customer-managed cluster's node group needs its own platform team to have
  # set them; this stand-in sets them itself so the example's autoscaler
  # actually works end to end.
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

# ── Customer-managed RDS PostgreSQL (stand-in) ───────────────────────────────
# Plain aws_db_instance standing in for a database a customer already runs
# (Aurora, RDS PostgreSQL, or otherwise) before pointing this module at it.
# The master password is a plain variable with a demo default, not a
# generated random_password, for the same reason
# customer_managed_redis_auth_token is in examples/customer-managed-redis:
# this value is wired both into the stand-in's own password argument and into
# the module's db_password, and a fresh random_password.result is unknown
# until apply, which would break the plan wherever that unknown value's
# nullness needs to be known ahead of it. A real customer-managed database's
# password is already a known secret the caller holds, not something
# Terraform generates in the same apply.

resource "aws_db_subnet_group" "customer_managed" {
  name       = "customer-managed-n8n-db-${var.cluster_name}"
  subnet_ids = module.vpc.private_subnets

  tags = merge(local.common_tags, { Name = "customer-managed-n8n-db-${var.cluster_name}" })
}

resource "aws_security_group" "customer_managed_rds" {
  # checkov:skip=CKV_AWS_382:Egress-all is intentional, same reasoning as this module's own security groups (redis.tf, database.tf): RDS does not originate arbitrary outbound traffic, and restricting it risks silently breaking AWS API calls routed through the VPC without a matching VPC endpoint, for no real security benefit on a non-internet-facing managed service.
  name        = "customer-managed-rds-sg-${var.cluster_name}"
  description = "Allow PostgreSQL access from within the VPC"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "PostgreSQL from VPC"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [module.vpc.vpc_cidr_block]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "customer-managed-rds-sg-${var.cluster_name}" })
}

resource "aws_db_instance" "customer_managed" {
  # checkov:skip=CKV2_AWS_30:Query logging is an explicit opt-in on this module's own aws_db_instance.n8n too (db_query_logging_enabled, database.tf), for the same reason: engine_version drift means a blanket default risks attaching a parameter group from the wrong PostgreSQL major family. A real customer-managed instance's actual logging configuration is the platform team's decision.
  # checkov:skip=CKV_AWS_118:Enhanced monitoring needs its own IAM role (see aws_iam_role.rds_enhanced_monitoring in database.tf for what this module itself creates for it), which is exactly the complexity a "pre-existing database" stand-in should not be modeling. A real customer-managed instance's actual monitoring setup is the platform team's decision.
  # checkov:skip=CKV_AWS_293:Deletion protection is intentionally left off so `terraform destroy` works cleanly during evaluation and example teardown, same reasoning as this module's own aws_db_instance.n8n (database.tf) and examples/large's Aurora cluster. Flip to true before treating this stand-in as anything but a throwaway demo.
  # checkov:skip=CKV_AWS_354:Performance Insights is encrypted with the RDS-managed default key, not a Customer Managed Key: adding a CMK just for Performance Insights is exactly the complexity a "pre-existing database" stand-in should not be modeling, same reasoning as CKV_AWS_118 above. A real customer-managed instance's actual key is the platform team's decision.
  identifier     = "customer-managed-n8n-${var.cluster_name}"
  engine         = "postgres"
  engine_version = var.customer_managed_db_engine_version
  instance_class = var.customer_managed_db_instance_class

  allocated_storage = 50
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = "n8n"
  username = "n8n"
  password = var.customer_managed_db_password

  db_subnet_group_name   = aws_db_subnet_group.customer_managed.name
  vpc_security_group_ids = [aws_security_group.customer_managed_rds.id]

  multi_az                            = true
  iam_database_authentication_enabled = true
  enabled_cloudwatch_logs_exports     = ["postgresql"]
  copy_tags_to_snapshot               = true
  auto_minor_version_upgrade          = true
  performance_insights_enabled        = true

  skip_final_snapshot = true
  apply_immediately   = true

  tags = local.common_tags
}

# ── Customer-managed Redis (stand-in) ────────────────────────────────────────
# Same pattern, and the same resources, as examples/customer-managed-redis:
# a two-node replication group with transit encryption required and an AUTH
# token, because that is what a real production customer-managed Redis looks
# like (AUTH tokens only exist on replication groups at all).

resource "aws_security_group" "customer_managed_redis" {
  # checkov:skip=CKV_AWS_382:Egress-all is intentional, same reasoning as this module's own security groups (redis.tf, database.tf): ElastiCache does not originate arbitrary outbound traffic, and restricting it risks silently breaking AWS API calls routed through the VPC without a matching VPC endpoint, for no real security benefit on a non-internet-facing managed service.
  name        = "customer-managed-redis-sg-${var.cluster_name}"
  description = "Allow Redis access from within the VPC"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "Redis from VPC"
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = [module.vpc.vpc_cidr_block]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "customer-managed-redis-sg-${var.cluster_name}" })
}

resource "aws_elasticache_subnet_group" "customer_managed" {
  name       = "customer-managed-redis-subnet-group-${var.cluster_name}"
  subnet_ids = module.vpc.private_subnets

  tags = merge(local.common_tags, { Name = "customer-managed-redis-subnet-group-${var.cluster_name}" })
}

resource "aws_elasticache_replication_group" "customer_managed" {
  replication_group_id = "${var.cluster_name}-cm-redis"
  description          = "Stand-in for a customer-managed Redis, for the customer-managed-everything example"

  engine         = "redis"
  engine_version = "7.1"
  node_type      = var.customer_managed_redis_node_type
  port           = 6379

  num_cache_clusters         = 2
  automatic_failover_enabled = true
  multi_az_enabled           = true

  subnet_group_name  = aws_elasticache_subnet_group.customer_managed.name
  security_group_ids = [aws_security_group.customer_managed_redis.id]

  # checkov:skip=CKV_AWS_191:Encrypted at rest with the ElastiCache-managed key (at_rest_encryption_enabled below), not a Customer Managed Key: this stand-in models a plausible minimum-viable customer Redis, not this module's own CMK-capable posture (redis_kms_encryption_enabled). A real customer-managed Redis's actual key is the caller's decision.
  at_rest_encryption_enabled = true

  transit_encryption_enabled = true
  transit_encryption_mode    = "required"
  auth_token                 = var.customer_managed_redis_auth_token

  tags = local.common_tags
}

# ── Customer-managed S3 bucket (stand-in) ────────────────────────────────────
# Same pattern as examples/customer-managed-s3: secured with its own
# public-access block and SSE-S3 configuration, entirely independent of the
# module, since s3.tf's design leaves a customer-managed bucket's security
# configuration to its owner, not to this module.

resource "aws_s3_bucket" "customer_managed" {
  # checkov:skip=CKV_AWS_21:Versioning would defeat n8n's own pruning, same reasoning as this module's own aws_s3_bucket.n8n (s3.tf): n8n prunes execution data in S3 itself, and with versioning enabled those deletes only write delete markers.
  # checkov:skip=CKV_AWS_18:Server access logging needs a second bucket to receive the logs, which this single-bucket stand-in does not create, same reasoning as this module's own aws_s3_bucket.n8n.
  # checkov:skip=CKV_AWS_144:Cross-region replication needs a destination bucket in a second region, which this single-region example does not create.
  # checkov:skip=CKV_AWS_145:Deliberately SSE-S3 (see the encryption configuration below), not SSE-KMS: this stand-in models a plausible minimum-viable customer bucket, not this module's own KMS-by-default posture (s3_kms_encryption_enabled). A real customer-managed bucket's actual encryption is the caller's decision, wired through s3_kms_key_arn if it is SSE-KMS.
  # checkov:skip=CKV2_AWS_61:No lifecycle configuration, by design, same reasoning as this module's own aws_s3_bucket.n8n: leaving object expiry to the caller is the only option that cannot silently delete data n8n still references.
  # checkov:skip=CKV2_AWS_62:Event notifications exist to drive downstream consumers, and nothing in this stand-in or the module consumes S3 events.
  bucket = "customer-managed-n8n-everything-${var.cluster_name}-${data.aws_caller_identity.current.account_id}"

  force_destroy = var.customer_managed_s3_force_destroy

  tags = merge(local.common_tags, { Name = "customer-managed-n8n-everything-${var.cluster_name}" })
}

resource "aws_s3_bucket_public_access_block" "customer_managed" {
  bucket = aws_s3_bucket.customer_managed.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "customer_managed" {
  bucket = aws_s3_bucket.customer_managed.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ── Customer-managed cluster controllers ─────────────────────────────────────
# Invokes modules/controllers directly, rather than going through the
# n8n module's own install_* toggles, exactly the pattern that submodule
# extraction exists for: an advanced caller deploying onto an existing
# cluster invokes the controllers submodule itself, standing in for whatever
# a platform team's own GitOps/IaC would install onto its shared cluster.
# module "n8n" below then sets every install_* / create_ebs_csi toggle to
# false, so it installs none of these itself and only consumes the
# ServiceAccount/IAM wiring this call creates.

module "controllers" {
  source = "../../modules/controllers"

  cluster_name     = var.cluster_name
  eks_cluster_name = aws_eks_cluster.customer_managed.name
  aws_region       = var.aws_region
  vpc_id           = module.vpc.vpc_id

  common_tags = local.common_tags

  # true, not false, even though module "n8n" below sets create_eks = false:
  # the two mean different things. n8n's create_eks = false says "the n8n
  # module does not own the cluster"; this submodule's create_eks says "the
  # cluster is being created by the same apply that is calling me", which is
  # true here, since aws_eks_cluster.customer_managed above is part of this
  # very configuration. That is what lets the LBC and Cluster Autoscaler Pod
  # Identity associations be created unconditionally: nothing can already be
  # bound to those ServiceAccounts on a cluster this apply just created. A
  # platform team copying this example onto a cluster that already exists
  # should set this to false instead, so the associations are created only
  # for the controllers this call actually installs and an association the
  # cluster already carries is not duplicated (EKS rejects the second one
  # with 409 ResourceInUseException).
  create_eks = true

  install_lbc                = true
  install_cluster_autoscaler = true
  install_metrics_server     = true
  install_keda               = true
  create_ebs_csi             = true

  depends_on = [
    aws_eks_node_group.customer_managed,
    aws_eks_addon.customer_managed_pod_identity,
  ]
}

# ── n8n ───────────────────────────────────────────────────────────────────────
# Every layer the module can create is instead customer-managed here:
# create_eks, create_database, create_elasticache, create_s3_bucket, and
# every install_*/create_ebs_csi controller toggle are all false. n8n itself,
# its Ingress, HPAs, and Kubernetes Secrets are still created and wired by
# this module exactly as they would be at examples/small; only the backing
# infrastructure and its cluster-level controllers are supplied rather than
# owned.
#
# existing_eks_cluster_prerequisites_confirmed = true is an attestation the
# caller makes, not something Terraform can verify; see
# examples/customer-managed-cluster's README for the full walkthrough of why
# each of its four items holds for a stand-in cluster shaped like this one.
#
# create_ingress = false, not the default true: install_lbc = false has a
# hard plan-time validation (variables.tf) requiring create_ingress = false,
# because the module's own Ingress waits for an ALB from an LBC it thinks it
# never installed, and that wait would time out the apply. This example's own
# Ingress, in ingress.tf, points at the ALB the directly-invoked
# module.controllers above installs instead, exactly the remedy that
# validation's own error message suggests.

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

  # ── Customer-managed Ingress wiring ─────────────────────────────────────────
  # See ingress.tf and dns.tf: this example owns its own Ingress and alias
  # record, pointed at the ALB the directly-invoked module.controllers
  # installs, since install_lbc = false below requires it.
  create_ingress = false

  # ── Customer-managed EKS cluster wiring ─────────────────────────────────────
  create_eks                                   = false
  existing_eks_cluster_name                    = aws_eks_cluster.customer_managed.name
  existing_eks_cluster_prerequisites_confirmed = true
  kubernetes_version                           = var.kubernetes_version

  # ── Customer-managed RDS wiring ─────────────────────────────────────────────
  create_database = false
  db_host         = aws_db_instance.customer_managed.address
  db_password     = var.customer_managed_db_password

  # ── Customer-managed Redis wiring ───────────────────────────────────────────
  create_elasticache               = false
  redis_host                       = aws_elasticache_replication_group.customer_managed.primary_endpoint_address
  redis_port                       = 6379
  redis_auth_token                 = var.customer_managed_redis_auth_token
  redis_transit_encryption_enabled = true

  # ── Customer-managed S3 wiring ──────────────────────────────────────────────
  create_s3_bucket        = false
  existing_s3_bucket_name = aws_s3_bucket.customer_managed.id

  # ── Customer-managed cluster controllers wiring ─────────────────────────────
  # module.controllers above installs all five directly; the n8n module
  # installs none of them itself.
  install_lbc                = false
  install_cluster_autoscaler = false
  install_metrics_server     = false
  install_keda               = false
  create_ebs_csi             = false

  tags = local.common_tags

  # module.controllers is the load-bearing entry here, not a formality. This
  # module's Helm release renders a KEDA ScaledObject unconditionally, even
  # with install_keda = false above, so it has to be applied after the KEDA
  # operator's CRDs exist and destroyed before they are removed. Nothing
  # infers that edge: install_keda = false means this module creates no KEDA
  # resource for module.controllers' release to be inferred against. See
  # modules/controllers/keda.tf for the full contract.
  #
  # This is only declarable because providers.tf configures the kubernetes and
  # helm providers against aws_eks_cluster.customer_managed directly rather
  # than against this module's own outputs. Sourced from the outputs, every
  # module.controllers resource would depend on module.n8n through the
  # provider config and this line would be a cycle.
  depends_on = [
    module.vpc,
    module.controllers,
    aws_db_instance.customer_managed,
    aws_elasticache_replication_group.customer_managed,
    aws_s3_bucket.customer_managed,
  ]
}
