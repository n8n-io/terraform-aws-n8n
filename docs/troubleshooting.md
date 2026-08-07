# Troubleshooting

Issues observed in real deployments and how to resolve them. If you hit something not covered here, open an issue.

## `terraform apply`: `no cached repo found ... hashicorp-index.yaml`

### Symptom

One or more `helm_release` resources fail at create time with:

```text
Error: could not download chart: no cached repo found.
(try 'helm repo update'):
open /Users/<you>/Library/Caches/helm/repository/<repo>-index.yaml: no such file or directory
```

### Cause

The `hashicorp/helm` Terraform provider embeds the Helm SDK v3 and reuses the local Helm CLI's repository cache (`$HELM_REPOSITORY_CACHE`). This is still true on the `~> 3.0` provider line this module pins: provider 3.x is a Plugin Framework rewrite, but it continues to vendor `helm.sh/helm/v3` (v3.18.5 as of provider v3.2.0), so the embedded SDK is unchanged from the 2.x era. When the system Helm CLI is **Helm 4** (released 2025), the cache layout differs slightly from the v3 SDK's expectations and the SDK fails to find the index files even though the chart URL is hard-coded in the `helm_release` block.

This is environmental, not a module bug — but anyone running Helm 4 on macOS will see it. The workaround below is unchanged under provider 3.x. (Note: if the repository cache is already populated — for example from earlier `helm repo add`/`helm repo update` runs — the apply succeeds without intervention; the failure only appears against an empty or Helm-4-only cache.)

### Fix

Pre-populate the v3-compatible cache once before the first apply:

```bash
helm repo add eks            https://aws.github.io/eks-charts
helm repo add kedacore       https://kedacore.github.io/charts
helm repo add autoscaler     https://kubernetes.github.io/autoscaler
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo update
```

Then re-run `terraform apply`. Already-created resources are skipped; only the failed `helm_release`s are retried.

If your environment supports it, downgrading to Helm 3 also resolves the issue:

```bash
brew uninstall helm
brew install helm@3
```

## `terraform apply`: KEDA install fails on AWS LBC webhook

### Symptom

```text
Error: release keda failed, and has been uninstalled due to atomic being set:
Internal error occurred: failed calling webhook "mservice.elbv2.k8s.aws":
no endpoints available for service "aws-load-balancer-webhook-service"
```

### Cause

The AWS Load Balancer Controller registers a cluster-wide `MutatingWebhookConfiguration` (`mservice.elbv2.k8s.aws`) that intercepts **every** Service creation, not just ALB-targeted ones. If KEDA installs in parallel with LBC, the webhook may already be registered before LBC pods are Ready, so KEDA's metrics/admission Services are rejected.

### Fix

The module serializes KEDA on `helm_release.lbc` (which has `wait = true`), so LBC pods are guaranteed Ready before KEDA installs. If you hit this on an older revision of the module, simply re-run `terraform apply` — by the time the second apply starts, LBC is up and KEDA installs cleanly.

## Smoke test reports `HTTP 000` after a recent destroy + re-apply

### Symptom

`tests/scripts/smoke-test.sh` fails the HTTP health, redirect, and API checks with `HTTP 000` against the n8n URL. Direct `dig n8n.example.com` resolves correctly, but `curl https://n8n.example.com/healthz` exits with code 6 (`CURLE_COULDNT_RESOLVE_HOST`).

### Cause (macOS)

`mDNSResponder` cached the NXDOMAIN response from the previous deployment's destroy phase and is serving it for 5–15 minutes even after Terraform re-created the Route 53 alias record. `dig` and `host` bypass `mDNSResponder`; `curl`, browsers, and anything else using `getaddrinfo()` do not.

This only reproduces when the same FQDN is reused across consecutive `apply` → `destroy` → `apply` cycles on the same workstation, which is common during iterative development of this module but unusual in production.

### Fix

Flush the macOS DNS cache:

```bash
sudo killall -HUP mDNSResponder
```

Or wait for the negative cache to age out (typically 5–15 minutes). To avoid the issue entirely, use a fresh subdomain per deployment.

## Webhooks return HTTP 200 with an HTML body and never execute

### Symptom

A production webhook, Form Trigger, Wait-node resumption, or MCP Server Trigger URL returns `200` and a chunk of HTML instead of running the workflow. Nothing appears in the executions list. The caller logs a success, so the failure is silent on both ends.

Most often seen on `/webhook-waiting`, `/form`, `/form-waiting`, and `/mcp`, while plain `/webhook` works.

### Cause

The request reached the **main** pods rather than the webhook processors. This module runs the chart with `disableProductionWebhooksOnMainProcess = true`, which disables five endpoint families on the mains: `/webhook`, `/webhook-waiting`, `/form`, `/form-waiting`, and `/mcp`. When one of those paths hits a main pod, no handler is registered, so the request falls through to the editor's single-page-app handler, which answers `200` with the editor HTML.

Two ways to end up here:

- **Module version `0.2.0` or earlier**, where the built-in Ingress routed only `/webhook` and the other four fell through to the catch-all. Upgrade; all five are routed now.
- **A bring-your-own Ingress** (`create_ingress = false`) whose catch-all rule precedes or replaces the webhook prefixes. This bites the internal ALB of a two-ALB split especially easily, because it is natural to give it only a `/` rule.

### Fix

Route every prefix in `n8n_webhook_path_prefixes` to `n8n_webhook_service_name`, declared **before** any catch-all, on *every* Ingress that fronts n8n, internal ones included. Iterate the output rather than hardcoding:

```hcl
dynamic "path" {
  for_each = module.n8n.n8n_webhook_path_prefixes
  content {
    path      = path.value
    path_type = "Prefix"
    backend {
      service {
        name = module.n8n.n8n_webhook_service_name
        port { number = module.n8n.n8n_service_port }
      }
    }
  }
}
```

To confirm which pods are actually behind a listener, compare the target group members with the pod IPs:

```bash
aws elbv2 describe-target-health --target-group-arn <arn> \
  --query 'TargetHealthDescriptions[].Target.Id' --output text
kubectl get pods -n n8n -o custom-columns='NAME:.metadata.name,IP:.status.podIP' --no-headers
```

A correctly routed webhook prefix returns `application/json` from n8n (for example `404 {"code":404,"message":"The requested webhook ... is not registered."}`), never `text/html`. The content type is the quickest discriminator.

See [examples/split-ingress](../examples/split-ingress/) for a worked two-ALB configuration.

## An inbound CIDR restriction applies cleanly but the ALB still answers everyone

### Symptom

A source restriction is configured, `terraform apply` succeeds with no warning, and the annotation is present on the Ingress. This covers both places the module offers one:

- the module inputs `alb_inbound_cidrs` / `alb_inbound_prefix_list_ids`, on the module-managed Ingress
- `admin_allowed_cidr_blocks` in `examples/split-ingress`, on that example's caller-owned internal ALB

```bash
# Ingress name is n8n-ingress for the module-managed one,
# n8n-admin-internal or n8n-webhook-public in examples/split-ingress.
kubectl get ingress <name> -n n8n \
  -o jsonpath='{.metadata.annotations.alb\.ingress\.kubernetes\.io/inbound-cidrs}'
```

The ALB's security group nevertheless allows `0.0.0.0/0`, or allows a range nobody configured here.

### Cause

Three possibilities, in the order worth checking. The first two are specific to the module-managed Ingress and are warned about at plan time. The third cannot affect the module-managed Ingress at all, but can affect an Ingress you wrote yourself.

1. **`ingress_annotations` sets `alb.ingress.kubernetes.io/security-groups`.** The controller stops managing the ALB's security group when you supply your own, and ignores both source restrictions: the group keeps whatever rules you gave it. Verified against LBC v3.5.0. The module raises a plan-time warning for this combination; check the plan output for it.

2. **`ingress_annotations` sets the same annotation key.** It is merged last and wins over the dedicated input. Also warned about at plan time.

3. **An `IngressClassParams` is overriding it, on a caller-owned Ingress.** If an `IngressClassParams` is bound to the IngressClass and sets `spec.inboundCIDRs` (or `spec.prefixListsIDs`), the controller uses that and ignores the Ingress annotation. It replaces rather than merges, per field.

    Two preconditions have to hold, and by default neither does:

    - The IngressClass must actually reference the params object through `spec.parameters`. The Helm chart this module installs (`aws-load-balancer-controller`, pinned to 3.5.0 by `lbc_chart_version`) creates both an `alb` IngressClass and an `alb` `IngressClassParams`, but does not wire them together, and the params object it creates has an empty spec. Filling in the spec alone changes nothing until someone also adds the reference. Everything below was verified against that version; a different `lbc_chart_version` may behave differently.
    - The Ingress must be classified through `spec.ingressClassName`. The controller checks the legacy `kubernetes.io/ingress.class` annotation first and returns as soon as it matches, so an Ingress carrying that annotation never has its IngressClass or params loaded.

    **The module-managed Ingress sets `kubernetes.io/ingress.class` (see `locals.tf`), so this cause cannot apply to it.** An `IngressClassParams` can be bound and populated and the module's `alb_inbound_cidrs` still wins. That immunity is incidental rather than designed, and it would disappear if the module ever dropped the legacy annotation, which is why the mechanism is documented here rather than left out.

    Caller-owned Ingresses that set only `spec.ingressClassName`, including both Ingresses in `examples/split-ingress`, do not have that immunity and are the real audience for this cause. All of the above was verified live against LBC v3.5.0, including that the override is a replacement.

    ```bash
    # Is the params object even bound? Empty output means this cause is ruled out.
    kubectl get ingressclass alb \
      -o jsonpath='{.spec.parameters.name}{"\n"}'
    kubectl get ingressclassparams <name> \
      -o jsonpath='{.spec.inboundCIDRs}{"\n"}{.spec.prefixListsIDs}{"\n"}'
    # Is this Ingress classified by the legacy annotation? A value here also rules it out.
    kubectl get ingress <name> -n n8n \
      -o jsonpath='{.metadata.annotations.kubernetes\.io/ingress\.class}{"\n"}'
    ```

    Clear those fields to hand control back to the Ingress annotations, or manage the allow-list there instead and leave the Terraform inputs empty. Splitting it across both is the one arrangement guaranteed to confuse the next person.

### Fix

Verify against the security group the controller actually owns, rather than against the annotation:

```bash
ALB_ARN=$(aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?DNSName=='$(kubectl get ingress n8n-ingress -n n8n \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')'].LoadBalancerArn" --output text)
aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[].SecurityGroups' --output text
aws ec2 describe-security-groups --group-ids <sg-id> \
  --query 'SecurityGroups[].IpPermissions[].{From:FromPort,CIDRs:IpRanges[].CidrIp,Prefixes:PrefixListIds[].PrefixListId}'
```

Note that hand-editing that security group is not a durable fix: the controller reverts it on the next reconcile. Change the Terraform inputs and apply.

## A prefix-list restriction takes the ALB offline for every source

### Symptom

`terraform apply` succeeds after setting `alb_inbound_prefix_list_ids`, and then every source times out: the editor UI, the REST API, and inbound webhooks alike. The annotation is present on the Ingress, but the controller-managed security group has no ingress rules at all:

```bash
kubectl get ingress n8n-ingress -n n8n \
  -o jsonpath='{.metadata.annotations.alb\.ingress\.kubernetes\.io/security-group-prefix-lists}'
# Resolve the ALB's security group as in the previous entry, then:
aws ec2 describe-security-groups --group-ids <sg-id> \
  --query 'SecurityGroups[].IpPermissions'   # returns []
```

### Cause

A security group rule that references a managed prefix list counts against the rules-per-security-group quota by the list's max-entries weight, not as one rule. The quota defaults to 60 (`L-0EA8095F`, "Inbound or outbound rules per security group"), and the controller writes each source once per listen port; the module's ALB listens on 80 and 443, so everything counts twice. The AWS-managed CloudFront origin-facing list (`pl-3b927c52` in us-east-1) has a weight of 55: alongside a single CIDR, the controller needs 2 x (55 + 1) = 112 rules and the quota stops it at 60.

The controller revokes the group's existing rules first, then fails on `AuthorizeSecurityGroupIngress` with `RulesPerSecurityGroupLimitExceeded` and retries indefinitely, leaving the group empty in between. The apply had already reported success, because the annotation itself applied cleanly; the failure exists only in the Ingress events and the controller log. Observed live against LBC v3.5.0.

```bash
kubectl describe ingress n8n-ingress -n n8n | tail -5
# Warning  FailedDeployModel ... api error RulesPerSecurityGroupLimitExceeded:
# The maximum number of rules per security group has been reached.
```

### Fix

Make the restriction fit the quota: keep 2 x (combined prefix-list weight + number of `alb_inbound_cidrs` entries) at or under it, move the ranges into `alb_inbound_cidrs`, or request an increase on `L-0EA8095F` before referencing heavy lists. Then `terraform apply`; the controller's next reconcile authorizes the rules and the ALB comes back without recreating anything. Adding rules to the group by hand does not help: the controller reverts them on the next reconcile, the same as the previous entry.

## Caller-owned Ingress fails with `namespaces "n8n" not found`

### Symptom

On the first `terraform apply` with `create_ingress = false`, your own `kubernetes_ingress_v1` (or any other namespaced resource) fails:

```text
Error: Failed to create Ingress 'n8n/my-ingress' because: namespaces "n8n" not found
```

A re-apply then succeeds, because the namespace exists by that point.

### Cause

Your resource had no dependency edge to the namespace, so Terraform scheduled it concurrently with the module rather than after it. In module versions where `output "namespace"` returned `var.namespace`, the output was a plan-time constant and consuming it created no ordering at all.

### Fix

Upgrade: `namespace` is now sourced from `kubernetes_namespace.n8n[0]` when the module creates the namespace (`create_namespace = true`, the default), so consuming it orders your resources implicitly. If you set `create_namespace = false` to deploy into a namespace you manage yourself, there is no module-owned namespace resource to order against; make sure that namespace already exists before applying this module.

Also add an explicit dependency on the whole module for anything an ALB registers targets for:

```hcl
resource "kubernetes_ingress_v1" "mine" {
  # ...
  depends_on = [module.n8n]
}
```

The namespace edge alone is not sufficient. With `wait_for_load_balancer = true`, the Ingress can otherwise be created before the Helm release has produced the Services, leaving the load balancer controller with nothing to register.

## Multi-main crash-loops after a rolling restart, Helm stuck in `pending-rollback`

### Symptom

After a Helm upgrade, a node rotation, or any other rolling restart of the main
pods, fresh main pods crash-loop. Logs show a license failure at init time,
typically one of:

- `feat:multipleMainInstances` reported as unavailable/disabled even though
  the license includes it.
- A license error surfacing from the S3 binary data feature gate on a pod
  that never previously had trouble with it.
- Running `n8n license:info` (or inspecting the license cert row in Postgres)
  shows `entitlements=0` / an empty cert, even though the license key is
  correct and was working moments before.

Because the Helm release is deployed with `atomic = true`, the failed
rollout triggers an automatic rollback, and the rollback itself times out
waiting for pods that never become ready. The release is left in
`pending-rollback`, and any further `helm upgrade` or `terraform apply`
fails immediately because Helm refuses to act on a release in that state.

### Cause

n8n's upstream default for `N8N_LICENSE_DETACH_FLOATING_ON_SHUTDOWN` is
`true`. In a multi-main deployment (`n8n_main_hpa_min_replicas > 1`, the module
default) the elected leader main detaches its floating license entitlement
when it shuts down, which zeroes the shared floating cert row in the
database. A fresh main pod starting during the leaderless window comes up as
a follower, never renews the license on init, reads the zeroed cert, fails
the init-time license gate, and crash-loops. Root-caused in
[issue #49](https://github.com/n8n-io/terraform-aws-n8n/issues/49), observed
on n8n 2.30.5 and 2.30.6.

All mains share the same device fingerprint, so detaching on shutdown is
unnecessary: a single floating seat is reused across restarts rather than
released and re-acquired.

### Fix

Module versions with `n8n_license_detach_floating_on_shutdown` default this
to `false`, overriding n8n's own default, which prevents the crash-loop from
recurring. If you are already on a module version with the input, confirm it
is not overridden to `true` unless you deliberately run a single main
(`n8n_main_hpa_min_replicas = 1`).

### Recovery from a stuck `pending-rollback` release

1. Find the Helm release secret Kubernetes is stuck on:

   ```bash
   kubectl -n <namespace> get secrets -l owner=helm,name=<release> \
     --sort-by=.metadata.creationTimestamp
   ```

2. Delete the newest one (the pending revision), not older successful
   revisions:

   ```bash
   kubectl -n <namespace> delete secret sh.helm.release.v1.<release>.v<N>
   ```

3. Re-apply (`terraform apply` or `helm upgrade`) with
   `n8n_license_detach_floating_on_shutdown = false` in effect. Helm treats
   the release as available for a new revision once the pending secret is
   gone.

4. Optionally force a license renewal on a running main pod once the release
   is healthy again, to confirm the cert is no longer zeroed:

   ```bash
   kubectl exec -n <namespace> <main-pod> -c n8n-main -- n8n license:info
   ```

## Pods stay `Pending` with `Insufficient cpu` and the node group never grows

### Symptom

Some n8n pods never schedule. `kubectl describe pod` reports:

```text
0/6 nodes are available: 6 Insufficient cpu
```

The Cluster Autoscaler adds no nodes, and its logs say the node group is already
at its maximum size. It usually shows up during a rolling update, which stalls
while the surging ReplicaSet competes for the same exhausted CPU.

### Cause

An autoscaler ceiling is set above what the node group can ever schedule. The
HPAs and KEDA scale toward their maxima regardless of whether the nodes exist,
and the Cluster Autoscaler stops at `node_max`. Confirm with:

```bash
# What the autoscalers are aiming for
kubectl -n <namespace> get hpa
kubectl -n <namespace> get scaledobject

# What the nodes can actually give
kubectl get nodes -o custom-columns='NODE:.metadata.name,ALLOCATABLE_CPU:.status.allocatable.cpu'
kubectl describe node <node> | sed -n '/Allocated resources/,/^Events/p'
```

### Fix

Size the three coupled input groups together: the autoscaler ceilings, the
per-pod CPU requests, and `node_instance_type` × `node_max`. See
[README.md → Sizing autoscaling against node capacity](../README.md#sizing-autoscaling-against-node-capacity)
for the arithmetic and the per-node rule of thumb.

The module warns about this at plan time, so `terraform plan` will already be
reporting `Warning: Check block assertion failed` with the two numbers. Module
versions up to 0.2.0 defaulted `n8n_main_hpa_max_replicas` to `20` and
`n8n_webhook_hpa_max_replicas` to `50`, neither of which fits the default node
group; upgrading lowers both to values that do.

## `terraform destroy` hangs on namespace or finalizers

See [destroy-cleanup.md](./destroy-cleanup.md).

## Webhook processor HPA thrashes, or pods OOMKill, with `n8n_reinstall_missing_packages = true`

### Symptom

With `n8n_reinstall_missing_packages = true`, every pod runs npm installs at
boot, and n8n rebroadcasts installs to all pods via pubsub, so during a
rolling restart every pod installs repeatedly. Against the webhook
processor's defaults (`n8n_webhook_cpu_request = "300m"`,
`n8n_webhook_cpu_limit = "800m"`, `n8n_webhook_memory_limit = "1Gi"`) this
produces two distinct failure modes:

1. **CPU:** installs burn 800-1000m per pod, 200-300% of the 300m request.
   The CPU-based `n8n_webhook` HPA (`scaling.tf`) reads that as sustained
   high utilization and scales up on every rollout: each new pod boots,
   installs, and broadcasts, keeping utilization above target and feeding
   back into further scale-up until capacity runs out.
2. **Memory:** concurrent installs plus the n8n baseline exceed the memory
   limit. Pods get OOMKilled (exit 137) mid-install, restart, reinstall, and
   broadcast again — a self-feeding crash loop. Interrupted installs can also
   leave corrupted package directories behind (`ENOTEMPTY`,
   `tar: invalid magic`), which persist because the packages directory lives
   on the pod's ephemeral filesystem.

`terraform plan`/`apply` surfaces a warning for this specific combination via
the `webhook_resources_sized_for_reinstall_missing_packages` check in
`scaling.tf`.

### Cause

`n8n_reinstall_missing_packages` is sized for the general case (occasional
reinstall of a handful of packages), not for the CPU/memory burst every pod
produces simultaneously during a rolling restart. The module's webhook
processor defaults predate that toggle's production cost.

### Fix

Raise the webhook processor's requests and limits above the module defaults.
One operator's stable production values, reported in
[issue #52](https://github.com/n8n-io/terraform-aws-n8n/issues/52):

```hcl
n8n_webhook_cpu_request    = "800m"
n8n_webhook_cpu_limit      = "1500m"
n8n_webhook_memory_request = "1Gi"
n8n_webhook_memory_limit   = "2Gi"
```

Optionally also widen `n8n_webhook_hpa_scale_up_stabilization_window_seconds`
(default `0`, matching the Kubernetes API's own default) so a short boot-time
CPU spike doesn't immediately trigger a scale-up:

```hcl
n8n_webhook_hpa_scale_up_stabilization_window_seconds = 300
```

If pods already have corrupted package directories from an interrupted
install, a rolling restart after raising the resources above resolves it —
n8n rewrites the directory from scratch on the next successful install.
