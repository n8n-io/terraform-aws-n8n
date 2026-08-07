# Destroy & cleanup guide

This guide covers how to cleanly tear down the n8n infrastructure and troubleshoot common issues that may arise during `terraform destroy`.

## Prerequisites

Before destroying, back up the following from `terraform output`:

```bash
terraform output -raw n8n_encryption_key   # Save to a password manager
terraform output -raw db_password           # Save to a password manager
```

Set shell variables used throughout this guide:

```bash
CLUSTER=$(terraform output -raw cluster_name)
REGION=$(terraform output -raw aws_region)
NS=$(terraform output -raw namespace)
```

## Standard destroy

```bash
terraform destroy
```

The module's dependency graph ensures resources are destroyed in the correct order:

1. Ingress (LBC deletes the ALB while the controller is still running)
2. 60-second pause for ALB ENI/SG release
3. n8n Helm release
4. Namespace
5. KEDA, LBC, Cluster Autoscaler, Metrics Server
6. EKS node group and cluster
7. RDS, ElastiCache, S3
8. IAM roles and policies

Most destroys complete in 10–15 minutes without intervention.

## Troubleshooting

### Ingress deletion hangs

**Symptom:** `terraform destroy` stalls on `kubernetes_ingress_v1.n8n` for several minutes.

**Cause:** The LBC validating webhook is rejecting Ingress mutations because LBC pods are unhealthy. The module sets `failurePolicy: Ignore` on the webhook, but if LBC was installed before this setting was applied, the old `Fail` policy may still be active.

**Fix:** Delete the webhook configurations manually:

```bash
kubectl delete validatingwebhookconfiguration aws-load-balancer-webhook
kubectl delete mutatingwebhookconfiguration aws-load-balancer-webhook
```

Then strip the LBC finalizer from all Ingresses:

```bash
kubectl get ingress -n "$NS" -o name | while read ing; do
  kubectl patch "$ing" -n "$NS" --type=merge \
    -p '{"metadata":{"finalizers":null}}'
done
```

### Ingress deletion hangs on `ResourceInUse` for a target group

**Symptom:** `terraform destroy` fails with `Error: Ingress (n8n/n8n-webhook-public) still exists`
after waiting out the delete timeout. The Ingress has a `deletionTimestamp` but still
holds the `ingress.k8s.aws/resources` finalizer, and LBC logs repeat:

```text
failed to delete targetGroup: ... ResourceInUse: Target group '...' is currently
in use by a listener or a rule
```

**Cause:** Not a finalizer bug, and not the webhook problem above. LBC tears an
Ingress down in two steps: delete the ALB, then delete its target groups. ELBv2
keeps reporting a target group as in use for **several minutes after the load
balancer is already gone**, so the second step fails and LBC retries, holding the
finalizer. Confirmed by checking that no ALB exists while a direct
`aws elbv2 delete-target-group` still returns `ResourceInUse`. Observed taking
roughly 9 minutes on a live teardown, and more likely when several stacks are
destroyed against the same account at once.

**Do not strip the finalizer first.** That is the fix for the webhook case above,
but here it removes the only thing still trying to delete the target group, and
leaves it orphaned. Check for orphans with:

```bash
aws elbv2 describe-target-groups \
  --query "TargetGroups[?length(LoadBalancerArns)==\`0\`].TargetGroupName" --output table
```

**Fix:** Wait for ELBv2 to release it, then let LBC finish.

```bash
# 1. Poll until the target group can actually be deleted.
TG=<target-group-arn-from-the-LBC-error>
until aws elbv2 delete-target-group --target-group-arn "$TG" 2>/dev/null; do
  aws elbv2 describe-target-groups --target-group-arns "$TG" >/dev/null 2>&1 || break
  sleep 30
done

# 2. LBC backs off exponentially after repeated failures, so restart it to force
#    an immediate reconcile rather than waiting out the backoff.
kubectl rollout restart deployment/aws-load-balancer-controller -n kube-system
kubectl rollout status  deployment/aws-load-balancer-controller -n kube-system

# 3. The finalizer clears within a minute; re-run the destroy, which resumes.
terraform destroy
```

The module and `examples/split-ingress` set a 20 minute `delete` timeout on their
Ingress resources so this normally resolves without intervention. The steps above
are for when it exceeds even that.

### Namespace stuck in Terminating

**Symptom:** The namespace stays in `Terminating` state for more than 2 minutes.

**Cause:** Orphaned custom resources (ScaledObjects, TargetGroupBindings) with finalizers from controllers that have already been uninstalled.

**Fix:** Strip finalizers from all remaining resources in the namespace:

```bash
kubectl api-resources --verbs=list --namespaced -o name | while read RESOURCE; do
  kubectl get "$RESOURCE" -n "$NS" \
    -o jsonpath='{range .items[?(@.metadata.finalizers)]}{@.kind}/{@.metadata.name}{"\n"}{end}' \
    2>/dev/null | while read OBJ; do
    [ -n "$OBJ" ] || continue
    NAME=$(echo "$OBJ" | cut -d/ -f2)
    kubectl patch "$RESOURCE/$NAME" -n "$NS" --type=merge \
      -p '{"metadata":{"finalizers":null}}'
  done
done
```

### VPC deletion fails with DependencyViolation

**Symptom:** Terraform fails to delete VPC resources (subnets, internet gateway, or the VPC itself) with a `DependencyViolation` error.

**Cause:** Orphaned AWS resources — typically ENIs or security groups created by the LBC or EKS that were not cleaned up when the cluster was destroyed.

**Fix — Delete orphaned ENIs:**

```bash
VPC_ID="<your-vpc-id>"

# Find available (detached) K8s ENIs
aws ec2 describe-network-interfaces \
  --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" \
            "Name=status,Values=available" \
            "Name=description,Values=aws-K8S-*" \
  --query "NetworkInterfaces[*].NetworkInterfaceId" \
  --output text | tr '\t' '\n' | while read ENI_ID; do
  echo "Deleting ENI $ENI_ID..."
  aws ec2 delete-network-interface --region "$REGION" \
    --network-interface-id "$ENI_ID"
done
```

**Fix — Delete orphaned security groups:**

```bash
VPC_ID="<your-vpc-id>"

# Find LBC-created and EKS-managed SGs
for PATTERN in "k8s-*" "eks-cluster-sg-*"; do
  SGS=$(aws ec2 describe-security-groups \
    --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
              "Name=group-name,Values=$PATTERN" \
    --query "SecurityGroups[*].GroupId" \
    --output text 2>/dev/null)
  
  for SG_ID in $SGS; do
    echo "Revoking rules on $SG_ID..."
    # Revoke ingress/egress to break cross-references
    aws ec2 revoke-security-group-ingress --region "$REGION" \
      --group-id "$SG_ID" \
      --ip-permissions "$(aws ec2 describe-security-groups \
        --region "$REGION" --group-ids "$SG_ID" \
        --query 'SecurityGroups[0].IpPermissions' --output json)" 2>/dev/null || true
    aws ec2 revoke-security-group-egress --region "$REGION" \
      --group-id "$SG_ID" \
      --ip-permissions "$(aws ec2 describe-security-groups \
        --region "$REGION" --group-ids "$SG_ID" \
        --query 'SecurityGroups[0].IpPermissionsEgress' --output json)" 2>/dev/null || true
  done
  
  for SG_ID in $SGS; do
    echo "Deleting $SG_ID..."
    aws ec2 delete-security-group --region "$REGION" \
      --group-id "$SG_ID" || true
  done
done
```

### VPC destroy sits on "Still destroying" for ~10 minutes

**Symptom:** `terraform destroy` does not error. It reports
`module.vpc.aws_vpc.this[0]: Still destroying... [10m0s elapsed]` and keeps
going. A VPC normally deletes in seconds, so anything past a minute or two means
something inside it is holding a reference.

**Cause:** The AWS Load Balancer Controller creates a shared backend security
group, named `k8s-traffic-<cluster>-<hash>` and described as
`[k8s] Shared Backend SecurityGroup for LoadBalancer`. It is created by the
controller, not by Terraform, so it is not in state and `terraform destroy`
never removes it. LBC normally deletes it once the last Ingress goes, but it can
be left behind when the Ingress teardown does not complete cleanly, for example
after the target-group wait above required manual recovery. The VPC then cannot
be deleted while it exists, and the AWS API expresses that as a long retry
rather than an immediate `DependencyViolation`.

**Fix:** Find it by tag rather than by name. The tags identify the owning
cluster exactly, which matters in a shared VPC where a name glob like `k8s-*`
would also match another cluster's security groups.

```bash
VPC_ID="<your-vpc-id>"
CLUSTER="<your-cluster-name>"

aws ec2 describe-security-groups \
  --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" \
            "Name=tag:elbv2.k8s.aws/cluster,Values=$CLUSTER" \
            "Name=tag:elbv2.k8s.aws/resource,Values=backend-sg" \
  --query "SecurityGroups[*].{Id:GroupId,Name:GroupName}" --output table

# Confirm it is the cluster you are destroying, then delete it.
aws ec2 delete-security-group --region "$REGION" --group-id "<sg-id>"
```

The in-flight `terraform destroy` picks this up on its next retry and finishes
without needing to be restarted.

### Orphaned ALB blocks IGW/VPC deletion

**Symptom:** The ALB created by the LBC was not cleaned up and blocks internet gateway or VPC deletion.

**Cause:** The LBC was removed before it could process the Ingress deletion and clean up the ALB.

**Fix:**

```bash
VPC_ID="<your-vpc-id>"

# Find and delete cluster-owned ALBs
ALB_ARNS=$(aws elbv2 describe-load-balancers \
  --region "$REGION" \
  --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" \
  --output text)

for ARN in $ALB_ARNS; do
  OWNED=$(aws elbv2 describe-tags --region "$REGION" \
    --resource-arns "$ARN" \
    --query "TagDescriptions[0].Tags[?Key=='elbv2.k8s.aws/cluster' && Value=='$CLUSTER'].Value" \
    --output text)
  if [ -n "$OWNED" ]; then
    echo "Deleting ALB $ARN..."
    aws elbv2 delete-load-balancer --region "$REGION" \
      --load-balancer-arn "$ARN"
  fi
done

# Wait for ALBs to fully deprovision (ENIs released)
echo "Waiting 60s for ALB deprovisioning..."
sleep 60

# Delete orphaned target groups
TG_ARNS=$(aws elbv2 describe-target-groups \
  --region "$REGION" \
  --query "TargetGroups[?VpcId=='$VPC_ID'].TargetGroupArn" \
  --output text)

for TG_ARN in $TG_ARNS; do
  OWNED=$(aws elbv2 describe-tags --region "$REGION" \
    --resource-arns "$TG_ARN" \
    --query "TagDescriptions[0].Tags[?Key=='elbv2.k8s.aws/cluster' && Value=='$CLUSTER'].Value" \
    --output text)
  if [ -n "$OWNED" ]; then
    echo "Deleting target group $TG_ARN..."
    aws elbv2 delete-target-group --region "$REGION" \
      --target-group-arn "$TG_ARN"
  fi
done
```

### Node group deletion takes 30+ minutes

**Symptom:** `terraform destroy` stalls on `aws_eks_node_group.n8n` for 30 minutes.

**Cause:** EKS adds a `Terminate-LC-Hook` lifecycle hook to the node group's Auto Scaling Group with a 30-minute heartbeat timeout. If the EKS control plane is being destroyed concurrently (or is already gone), no handler responds and instances wait the full timeout.

**Fix:** Delete the lifecycle hook manually:

```bash
# Find the ASG name
ASG_NAME=$(aws autoscaling describe-auto-scaling-groups \
  --region "$REGION" \
  --query "AutoScalingGroups[?contains(Tags[?Key=='eks:cluster-name'].Value, '$CLUSTER')].AutoScalingGroupName" \
  --output text)

# Delete the hook
aws autoscaling delete-lifecycle-hook \
  --region "$REGION" \
  --auto-scaling-group-name "$ASG_NAME" \
  --lifecycle-hook-name "Terminate-LC-Hook"

# If instances are already stuck in Terminating:Wait, complete the action
for INSTANCE_ID in $(aws autoscaling describe-auto-scaling-instances \
  --region "$REGION" \
  --query "AutoScalingInstances[?AutoScalingGroupName=='$ASG_NAME' && LifecycleState=='Terminating:Wait'].InstanceId" \
  --output text); do
  aws autoscaling complete-lifecycle-action \
    --region "$REGION" \
    --auto-scaling-group-name "$ASG_NAME" \
    --lifecycle-hook-name "Terminate-LC-Hook" \
    --instance-id "$INSTANCE_ID" \
    --lifecycle-action-result CONTINUE
done
```

### Orphaned EBS volumes

**Symptom:** EBS volumes tagged with the cluster name remain after destroy.

**Cause:** PVCs that were not deleted before the node group was removed leave orphaned EBS volumes. The module ships a default `gp3` StorageClass (`storage.tf`), so stateful workloads deployed beside n8n create EBS volumes; delete their PVCs before running `terraform destroy`.

**Fix:**

```bash
VOL_IDS=$(aws ec2 describe-volumes \
  --region "$REGION" \
  --filters "Name=tag:kubernetes.io/cluster/$CLUSTER,Values=owned" \
  --query "Volumes[*].VolumeId" \
  --output text)

for VOL in $VOL_IDS; do
  echo "Deleting volume $VOL..."
  aws ec2 detach-volume --region "$REGION" --volume-id "$VOL" --force 2>/dev/null || true
  sleep 5
  aws ec2 delete-volume --region "$REGION" --volume-id "$VOL"
done
```

### Removing stuck resources from Terraform state

If a resource was already deleted outside of Terraform (e.g. via the console) and Terraform cannot refresh it:

```bash
# List all resources in state
terraform state list

# Remove a specific resource from state (does NOT delete the actual resource)
terraform state rm <resource_address>

# Example: remove a namespace that was force-deleted via kubectl
terraform state rm kubernetes_namespace.n8n[0]
```

After removing the resource from state, re-run `terraform destroy` for the remaining resources.
