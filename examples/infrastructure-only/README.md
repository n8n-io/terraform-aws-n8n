# Infrastructure-only example

Provisions the AWS infrastructure for n8n and stops there. Terraform creates
nothing inside the cluster, and a cluster operator installs the controllers
and n8n with tooling of their own, such as Helm, Argo CD or Flux.

This is [`examples/small`](../small/) with one deliberate difference:
`create_kubernetes_resources = false`.

**`terraform apply` alone does not give you a running n8n.** That is the
point of this mode. Use it for a new deployment only: setting the toggle to
`false` on a running deployment makes Terraform uninstall n8n and the
controllers and delete the Secrets and namespace it created.

## What it creates

- VPC with public and private subnets across two AZs, NAT gateway, EKS/ALB subnet tags (via `terraform-aws-modules/vpc/aws`)
- EKS cluster, managed node group and EKS add-ons, including the EBS CSI driver
- RDS PostgreSQL, ElastiCache Redis, S3 bucket
- The ACM certificate, validated through Route 53
- Every IAM role and Pod Identity association: for n8n's S3 access, the AWS Load Balancer Controller and the Cluster Autoscaler

## What it leaves to the operator

- The AWS Load Balancer Controller, Cluster Autoscaler, metrics-server and KEDA
- The namespace and the Kubernetes Secrets
- The n8n Helm release
- The webhook autoscaler, two PodDisruptionBudgets and the Ingress
- The DNS record for `n8n_domain`

[`docs/infrastructure-only.md`](../../docs/infrastructure-only.md) is the
reference for each of these: names, keys, and the values the module itself
would use.

## Prerequisites

- A Route53 hosted zone for the parent domain (e.g. `example.com` if `n8n_domain = n8n.example.com`). Note its zone ID.
- For the steps after `terraform apply`: `kubectl` and `helm`, and an identity with access to the cluster. The identity that runs `terraform apply` is a cluster administrator. Any other identity needs an EKS access entry, which this example does not create.

This configuration has no `kubernetes` or `helm` provider block, and
Terraform needs no cluster credentials. `terraform init` still downloads both
providers, because the module declares them.

## Apply

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars and set n8n_domain and route53_zone_id

terraform init
terraform apply -compact-warnings
```

There is no `n8n_license_key` input. The module rejects a literal license key
in this mode, because it would be stored in Terraform state with nothing
reading it.

## After apply

These steps use `kubectl` and `helm`. Use the equivalent in your own tooling.

1. Connect to the cluster:

   ```bash
   $(terraform output -raw kubectl_config_command)
   ```

2. Install the controllers. The IAM bindings exist already and expect these
   ServiceAccount names: `aws-load-balancer-controller` and
   `cluster-autoscaler`, both in `kube-system`. Install KEDA before n8n. See
   [Controllers the operator installs](../../docs/infrastructure-only.md#controllers-the-operator-installs)
   for charts, versions and values. The `cluster_name` and `vpc_id` outputs
   carry what the Load Balancer Controller chart needs.

3. Create the namespace and the Secrets:

   ```bash
   NS=$(terraform output -raw namespace)
   kubectl create namespace "$NS"

   # Set N8N_LICENSE_KEY to your n8n license key first.

   kubectl -n "$NS" create secret generic n8n-enterprise-secrets \
     --from-literal=N8N_ENCRYPTION_KEY="$(openssl rand -hex 32)" \
     --from-literal=N8N_LICENSE_ACTIVATION_KEY="$N8N_LICENSE_KEY"

   kubectl -n "$NS" create secret generic n8n-task-runner-token \
     --from-literal=N8N_RUNNERS_AUTH_TOKEN="$(openssl rand -hex 32)"

   kubectl -n "$NS" create secret generic n8n-enterprise-db-secret \
     --from-literal=password="$(terraform output -raw db_password)"
   ```

   Back up the encryption key now. Losing it makes every credential stored
   in n8n unreadable. If you enable Redis AUTH, also create
   `n8n-enterprise-redis-secret`; see
   [Secrets the operator creates](../../docs/infrastructure-only.md#secrets-the-operator-creates).

4. Install n8n. The release name `n8n` and the namespace are fixed, because
   the S3 access is bound to them:

   ```bash
   terraform output -raw n8n_helm_values > values.yaml

   # The module's n8n_chart_version. This example does not override it, so it
   # is the default in the module's variables.tf.
   CHART_VERSION=2.0.0-rc.1

   helm upgrade --install n8n oci://ghcr.io/n8n-io/n8n-helm-chart/n8n \
     --version "$CHART_VERSION" --namespace "$NS" --values values.yaml
   ```

   The values are written for that chart version, so check `CHART_VERSION`
   against the module version you use before you run this. `values.yaml` can hold sensitive
   settings, so check it before you commit it to Git.

5. Create the webhook autoscaler, the two PodDisruptionBudgets and the
   Ingress, then the DNS record that points `n8n_domain` at the load
   balancer. See
   [Objects outside the chart](../../docs/infrastructure-only.md#objects-outside-the-chart).
   The `certificate_arn` output is the certificate for the Ingress.

## Teardown

Remove the cluster side first, while the controllers are running: the
Ingress, then n8n, then the controllers. Wait until the load balancer is
gone. Then:

```bash
terraform destroy
```

A load balancer left behind blocks the deletion of the VPC. See
[Teardown](../../docs/infrastructure-only.md#teardown).

## Production considerations

This example is a reference deployment optimized for clean `apply` / `destroy` cycles during evaluation. The module ships with teardown-friendly defaults that you should review before promoting to production:

| Module input | Current default | Production |
|---|---|---|
| `db_backup_retention_period` | `7` | Match your RPO (up to 35 days) |
| `db_deletion_protection` | `false` | `true` |
| `db_skip_final_snapshot` | `true` | `false`, plus set `db_final_snapshot_identifier` |
| `db_delete_automated_backups` | `true` | `false` |
| `s3_force_destroy` | `true` | `false` |

These inputs are passed straight through to the module; set them in `terraform.tfvars` (or via any other variable source) to override the defaults.

See [`docs/build-time-decisions.md`](../../docs/build-time-decisions.md) for the module-level settings elsewhere in the root module that are fixed at the first `terraform apply`.

<!-- The block below is auto-generated by terraform-docs. Run `terraform-docs markdown table --output-file README.md --output-mode inject .` to refresh it. -->
<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.13 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 6.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_aws"></a> [aws](#provider\_aws) | ~> 6.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_n8n"></a> [n8n](#module\_n8n) | ../.. | n/a |
| <a name="module_vpc"></a> [vpc](#module\_vpc) | terraform-aws-modules/vpc/aws | ~> 5.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_availability_zones.available](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/availability_zones) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_aws_partner_attribution_tag"></a> [aws\_partner\_attribution\_tag](#input\_aws\_partner\_attribution\_tag) | Value of the aws-apn-id tag added to every taggable AWS resource this example and the module create, so AWS Partner Revenue Measurement attributes their spend to n8n. Passed to the module's aws\_partner\_attribution\_tag and merged into this example's own tags, which is how the VPC, NAT gateway and any stand-in infrastructure get it. This input owns the tag: an aws-apn-id key in tags is ignored. Set to an empty string to remove the tag from resources Terraform manages and stop new load balancers and volumes receiving it; EBS volumes that already exist keep it. Keep the default and validation in sync with the module root's variables.tf. | `string` | `"pc:26au7o6cdeh7fqdt376h9m9xk"` | no |
| <a name="input_aws_region"></a> [aws\_region](#input\_aws\_region) | AWS region to deploy into (e.g. us-east-1, eu-west-1, ap-southeast-1). | `string` | `"us-east-1"` | no |
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | Name for the EKS cluster. Keep to 14 characters or fewer — the module derives an ElastiCache cluster ID of `<cluster_name>-redis`, and AWS caps ElastiCache IDs at 20 chars. Use only lowercase letters, digits and hyphens: the name is also used for the EKS cluster, which does not accept periods, and in the S3 bucket name `n8n-<cluster_name>-<id>`, which does not accept uppercase letters or underscores. The module rejects uppercase letters and underscores at plan time. | `string` | `"n8n-cluster"` | no |
| <a name="input_db_backup_retention_period"></a> [db\_backup\_retention\_period](#input\_db\_backup\_retention\_period) | Number of whole days to retain automated RDS backups. A value of 0 disables automated backups and point-in-time recovery. Passed to the module's db\_backup\_retention\_period. Leave null (the default) to use the module's default of 7 days. | `number` | `null` | no |
| <a name="input_db_delete_automated_backups"></a> [db\_delete\_automated\_backups](#input\_db\_delete\_automated\_backups) | Passed to the module's db\_delete\_automated\_backups. Leave null (the default) to use the module's teardown-friendly default of true. | `bool` | `null` | no |
| <a name="input_db_deletion_protection"></a> [db\_deletion\_protection](#input\_db\_deletion\_protection) | Passed to the module's db\_deletion\_protection. Leave null (the default) to use the module's teardown-friendly default of false. | `bool` | `null` | no |
| <a name="input_db_final_snapshot_identifier"></a> [db\_final\_snapshot\_identifier](#input\_db\_final\_snapshot\_identifier) | Passed to the module's db\_final\_snapshot\_identifier. Required when db\_skip\_final\_snapshot is false; must be left null otherwise, or the module rejects the plan. | `string` | `null` | no |
| <a name="input_db_skip_final_snapshot"></a> [db\_skip\_final\_snapshot](#input\_db\_skip\_final\_snapshot) | Passed to the module's db\_skip\_final\_snapshot. Leave null (the default) to use the module's teardown-friendly default of true. | `bool` | `null` | no |
| <a name="input_n8n_additional_domains"></a> [n8n\_additional\_domains](#input\_n8n\_additional\_domains) | Extra hostnames n8n should answer on, beyond n8n\_domain. Each is added to the module-issued ACM certificate as a subject alternative name, and given a Route 53 validation record. The module creates no Ingress and no alias A-record in this example: route each name in the Ingress you create, and add its DNS record yourself. Leave empty for a single hostname. | `list(string)` | `[]` | no |
| <a name="input_n8n_custom_extensions_path"></a> [n8n\_custom\_extensions\_path](#input\_n8n\_custom\_extensions\_path) | Absolute path inside the n8n container that n8n scans for custom nodes at startup (e.g. "/opt/n8n-nodes"). Maps to N8N\_CUSTOM\_EXTENSIONS, and is set on main, worker and webhook processor pods alike. Set this alongside n8n\_image\_repository when the custom image bakes community packages in: since n8n 1.0 the loader no longer reads the image's global node\_modules, so a plain npm install into the image is never scanned and the packages ship but never load. Nodes found here register under the package name CUSTOM, so a node installed from npm as n8n-nodes-example.myNode becomes CUSTOM.myNode and existing workflows referencing the npm-qualified type will not resolve. Leave null (the default) to omit the env var. | `string` | `null` | no |
| <a name="input_n8n_domain"></a> [n8n\_domain](#input\_n8n\_domain) | Fully-qualified domain name for n8n (e.g. n8n.example.com). The parent zone must be hosted in Route53 (pass its ID via route53\_zone\_id). | `string` | n/a | yes |
| <a name="input_n8n_execution_data_storage_mode"></a> [n8n\_execution\_data\_storage\_mode](#input\_n8n\_execution\_data\_storage\_mode) | Where n8n stores the data of each new execution. Passed to the module's n8n\_execution\_data\_storage\_mode. "database" keeps execution data in PostgreSQL; "s3" offloads it to the S3 bucket the module already creates for binary data. This example runs the module's default database (db.t3.small on 50 GB of gp2, a 150 IOPS baseline), which has the least room of any sizing this module ships to absorb execution-data growth, so reaching for this is often cheaper than resizing the database. Requires n8n >= 2.27 (pin n8n\_image\_tag accordingly) and an Enterprise license carrying the feat:executionDataS3 entitlement, which is not the same one binary data offload uses. There is no backfill: existing executions stay readable where they were written. Read the execution data section of the root README before enabling it, in particular the durability trade-off and the S3 lifecycle constraint. | `string` | `"database"` | no |
| <a name="input_n8n_extra_ca_pem"></a> [n8n\_extra\_ca\_pem](#input\_n8n\_extra\_ca\_pem) | Passed to the module's n8n\_extra\_ca\_pem: PEM CA certificate(s) trusted by the main, worker and webhook-processor pods for outbound TLS, for a TLS-inspecting egress proxy or a private CA; task-runner sidecars are not covered. Certificates only, never a private key. Leave null (the default) to add none. See [TLS proxy guide](../../docs/tls-proxy.md). | `string` | `null` | no |
| <a name="input_n8n_extra_env"></a> [n8n\_extra\_env](#input\_n8n\_extra\_env) | Passed to the module's n8n\_extra\_env: extra environment variables for the n8n containers on every role (main, worker, webhook processor), not the task runner sidecars, e.g. HTTP\_PROXY, HTTPS\_PROXY and NO\_PROXY for an egress proxy. The module rejects names it manages. Values are stored in plaintext in Terraform state and the Helm release, so never embed credentials in a proxy URL (http://user:pass@proxy). See [TLS proxy guide](../../docs/tls-proxy.md). | <pre>list(object({<br/>    name  = string<br/>    value = string<br/>  }))</pre> | `[]` | no |
| <a name="input_n8n_image_pull_secrets"></a> [n8n\_image\_pull\_secrets](#input\_n8n\_image\_pull\_secrets) | Names of existing Kubernetes secrets of type kubernetes.io/dockerconfigjson, in the n8n namespace, that the pods authenticate to their image registry with. Leave empty (the default) unless n8n\_image\_repository points somewhere the node group's IAM role cannot already reach: a public registry and an ECR repository in this account both pull without credentials. Setting it makes the Helm values tell the chart not to create a ServiceAccount, and the module creates none in this example: create the ServiceAccount n8n-enterprise-pull yourself and attach these secrets to it. The module leaves the chart's own top-level imagePullSecrets value unset. Create and rotate the secrets yourself; the module takes names, not credentials, so none of them land in Terraform state. Cross-account ECR is the exception and should not use this: its authorization tokens expire after 12 hours, so add the node group role to the source repository's policy instead. | `list(string)` | `[]` | no |
| <a name="input_n8n_image_repository"></a> [n8n\_image\_repository](#input\_n8n\_image\_repository) | Container image repository for the n8n application, without a tag (e.g. "123456789012.dkr.ecr.eu-west-1.amazonaws.com/n8n"). Leave null to use the Helm chart's own repository (docker.n8n.io/n8nio/n8n). Set this to run a custom image, for example one with community packages baked in so they are not reinstalled on every pod boot. The image must be pullable by the node group's IAM role (ECR in the same account is) or be public, otherwise name a dockerconfigjson secret in n8n\_image\_pull\_secrets, and n8n\_task\_runner\_image\_tag usually has to be set alongside it. | `string` | `null` | no |
| <a name="input_n8n_image_tag"></a> [n8n\_image\_tag](#input\_n8n\_image\_tag) | n8n application image tag to deploy (e.g. "2.27.4"). Leave null to use the selected Helm chart's default (appVersion 2.44.5 in chart 2.0.0-rc.1). Inspect and pin the running application version before upgrading the chart to avoid a downgrade; see the [upgrade guide](../../docs/upgrading-n8n.md). | `string` | `null` | no |
| <a name="input_n8n_main_hpa_min_replicas"></a> [n8n\_main\_hpa\_min\_replicas](#input\_n8n\_main\_hpa\_min\_replicas) | Minimum (and therefore default) replica count for n8n main pods, passed straight through to the module's own n8n\_main\_hpa\_min\_replicas. Leave null (the default) to use the module's default of 2 (multi-main, needs an Enterprise/Startup license carrying feat:multipleMainInstances). Set to 1 to run a single main pod in plain queue mode instead, which only needs a Business-tier license: n8n's multi-main leader-election gate never engages at 1 replica. | `number` | `null` | no |
| <a name="input_n8n_proxy_hops"></a> [n8n\_proxy\_hops](#input\_n8n\_proxy\_hops) | Passed to the module's n8n\_proxy\_hops: number of proxies in front of n8n that add an X-Forwarded-For entry (the module's own ALB counts as 1, an additional proxy or WAF that adds its own entry makes 2). At any hop count of 1 or more, a caller that bypasses the declared proxy chain can forge X-Forwarded-For and spoof its client IP, including an in-cluster caller that reaches the n8n Services directly. When a proxy sits in front of the ALB, restrict the ALB to that proxy's egress addresses with the module's alb\_inbound\_cidrs or alb\_inbound\_prefix\_list\_ids input, which this example does not pass through (add it in main.tf), and keep in-cluster callers off the n8n Services. Leave null (the default) to use the module's default of 1. See [TLS proxy guide](../../docs/tls-proxy.md). | `number` | `null` | no |
| <a name="input_n8n_task_runner_image_repository"></a> [n8n\_task\_runner\_image\_repository](#input\_n8n\_task\_runner\_image\_repository) | Container image repository for the task runner sidecar (n8nio/runners), without a tag or digest (e.g. "123456789012.dkr.ecr.eu-west-1.amazonaws.com/n8n-runners"). Leave null to use the Helm chart's own repository (n8nio/runners). Set alongside n8n\_image\_repository when mirroring both images into the same private registry; the two are independent. Use n8n\_task\_runner\_image\_tag for the runner tag. Private-registry pull access is granted the same way as n8n\_image\_repository, through n8n\_image\_pull\_secrets. In this example the module creates no ServiceAccount, so attach those secrets to the ServiceAccount n8n-enterprise-pull that you create yourself. | `string` | `null` | no |
| <a name="input_n8n_task_runner_image_tag"></a> [n8n\_task\_runner\_image\_tag](#input\_n8n\_task\_runner\_image\_tag) | Image tag for the task runner sidecar (`n8nio/runners`). Leave null to inherit the n8n application image's tag, which is correct as long as that tag is a published n8n version. Set it to the underlying n8n version when running a custom image whose tag is not one (e.g. n8n\_image\_tag = "2.27.4-mypackages" together with n8n\_task\_runner\_image\_tag = "2.27.4"); otherwise the sidecar image cannot be pulled and every pod carrying a runner stays in ImagePullBackOff (workers only in upstream chart 2.0.0-rc.1 queue mode). | `string` | `null` | no |
| <a name="input_route53_zone_id"></a> [route53\_zone\_id](#input\_route53\_zone\_id) | Route53 hosted zone ID for the parent of n8n\_domain (e.g. the zone for example.com if n8n\_domain = n8n.example.com). The module creates the ACM certificate and its validation records inside this zone. It creates no alias A-record in this example: add the record yourself once your Ingress has a load balancer. | `string` | n/a | yes |
| <a name="input_s3_force_destroy"></a> [s3\_force\_destroy](#input\_s3\_force\_destroy) | Passed to the module's s3\_force\_destroy. Leave null (the default) to use the module's teardown-friendly default of true. | `bool` | `null` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Additional AWS tags to apply to every resource this example creates. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_certificate_arn"></a> [certificate\_arn](#output\_certificate\_arn) | ARN of the validated ACM certificate. Attach it to your Ingress with the alb.ingress.kubernetes.io/certificate-arn annotation. |
| <a name="output_cluster_name"></a> [cluster\_name](#output\_cluster\_name) | EKS cluster name. The Load Balancer Controller and Cluster Autoscaler charts need it. |
| <a name="output_db_password"></a> [db\_password](#output\_db\_password) | RDS PostgreSQL password. Goes into the Secret n8n-enterprise-db-secret under the key password. |
| <a name="output_kubectl_config_command"></a> [kubectl\_config\_command](#output\_kubectl\_config\_command) | Command to configure kubectl for this cluster. |
| <a name="output_n8n_helm_values"></a> [n8n\_helm\_values](#output\_n8n\_helm\_values) | Values for the n8n Helm chart. Write to a file with terraform output -raw n8n\_helm\_values > values.yaml and install the chart with it as release n8n. |
| <a name="output_n8n_url"></a> [n8n\_url](#output\_n8n\_url) | URL n8n answers on once the Ingress and DNS record you create are in place. |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | Namespace to install n8n into. The module does not create it in this example; the S3 Pod Identity association is bound to this name. |
| <a name="output_redis_auth_token"></a> [redis\_auth\_token](#output\_redis\_auth\_token) | Redis AUTH token, or null when Redis runs without one (the default). When set, it goes into the Secret n8n-enterprise-redis-secret under the key password. |
| <a name="output_vpc_id"></a> [vpc\_id](#output\_vpc\_id) | VPC ID. The Load Balancer Controller chart needs it. |
<!-- END_TF_DOCS -->
