# ── Pre-destroy: ALB cleanup, finalizer stripping, pod drain, PVC release ────
# This resource runs FIRST in the destroy sequence — before the Ingress, the
# Helm release, or the namespace are touched. At this point the EKS cluster,
# node group, and kubectl are all still alive.
#
# Destroy ordering (reverse of depends_on):
#   1. null_resource.drain_n8n_pods  ← THIS RUNS FIRST
#   2. kubernetes_ingress_v1.n8n     ← completes instantly (finalizer stripped)
#   3. helm_release.n8n              ← completes fast (pods already force-deleted)
#   ...remaining resources...
#
# It solves the chicken-and-egg problem where:
#   - Terraform tries to delete the Ingress K8s resource
#   - K8s blocks on the LBC finalizer (ingress.k8s.aws/resources)
#   - The LBC tries to delete the ALB but may be evicted mid-cleanup
#   - The Ingress deletion hangs for up to 30 minutes
#
# By force-deleting the ALB via the AWS API and stripping all finalizers here,
# every downstream Terraform deletion (Ingress, namespace, ACM cert, IGW)
# completes instantly.

resource "null_resource" "drain_n8n_pods" {
  triggers = {
    cluster_name = aws_eks_cluster.n8n.name
    namespace    = var.namespace
    aws_region   = local.aws_region
    vpc_id       = local.vpc_id
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      set +e
      REGION="${self.triggers.aws_region}"
      VPC_ID="${self.triggers.vpc_id}"
      CLUSTER="${self.triggers.cluster_name}"
      NS="${self.triggers.namespace}"

      aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" 2>/dev/null || true

      # ── 1. Force-delete cluster-owned ALBs via AWS API ────────────────────
      # Bypasses the LBC entirely — no need to wait for the controller to
      # reconcile. Once the ALB is gone, the LBC finalizer becomes a no-op.
      echo "Scanning for cluster-owned ALBs in VPC $VPC_ID..."
      ALB_ARNS=$(aws elbv2 describe-load-balancers \
        --region "$REGION" \
        --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" \
        --output text 2>/dev/null || echo "")

      DELETED_ARNS=""
      for ARN in $ALB_ARNS; do
        OWNED=$(aws elbv2 describe-tags \
          --region "$REGION" \
          --resource-arns "$ARN" \
          --query "TagDescriptions[0].Tags[?Key=='elbv2.k8s.aws/cluster' && Value=='$CLUSTER'].Value" \
          --output text 2>/dev/null || echo "")
        if [ -n "$OWNED" ]; then
          echo "  Deleting ALB $ARN..."
          aws elbv2 delete-load-balancer \
            --region "$REGION" \
            --load-balancer-arn "$ARN" 2>/dev/null \
            && DELETED_ARNS="$DELETED_ARNS $ARN" \
            || echo "  Failed to issue delete for $ARN"
        fi
      done

      # ── 2. Delete LBC webhooks ────────────────────────────────────────────
      # The LBC installs a ValidatingWebhookConfiguration that intercepts all
      # Ingress mutations. When LBC pods are unhealthy the webhook rejects
      # every patch — including our finalizer strip below. Delete it first.
      echo "Deleting LBC admission webhooks..."
      kubectl delete validatingwebhookconfiguration aws-load-balancer-webhook 2>/dev/null \
        && echo "  Deleted validating webhook" || true
      kubectl delete mutatingwebhookconfiguration aws-load-balancer-webhook 2>/dev/null \
        && echo "  Deleted mutating webhook" || true

      # ── 3. Strip Ingress finalizers ───────────────────────────────────────
      # The LBC adds "ingress.k8s.aws/resources" to every Ingress it manages.
      # Stripping it now means the later `terraform destroy` of the Ingress
      # K8s resource completes instantly instead of blocking for 30 minutes.
      echo "Stripping Ingress finalizers in namespace $NS..."
      kubectl get ingress -n "$NS" -o name 2>/dev/null | while read ing; do
        kubectl patch "$ing" -n "$NS" --type=merge \
          -p '{"metadata":{"finalizers":null}}' 2>/dev/null \
          && echo "  Stripped finalizers from $ing" || true
      done

      # ── 4. Strip TargetGroupBinding finalizers ────────────────────────────
      # Prevents namespace deletion from hanging on TGB CRD finalizers.
      echo "Stripping TargetGroupBinding finalizers in namespace $NS..."
      kubectl get targetgroupbindings.elbv2.k8s.aws -n "$NS" -o name 2>/dev/null | while read tgb; do
        kubectl patch "$tgb" -n "$NS" --type=merge \
          -p '{"metadata":{"finalizers":null}}' 2>/dev/null \
          && echo "  Stripped finalizers from $tgb" || true
      done

      # ── 5. Strip KEDA ScaledObject finalizers ─────────────────────────────
      # KEDA adds "finalizer.keda.sh" to ScaledObjects. If the KEDA controller
      # is evicted before cleanup, the finalizer blocks namespace deletion.
      echo "Stripping KEDA ScaledObject finalizers in namespace $NS..."
      kubectl get scaledobjects.keda.sh -n "$NS" -o name 2>/dev/null | while read so; do
        kubectl patch "$so" -n "$NS" --type=merge \
          -p '{"metadata":{"finalizers":null}}' 2>/dev/null \
          && echo "  Stripped finalizers from $so" || true
      done

      # ── 6. Wait for ALBs to be fully deprovisioned (ENIs released) ───────
      # The ALB must be fully gone before the IGW or VPC can be destroyed.
      if [ -n "$DELETED_ARNS" ]; then
        echo "Waiting for ALBs to be fully deprovisioned..."
        for ATTEMPT in $(seq 1 30); do
          ALL_GONE=true
          for ARN in $DELETED_ARNS; do
            STATE=$(aws elbv2 describe-load-balancers \
              --region "$REGION" \
              --load-balancer-arns "$ARN" \
              --query "LoadBalancers[0].State.Code" \
              --output text 2>/dev/null || echo "gone")
            if [ "$STATE" != "gone" ]; then
              ALL_GONE=false
            fi
          done
          if $ALL_GONE; then
            echo "  All ALBs deprovisioned."
            break
          fi
          echo "  Attempt $ATTEMPT/30: ALBs still deprovisioning, waiting 10s..."
          sleep 10
        done
      else
        echo "  No cluster-owned ALBs found."
      fi

      # ── 7. Scale down pods and force-delete stragglers ────────────────────
      # Without this, `helm uninstall --wait` blocks on Terminating pods for
      # up to 10 minutes. Force-delete ensures Helm completes instantly.
      echo "Draining n8n pods before Helm uninstall..."
      kubectl scale deployment --all -n "$NS" --replicas=0 2>/dev/null || true
      kubectl get pods -n "$NS" -o name 2>/dev/null | \
        xargs -r kubectl delete --force --grace-period=0 -n "$NS" 2>/dev/null || true

      # ── 8. Delete PVCs so EBS CSI releases volumes ────────────────────────
      echo "Deleting PVCs so EBS CSI releases the underlying volumes..."
      kubectl delete pvc --all -n "$NS" --timeout=60s 2>/dev/null || true
      kubectl get pvc -n "$NS" -o name 2>/dev/null | while read pvc; do
        kubectl patch "$pvc" -n "$NS" --type=merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
      done

      # ── 9. Delete ASG terminate lifecycle hooks ───────────────────────
      # EKS adds Terminate-LC-Hook to the node group ASG with a 30-minute
      # heartbeat timeout. When Terraform deletes the node group, the ASG
      # scales to 0 and instances enter Terminating:Wait. The hook notifies
      # the EKS control plane, but if the cluster is being torn down
      # concurrently, no handler responds and instances wait the full
      # 30 minutes before DefaultResult=CONTINUE fires. Deleting the hook
      # now means the later node group deletion completes in ~2 minutes
      # instead of 30.
      echo "Removing ASG terminate lifecycle hooks..."
      ASG_NAMES=$(aws autoscaling describe-auto-scaling-groups \
        --region "$REGION" \
        --query "AutoScalingGroups[?contains(Tags[?Key=='eks:cluster-name'].Value, '$CLUSTER')].AutoScalingGroupName" \
        --output text 2>/dev/null || echo "")
      for ASG_NAME in $ASG_NAMES; do
        aws autoscaling delete-lifecycle-hook \
          --region "$REGION" \
          --auto-scaling-group-name "$ASG_NAME" \
          --lifecycle-hook-name "Terminate-LC-Hook" 2>/dev/null \
          && echo "  Deleted Terminate-LC-Hook from $ASG_NAME" || true
      done

      echo "Pre-destroy drain complete."
    EOT
  }

  # depends_on controls destroy ordering (reversed):
  #   drain_n8n_pods depends_on [ingress, helm] means during destroy:
  #   drain runs FIRST → then ingress → then helm release
  # This ensures ALB cleanup and finalizer stripping happen while the cluster
  # is fully operational, before Terraform touches the Ingress or Helm release.
  depends_on = [
    kubernetes_ingress_v1.n8n,
    helm_release.n8n,
  ]
}

# ── VPC-scoped orphan cleanup (safety net) ───────────────────────────────────
# Belt-and-suspenders companion to drain_n8n_pods above. The drain resource
# handles the critical-path ALB deletion and finalizer stripping. This resource
# runs later in the destroy sequence and catches anything that slipped through:
# orphaned target groups, security groups, and EBS volumes that would otherwise
# block VPC/IGW deletion.

resource "null_resource" "cleanup_alb_sgs" {
  triggers = {
    vpc_id       = local.vpc_id
    aws_region   = local.aws_region
    cluster_name = aws_eks_cluster.n8n.name
    namespace    = var.namespace
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      set +e
      REGION="${self.triggers.aws_region}"
      VPC_ID="${self.triggers.vpc_id}"
      CLUSTER="${self.triggers.cluster_name}"
      NS="${self.triggers.namespace}"

      # ── 1. Configure kubectl ──────────────────────────────────────────────
      aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" 2>/dev/null || true

      # ── 2. Strip remaining finalizers (safety net) ────────────────────────
      echo "Stripping finalizers from all remaining resources in namespace $NS..."
      # By this point KEDA and LBC Helm charts have been uninstalled, removing
      # their CRDs. Any custom resource instances (ScaledObjects, TGBs) that
      # still have finalizers become orphans the namespace controller cannot
      # finalize, hanging namespace deletion indefinitely.
      # A blanket strip via the K8s API avoids enumerating every CRD type.
      kubectl api-resources --verbs=list --namespaced -o name 2>/dev/null | while read RESOURCE; do
        kubectl get "$RESOURCE" -n "$NS" -o jsonpath='{range .items[?(@.metadata.finalizers)]}{@.kind}/{@.metadata.name}{"\n"}{end}' 2>/dev/null | while read OBJ; do
          if [ -n "$OBJ" ]; then
            NAME=$(echo "$OBJ" | cut -d/ -f2)
            kubectl patch "$RESOURCE/$NAME" -n "$NS" --type=merge \
              -p '{"metadata":{"finalizers":null}}' 2>/dev/null \
              && echo "  Stripped finalizers from $OBJ" || true
          fi
        done
      done

      # ── 3. Find and delete cluster-owned ALBs ─────────────────────────────
      echo "Scanning for orphaned ALBs in VPC $VPC_ID..."
      ALB_ARNS=$(aws elbv2 describe-load-balancers \
        --region "$REGION" \
        --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" \
        --output text 2>/dev/null || echo "")

      DELETED_ARNS=""
      for ARN in $ALB_ARNS; do
        OWNED=$(aws elbv2 describe-tags \
          --region "$REGION" \
          --resource-arns "$ARN" \
          --query "TagDescriptions[0].Tags[?Key=='elbv2.k8s.aws/cluster' && Value=='$CLUSTER'].Value" \
          --output text 2>/dev/null || echo "")
        if [ -n "$OWNED" ]; then
          echo "Deleting ALB $ARN..."
          aws elbv2 delete-load-balancer \
            --region "$REGION" \
            --load-balancer-arn "$ARN" 2>/dev/null \
            && DELETED_ARNS="$DELETED_ARNS $ARN" \
            || echo "  Failed to issue delete for $ARN"
        fi
      done

      # ── 4. Wait for ALBs to be fully gone (ENIs released) ─────────────────
      if [ -n "$DELETED_ARNS" ]; then
        echo "Waiting for ALBs to be fully deprovisioned..."
        for ATTEMPT in $(seq 1 30); do
          ALL_GONE=true
          for ARN in $DELETED_ARNS; do
            STATE=$(aws elbv2 describe-load-balancers \
              --region "$REGION" \
              --load-balancer-arns "$ARN" \
              --query "LoadBalancers[0].State.Code" \
              --output text 2>/dev/null || echo "gone")
            if [ "$STATE" != "gone" ]; then
              ALL_GONE=false
            fi
          done
          if $ALL_GONE; then
            echo "  All ALBs deprovisioned."
            break
          fi
          echo "  Attempt $ATTEMPT/30: ALBs still deprovisioning, waiting 10s..."
          sleep 10
        done
      else
        echo "No cluster-owned ALBs found."
      fi

      # ── 5. Delete orphaned target groups ──────────────────────────────────
      echo "Scanning for orphaned target groups in VPC $VPC_ID..."
      TG_ARNS=$(aws elbv2 describe-target-groups \
        --region "$REGION" \
        --query "TargetGroups[?VpcId=='$VPC_ID'].TargetGroupArn" \
        --output text 2>/dev/null || echo "")
      for TG_ARN in $TG_ARNS; do
        OWNED=$(aws elbv2 describe-tags \
          --region "$REGION" \
          --resource-arns "$TG_ARN" \
          --query "TagDescriptions[0].Tags[?Key=='elbv2.k8s.aws/cluster' && Value=='$CLUSTER'].Value" \
          --output text 2>/dev/null || echo "")
        if [ -n "$OWNED" ]; then
          aws elbv2 delete-target-group \
            --region "$REGION" \
            --target-group-arn "$TG_ARN" 2>/dev/null \
            && echo "  Deleted target group $TG_ARN" || true
        fi
      done

      # ── 6. Delete orphaned ENIs ───────────────────────────────────────
      # When EKS nodes terminate, their secondary K8s ENIs (aws-K8S-*)
      # are released asynchronously. If they're still attached to the
      # EKS cluster SG when we try to delete it, the SG deletion fails
      # with DependencyViolation. Delete them first.
      echo "Scanning for orphaned ENIs in VPC $VPC_ID..."
      ORPHAN_ENIS=$(aws ec2 describe-network-interfaces \
        --region "$REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" \
                  "Name=status,Values=available" \
                  "Name=description,Values=aws-K8S-*" \
        --query "NetworkInterfaces[*].NetworkInterfaceId" \
        --output text 2>/dev/null || echo "")
      if [ -z "$ORPHAN_ENIS" ]; then
        echo "No orphaned ENIs found."
      else
        for ENI_ID in $ORPHAN_ENIS; do
          aws ec2 delete-network-interface \
            --region "$REGION" \
            --network-interface-id "$ENI_ID" 2>/dev/null \
            && echo "  Deleted $ENI_ID" || true
        done
      fi

      # ── 7. Delete orphaned security groups ────────────────────────────────
      echo "Scanning for orphaned security groups in VPC $VPC_ID..."
      # Match both LBC-created SGs (k8s-*) and EKS-managed cluster SGs
      # (eks-cluster-sg-*). The EKS cluster SG is created by AWS when the
      # cluster is provisioned but is NOT always deleted when the cluster
      # is destroyed, leaving an orphan that blocks VPC deletion.
      LBC_SGS=$(aws ec2 describe-security-groups \
        --region "$REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" \
                  "Name=group-name,Values=k8s-*" \
        --query "SecurityGroups[*].GroupId" \
        --output text 2>/dev/null || echo "")
      EKS_SGS=$(aws ec2 describe-security-groups \
        --region "$REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" \
                  "Name=group-name,Values=eks-cluster-sg-*" \
        --query "SecurityGroups[*].GroupId" \
        --output text 2>/dev/null || echo "")
      ALL_SGS=$(echo "$LBC_SGS $EKS_SGS" | xargs)
      if [ -z "$ALL_SGS" ]; then
        echo "No orphaned security groups found."
      else
        echo "Found security groups to clean up: $ALL_SGS"
        # First revoke all ingress/egress rules to break cross-references,
        # then delete. Without this, SG-A referencing SG-B blocks deletion of
        # SG-B even though both are in our delete list.
        for SG_ID in $ALL_SGS; do
          aws ec2 revoke-security-group-ingress \
            --region "$REGION" \
            --group-id "$SG_ID" \
            --ip-permissions "$(aws ec2 describe-security-groups \
              --region "$REGION" \
              --group-ids "$SG_ID" \
              --query "SecurityGroups[0].IpPermissions" \
              --output json 2>/dev/null)" 2>/dev/null || true
          aws ec2 revoke-security-group-egress \
            --region "$REGION" \
            --group-id "$SG_ID" \
            --ip-permissions "$(aws ec2 describe-security-groups \
              --region "$REGION" \
              --group-ids "$SG_ID" \
              --query "SecurityGroups[0].IpPermissionsEgress" \
              --output json 2>/dev/null)" 2>/dev/null || true
        done
        for SG_ID in $ALL_SGS; do
          aws ec2 delete-security-group \
            --region "$REGION" \
            --group-id "$SG_ID" 2>/dev/null \
            && echo "  Deleted $SG_ID" || true
        done
      fi

      # ── 7. Delete orphaned EBS volumes ────────────────────────────────────
      echo "Scanning for orphaned EBS volumes tagged with cluster $CLUSTER..."
      VOL_IDS=$(aws ec2 describe-volumes \
        --region "$REGION" \
        --filters "Name=tag:kubernetes.io/cluster/$CLUSTER,Values=owned" \
        --query "Volumes[*].VolumeId" \
        --output text 2>/dev/null || echo "")
      if [ -z "$VOL_IDS" ]; then
        echo "No orphaned EBS volumes found."
      else
        echo "Found EBS volumes to clean up: $VOL_IDS"
        for VOL in $VOL_IDS; do
          aws ec2 detach-volume --region "$REGION" --volume-id "$VOL" --force 2>/dev/null || true
          for i in 1 2 3 4 5; do
            STATE=$(aws ec2 describe-volumes --region "$REGION" --volume-ids "$VOL" \
              --query "Volumes[0].State" --output text 2>/dev/null || echo "")
            [ "$STATE" = "available" ] && break
            sleep 3
          done
          aws ec2 delete-volume --region "$REGION" --volume-id "$VOL" 2>/dev/null \
            && echo "  Deleted $VOL" || echo "  Failed to delete $VOL (may still be in-use)"
        done
      fi

      echo "Cleanup complete."
    EOT
  }

  # Safety net — runs after the ingress is deleted but before the namespace,
  # cert, and VPC. Catches orphaned target groups, security groups, and EBS
  # volumes that drain_n8n_pods didn't handle.
  depends_on = [
    aws_acm_certificate.n8n,
    kubernetes_namespace.n8n,
  ]
}