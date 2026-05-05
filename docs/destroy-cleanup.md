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

**Cause:** PVCs that were not deleted before the node group was removed leave orphaned EBS volumes.

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
terraform state rm kubernetes_namespace.n8n
```

After removing the resource from state, re-run `terraform destroy` for the remaining resources.
