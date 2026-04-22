# ── AWS Load Balancer Controller IAM ─────────────────────────────────────────
# EKS Pod Identity binds this role to the LBC's ServiceAccount — no OIDC
# provider, no IRSA annotations, no static keys.

data "http" "lbc_iam_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.2.1/docs/install/iam_policy.json"
}

resource "aws_iam_policy" "lbc" {
  name   = "AWSLoadBalancerControllerIAMPolicy-${local.cluster_name}"
  policy = data.http.lbc_iam_policy.response_body
  tags   = local.common_tags
}

resource "aws_iam_role" "lbc" {
  name = "AmazonEKSLoadBalancerControllerRole-${local.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "lbc" {
  role       = aws_iam_role.lbc.name
  policy_arn = aws_iam_policy.lbc.arn
}

resource "aws_iam_role_policy" "lbc_describe_listener_attributes" {
  name = "AllowDescribeListenerAttributes"
  role = aws_iam_role.lbc.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "elasticloadbalancing:DescribeListenerAttributes"
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy" "lbc_set_rule_priorities" {
  name = "AllowSetRulePriorities"
  role = aws_iam_role.lbc.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "elasticloadbalancing:SetRulePriorities"
      Resource = "*"
    }]
  })
}

resource "aws_eks_pod_identity_association" "lbc" {
  cluster_name    = aws_eks_cluster.n8n.name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.lbc.arn

  depends_on = [aws_eks_addon.pod_identity_agent]
}

# ── Cluster Autoscaler IAM ────────────────────────────────────────────────────

resource "aws_iam_policy" "cluster_autoscaler" {
  name = "${local.cluster_name}-cluster-autoscaler-policy"
  tags = local.common_tags

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          "autoscaling:DescribeTags",
          "ec2:DescribeImages",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:GetInstanceTypesFromInstanceRequirements",
          "eks:DescribeNodegroup",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_role" "cluster_autoscaler" {
  name = "${local.cluster_name}-cluster-autoscaler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "cluster_autoscaler" {
  role       = aws_iam_role.cluster_autoscaler.name
  policy_arn = aws_iam_policy.cluster_autoscaler.arn
}

resource "aws_eks_pod_identity_association" "cluster_autoscaler" {
  cluster_name    = aws_eks_cluster.n8n.name
  namespace       = "kube-system"
  service_account = "cluster-autoscaler"
  role_arn        = aws_iam_role.cluster_autoscaler.arn

  depends_on = [aws_eks_addon.pod_identity_agent]
}

# Note: No EBS CSI IAM role here — multi-main pods are stateless.
# RDS handles the database, S3 handles file storage. No PVCs are needed.
