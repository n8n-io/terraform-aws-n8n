# ── Pre-destroy pod drain + PVC release ──────────────────────────────────────
# When Helm uninstalls n8n, it waits for pods to terminate. EBS volume detach
# delays can hold pods in Terminating state for 5–10+ minutes, causing the
# Helm uninstall to time out with "context deadline exceeded".
#
# This resource scales down all n8n deployments, force-deletes any remaining
# pods, and deletes PVCs (which triggers the EBS CSI driver to release the
# underlying EBS volumes) — all while the cluster and CSI driver are still
# alive. Without the PVC step, volumes would be orphaned when node groups go
# away.

resource "null_resource" "drain_n8n_pods" {
  triggers = {
    cluster_name = aws_eks_cluster.n8n.name
    namespace    = var.namespace
    aws_region   = local.aws_region
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      echo "Draining n8n pods before Helm uninstall..."
      aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.aws_region} 2>/dev/null || true
      kubectl scale deployment --all -n ${self.triggers.namespace} --replicas=0 2>/dev/null || true
      kubectl get pods -n ${self.triggers.namespace} -o name 2>/dev/null | \
        xargs -r kubectl delete --force --grace-period=0 -n ${self.triggers.namespace} 2>/dev/null || true
      echo "Deleting PVCs so EBS CSI releases the underlying volumes..."
      kubectl delete pvc --all -n ${self.triggers.namespace} --timeout=60s 2>/dev/null || true
      # Stubborn PVCs blocked on finalizers — strip them so deletion completes.
      kubectl get pvc -n ${self.triggers.namespace} -o name 2>/dev/null | while read pvc; do
        kubectl patch "$pvc" -n ${self.triggers.namespace} --type=merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
      done
      echo "Pod and PVC drain complete."
    EOT
  }

  # depends_on = [helm_release.n8n] ensures this resource is destroyed BEFORE
  # the Helm release — so pods and PVCs are gone before Helm tries to uninstall.
  depends_on = [helm_release.n8n]
}

# ── VPC-scoped orphan cleanup (ALBs, target groups, security groups, EBS) ────
# The AWS Load Balancer Controller creates ALBs, target groups, security groups,
# and TargetGroupBinding CRDs outside of Terraform state. During destroy the LBC
# pod may be evicted before it finishes cleaning up, leaving:
#
#   - ALBs with ENIs in VPC subnets      → blocks Internet Gateway deletion
#   - ALB listeners referencing the cert  → blocks ACM certificate deletion
#   - TargetGroupBindings with finalizers → blocks namespace deletion
#   - Security groups with cross-refs     → blocks VPC deletion
#
# This script force-deletes all of these using the AWS API and kubectl.

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

      # ── 2. Strip TargetGroupBinding finalizers (unblocks namespace) ────────
      echo "Stripping TargetGroupBinding finalizers in namespace $NS..."
      kubectl get targetgroupbindings.elbv2.k8s.aws -n "$NS" -o name 2>/dev/null | while read tgb; do
        kubectl patch "$tgb" -n "$NS" --type=merge \
          -p '{"metadata":{"finalizers":null}}' 2>/dev/null \
          && echo "  Stripped finalizers from $tgb" || true
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

      # ── 6. Delete orphaned security groups ────────────────────────────────
      echo "Scanning for orphaned ALB security groups in VPC $VPC_ID..."
      ALL_SGS=$(aws ec2 describe-security-groups \
        --region "$REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" \
                  "Name=group-name,Values=k8s-*" \
        --query "SecurityGroups[*].GroupId" \
        --output text 2>/dev/null || echo "")
      if [ -z "$ALL_SGS" ]; then
        echo "No orphaned ALB security groups found."
      else
        echo "Found security groups to clean up: $ALL_SGS"
        # Two passes handle cross-references between the ALB and traffic SGs.
        for PASS in 1 2; do
          for SG_ID in $ALL_SGS; do
            aws ec2 delete-security-group \
              --region "$REGION" \
              --group-id "$SG_ID" 2>/dev/null \
              && echo "  Deleted $SG_ID" || true
          done
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

  # Destroy ordering (reversed from depends_on):
  #   1. kubernetes_ingress_v1.n8n     → tells K8s to delete the Ingress
  #   2. null_resource.cleanup_alb_sgs → strips TGB finalizers, force-deletes ALB, waits for ENI release
  #   3. kubernetes_namespace.n8n      → namespace can now be deleted (TGB finalizers are gone)
  #      aws_acm_certificate.n8n       → cert can now be deleted (ALB listener is gone)
  #
  # Without these dependencies, (2) and (3) run in parallel and the cert/namespace
  # deletions hang for minutes waiting for the ALB and TGB finalizers.
  depends_on = [
    aws_acm_certificate.n8n,
    kubernetes_namespace.n8n,
  ]
}