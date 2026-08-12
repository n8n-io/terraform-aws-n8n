# EKS Pod Identity

This module uses [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html) exclusively for granting AWS permissions to pods, not IRSA (IAM Roles for Service Accounts). It creates no OIDC provider, IRSA trust policy, or static IAM keys. The chart-owned n8n ServiceAccount carries an inert `eks.amazonaws.com/role-arn` compatibility annotation because the chart requires `serviceAccount.awsRoleArn`; credentials still come from Pod Identity.

## Why Pod Identity instead of IRSA

Pod Identity is the newer of the two mechanisms and needs less wiring: no OIDC provider to create and no per-role trust policy referencing the cluster's OIDC issuer URL. A role's trust policy just allows the `pods.eks.amazonaws.com` service principal to assume it, and an `aws_eks_pod_identity_association` binds that role to a namespace + ServiceAccount pair. The [`pod-identity-agent`](https://docs.aws.amazon.com/eks/latest/userguide/pod-id-agent-setup.html) EKS addon (`aws_eks_addon.pod_identity_agent`, see `eks.tf`) does the credential injection.

## Associations this module creates

| Component | IAM role | Namespace | ServiceAccount | Grants |
| --- | --- | --- | --- | --- |
| AWS Load Balancer Controller | `module.controllers.aws_iam_role.lbc` (`modules/controllers/iam.tf`) | `kube-system` | `aws-load-balancer-controller` | ALB/NLB and security group management (`data.aws_iam_policy_document.lbc`, the Terraform-native equivalent of the [upstream LBC IAM policy](https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.2.1/docs/install/iam_policy.json)). |
| Cluster Autoscaler | `module.controllers.aws_iam_role.cluster_autoscaler` (`modules/controllers/iam.tf`) | `kube-system` | `cluster-autoscaler` | `autoscaling:*`/`ec2:Describe*` needed to scale the node group. |
| EBS CSI driver | `module.controllers.aws_iam_role.ebs_csi` (`modules/controllers/iam.tf`) | `kube-system` | `ebs-csi-controller-sa` | `AmazonEBSCSIDriverPolicy` (AWS-managed), for the default `gp3` StorageClass. |
| n8n (S3 binary storage) | `aws_iam_role.s3` (`s3.tf`) | `var.namespace` (default `n8n`) | `n8n-enterprise` by default, `n8n-enterprise-pull` when `n8n_image_pull_secrets` is set (`local.n8n_service_account_name`) | `s3:GetObject`/`PutObject`/`DeleteObject`/`ListBucket` scoped to the module-created bucket (`aws_s3_bucket.n8n`). |

The first three live in `modules/controllers`, a submodule extracted from the
root module so an advanced caller onto an existing, shared cluster can invoke
it directly instead of going through the root module's `install_*` toggles
(see `examples/customer-managed-everything` and
`docs/customer-managed-infrastructure.md`). `create_eks = true` (the root
module's default, and the submodule's own default when invoked directly) is
what lets the LBC and Cluster Autoscaler associations below be created
unconditionally, i.e. regardless of `install_lbc`/`install_cluster_autoscaler`:
on a cluster this apply just created, nothing can already be bound to those
ServiceAccounts. `create_eks = false` (pointing at a pre-existing cluster)
changes that: the associations are then created only when the matching
`install_*` toggle is `true`, so `install_lbc = false` on an existing cluster
is read as an attestation that its association already exists there. See
`modules/controllers/iam.tf`'s `count` expressions for the exact gate.

Every association depends on `aws_eks_addon.pod_identity_agent` and binds a role that trusts `pods.eks.amazonaws.com` to a namespace and ServiceAccount. Most use `aws_eks_pod_identity_association`; EBS CSI uses the addon's inline `pod_identity_association` block. `serviceAccount.awsRoleArn` only satisfies the n8n chart; it does not provide credentials.

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
- **`terraform apply` fails on `aws_eks_pod_identity_association.lbc`/`.cluster_autoscaler` with `409 ResourceInUseException`** on `create_eks = false`: the existing cluster's `aws-load-balancer-controller` or `cluster-autoscaler` ServiceAccount already carries an association, e.g. from a previous invocation of this exact module against the same cluster, and EKS allows only one association per ServiceAccount. Confirmed live. Set `install_lbc = false` / `install_cluster_autoscaler = false`, which both skips installing a second controller release and (as of this module's `create_eks || install_<x>` gate) skips creating a colliding second association.
