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

# ── VPC-scoped orphan cleanup (ALB security groups + EBS volumes) ────────────
# The AWS Load Balancer Controller creates security groups for each ALB
# (k8s-n8n-* and k8s-traffic-*) outside of Terraform state. If Ingress deletion
# times out or the LBC can't finish, those SGs block VPC deletion with a
# DependencyViolation.
#
# Dynamically provisioned EBS volumes (created by the EBS CSI driver in
# response to PVCs) are similarly outside Terraform state. The drain step
# above should have released them, but a best-effort sweep by cluster tag
# catches any that slipped through.
#
# This runs after the Ingress/ALB has been torn down but before the VPC is
# destroyed.

resource "null_resource" "cleanup_alb_sgs" {
  triggers = {
    vpc_id       = local.vpc_id
    aws_region   = local.aws_region
    cluster_name = aws_eks_cluster.n8n.name
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      echo "Scanning for orphaned ALB security groups in VPC ${self.triggers.vpc_id}..."
      ALL_SGS=$(aws ec2 describe-security-groups \
        --region ${self.triggers.aws_region} \
        --filters "Name=vpc-id,Values=${self.triggers.vpc_id}" \
                  "Name=group-name,Values=k8s-*" \
        --query "SecurityGroups[*].GroupId" \
        --output text 2>/dev/null || echo "")
      if [ -z "$ALL_SGS" ]; then
        echo "No orphaned ALB security groups found."
      else
        echo "Found security groups to clean up: $ALL_SGS"
        # Two passes handle cross-references between the ALB and traffic security groups
        for PASS in 1 2; do
          for SG_ID in $ALL_SGS; do
            aws ec2 delete-security-group \
              --region ${self.triggers.aws_region} \
              --group-id "$SG_ID" 2>/dev/null \
              && echo "Deleted $SG_ID" || true
          done
        done
      fi

      echo "Scanning for orphaned EBS volumes tagged with cluster ${self.triggers.cluster_name}..."
      VOL_IDS=$(aws ec2 describe-volumes \
        --region ${self.triggers.aws_region} \
        --filters "Name=tag:kubernetes.io/cluster/${self.triggers.cluster_name},Values=owned" \
        --query "Volumes[*].VolumeId" \
        --output text 2>/dev/null || echo "")
      if [ -z "$VOL_IDS" ]; then
        echo "No orphaned EBS volumes found."
      else
        echo "Found EBS volumes to clean up: $VOL_IDS"
        for VOL in $VOL_IDS; do
          # Force-detach if still attached (nodes are usually gone by now).
          aws ec2 detach-volume --region ${self.triggers.aws_region} --volume-id "$VOL" --force 2>/dev/null || true
          for i in 1 2 3 4 5; do
            STATE=$(aws ec2 describe-volumes --region ${self.triggers.aws_region} --volume-ids "$VOL" --query "Volumes[0].State" --output text 2>/dev/null || echo "")
            [ "$STATE" = "available" ] && break
            sleep 3
          done
          aws ec2 delete-volume --region ${self.triggers.aws_region} --volume-id "$VOL" 2>/dev/null \
            && echo "Deleted $VOL" || echo "Failed to delete $VOL (may still be in-use)"
        done
      fi
    EOT
  }

  # The VPC is owned by the caller, so orphans created outside Terraform state
  # (ALB SGs, dynamically provisioned EBS) must be swept before the caller's
  # VPC destroy runs. Adding null_resource.cleanup_alb_sgs to the Ingress
  # depends_on ensures the Ingress is destroyed BEFORE this cleanup runs.
}
