# ── AWS Load Balancer Controller IAM ─────────────────────────────────────────
# EKS Pod Identity binds this role to the LBC's ServiceAccount — no OIDC
# provider, no IRSA annotations, no static keys.
#
# The IAM policy below is the native Terraform equivalent of the upstream JSON
# policy for LBC v3.2.x. It is maintained inline so the module has no network
# dependency at plan time and works in air-gapped environments.
# Source: https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.2.1/docs/install/iam_policy.json
#
# Everything below is gated on `create_eks || install_lbc`, not on install_lbc
# alone: install_lbc only controls whether this submodule installs the *chart*,
# while the credential wiring follows the compound gate. On a freshly created
# cluster (create_eks = true) an externally-installed LBC (e.g. one a platform
# team manages through GitOps, the case install_lbc = false documents) still
# gets the IAM role bound via Pod Identity to the standard-named
# aws-load-balancer-controller ServiceAccount in kube-system. Only when both
# are false is the wiring skipped entirely, because the existing cluster may
# already carry that ServiceAccount's association. See the comment above
# aws_iam_policy.lbc for the full reasoning, and the association's own comment
# for the create_eks = false collision it avoids.

data "aws_iam_policy_document" "lbc" {
  # checkov:skip=CKV_AWS_111:Verbatim transcription of the upstream AWS Load Balancer Controller IAM policy (source URL above). Narrowing actions/resources diverges from the AWS-maintained policy and risks breaking the controller; track upstream for tightening instead.
  # checkov:skip=CKV_AWS_356:Same rationale as CKV_AWS_111 above - several of these actions (e.g. elasticloadbalancing:Describe*, ec2:Describe*) do not support resource-level ARNs in IAM at all, so "*" is the only valid value regardless.
  statement {
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["elasticloadbalancing.amazonaws.com"]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "ec2:DescribeAccountAttributes",
      "ec2:DescribeAddresses",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeInternetGateways",
      "ec2:DescribeVpcs",
      "ec2:DescribeVpcPeeringConnections",
      "ec2:DescribeSubnets",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeInstances",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeTags",
      "ec2:GetCoipPoolUsage",
      "ec2:DescribeCoipPools",
      "elasticloadbalancing:DescribeLoadBalancers",
      "elasticloadbalancing:DescribeLoadBalancerAttributes",
      "elasticloadbalancing:DescribeListeners",
      "elasticloadbalancing:DescribeListenerCertificates",
      "elasticloadbalancing:DescribeListenerAttributes",
      "elasticloadbalancing:DescribeSSLPolicies",
      "elasticloadbalancing:DescribeRules",
      "elasticloadbalancing:DescribeTargetGroups",
      "elasticloadbalancing:DescribeTargetGroupAttributes",
      "elasticloadbalancing:DescribeTargetHealth",
      "elasticloadbalancing:DescribeTags",
      "elasticloadbalancing:DescribeTrustStores",
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "cognito-idp:DescribeUserPoolClient",
      "acm:ListCertificates",
      "acm:DescribeCertificate",
      "iam:ListServerCertificates",
      "iam:GetServerCertificate",
      "waf-regional:GetWebACL",
      "waf-regional:GetWebACLForResource",
      "waf-regional:AssociateWebACL",
      "waf-regional:DisassociateWebACL",
      "wafv2:GetWebACL",
      "wafv2:GetWebACLForResource",
      "wafv2:AssociateWebACL",
      "wafv2:DisassociateWebACL",
      "shield:GetSubscriptionState",
      "shield:DescribeProtection",
      "shield:CreateProtection",
      "shield:DeleteProtection",
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupIngress",
    ]
    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["ec2:CreateSecurityGroup"]
    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["ec2:CreateTags"]
    resources = ["arn:aws:ec2:*:*:security-group/*"]
    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = ["CreateSecurityGroup"]
    }
    condition {
      test     = "Null"
      variable = "aws:RequestTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "ec2:CreateTags",
      "ec2:DeleteTags",
    ]
    resources = ["arn:aws:ec2:*:*:security-group/*"]
    condition {
      test     = "Null"
      variable = "aws:RequestTag/elbv2.k8s.aws/cluster"
      values   = ["true"]
    }
    condition {
      test     = "Null"
      variable = "aws:ResourceTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:DeleteSecurityGroup",
    ]
    resources = ["*"]
    condition {
      test     = "Null"
      variable = "aws:ResourceTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "elasticloadbalancing:CreateLoadBalancer",
      "elasticloadbalancing:CreateTargetGroup",
    ]
    resources = ["*"]
    condition {
      test     = "Null"
      variable = "aws:RequestTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "elasticloadbalancing:CreateListener",
      "elasticloadbalancing:DeleteListener",
      "elasticloadbalancing:CreateRule",
      "elasticloadbalancing:DeleteRule",
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "elasticloadbalancing:AddTags",
      "elasticloadbalancing:RemoveTags",
    ]
    resources = [
      "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*",
      "arn:aws:elasticloadbalancing:*:*:loadbalancer/net/*/*",
      "arn:aws:elasticloadbalancing:*:*:loadbalancer/app/*/*",
    ]
    condition {
      test     = "Null"
      variable = "aws:RequestTag/elbv2.k8s.aws/cluster"
      values   = ["true"]
    }
    condition {
      test     = "Null"
      variable = "aws:ResourceTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "elasticloadbalancing:AddTags",
      "elasticloadbalancing:RemoveTags",
    ]
    resources = [
      "arn:aws:elasticloadbalancing:*:*:listener/net/*/*/*",
      "arn:aws:elasticloadbalancing:*:*:listener/app/*/*/*",
      "arn:aws:elasticloadbalancing:*:*:listener-rule/net/*/*/*",
      "arn:aws:elasticloadbalancing:*:*:listener-rule/app/*/*/*",
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "elasticloadbalancing:ModifyLoadBalancerAttributes",
      "elasticloadbalancing:SetIpAddressType",
      "elasticloadbalancing:SetSecurityGroups",
      "elasticloadbalancing:SetSubnets",
      "elasticloadbalancing:DeleteLoadBalancer",
      "elasticloadbalancing:ModifyTargetGroup",
      "elasticloadbalancing:ModifyTargetGroupAttributes",
      "elasticloadbalancing:DeleteTargetGroup",
      "elasticloadbalancing:ModifyListenerAttributes",
    ]
    resources = ["*"]
    condition {
      test     = "Null"
      variable = "aws:ResourceTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "elasticloadbalancing:AddTags",
    ]
    resources = [
      "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*",
      "arn:aws:elasticloadbalancing:*:*:loadbalancer/net/*/*",
      "arn:aws:elasticloadbalancing:*:*:loadbalancer/app/*/*",
    ]
    condition {
      test     = "StringEquals"
      variable = "elasticloadbalancing:CreateAction"
      values   = ["CreateTargetGroup", "CreateLoadBalancer"]
    }
    condition {
      test     = "Null"
      variable = "aws:RequestTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "elasticloadbalancing:RegisterTargets",
      "elasticloadbalancing:DeregisterTargets",
    ]
    resources = ["arn:aws:elasticloadbalancing:*:*:targetgroup/*/*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "elasticloadbalancing:SetWebAcl",
      "elasticloadbalancing:ModifyListener",
      "elasticloadbalancing:AddListenerCertificates",
      "elasticloadbalancing:RemoveListenerCertificates",
      "elasticloadbalancing:ModifyRule",
      "elasticloadbalancing:SetRulePriorities",
    ]
    resources = ["*"]
  }
}

# Role, policy and attachment carry the same create_eks || install_lbc gate as
# the Pod Identity association below, rather than being created
# unconditionally. Three reasons, all of which only bite on the
# customer-managed path this submodule exists to serve:
#
#   1. Nothing consumes them when the gate is false. The association is the
#      only thing that binds this role to a ServiceAccount, and it is skipped
#      on exactly that combination, so an unconditional role would be an IAM
#      role carrying AWSLoadBalancerControllerIAMPolicy that no principal in
#      the account can assume. Same defect create_ebs_csi already avoids for
#      the EBS CSI role below.
#   2. The names are deterministic and derived from cluster_name alone, so two
#      calls of this submodule sharing a cluster_name collide on apply with
#      EntityAlreadyExists. That is not hypothetical: examples/customer-managed-
#      everything invokes this submodule directly AND calls module "n8n", whose
#      own controllers call is always instantiated. The n8n call's toggles are
#      all false there, so this gate is what keeps it from racing the direct
#      call for the same role name.
#   3. It keeps "which resources does install_lbc = false actually skip" a
#      single answer instead of two.
#
# create_eks = true still creates them regardless of install_lbc, preserving
# the externally-installed-controller-on-a-new-cluster case the association's
# own comment below describes: that case needs the role to exist.
resource "aws_iam_policy" "lbc" {
  count = var.create_eks || var.install_lbc ? 1 : 0

  name   = "AWSLoadBalancerControllerIAMPolicy-${var.cluster_name}"
  policy = data.aws_iam_policy_document.lbc.json
  tags   = var.common_tags
}

resource "aws_iam_role" "lbc" {
  count = var.create_eks || var.install_lbc ? 1 : 0

  name = "AmazonEKSLoadBalancerControllerRole-${var.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  permissions_boundary = var.iam_permissions_boundary_arn

  tags = var.common_tags
}

resource "aws_iam_role_policy_attachment" "lbc" {
  count = var.create_eks || var.install_lbc ? 1 : 0

  role       = aws_iam_role.lbc[0].name
  policy_arn = aws_iam_policy.lbc[0].arn
}

# Gated on create_eks || install_lbc, not left unconditional: on a freshly
# created cluster (create_eks = true) nothing can already be bound to this
# ServiceAccount, so creating the association regardless of install_lbc is
# what lets an externally-installed LBC on that new cluster still get its IAM
# binding. On an existing cluster (create_eks = false), that assumption
# doesn't hold: the ServiceAccount may already carry an association (e.g.
# from a previous invocation of this exact module against the same
# cluster), and EKS hard-rejects a second one for the same ServiceAccount
# (409 ResourceInUseException, confirmed live). install_lbc = false on that
# path is this module's signal that an association already exists and it
# should not create a colliding one.
resource "aws_eks_pod_identity_association" "lbc" {
  count = var.create_eks || var.install_lbc ? 1 : 0

  cluster_name    = var.eks_cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.lbc[0].arn

  tags = var.common_tags
}

# ── Cluster Autoscaler IAM ────────────────────────────────────────────────────
# Same create_eks-aware gating as the LBC association above, and for the same
# reason: not gated on var.install_cluster_autoscaler alone, since an
# externally-installed Cluster Autoscaler on a freshly created cluster still
# needs this role bound via Pod Identity, but an existing cluster may already
# carry this ServiceAccount's association from elsewhere.

resource "aws_iam_policy" "cluster_autoscaler" {
  # checkov:skip=CKV_AWS_290:The Describe* actions in the first statement don't support resource-level ARNs in IAM at all, so "*" is required. The write actions in the second statement are scoped via a ResourceTag condition to this cluster's own node group ASGs (see eks.tf's k8s.io/cluster-autoscaler tags) - AWS's own documented mitigation for Auto Scaling APIs, which likewise don't support resource-level ARNs.
  # checkov:skip=CKV_AWS_355:Same rationale as CKV_AWS_290 above.
  count = var.create_eks || var.install_cluster_autoscaler ? 1 : 0

  name = "${var.cluster_name}-cluster-autoscaler-policy"
  tags = var.common_tags

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
        Condition = {
          StringEquals = {
            # eks_cluster_name, not cluster_name: this condition has to match
            # the ASG tag the Cluster Autoscaler actually auto-discovers by,
            # and the chart is configured with autoDiscovery.clusterName =
            # var.eks_cluster_name (controllers.tf). The two inputs are the
            # same string on the create_eks = true path (the module names the
            # cluster it creates after cluster_name), so this changes nothing
            # for a greenfield deployment. They diverge on create_eks = false,
            # where cluster_name is only this module's own resource-naming
            # prefix and the real cluster (and therefore the k8s.io/cluster-
            # autoscaler/<name> tag on its node group ASGs) carries a
            # different name entirely. Keyed on cluster_name there, the
            # condition matches no ASG and Cluster Autoscaler silently loses
            # SetDesiredCapacity/TerminateInstanceInAutoScalingGroup while
            # still appearing installed and healthy.
            "autoscaling:ResourceTag/k8s.io/cluster-autoscaler/${var.eks_cluster_name}" = "owned"
          }
        }
      },
    ]
  })
}

resource "aws_iam_role" "cluster_autoscaler" {
  count = var.create_eks || var.install_cluster_autoscaler ? 1 : 0

  name = "${var.cluster_name}-cluster-autoscaler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  permissions_boundary = var.iam_permissions_boundary_arn

  tags = var.common_tags
}

resource "aws_iam_role_policy_attachment" "cluster_autoscaler" {
  count = var.create_eks || var.install_cluster_autoscaler ? 1 : 0

  role       = aws_iam_role.cluster_autoscaler[0].name
  policy_arn = aws_iam_policy.cluster_autoscaler[0].arn
}

resource "aws_eks_pod_identity_association" "cluster_autoscaler" {
  count = var.create_eks || var.install_cluster_autoscaler ? 1 : 0

  cluster_name    = var.eks_cluster_name
  namespace       = "kube-system"
  service_account = "cluster-autoscaler"
  role_arn        = aws_iam_role.cluster_autoscaler[0].arn

  tags = var.common_tags
}

# ── EBS CSI driver IAM ────────────────────────────────────────────────────────
# EKS Pod Identity binds this role to the CSI controller's ServiceAccount via
# the pod_identity_association block on aws_eks_addon.ebs_csi (storage.tf).
#
# Gated on create_ebs_csi to match that addon, its only consumer: without the
# gate, create_ebs_csi = false left behind a role carrying
# AmazonEBSCSIDriverPolicy that nothing could ever assume. Unlike LBC/Cluster
# Autoscaler above, there is no externally-managed-CSI-driver case this
# submodule needs to support: create_ebs_csi = false already means "the
# cluster's own CSI driver handles this," with its own IAM the caller's
# platform team owns, not this submodule's.

resource "aws_iam_role" "ebs_csi" {
  count = var.create_ebs_csi ? 1 : 0

  name = "${var.cluster_name}-ebs-csi-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  permissions_boundary = var.iam_permissions_boundary_arn

  tags = var.common_tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  count = var.create_ebs_csi ? 1 : 0

  role       = aws_iam_role.ebs_csi[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}
