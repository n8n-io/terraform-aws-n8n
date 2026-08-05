# EKS Pod Identity

This module uses [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html) exclusively for granting AWS permissions to pods, not IRSA (IAM Roles for Service Accounts). There is no OIDC provider, no `eks.amazonaws.com/role-arn` ServiceAccount annotation, and no static IAM keys anywhere in the module.

## Why Pod Identity instead of IRSA

Pod Identity is the newer of the two mechanisms and needs less wiring: no OIDC provider to create and no per-role trust policy referencing the cluster's OIDC issuer URL. A role's trust policy just allows the `pods.eks.amazonaws.com` service principal to assume it, and an `aws_eks_pod_identity_association` binds that role to a namespace + ServiceAccount pair. The [`pod-identity-agent`](https://docs.aws.amazon.com/eks/latest/userguide/pod-id-agent-setup.html) EKS addon (`aws_eks_addon.pod_identity_agent`, see `eks.tf`) does the credential injection.

## Associations this module creates

| Component | IAM role (`iam.tf` / `s3.tf`) | Namespace | ServiceAccount | Grants |
| --- | --- | --- | --- | --- |
| AWS Load Balancer Controller | `aws_iam_role.lbc` | `kube-system` | `aws-load-balancer-controller` | ALB/NLB and security group management (`data.aws_iam_policy_document.lbc`, the Terraform-native equivalent of the [upstream LBC IAM policy](https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.2.1/docs/install/iam_policy.json)). |
| Cluster Autoscaler | `aws_iam_role.cluster_autoscaler` | `kube-system` | `cluster-autoscaler` | `autoscaling:*`/`ec2:Describe*` needed to scale the node group. |
| EBS CSI driver | `aws_iam_role.ebs_csi` | `kube-system` | `ebs-csi-controller-sa` | `AmazonEBSCSIDriverPolicy` (AWS-managed), for the default `gp3` StorageClass. |
| n8n (S3 binary storage) | `aws_iam_role.s3` | `var.namespace` (default `n8n`) | `n8n-enterprise` | `s3:GetObject`/`PutObject`/`DeleteObject`/`ListBucket` scoped to the module-created bucket (`aws_s3_bucket.n8n`). |

Every association depends on `aws_eks_addon.pod_identity_agent` and follows the same shape: an IAM role trusting `pods.eks.amazonaws.com` for `sts:AssumeRole` + `sts:TagSession`, a policy attachment, and an `aws_eks_pod_identity_association` binding the role to a `(namespace, service_account)` pair. `n8n.tf`'s `helm_release.n8n` sets `serviceAccount.awsRoleArn` to `aws_iam_role.s3.arn` only to satisfy the chart's template validation; the actual credentials come from the Pod Identity agent, not from that field.

## Extending Pod Identity for your own workloads

To grant AWS permissions to a workload you deploy beside n8n (in the same cluster), follow the same pattern rather than reaching for IRSA or static keys:

```hcl
resource "aws_iam_role" "my_workload" {
  name = "my-workload-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "my_workload" {
  role       = aws_iam_role.my_workload.name
  policy_arn = aws_iam_policy.my_workload.arn
}

resource "aws_eks_pod_identity_association" "my_workload" {
  cluster_name    = module.n8n.cluster_name
  namespace       = "my-namespace"
  service_account = "my-service-account"
  role_arn        = aws_iam_role.my_workload.arn
}
```

The `pod-identity-agent` addon this module installs is cluster-wide, so your association only needs `module.n8n.cluster_name`; you do not need to reinstall the addon or create a second one.

## Troubleshooting

- **Pods hang waiting for AWS credentials, or calls fail with `AccessDenied`/`NoCredentialProviders`:** confirm the association's `namespace` and `service_account` exactly match what the pod actually runs as (`kubectl get pod <pod> -o jsonpath='{.spec.serviceAccountName}'` and `-n <namespace>`), and that the `pod-identity-agent` addon is `ACTIVE` (`aws eks describe-addon --cluster-name <cluster> --addon-name eks-pod-identity-agent`).
- **A newly created association has no effect on already-running pods:** Pod Identity credentials are fetched at pod start. Restart the affected pods (e.g. `kubectl rollout restart deployment/<name> -n <namespace>`) after creating or changing an association.
