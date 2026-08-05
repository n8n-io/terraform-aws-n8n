# ── HPA: n8n webhook processor pods (CPU-based) ───────────────────────────────
# The n8n Helm chart skips creating the webhook-processor HPA when keda.enabled
# is true. Since we always use KEDA for workers, this external HPA is always
# required to cover webhook processor scaling.

resource "kubernetes_horizontal_pod_autoscaler_v2" "n8n_webhook" {
  metadata {
    name      = "n8n-webhook-processor"
    namespace = var.namespace
  }

  spec {
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = "n8n-webhook-processor"
    }

    min_replicas = var.n8n_webhook_hpa_min_replicas
    max_replicas = var.n8n_webhook_hpa_max_replicas

    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = var.n8n_webhook_hpa_cpu_threshold
        }
      }
    }

    # Scale-down keeps the Kubernetes API's own defaults (300s stabilization).
    # Only scale-up is exposed: see n8n_webhook_hpa_scale_up_stabilization_window_seconds.
    # The two policy blocks reproduce the Kubernetes API's own default scale-up
    # policy verbatim (see "Default Behavior" at
    # https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/)
    # — the provider schema requires at least one policy block once behavior is
    # set at all, and this keeps the scale-up ramp unchanged when the
    # stabilization window is left at its default of 0.
    behavior {
      scale_up {
        stabilization_window_seconds = var.n8n_webhook_hpa_scale_up_stabilization_window_seconds
        # The provider omits selectPolicy when unset and the Kubernetes API
        # rejects the resulting empty string; "Max" is the API's own default.
        select_policy = "Max"

        policy {
          type           = "Percent"
          value          = 100
          period_seconds = 15
        }

        policy {
          type           = "Pods"
          value          = 4
          period_seconds = 15
        }
      }
    }
  }

  depends_on = [helm_release.n8n]
}

# ── Autoscaling capacity model ────────────────────────────────────────────────
# Three variable groups have to be sized together, and nothing in Kubernetes
# couples them: the autoscaler ceilings (n8n_main_hpa_max_replicas,
# n8n_webhook_hpa_max_replicas, n8n_worker_keda_max_replicas), the per-pod CPU
# requests, and the node group (node_instance_type × node_max). Set a ceiling
# above what the node group can ever hold and the autoscalers will still scale
# toward it: pods pile up Pending with "Insufficient cpu" while the Cluster
# Autoscaler sits at node_max with nothing left to add. That churn also delays
# rollouts, because a surging ReplicaSet competes for the same exhausted CPU.
# See https://github.com/n8n-io/terraform-aws-n8n/issues/51.
#
# The locals below model the CPU side of that arithmetic so the check at the
# bottom of this file can warn at plan time. CPU is the binding constraint at
# the module's defaults; memory is modelled the same way in principle but is not
# what runs out first, so it is deliberately left out rather than half-modelled.
#
# The model is deliberately pure: no data source reads AWS for the instance
# type's vCPU count. data.aws_ec2_instance_type would be more precise, but a
# check block whose condition is unknown at plan is a hard error rather than a
# warning (see AGENTS.md), and a data source read is exactly the thing that can
# be deferred to apply. That would turn an advisory sizing hint into a broken
# plan. Deriving vCPU from the instance size instead keeps the check unable to
# fail a plan it was only ever meant to annotate.

locals {
  # Kubernetes CPU quantities are either a core count ("1", "1.5") or millicores
  # ("500m"). Normalize to millicores so they can be summed.
  #
  # can() guards a quantity in a form this module cannot read. That drops
  # n8n_capacity_model_readable to false and the check below stays silent, rather
  # than failing the plan over an input Kubernetes itself would have rejected at
  # apply. Unreadable entries fall back to 0 rather than null, because a check
  # block evaluates its error_message alongside its condition and null operands
  # in the interpolated arithmetic would abort the plan outright.
  n8n_cpu_requests = {
    main = var.n8n_main_cpu_request
    # A task runner sidecar rides on main and worker pods only. The chart adds
    # the container in deployment-main.yaml and deployment-worker.yaml, not in
    # deployment-webhook-processor.yaml, so webhook processors carry no sidecar
    # cost below.
    task_runner = var.n8n_task_runners_enabled ? var.n8n_task_runner_cpu_request : "0"
    webhook     = var.n8n_webhook_cpu_request
    worker      = var.n8n_worker_cpu_request
  }

  n8n_cpu_requests_readable = alltrue([
    for quantity in values(local.n8n_cpu_requests) : can(tonumber(trimsuffix(quantity, "m")))
  ])

  n8n_cpu_request_millis = {
    for name, quantity in local.n8n_cpu_requests : name => (
      can(tonumber(trimsuffix(quantity, "m")))
      ? (endswith(quantity, "m") ? tonumber(trimsuffix(quantity, "m")) : tonumber(quantity) * 1000)
      : 0
    )
  }

  # What the three pod families request when every autoscaler sits at its
  # ceiling simultaneously. Not a forecast: the point is that this number must
  # be schedulable at all, because each autoscaler can independently reach its
  # own maximum.
  n8n_peak_cpu_request_millis = local.n8n_cpu_requests_readable ? (
    var.n8n_main_hpa_max_replicas * (local.n8n_cpu_request_millis["main"] + local.n8n_cpu_request_millis["task_runner"]) +
    var.n8n_worker_keda_max_replicas * (local.n8n_cpu_request_millis["worker"] + local.n8n_cpu_request_millis["task_runner"]) +
    var.n8n_webhook_hpa_max_replicas * local.n8n_cpu_request_millis["webhook"]
  ) : 0

  # vCPU per node, read off the instance size rather than from the EC2 API.
  #
  # This reads the size suffix only, never the family, which is what keeps it
  # from going stale. AWS sizes instances on a fixed ladder: "large" is 2 vCPU,
  # "xlarge" is 4, and every "Nxlarge" is 4N. c5.9xlarge is 36, m5.24xlarge is
  # 96, x1e.32xlarge is 128. Sizes below "large" (nano through medium) are 2 on
  # every current generation. A family AWS ships next year lands on the same
  # ladder, so m8i.4xlarge resolves to 16 with no change here, and the Nxlarge
  # arm is arithmetic rather than a table, so a size larger than any that exists
  # today resolves too.
  #
  # Against the 1,150 instance types ec2:DescribeInstanceTypes reports in
  # eu-west-1, this resolves 995 exactly, leaves 104 off the ladder, over-counts
  # 48 and under-counts 3.
  #
  #   - Off-ladder is exactly the bare-metal set ("metal" through "metal-96xl").
  #     Those leave node_vcpus_derived null, the model goes unreadable, and the
  #     check says nothing at all rather than warning off a guess.
  #   - Over-counts are ".medium" on the 1 vCPU families (Graviton, c7a/c8a/m7a
  #     and friends), the SMT-disabled hpc7a sizes, and the pre-2015 m1/m2/t1/t2
  #     legacy types. An over-count makes the check think there is more room than
  #     there is, so it costs a warning rather than raising a false one.
  #   - Under-counts are three legacy types only: c1.xlarge (8, not 4) and
  #     c4/d2.8xlarge (36, not 32). c4 and d2 are 11% low, enough to warn a hair
  #     early at the boundary and nothing more.
  #
  # None of this affects the deployment: these locals feed the advisory check
  # below and nothing else.
  node_size = element(split(".", var.node_instance_type), 1)

  node_vcpus_derived = (
    can(regex("^[0-9]+xlarge$", local.node_size))
    ? tonumber(trimsuffix(local.node_size, "xlarge")) * 4
    : lookup({
      xlarge = 4
      large  = 2
      medium = 2
      small  = 2
      micro  = 2
      nano   = 2
    }, local.node_size, null)
  )

  # Zero stands in for an unreadable size everywhere below. A check block
  # evaluates its error_message alongside its condition, so a null reaching the
  # message's interpolated arithmetic would abort the plan instead of letting
  # n8n_capacity_model_readable quietly suppress the warning.
  node_vcpus = coalesce(local.node_vcpus_derived, 0)

  # EKS does not hand a node's full vCPU count to pods. The AMI's bootstrap
  # script reserves CPU for kubelet and the container runtime on a tiered curve
  # (get_cpu_millicores_to_reserve): 6% of the first vCPU, 1% of the second,
  # 0.5% of the third and fourth, 0.25% of every vCPU beyond. A t3.xlarge
  # (4 vCPU) therefore reports 3,920m allocatable, not 4,000m.
  node_kube_reserved_cpu_millis = local.node_vcpus == 0 ? 0 : (
    60
    + (local.node_vcpus >= 2 ? 10 : 0)
    + min(max(local.node_vcpus - 2, 0), 2) * 5
    + max(local.node_vcpus - 4, 0) * 2.5
  )

  # DaemonSets that land on every node and claim their requests ahead of any n8n
  # pod. These are the requests the containers declare on a cluster this module
  # builds, which is not always what the upstream charts document:
  #
  #   aws-node                 50m   (aws-node 25m + aws-eks-nodeagent 25m)
  #   kube-proxy              100m
  #   ebs-csi-node             30m   (3 containers × 10m, from storage.tf)
  #   eks-pod-identity-agent    0m   (declares no requests)
  #
  # ebs-csi-node-windows is excluded deliberately: it exists in kube-system but
  # reports desiredNumberScheduled = 0, because no node here matches its Windows
  # selector. Counting it would overstate overhead by 30m per node.
  #
  # Maintenance: this constant is measured, not sourced from a pin. aws-node and
  # kube-proxy track var.kubernetes_version and ebs-csi-node comes from the
  # unpinned aws_eks_addon in storage.tf, so re-verify after bumping
  # kubernetes_version or when the addon moves:
  #   kubectl -n kube-system get ds -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[*].resources.requests.cpu}{"\n"}{end}'
  node_daemonset_cpu_millis = 180

  node_schedulable_cpu_millis = max(
    local.node_vcpus * 1000 - local.node_kube_reserved_cpu_millis - local.node_daemonset_cpu_millis,
    0,
  )

  # Cluster-wide singletons come off the total once rather than per node:
  #
  #   CoreDNS                            200m   (100m × 2 replicas)
  #   metrics-server                     100m
  #   KEDA operator / metrics / webhooks 300m   (100m × 3)
  #   ebs-csi-controller                 120m   (6 containers × 10m × 2 replicas)
  #
  # The AWS Load Balancer Controller and Cluster Autoscaler charts declare no
  # requests at the versions this module installs, so they cost nothing against a
  # request-based model. Still an approximation, since a caller's own workloads
  # and DaemonSets are invisible here, which is why the check below only warns.
  #
  # Maintenance: this constant is measured, not sourced from a pin. CoreDNS
  # tracks var.kubernetes_version; metrics-server, KEDA and ebs-csi-controller
  # come from the unpinned charts and addon in controllers.tf, keda.tf and
  # storage.tf, so a chart release can move these requests without any change in
  # this repo. Re-verify after bumping kubernetes_version or upgrading a cluster:
  #   kubectl -n kube-system get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[*].resources.requests.cpu}{"\n"}{end}'
  cluster_addon_cpu_millis = 720

  n8n_schedulable_cpu_millis = max(
    var.node_max * local.node_schedulable_cpu_millis - local.cluster_addon_cpu_millis,
    0,
  )

  # Both halves of the comparison have to be readable for the warning to mean
  # anything. Either an unparseable CPU quantity or an instance size off the
  # standard ladder silences the check instead of warning off a guess.
  n8n_capacity_model_readable = local.n8n_cpu_requests_readable && local.node_vcpus_derived != null
}

# Warns, rather than fails, for two reasons. The model is an approximation (the
# add-on allowance above is a constant, and a caller may run their own
# DaemonSets or workloads on these nodes), and a caller may deliberately want
# ceilings the current node group cannot reach because node_max is the next
# thing they plan to raise. Blocking either case would be wrong.
#
# Terraform evaluates a check block's error_message alongside its condition, not
# lazily on failure, so every value interpolated below is evaluated on every
# plan. That is why the inputs this block reads carry nullable = false. On a
# nullable variable, a caller writing `x = null` in the module block propagates
# that null into the input rather than falling back to the default, and a null
# reaching the interpolations below aborts the plan from inside a block whose
# entire purpose is to warn without failing. With nullable = false, Terraform
# substitutes the declared default for an explicit null at the variable boundary,
# so the model always has numbers to work with.
check "autoscaling_maxima_fit_node_group_capacity" {
  assert {
    condition = local.n8n_capacity_model_readable ? (
      local.n8n_peak_cpu_request_millis <= local.n8n_schedulable_cpu_millis
    ) : true
    error_message = join("", [
      "Autoscaler maxima exceed the CPU the node group can ever schedule. At their ceilings the n8n pods ",
      "request ${local.n8n_peak_cpu_request_millis}m CPU ",
      "(main ${var.n8n_main_hpa_max_replicas} × ${local.n8n_cpu_request_millis["main"] + local.n8n_cpu_request_millis["task_runner"]}m, ",
      "worker ${var.n8n_worker_keda_max_replicas} × ${local.n8n_cpu_request_millis["worker"] + local.n8n_cpu_request_millis["task_runner"]}m, ",
      "webhook ${var.n8n_webhook_hpa_max_replicas} × ${local.n8n_cpu_request_millis["webhook"]}m), ",
      "but ${var.node_max} × ${var.node_instance_type} leaves only about ",
      "${local.n8n_schedulable_cpu_millis}m for them ",
      "(${local.node_vcpus} vCPU per node, less kubelet reservations, the aws-node and kube-proxy ",
      "DaemonSets, and this module's cluster add-ons). The autoscalers will still scale toward those ",
      "maxima, leaving pods Pending with \"Insufficient cpu\" once the Cluster Autoscaler reaches node_max. ",
      "Either lower the maxima, lower the CPU requests, or raise node_max / node_instance_type. ",
      "See README.md → \"Sizing autoscaling against node capacity\".",
    ])
  }
}

# ── Advisory: webhook resources vs. reinstall_missing_packages ────────────────
# With n8n_reinstall_missing_packages = true, every pod (main, worker, webhook
# processor) runs npm installs at boot, and n8n rebroadcasts installs to every
# pod via pubsub, so a rolling restart makes every webhook pod install
# repeatedly at once. Against the webhook processor's low default resources
# this produces two production failure modes: CPU spikes read as 200-300% of
# the request and drive the CPU-based HPA above into a scale-up-on-every-rollout
# loop, and concurrent installs plus the n8n baseline exceed a 1Gi memory limit,
# OOMKilling pods mid-install into a reinstall/broadcast crash loop that can
# leave corrupted package directories behind. See
# https://github.com/n8n-io/terraform-aws-n8n/issues/52.
#
# This only warns: the thresholds below are one operator's stable production
# values, not a hard requirement, and n8n_reinstall_missing_packages defaults to
# false, so most callers never hit this. See docs/troubleshooting.md.

locals {
  # can() turns an unparseable quantity (a caller's typo, or a form this module
  # doesn't recognize) into "unreadable" rather than a plan-time error — this
  # check exists to warn, not to validate the quantity syntax. Kubernetes itself
  # rejects a bad quantity at apply.
  n8n_webhook_cpu_millis = {
    for name, quantity in {
      request = var.n8n_webhook_cpu_request
      limit   = var.n8n_webhook_cpu_limit
      } : name => can(regex("^[0-9]+(\\.[0-9]+)?m?$", quantity)) ? (
      endswith(quantity, "m") ? tonumber(trimsuffix(quantity, "m")) : tonumber(quantity) * 1000
    ) : null
  }

  n8n_webhook_memory_mebibytes = {
    for name, quantity in {
      request = var.n8n_webhook_memory_request
      limit   = var.n8n_webhook_memory_limit
      } : name => can(regex("^[0-9]+(\\.[0-9]+)?(Mi|Gi)$", quantity)) ? (
      endswith(quantity, "Gi") ? tonumber(trimsuffix(quantity, "Gi")) * 1024 : tonumber(trimsuffix(quantity, "Mi"))
    ) : null
  }

  n8n_webhook_resources_readable = alltrue([
    for v in concat(values(local.n8n_webhook_cpu_millis), values(local.n8n_webhook_memory_mebibytes)) : v != null
  ])

  # Thresholds are the reporter's own stable production values from
  # https://github.com/n8n-io/terraform-aws-n8n/issues/52: CPU 800m request /
  # 1500m limit, memory 1Gi request / 2Gi limit. The module's own defaults
  # (300m/800m CPU, 512Mi/1Gi memory) sit below all four, which is deliberate:
  # this check exists because those defaults are the ones that failed.
  n8n_webhook_resources_sized_for_reinstall = local.n8n_webhook_resources_readable ? (
    local.n8n_webhook_cpu_millis["request"] >= 800 &&
    local.n8n_webhook_cpu_millis["limit"] >= 1500 &&
    local.n8n_webhook_memory_mebibytes["request"] >= 1024 &&
    local.n8n_webhook_memory_mebibytes["limit"] >= 2048
  ) : true
}

check "webhook_resources_sized_for_reinstall_missing_packages" {
  assert {
    condition = var.n8n_reinstall_missing_packages ? local.n8n_webhook_resources_sized_for_reinstall : true
    error_message = join("", [
      "n8n_reinstall_missing_packages is true, but the webhook processor's CPU/memory requests and limits ",
      "(currently ${var.n8n_webhook_cpu_request}/${var.n8n_webhook_cpu_limit} CPU, ",
      "${var.n8n_webhook_memory_request}/${var.n8n_webhook_memory_limit} memory) are below the values known to ",
      "survive it in production. Every pod reinstalls community packages on boot and n8n rebroadcasts installs ",
      "to all pods, so a rolling restart makes every webhook pod install repeatedly at once: CPU spikes to ",
      "200-300% of a low request (driving the CPU-based HPA into a scale-up-on-every-rollout loop), and ",
      "concurrent installs plus the n8n baseline can exceed a low memory limit and OOMKill pods mid-install into ",
      "a reinstall/broadcast crash loop. Raise n8n_webhook_cpu_request/limit to at least 800m/1500m and ",
      "n8n_webhook_memory_request/limit to at least 1Gi/2Gi. See docs/troubleshooting.md and ",
      "https://github.com/n8n-io/terraform-aws-n8n/issues/52.",
    ])
  }
}
