# ── Cluster IAM role ──────────────────────────────────────────────────────────

resource "aws_iam_role" "cluster" {
  name = "${local.cluster_name}-cluster-role"

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

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.cluster.name
}

# ── Node group IAM role ───────────────────────────────────────────────────────

resource "aws_iam_role" "nodes" {
  name = "${local.cluster_name}-node-role"

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

resource "aws_iam_role_policy_attachment" "nodes_worker" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.nodes.name
}

resource "aws_iam_role_policy_attachment" "nodes_cni" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.nodes.name
}

resource "aws_iam_role_policy_attachment" "nodes_ecr" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.nodes.name
}

# ── EKS Cluster ───────────────────────────────────────────────────────────────

resource "aws_eks_cluster" "n8n" {
  name     = local.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids = concat(local.public_subnets, local.private_subnets)
  }

  # API auth mode replaces the legacy aws-auth ConfigMap. Cluster access is
  # granted via aws_eks_access_entry + aws_eks_access_policy_association.
  # bootstrap_cluster_creator_admin_permissions gives the principal that creates
  # the cluster (the one running `terraform apply`) immediate admin access so
  # `kubectl` works right after apply.
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  tags = local.common_tags

  depends_on = [aws_iam_role_policy_attachment.cluster_policy]
}

# ── Managed node group ────────────────────────────────────────────────────────
# 3 nodes by default — enough for 6 pods at minimum replicas.
# HPA scales pods horizontally; Cluster Autoscaler (controllers.tf) adds/removes
# nodes between node_min and node_max as pod demand changes.

resource "aws_eks_node_group" "n8n" {
  cluster_name    = aws_eks_cluster.n8n.name
  node_group_name = "n8n-nodes"
  node_role_arn   = aws_iam_role.nodes.arn
  subnet_ids      = local.private_subnets
  instance_types  = [var.node_instance_type]

  scaling_config {
    desired_size = var.node_desired
    min_size     = var.node_min
    max_size     = var.node_max
  }

  # Required for Cluster Autoscaler auto-discovery. The CA scans for ASGs
  # tagged with these two keys to know which node groups it can scale.
  tags = merge(local.common_tags, {
    "k8s.io/cluster-autoscaler/${local.cluster_name}" = "owned"
    "k8s.io/cluster-autoscaler/enabled"               = "true"
  })

  depends_on = [
    aws_iam_role_policy_attachment.nodes_worker,
    aws_iam_role_policy_attachment.nodes_cni,
    aws_iam_role_policy_attachment.nodes_ecr,
  ]
}

# ── EKS Pod Identity Agent ────────────────────────────────────────────────────
# The agent runs as a DaemonSet and injects AWS credentials into pods whose
# service accounts are bound via aws_eks_pod_identity_association. This is the
# AWS-recommended replacement for IRSA — no OIDC provider, no federated trust
# policies, no service account annotations.

resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name = aws_eks_cluster.n8n.name
  addon_name   = "eks-pod-identity-agent"

  tags = local.common_tags

  depends_on = [aws_eks_node_group.n8n]
}
