# Infrastructure-only mode

By default one `terraform apply` builds the AWS infrastructure and installs
n8n into the cluster. Some teams split that work: Terraform owns AWS, and a
cluster operator owns everything behind the Kubernetes API with tooling of
their own, such as Helm, Argo CD or Flux.

`create_kubernetes_resources = false` gives you that split. The module then
makes no call to the Kubernetes API. EKS add-ons such as the Pod Identity
Agent and the EBS CSI driver still run in the cluster, because the module
installs them through the AWS API. This page is the reference for what the
module still creates, what it skips, and what the operator must create so
that n8n starts.

For a runnable configuration and a step-by-step walkthrough, see
[`examples/infrastructure-only`](../examples/infrastructure-only/).

## Before you choose this mode

- **It is for new deployments only.** Setting the toggle to `false` on a
  running deployment makes Terraform destroy every cluster object it manages:
  the n8n release, the controllers, and the Secrets the module created. If
  the module created the namespace (`create_namespace = true`, the default),
  it deletes the namespace too, and Kubernetes then removes everything else
  in it. A namespace or Secret you supplied yourself (`create_namespace =
  false`, a `*_secret_ref` input) is not Terraform's and stays. Nothing is
  handed over. Setting the toggle back to `true` later does not adopt a
  release the operator installed.
- **The operator owns the application secrets.** The module generates no n8n
  encryption key and no task runner token in this mode. Losing the encryption
  key makes every credential stored in n8n unreadable, so the operator must
  back it up.
- **The operator owns cluster teardown.** Terraform does not know about a
  load balancer or a volume that an operator-installed controller created.
  See [Teardown](#teardown).
- **The providers are still downloaded.** `terraform init` installs the
  `kubernetes`, `helm` and `time` providers, because the module declares
  them. The calling configuration needs no `provider "kubernetes"` or
  `provider "helm"` block and no cluster credentials.
- **Plan-time checks cover less.** The module cannot see what the operator
  installs. For example, it cannot confirm that the chart version in use
  supports worker pools once the values leave Terraform.

## What the module creates and skips

The toggle skips everything the module would create through the Kubernetes
API:

- the Load Balancer Controller, Cluster Autoscaler, metrics-server and KEDA
  Helm releases,
- the `gp3` StorageClass,
- the namespace, the Secrets and the ServiceAccount,
- the n8n Helm release,
- the webhook HorizontalPodAutoscaler, both PodDisruptionBudgets and the
  Ingress,
- the Route 53 alias records for the load balancer,
- the optional `redis_exporter`.

It changes nothing on the AWS side. Each AWS resource keeps following the
input that already controls it:

| AWS resource | Controlled by |
| --- | --- |
| EKS cluster, node group, Pod Identity Agent add-on | `create_eks` |
| EBS CSI driver add-on and its IAM role | `create_ebs_csi` |
| RDS PostgreSQL | `create_database` |
| ElastiCache Redis | `create_elasticache` |
| S3 bucket | `create_s3_bucket` |
| IAM role and Pod Identity association for n8n's S3 access | Always created |
| IAM roles and Pod Identity associations for the Load Balancer Controller and Cluster Autoscaler | Always created on a cluster the module creates. On an existing cluster, `install_lbc` and `install_cluster_autoscaler`. |
| ACM certificate and its Route 53 validation records | `route53_zone_id`. With `certificate_arn` the module creates no certificate and passes yours through. |

The toggle overrides `install_lbc`, `install_cluster_autoscaler`,
`install_metrics_server`, `install_keda`, `create_namespace`,
`create_ingress`, `n8n_webhook_hpa_enabled`, `n8n_webhook_pdb_enabled`,
`n8n_worker_pdb_enabled`, `lbc_pdb_enabled`, `redis_exporter_enabled` and the
StorageClass half of `create_ebs_csi`. It does so without a warning, whatever
those inputs are set to.

On an existing cluster (`create_eks = false`) the controller IAM follows
`install_lbc` and `install_cluster_autoscaler`, as it does on the default
path. Set one to `false`
when that controller already runs there with its own IAM binding, because
EKS allows one role per ServiceAccount.

## Inputs that behave differently

| Input | Behavior in this mode |
| --- | --- |
| `n8n_license_key` | Must be `null`. The plan fails otherwise. The key would be stored in Terraform state with nothing reading it. |
| `n8n_encryption_key` | Must be `null`, for the same reason. |
| `n8n_license_key_secret_ref`, `n8n_license_cert_secret_ref` | Optional. Set at most one. With neither set, the values name the Secret `n8n-enterprise-secrets`. |
| `ingress_scheme`, `alb_ssl_policy`, `ingress_annotations`, `alb_inbound_cidrs`, `alb_inbound_prefix_list_ids` | Applied to nothing. The plan warns when one is set. Put them on your own Ingress. |
| Every other input | Unchanged. Inputs that configure n8n itself (most `n8n_*` inputs, and the database and Redis connection, TLS and authentication inputs) shape the Helm values in the `n8n_helm_values` output. Inputs that size or protect AWS resources, such as `db_backup_retention_period` or `redis_node_type`, still act on those resources only. |

## Cluster access for the operator

The cluster uses EKS access entries, and only the identity that ran
`terraform apply` is a cluster administrator by default. An operator with a
different identity needs an access entry. The module does not create one.
Declare it next to the module call, for example with `aws_eks_access_entry`
and `aws_eks_access_policy_association`, using the `cluster_name` output.

The operator also needs network access to the API server. See
`cluster_endpoint_public_access` and `cluster_endpoint_public_access_cidrs`.

## Controllers the operator installs

The IAM side is ready. Each Pod Identity association binds one namespace and
one ServiceAccount name, so the controller must run under exactly that name.
No role ARN annotation is needed.

| Controller | Namespace | ServiceAccount the IAM binding expects | Chart the module would install |
| --- | --- | --- | --- |
| AWS Load Balancer Controller | `kube-system` | `aws-load-balancer-controller` | `aws-load-balancer-controller` from `https://aws.github.io/eks-charts`, version `lbc_chart_version` |
| Cluster Autoscaler | `kube-system` | `cluster-autoscaler` | `cluster-autoscaler` from `https://kubernetes.github.io/autoscaler`, version `cluster_autoscaler_chart_version` |
| metrics-server | `kube-system` | No AWS access needed | `metrics-server` from `https://kubernetes-sigs.github.io/metrics-server/`, version `metrics_server_chart_version` |
| KEDA | `keda` | No AWS access needed | `keda` from `https://kedacore.github.io/charts`, version `keda_chart_version` |
| EBS CSI driver | `kube-system` | Installed by the module as an EKS add-on while `create_ebs_csi = true` (the default) | Do not install a second driver. With `create_ebs_csi = false` the module installs none, and providing a driver is yours. |

The values the module passes to each chart are in
[`modules/controllers/controllers.tf`](../modules/controllers/controllers.tf)
and [`modules/controllers/keda.tf`](../modules/controllers/keda.tf). The
Load Balancer Controller needs the cluster name and the VPC ID. The Cluster
Autoscaler needs the cluster name, the region, and
`rbac.serviceAccount.name=cluster-autoscaler`.

Two requirements come from the n8n chart values, not from AWS:

- **KEDA must be installed before n8n.** The values set `keda.enabled`, so
  the chart renders a `ScaledObject` for the workers.
- **KEDA must be able to read Secrets in the n8n namespace** when Redis uses
  an AUTH token. This is the KEDA chart's default.

With `create_ebs_csi = true` the EBS CSI driver is installed, but the module
creates no StorageClass in this mode. n8n itself needs no volume. If other workloads do, create a
default StorageClass with the provisioner `ebs.csi.aws.com`.

## Secrets the operator creates

Create these in the namespace from the `namespace` output before installing
n8n. The Helm values hold only the names.

| Secret | Key | Content | Needed when |
| --- | --- | --- | --- |
| `n8n-enterprise-secrets` | `N8N_ENCRYPTION_KEY` | A key you generate, 64 hexadecimal characters, for example with `openssl rand -hex 32` | `n8n_encryption_key_secret_ref` is not set |
| `n8n-enterprise-secrets` | `N8N_LICENSE_ACTIVATION_KEY` | Your n8n license key | Neither license reference input is set |
| `n8n-task-runner-token` | `N8N_RUNNERS_AUTH_TOKEN` | A random token you generate, for example with `openssl rand -hex 32` | Always |
| `n8n-enterprise-db-secret` | `password` | The `db_password` output | `db_password_secret_ref` is not set |
| `n8n-enterprise-redis-secret` | `password` | The `redis_auth_token` output | Redis AUTH is active and `redis_auth_token_secret_ref` is not set |
| `n8n-ca-bundle-secret` | `ca.crt` | The PEM you passed as `n8n_extra_ca_pem` | `n8n_extra_ca_pem` is set |

To use Secret names of your own, set the matching `*_secret_ref` input. The
values then carry your name and key.

Two more objects depend on inputs:

- With `n8n_image_pull_secrets` set, the values tell the chart not to create
  a ServiceAccount. Create the ServiceAccount `n8n-enterprise-pull` yourself
  and attach the pull secrets to it.
- With `db_password_write_only = true`, the `db_password` output is `null`.
  Take the password from the source that feeds `db_password_wo`.

### Restoring a database snapshot

n8n encrypts stored credentials with `N8N_ENCRYPTION_KEY`. When you restore
with `db_snapshot_identifier`, the Secret must hold the key that the
snapshot's instance ran under. With any other key the workflows come back
and every credential in them is unreadable. The module warns about this on
the default path. In this mode it cannot, because it never reads the Secret.

## The n8n release

After `terraform apply`:

```bash
terraform output -raw n8n_helm_values > values.yaml
```

Install the chart from `n8n_chart_repository` at `n8n_chart_version`, with
these fixed coordinates:

| Setting | Value | Why it is fixed |
| --- | --- | --- |
| Release name | `n8n` | The Deployment and Service names in this page derive from it. |
| Namespace | The `namespace` output | The S3 Pod Identity association binds this namespace. |
| ServiceAccount | Set by the values: `n8n-enterprise`, or `n8n-enterprise-pull` when `n8n_image_pull_secrets` is set | The same association binds this name. With another name n8n gets no S3 credentials. With `n8n_image_pull_secrets` set you create this ServiceAccount yourself. |

The values file needs care:

- **It is marked sensitive.** `n8n_otel_exporter_otlp_headers` and
  `n8n_log_streaming_destinations` render into it, and so does any literal
  credential you put into `n8n_extra_env`. Check it before you commit it to
  a Git repository that Argo CD or Flux reads.
- **It follows the chart's values schema.** The content is valid for
  `n8n_chart_version` and changes when that version changes.
- **Read it after apply.** It embeds endpoints that are unknown at plan time.

## Objects outside the chart

On the default path the module creates four kinds of object beside the
release. The chart does not render them with these values, so the operator
creates them.

| Object | What the module would create | Source |
| --- | --- | --- |
| Webhook autoscaler | A `HorizontalPodAutoscaler` named `n8n-webhook-processor` for the Deployment of the same name, on CPU utilization, between `n8n_webhook_hpa_min_replicas` and `n8n_webhook_hpa_max_replicas`. It needs metrics-server. | [`scaling.tf`](../scaling.tf) |
| Webhook disruption budget | A `PodDisruptionBudget` with `maxUnavailable: 1` selecting `app.kubernetes.io/name: n8n`, `app.kubernetes.io/component: webhook-processor`, `app.kubernetes.io/instance: n8n` | [`n8n.tf`](../n8n.tf) |
| Worker disruption budget | The same with `app.kubernetes.io/component: worker` | [`n8n.tf`](../n8n.tf) |
| Ingress | One ALB Ingress routing the webhook path prefixes to the Service `n8n-webhook-processor` and everything else to `n8n-main`, both on port `5678` | [`n8n.tf`](../n8n.tf), [`locals.tf`](../locals.tf) |

For the Ingress, use these outputs so it cannot drift from what n8n serves:
`certificate_arn`, `n8n_service_name`, `n8n_webhook_service_name`,
`n8n_service_port` and `n8n_webhook_path_prefixes`. Route every prefix in
that list to the webhook Service. The main pods serve none of them. See
[Customer-managed Ingress](../README.md#customer-managed-ingress-two-alb-split)
for the annotations the module uses, including the session stickiness the
editor needs.

After the load balancer exists, create the DNS record for `n8n_domain` and
for each name in `n8n_additional_domains`. The module creates the
certificate validation records, but no alias record.

## Teardown

Remove the cluster side first, while the controllers and nodes are healthy:

1. Stop Argo CD or Flux from recreating what you delete.
2. Delete the Ingress, and any Service of type `LoadBalancer`. Wait until the
   load balancer, its target groups and its security groups are gone.
3. Uninstall n8n. Delete or keep volumes on purpose. A StorageClass with the
   reclaim policy `Delete` removes the volume with its claim.
4. Uninstall the controllers.
5. Run `terraform destroy`.

A load balancer or security group that a controller left behind blocks the
deletion of the VPC. [Destroy and cleanup](./destroy-cleanup.md) shows how to
find and remove such leftovers.

## What is and is not verified

The module's tests replace every provider with a mock. They show which
resources the module plans and what the values contain.

Leaving the `kubernetes` and `helm` providers unconfigured was checked
separately, in an isolated configuration with the provider versions this
repository locks (`kubernetes` 3.2.1, `helm` 3.3.0, `time` 0.14.2), no
provider block and no kubeconfig: with every resource of those providers at
`count = 0`, `terraform plan` and `terraform apply` both succeed. That was
not repeated with the whole module against a real AWS account.

Not verified at all: that the chart accepts the values together with Secrets
you created. Check both points in a test environment before you rely on this
mode.
