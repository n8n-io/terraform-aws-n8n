# Plan-time tests for create_kubernetes_resources = false, the
# infrastructure-only mode: Terraform provisions AWS and makes no call to the
# Kubernetes API, and a cluster operator installs the controllers and n8n.
#
# A separate file from defaults.tftest.hcl because it needs a different mocked
# shape (see AGENTS.md): the override_resource block below makes the one
# computed AWS attribute the Helm values embed known at plan, so runs here can
# decode output.n8n_helm_values. Runs that read the values also point the
# module at an external database and Redis, whose endpoints are plain inputs.
# Widening the shared mock in defaults.tftest.hcl instead would change what
# every run there sees.
#
# What these runs cannot prove, because every provider is mocked:
#   - that a caller can leave the kubernetes and helm providers unconfigured,
#   - that the chart accepts the values with operator-created Secrets,
#   - that the rendered values match an earlier release byte for byte.
# Verify those with a real plan and a real `helm template`.
#
# Run: terraform test -filter=tests/infrastructure-only.tftest.hcl

mock_provider "aws" {
  # Same fixture as defaults.tftest.hcl: one validation option for the single
  # n8n_domain, so runs that set route53_zone_id can plan.
  mock_resource "aws_acm_certificate" {
    defaults = {
      domain_validation_options = [{
        domain_name           = "n8n.test.example.com"
        resource_record_name  = "_acme-challenge.n8n.test.example.com."
        resource_record_type  = "CNAME"
        resource_record_value = "_validation.acm-validations.aws."
      }]
    }
  }

  mock_data "aws_db_snapshot" {
    defaults = {
      engine            = "postgres"
      encrypted         = false
      kms_key_id        = ""
      allocated_storage = 20
      status            = "available"
    }
  }

  mock_data "aws_eks_cluster" {
    defaults = {
      endpoint = "https://EXISTING1234567890EXAMPLE.gr7.us-east-1.eks.amazonaws.com"
      version  = "1.35"
      certificate_authority = [{
        data = "ZmFrZS1jYS1kYXRh"
      }]
      vpc_config = [{
        vpc_id                    = "vpc-test12345"
        cluster_security_group_id = "sg-existingcluster"
        endpoint_private_access   = true
        endpoint_public_access    = true
        public_access_cidrs       = ["0.0.0.0/0"]
        security_group_ids        = []
        subnet_ids                = ["subnet-priv1", "subnet-priv2", "subnet-priv3", "subnet-pub1", "subnet-pub2", "subnet-pub3"]
      }]
    }
  }

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/test"
      user_id    = "AIDATESTUSER"
    }
  }

  override_data {
    target = module.controllers.data.aws_iam_policy_document.lbc
    values = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"elasticloadbalancing:*\"],\"Resource\":\"*\"}]}"
    }
  }

  # The chart requires serviceAccount.awsRoleArn, so the S3 role ARN is part
  # of the Helm values. Under mocks it is unknown at plan, which would make
  # the whole encoded string unknown. override_during = plan is required: the
  # default applies the override at apply only (see AGENTS.md).
  override_resource {
    target          = aws_iam_role.s3
    override_during = plan
    values = {
      arn  = "arn:aws:iam::123456789012:role/n8n-cluster-n8n-s3"
      name = "n8n-cluster-n8n-s3"
    }
  }
}

mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "random" {}
mock_provider "time" {}

# No n8n_license_key here, unlike defaults.tftest.hcl: the literal is rejected
# in infrastructure-only mode, so runs on the default path set it themselves.
variables {
  aws_region      = "us-east-1"
  cluster_name    = "n8n-cluster"
  n8n_domain      = "n8n.test.example.com"
  vpc_id          = "vpc-test12345"
  private_subnets = ["subnet-priv1", "subnet-priv2", "subnet-priv3"]
  public_subnets  = ["subnet-pub1", "subnet-pub2", "subnet-pub3"]
  vpc_cidr_block  = "10.0.0.0/16"
  certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/test-cert"
}

# ── Default path ──────────────────────────────────────────────────────────────

run "toggle_defaults_to_true_and_keeps_every_kubernetes_resource" {
  command = plan

  variables {
    n8n_license_key = "test-license-key-not-real"
  }

  assert {
    condition     = var.create_kubernetes_resources == true
    error_message = "create_kubernetes_resources must default to true so existing callers plan unchanged"
  }

  assert {
    condition = (
      length(helm_release.n8n) == 1 &&
      length(kubernetes_namespace.n8n) == 1 &&
      length(kubernetes_secret.n8n) == 1 &&
      length(kubernetes_secret.n8n_db) == 1 &&
      length(kubernetes_secret_v1.n8n_task_runner_token) == 1 &&
      length(random_password.task_runner_token) == 1 &&
      length(random_id.n8n_encryption_key) == 1 &&
      length(kubernetes_pod_disruption_budget_v1.n8n_webhook) == 1 &&
      length(kubernetes_pod_disruption_budget_v1.n8n_worker) == 1 &&
      length(kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook) == 1 &&
      length(kubernetes_ingress_v1.n8n) == 1 &&
      length(time_sleep.wait_for_alb_cleanup) == 1
    )
    error_message = "The default path must keep one instance of every module-managed Kubernetes resource"
  }

  assert {
    condition = (
      length(module.controllers.lbc_helm_release) == 1 &&
      length(module.controllers.cluster_autoscaler_helm_release) == 1 &&
      length(module.controllers.metrics_server_helm_release) == 1 &&
      length(module.controllers.keda_helm_release) == 1 &&
      length(module.controllers.gp3_storage_class) == 1
    )
    error_message = "The default path must keep every controller Helm release and the gp3 StorageClass"
  }
}

# The output and the release read one local, so they cannot drift apart. The
# external database and Redis make every value in it known at plan.
run "default_path_output_is_what_the_release_receives" {
  command = plan

  variables {
    n8n_license_key        = "test-license-key-not-real"
    create_database        = false
    db_host                = "db.internal.example.com"
    db_password_secret_ref = { name = "caller-db-secret" }
    create_elasticache     = false
    redis_host             = "redis.internal.example.com"
  }

  assert {
    condition     = nonsensitive(output.n8n_helm_values) == nonsensitive(helm_release.n8n[0].values[0])
    error_message = "output.n8n_helm_values must be exactly the values string helm_release.n8n receives"
  }

  assert {
    condition = (
      yamldecode(nonsensitive(output.n8n_helm_values)).taskRunners.authToken.existingSecret == "n8n-task-runner-token" &&
      yamldecode(nonsensitive(output.n8n_helm_values)).secretRefs.existingSecret == "n8n-enterprise-secrets" &&
      yamldecode(nonsensitive(output.n8n_helm_values)).license.existingSecret.name == "n8n-enterprise-secrets"
    )
    error_message = "The default path must keep pointing the chart at the module-managed Secrets by their existing names"
  }
}

# Without a license the default path must still fail: the rule only relaxes in
# infrastructure-only mode.
run "default_path_still_requires_exactly_one_license_input" {
  command = plan

  expect_failures = [var.n8n_license_key_secret_ref]
}

# ── Infrastructure-only: nothing in the cluster ───────────────────────────────
# Optional resources are switched on where an input can do it, so a zero count
# proves the new gate and not the resource's own default.

run "infrastructure_only_creates_no_kubernetes_or_helm_resource" {
  command = plan

  variables {
    create_kubernetes_resources = false
    certificate_arn             = null
    route53_zone_id             = "Z0123456789ABCDEFGHIJ"
    redis_exporter_enabled      = true
  }

  assert {
    condition = (
      length(helm_release.n8n) == 0 &&
      length(kubernetes_namespace.n8n) == 0 &&
      length(kubernetes_secret.n8n) == 0 &&
      length(kubernetes_secret.n8n_db) == 0 &&
      length(kubernetes_secret.n8n_redis) == 0 &&
      length(kubernetes_secret_v1.n8n_ca_bundle) == 0 &&
      length(kubernetes_secret_v1.n8n_task_runner_token) == 0 &&
      length(kubernetes_service_account_v1.n8n) == 0
    )
    error_message = "Infrastructure-only mode must create no namespace, Secret, ServiceAccount or n8n release"
  }

  assert {
    condition = (
      length(kubernetes_pod_disruption_budget_v1.n8n_webhook) == 0 &&
      length(kubernetes_pod_disruption_budget_v1.n8n_worker) == 0 &&
      length(kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook) == 0 &&
      length(kubernetes_ingress_v1.n8n) == 0 &&
      length(time_sleep.wait_for_alb_cleanup) == 0 &&
      length(kubernetes_deployment_v1.redis_exporter) == 0 &&
      length(kubernetes_service_v1.redis_exporter) == 0
    )
    error_message = "Infrastructure-only mode must create no autoscaler, budget, Ingress, cleanup sleep or exporter, even with redis_exporter_enabled = true"
  }

  assert {
    condition = (
      length(module.controllers.lbc_helm_release) == 0 &&
      length(module.controllers.cluster_autoscaler_helm_release) == 0 &&
      length(module.controllers.metrics_server_helm_release) == 0 &&
      length(module.controllers.keda_helm_release) == 0 &&
      length(module.controllers.gp3_storage_class) == 0
    )
    error_message = "Infrastructure-only mode must install no controller and create no StorageClass, overriding the install_* defaults"
  }

  # The operator owns the application secrets, so Terraform generates none.
  assert {
    condition     = length(random_id.n8n_encryption_key) == 0 && length(random_password.task_runner_token) == 0
    error_message = "Infrastructure-only mode must not generate an encryption key or a task runner token into state"
  }

  # The alias records point at an ALB that only exists once the operator
  # creates an Ingress, so they and the lookup behind them are skipped.
  assert {
    condition = (
      length(aws_route53_record.n8n_alias) == 0 &&
      length(aws_route53_record.n8n_alias_additional) == 0 &&
      length(data.aws_lb.n8n) == 0
    )
    error_message = "Infrastructure-only mode must skip the Route 53 alias records and the ALB lookup"
  }
}

# The Secrets and the ServiceAccount each have an input that switches them on.
# A separate run from the one above, because these inputs need an external
# Redis and a custom image to plan without unrelated warnings.
run "infrastructure_only_skips_secrets_its_inputs_would_otherwise_create" {
  command = plan

  variables {
    create_kubernetes_resources = false
    create_elasticache          = false
    redis_host                  = "redis.internal.example.com"
    redis_auth_token            = "not-a-real-token-0123456789"
    n8n_image_repository        = "registry.example.com/n8n"
    n8n_image_tag               = "2.44.5"
    n8n_task_runner_image_tag   = "2.44.5"
    n8n_image_pull_secrets      = ["regcred"]
    n8n_extra_ca_pem            = "-----BEGIN CERTIFICATE-----\nMIIBinfrastructureonly\n-----END CERTIFICATE-----\n"
  }

  assert {
    condition = (
      length(kubernetes_secret.n8n_redis) == 0 &&
      length(kubernetes_secret_v1.n8n_ca_bundle) == 0 &&
      length(kubernetes_service_account_v1.n8n) == 0
    )
    error_message = "Redis AUTH, n8n_extra_ca_pem and n8n_image_pull_secrets must not create a Secret or ServiceAccount in infrastructure-only mode"
  }

  # The S3 binding follows the ServiceAccount name the values carry, which
  # the operator now creates.
  assert {
    condition     = aws_eks_pod_identity_association.s3.service_account == "n8n-enterprise-pull"
    error_message = "With n8n_image_pull_secrets set, the S3 association must bind the ServiceAccount the operator creates"
  }
}

run "infrastructure_only_keeps_the_aws_side" {
  command = plan

  variables {
    create_kubernetes_resources = false
    certificate_arn             = null
    route53_zone_id             = "Z0123456789ABCDEFGHIJ"
  }

  assert {
    condition = (
      length(aws_eks_cluster.n8n) == 1 &&
      length(aws_eks_node_group.n8n) == 1 &&
      length(aws_db_instance.n8n) == 1 &&
      length(aws_s3_bucket.n8n) == 1
    )
    error_message = "Infrastructure-only mode must still create the cluster, node group, database and bucket"
  }

  # The certificate stays: the operator's Ingress attaches it.
  assert {
    condition     = length(aws_acm_certificate.n8n) == 1 && length(aws_acm_certificate_validation.n8n) == 1 && length(aws_route53_record.cert_validation) == 1
    error_message = "Infrastructure-only mode must still issue and validate the ACM certificate"
  }

  # AWS resources inside modules/controllers follow their own gates, not the
  # new toggle: the add-on and the IAM bindings the operator's controllers use.
  assert {
    condition = (
      length(module.controllers.ebs_csi_addon) == 1 &&
      length(module.controllers.ebs_csi_iam_role) == 1 &&
      length(module.controllers.lbc_pod_identity_association) == 1 &&
      length(module.controllers.cluster_autoscaler_pod_identity_association) == 1
    )
    error_message = "Infrastructure-only mode must keep the EBS CSI add-on and the controller Pod Identity associations"
  }

  assert {
    condition = (
      module.controllers.lbc_pod_identity_association[0].namespace == "kube-system" &&
      module.controllers.lbc_pod_identity_association[0].service_account == "aws-load-balancer-controller" &&
      module.controllers.cluster_autoscaler_pod_identity_association[0].service_account == "cluster-autoscaler"
    )
    error_message = "The controller Pod Identity associations must keep the ServiceAccount names the operator installs against"
  }

  # The S3 binding names a namespace and ServiceAccount that do not exist yet.
  # EKS accepts that, and the operator's release must use exactly these names.
  assert {
    condition     = aws_eks_pod_identity_association.s3.namespace == "n8n" && aws_eks_pod_identity_association.s3.service_account == "n8n-enterprise"
    error_message = "The S3 Pod Identity association must bind the namespace and ServiceAccount the Helm values name"
  }
}

# On an existing cluster the controller IAM follows install_* exactly as it
# does today, because another installation may already hold that binding.
run "infrastructure_only_on_an_existing_cluster_keeps_iam_on_the_install_toggles" {
  command = plan

  variables {
    create_kubernetes_resources                  = false
    create_eks                                   = false
    existing_eks_cluster_name                    = "platform-shared-cluster"
    existing_eks_cluster_prerequisites_confirmed = true
    install_lbc                                  = false
  }

  # The storage check always fires on create_eks = false (see storage.tf).
  expect_failures = [check.existing_eks_cluster_needs_its_own_storage_toggle]

  assert {
    condition     = length(module.controllers.lbc_pod_identity_association) == 0 && length(module.controllers.lbc_iam_role) == 0
    error_message = "install_lbc = false on an existing cluster must still skip the LBC IAM role and association"
  }

  assert {
    condition     = length(module.controllers.cluster_autoscaler_pod_identity_association) == 1 && length(module.controllers.cluster_autoscaler_helm_release) == 0
    error_message = "install_cluster_autoscaler = true on an existing cluster must keep its IAM binding while the Helm release is skipped"
  }
}

# ── Infrastructure-only: outputs ──────────────────────────────────────────────

run "infrastructure_only_outputs_report_what_terraform_does_not_own" {
  command = plan

  variables {
    create_kubernetes_resources = false
  }

  assert {
    condition     = output.alb_hostname == null
    error_message = "alb_hostname must be null in infrastructure-only mode, not the 'not yet provisioned' fallback text"
  }

  assert {
    condition     = output.n8n_encryption_key == null
    error_message = "n8n_encryption_key must be null in infrastructure-only mode: the operator owns the key"
  }

  assert {
    condition     = output.namespace == "n8n"
    error_message = "namespace must return the intended name from var.namespace when the module creates no namespace"
  }
}

# ── Infrastructure-only: Helm values ──────────────────────────────────────────

run "infrastructure_only_values_name_the_secrets_the_operator_creates" {
  command = plan

  variables {
    create_kubernetes_resources = false
    create_database             = false
    db_host                     = "db.internal.example.com"
    db_password                 = "not-a-real-password"
    create_elasticache          = false
    redis_host                  = "redis.internal.example.com"
    redis_auth_token            = "not-a-real-token-0123456789"
  }

  assert {
    condition = (
      yamldecode(nonsensitive(output.n8n_helm_values)).secretRefs.existingSecret == "n8n-enterprise-secrets" &&
      yamldecode(nonsensitive(output.n8n_helm_values)).license.existingSecret.name == "n8n-enterprise-secrets" &&
      yamldecode(nonsensitive(output.n8n_helm_values)).license.existingSecret.key == "N8N_LICENSE_ACTIVATION_KEY"
    )
    error_message = "With no reference inputs, the values must name n8n-enterprise-secrets for the encryption key and the license"
  }

  assert {
    condition = (
      yamldecode(nonsensitive(output.n8n_helm_values)).taskRunners.authToken.existingSecret == "n8n-task-runner-token" &&
      yamldecode(nonsensitive(output.n8n_helm_values)).taskRunners.authToken.existingSecretKey == "N8N_RUNNERS_AUTH_TOKEN"
    )
    error_message = "The values must name n8n-task-runner-token for the task runner token"
  }

  assert {
    condition = (
      yamldecode(nonsensitive(output.n8n_helm_values)).database.passwordSecret.name == "n8n-enterprise-db-secret" &&
      yamldecode(nonsensitive(output.n8n_helm_values)).database.passwordSecret.key == "password" &&
      yamldecode(nonsensitive(output.n8n_helm_values)).redis.passwordSecret.name == "n8n-enterprise-redis-secret" &&
      yamldecode(nonsensitive(output.n8n_helm_values)).redis.passwordSecret.key == "password"
    )
    error_message = "The values must name n8n-enterprise-db-secret and n8n-enterprise-redis-secret for the database and Redis credentials"
  }

  # The chart must agree with the S3 Pod Identity binding, or n8n gets no
  # S3 credentials.
  assert {
    condition = (
      yamldecode(nonsensitive(output.n8n_helm_values)).serviceAccount.name == "n8n-enterprise" &&
      yamldecode(nonsensitive(output.n8n_helm_values)).serviceAccount.awsRoleArn == "arn:aws:iam::123456789012:role/n8n-cluster-n8n-s3"
    )
    error_message = "The values must carry the ServiceAccount name the S3 association binds and the S3 role ARN the chart requires"
  }
}

# A caller's *_secret_ref still wins over the fixed names: only the fallback
# to a module-managed Secret changes in this mode.
run "infrastructure_only_values_keep_caller_secret_references" {
  command = plan

  variables {
    create_kubernetes_resources   = false
    create_database               = false
    db_host                       = "db.internal.example.com"
    db_password_secret_ref        = { name = "caller-db-secret", key = "pg-password" }
    create_elasticache            = false
    redis_host                    = "redis.internal.example.com"
    redis_auth_token_secret_ref   = { name = "caller-redis-secret", key = "auth" }
    n8n_encryption_key_secret_ref = { name = "caller-core-secret" }
    n8n_license_key_secret_ref    = { name = "caller-license-secret", key = "activation" }
  }

  assert {
    condition = (
      yamldecode(nonsensitive(output.n8n_helm_values)).secretRefs.existingSecret == "caller-core-secret" &&
      yamldecode(nonsensitive(output.n8n_helm_values)).license.existingSecret.name == "caller-license-secret" &&
      yamldecode(nonsensitive(output.n8n_helm_values)).license.existingSecret.key == "activation"
    )
    error_message = "Caller references for the encryption key and the license must reach the values with their own name and key"
  }

  assert {
    condition = (
      yamldecode(nonsensitive(output.n8n_helm_values)).database.passwordSecret.name == "caller-db-secret" &&
      yamldecode(nonsensitive(output.n8n_helm_values)).database.passwordSecret.key == "pg-password" &&
      yamldecode(nonsensitive(output.n8n_helm_values)).redis.passwordSecret.name == "caller-redis-secret" &&
      yamldecode(nonsensitive(output.n8n_helm_values)).redis.passwordSecret.key == "auth"
    )
    error_message = "Caller references for the database and Redis credentials must reach the values with their own name and key"
  }
}

# Offline licensing has no license.existingSecret: the certificate reaches n8n
# through env.shared.
run "infrastructure_only_values_support_the_offline_license_certificate" {
  command = plan

  variables {
    create_kubernetes_resources = false
    create_database             = false
    db_host                     = "db.internal.example.com"
    db_password_secret_ref      = { name = "caller-db-secret" }
    create_elasticache          = false
    redis_host                  = "redis.internal.example.com"
    n8n_license_cert_secret_ref = { name = "caller-license-cert" }
  }

  assert {
    condition     = !contains(keys(yamldecode(nonsensitive(output.n8n_helm_values)).license), "existingSecret")
    error_message = "The offline certificate path must not render license.existingSecret"
  }

  assert {
    condition     = yamldecode(nonsensitive(output.n8n_helm_values)).env.shared.N8N_LICENSE_CERT.secretKeyRef.name == "caller-license-cert"
    error_message = "The offline certificate must reach env.shared as a secretKeyRef to the caller's Secret"
  }
}

# ── Infrastructure-only: rejected inputs ──────────────────────────────────────
# A literal application secret would sit in state with nothing reading it.

run "infrastructure_only_rejects_a_literal_license_key" {
  command = plan

  variables {
    create_kubernetes_resources = false
    n8n_license_key             = "test-license-key-not-real"
  }

  expect_failures = [var.n8n_license_key]
}

run "infrastructure_only_rejects_a_literal_encryption_key" {
  command = plan

  variables {
    create_kubernetes_resources = false
    n8n_encryption_key          = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  }

  expect_failures = [var.n8n_encryption_key]
}

run "infrastructure_only_rejects_two_license_references" {
  command = plan

  variables {
    create_kubernetes_resources = false
    n8n_license_key_secret_ref  = { name = "caller-license-secret" }
    n8n_license_cert_secret_ref = { name = "caller-license-cert" }
  }

  expect_failures = [var.n8n_license_key_secret_ref]
}

# The release owns this rule on the default path. With no release instance the
# output owns it, so a chart that ignores pools still fails the plan.
run "infrastructure_only_rejects_worker_pools_on_a_numbered_chart" {
  command = plan

  variables {
    create_kubernetes_resources = false
    db_instance_class           = "db.m6g.2xlarge"
    n8n_chart_version           = "2.0.0"
    n8n_worker_pools            = [{ name = "gpu" }]
  }

  expect_failures = [output.n8n_helm_values]
}

# ── Infrastructure-only: relaxed rules and warnings ───────────────────────────

# Rejected on the default path, because the module-managed Ingress would wait
# for a controller that is not there. There is no such Ingress in this mode.
run "infrastructure_only_accepts_install_lbc_false" {
  command = plan

  variables {
    create_kubernetes_resources = false
    install_lbc                 = false
  }

  assert {
    condition     = length(kubernetes_ingress_v1.n8n) == 0
    error_message = "install_lbc = false must plan in infrastructure-only mode, with no module-managed Ingress"
  }
}

# The Ingress inputs reach nothing here, and the caller should hear that once.
# The annotations also override the scheme, the TLS policy and the source
# restrictions, which on the default path fires four more warnings; in this
# mode they would describe an ALB that does not exist, so only the tuning
# warning may fire.
run "infrastructure_only_warns_once_that_ingress_inputs_are_inert" {
  command = plan

  variables {
    create_kubernetes_resources = false
    ingress_scheme              = "internal"
    alb_inbound_cidrs           = ["10.0.0.0/8"]
    ingress_annotations = {
      "alb.ingress.kubernetes.io/scheme"          = "internal"
      "alb.ingress.kubernetes.io/ssl-policy"      = "ELBSecurityPolicy-TLS13-1-2-2021-06"
      "alb.ingress.kubernetes.io/inbound-cidrs"   = "10.0.0.0/8"
      "alb.ingress.kubernetes.io/security-groups" = "sg-0123456789abcdef0"
    }
  }

  expect_failures = [check.ingress_tuning_requires_module_managed_ingress]
}

# With no webhook autoscaler there is nothing left to need metrics-server, and
# with no generated key the snapshot warning would give wrong advice. Both
# must stay quiet: a firing check fails this run.
run "infrastructure_only_silences_warnings_about_objects_it_does_not_create" {
  command = plan

  variables {
    create_kubernetes_resources = false
    install_metrics_server      = false
    db_snapshot_identifier      = "n8n-postgres-pre-rebuild"
    # The fixture snapshot is unencrypted, and a restore inherits that.
    db_storage_encrypted = false
  }

  assert {
    condition     = length(kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook) == 0
    error_message = "The run must plan cleanly, with no webhook autoscaler and no warning about metrics-server or the snapshot's encryption key"
  }
}
