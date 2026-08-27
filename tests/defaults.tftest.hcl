# Plan-time tests for the terraform-aws-n8n module using mocked providers.
#
# Exercises the module end-to-end (EKS, RDS, Redis, S3, KEDA, n8n Helm release)
# without contacting AWS. Providers are mocked and network-backed data sources
# are overridden with fixed values.
#
# Run: terraform test
#   (from the module root — requires terraform >= 1.7)

mock_provider "aws" {
  # The mock provider invents values for most computed attributes but leaves a
  # computed set-of-object unknown at plan time. domain_validation_options is
  # one, and aws_route53_record.cert_validation derives its for_each keys from
  # local.acm_domain_names but its values from this attribute, so without a
  # concrete default here any run that sets route53_zone_id fails to plan.
  #
  # One entry, matching the single n8n_domain every run in this file uses. That
  # is what makes the check block in dns.tf meaningful here: it compares the
  # number of validation records against the number of names on the
  # certificate, so the mock has to mirror the configured domain set exactly.
  # Multi-domain runs live in additional-domains.tftest.hcl, which declares its
  # own mock with one entry per name.
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

  # data.aws_kms_key.db_byo / .db_logs_byo describe a caller-supplied CMK so an
  # unusable key fails the plan instead of the apply (database.tf). The mock
  # provider would otherwise invent values for key_state, key_usage and key_spec,
  # and the db_byo_kms_keys_are_usable check would then report a healthy fixture
  # key as disabled or asymmetric. These are the values a real symmetric,
  # enabled, encryption key returns. Runs that want the unhappy path override
  # them per-run.
  #
  # The key ID in every KMS ARN fixture below is a strictly RFC 4122-shaped UUID
  # for the same reason: the provider's own key_id validator rejects anything
  # else, including AWS's own docs placeholder 1234abcd-12ab-34cd-56ef-...,
  # whose fourth group does not start with 8, 9, a or b. Do not "correct" the
  # fixtures back to the docs value.
  mock_data "aws_kms_key" {
    defaults = {
      key_state = "Enabled"
      key_usage = "ENCRYPT_DECRYPT"
      key_spec  = "SYMMETRIC_DEFAULT"
    }
  }

  # data.aws_db_snapshot.restore is read whenever db_snapshot_identifier is set,
  # so the checks in database.tf can compare the snapshot against the
  # configuration before a ForceNew mismatch turns into a permanent replacement
  # diff. Default fixture is an unencrypted 20 GB postgres snapshot, which is the
  # combination that needs the fewest inputs to plan cleanly. Runs override it for
  # the encrypted case and for each mismatch.
  mock_data "aws_db_snapshot" {
    defaults = {
      engine            = "postgres"
      encrypted         = false
      kms_key_id        = ""
      allocated_storage = 20
      status            = "available"
    }
  }

  # data.aws_secretsmanager_secret.external_secrets resolves each name in
  # n8n_external_secrets_aws_secret_names to an ARN. Every instance gets the
  # same fixture ARN unless a run overrides it, which is deliberately what
  # makes the intersection-check tests below work: pointing
  # module_managed.arns at this same value is what triggers the check.
  mock_data "aws_secretsmanager_secret" {
    defaults = {
      arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:mock-AbCdEf"
    }
  }

  # data.aws_secretsmanager_secrets.module_managed is the best-effort tag
  # query behind the intersection check (s3.tf). Empty by default, matching a
  # test account with nothing tagged ManagedBy = terraform in Secrets Manager.
  mock_data "aws_secretsmanager_secrets" {
    defaults = {
      arns  = []
      names = []
    }
  }

  # data.aws_eks_cluster.existing (create_eks = false) describes a caller's
  # existing cluster. Defaults match this file's own vpc_id and
  # kubernetes_version defaults exactly, so a run that only sets create_eks =
  # false and existing_eks_cluster_name plans cleanly with no VPC or version
  # check firing; runs exercising those mismatches override vpc_config.vpc_id
  # or version explicitly.
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
}

mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "random" {}
mock_provider "time" {}

variables {
  aws_region      = "us-east-1"
  cluster_name    = "n8n-cluster"
  n8n_domain      = "n8n.test.example.com"
  vpc_id          = "vpc-test12345"
  private_subnets = ["subnet-priv1", "subnet-priv2", "subnet-priv3"]
  public_subnets  = ["subnet-pub1", "subnet-pub2", "subnet-pub3"]
  vpc_cidr_block  = "10.0.0.0/16"
  certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/test-cert"

  n8n_license_key = "test-license-key-not-real"
}

run "defaults_produce_valid_plan" {
  command = plan

  assert {
    condition     = aws_eks_cluster.n8n[0].name == "n8n-cluster"
    error_message = "var.cluster_name should flow through to aws_eks_cluster.name"
  }

  assert {
    condition     = aws_eks_cluster.n8n[0].version == "1.35"
    error_message = "kubernetes_version should default to 1.35"
  }

  # Multi-main sizes nodes larger than single (6 n8n pods + overhead).
  assert {
    condition     = aws_eks_node_group.n8n[0].instance_types[0] == "t3.xlarge"
    error_message = "node_instance_type default should be t3.xlarge for multi-main workload"
  }

  # Confirms desired_size still plans from var.node_desired on create. The
  # lifecycle.ignore_changes = [scaling_config[0].desired_size] added for issue
  # #50 only suppresses drift against *real* state once the Cluster Autoscaler
  # has changed the live desired_size out-of-band — a mocked plan-time test has
  # no prior state to diverge from, so it cannot exercise that behavior. It is
  # verified by a live apply, a manual scale event (or CA-driven scale), and a
  # follow-up `terraform plan` showing no changes to desired_size.
  assert {
    condition     = aws_eks_node_group.n8n[0].scaling_config[0].desired_size == 3
    error_message = "node_desired should default to 3 (multi-main minimum)"
  }

  assert {
    condition     = aws_eks_node_group.n8n[0].scaling_config[0].min_size == 3
    error_message = "node_min should default to 3"
  }

  assert {
    condition     = aws_eks_node_group.n8n[0].scaling_config[0].max_size == 6
    error_message = "node_max should default to 6"
  }

  # Cluster Autoscaler relies on these tags for ASG discovery.
  assert {
    condition     = aws_eks_node_group.n8n[0].tags["k8s.io/cluster-autoscaler/enabled"] == "true"
    error_message = "node group must carry k8s.io/cluster-autoscaler/enabled tag"
  }

  assert {
    condition     = aws_eks_node_group.n8n[0].tags["k8s.io/cluster-autoscaler/n8n-cluster"] == "owned"
    error_message = "node group must carry cluster-specific autoscaler ownership tag"
  }
}

# ── Credentials held in the shared Secret rather than in Helm values ─────────
# The license key and the task runner token both used to be passed to the chart
# as literal values, which put them in the rendered Helm release and therefore in
# Helm's own release Secret in-cluster. Both now go through
# kubernetes_secret.n8n, like the encryption key below.
#
# Only the presence and content of the Secret is assertable here. That the values
# are *absent* from the Helm release is not: helm_release.n8n.values embeds the
# Redis endpoint, so it is unknown at plan time, the same limitation the KEDA and
# extraEnv sections further down work around.

# ── Bring your own EKS cluster (create_eks) ──────────────────────────────────

run "create_eks_default_creates_the_cluster" {
  command = plan

  assert {
    condition = (
      length(aws_eks_cluster.n8n) == 1 &&
      length(aws_eks_node_group.n8n) == 1 &&
      length(aws_iam_role.cluster) == 1 &&
      length(aws_iam_role.nodes) == 1 &&
      length(aws_eks_addon.pod_identity_agent) == 1 &&
      length(data.aws_eks_cluster.existing) == 0
    )
    error_message = "create_eks = true (the default) must create the cluster, node group, both IAM roles and the Pod Identity Agent addon, and read no existing cluster"
  }
}

run "create_eks_false_requires_existing_eks_cluster_name" {
  command = plan

  variables {
    create_eks = false
  }

  # existing_eks_cluster_prerequisites_confirmed also defaults to false, so it
  # trips here too; listed alongside the input this run is actually about.
  expect_failures = [var.existing_eks_cluster_name, var.existing_eks_cluster_prerequisites_confirmed]
}

run "create_eks_false_requires_prerequisites_confirmed" {
  command = plan

  variables {
    create_eks                = false
    existing_eks_cluster_name = "platform-shared-cluster"
  }

  # The storage check also fires unconditionally whenever create_eks = false
  # (see storage.tf), independent of this run's actual subject.
  expect_failures = [var.existing_eks_cluster_prerequisites_confirmed, check.existing_eks_cluster_needs_its_own_storage_toggle]
}

run "create_eks_false_skips_module_managed_cluster_resources" {
  command = plan

  variables {
    create_eks                                   = false
    existing_eks_cluster_name                    = "platform-shared-cluster"
    existing_eks_cluster_prerequisites_confirmed = true
  }

  # The storage check always fires on this path (see storage.tf); listing it
  # here is what proves nothing else unexpected also fired.
  expect_failures = [check.existing_eks_cluster_needs_its_own_storage_toggle]

  assert {
    condition = (
      length(aws_eks_cluster.n8n) == 0 &&
      length(aws_eks_node_group.n8n) == 0 &&
      length(aws_iam_role.cluster) == 0 &&
      length(aws_iam_role.nodes) == 0 &&
      length(aws_eks_addon.pod_identity_agent) == 0 &&
      length(data.aws_eks_cluster.existing) == 1
    )
    error_message = "create_eks = false must create no module-managed cluster resources and instead read the existing cluster"
  }

  # eks_secrets_encryption_enabled defaults to true, but its CMK, alias and
  # control-plane log group have no consumer on this path: the encryption_config
  # they would feed lives on aws_eks_cluster.n8n, which does not exist here, and
  # their policy needs aws_iam_role.cluster, which also does not exist.
  assert {
    condition = (
      length(aws_kms_key.eks) == 0 &&
      length(aws_kms_alias.eks) == 0 &&
      length(aws_cloudwatch_log_group.eks_cluster) == 0
    )
    error_message = "create_eks = false must create no cluster-secrets CMK, alias, or control-plane log group: none of the module-created cluster resources they support exist on this path"
  }

  assert {
    condition     = local.eks_cluster_name == "platform-shared-cluster"
    error_message = "local.eks_cluster_name must resolve to the existing cluster's name on this path"
  }

  assert {
    condition     = aws_iam_role_policy_attachment.s3.role == aws_iam_role.s3.name
    error_message = "IAM/Pod Identity resources this module still owns (the n8n service account's S3 role, for example) must keep working against the existing cluster"
  }
}

run "create_eks_false_rejects_a_vpc_mismatch" {
  command = plan

  variables {
    create_eks                                   = false
    existing_eks_cluster_name                    = "platform-shared-cluster"
    existing_eks_cluster_prerequisites_confirmed = true
  }

  override_data {
    target = data.aws_eks_cluster.existing[0]
    values = {
      vpc_config = [{
        vpc_id                    = "vpc-wrong00000"
        cluster_security_group_id = "sg-existingcluster"
        endpoint_private_access   = true
        endpoint_public_access    = true
        public_access_cidrs       = ["0.0.0.0/0"]
        security_group_ids        = []
        subnet_ids                = ["subnet-priv1"]
      }]
    }
  }

  expect_failures = [data.aws_eks_cluster.existing, check.existing_eks_cluster_needs_its_own_storage_toggle]
}

run "create_eks_false_kubernetes_version_mismatch_warns" {
  command = plan

  variables {
    create_eks                                   = false
    existing_eks_cluster_name                    = "platform-shared-cluster"
    existing_eks_cluster_prerequisites_confirmed = true
    kubernetes_version                           = "1.31"
  }

  # The mock cluster is fixed at version 1.35 (see mock_data above), so asking
  # for 1.31 here is the mismatch this check exists to surface. The storage
  # check also fires: create_ebs_csi is left at its true default (see the run
  # above).
  expect_failures = [
    check.existing_eks_cluster_kubernetes_version_matches,
    check.existing_eks_cluster_needs_its_own_storage_toggle,
  ]
}

# The mirror image of the required-when-false validation above: naming a cluster
# while leaving create_eks at its default is accepted, and quietly builds a whole
# new cluster next to the one the caller meant to deploy onto.
run "existing_eks_cluster_name_without_create_eks_false_warns" {
  command = plan

  variables {
    existing_eks_cluster_name = "platform-shared-cluster"
  }

  expect_failures = [check.existing_eks_cluster_name_requires_create_eks_false]
}

run "existing_eks_cluster_name_unset_is_silent_on_the_default_path" {
  command = plan

  assert {
    condition     = length(data.aws_eks_cluster.existing) == 0
    error_message = "create_eks = true (the default) must read no existing cluster, so the ignored-input check has nothing to warn about"
  }
}

# ── create_ebs_csi ────────────────────────────────────────────────────────────

run "create_ebs_csi_default_installs_storage" {
  command = plan

  assert {
    condition     = length(module.controllers.ebs_csi_addon) == 1 && length(module.controllers.gp3_storage_class) == 1
    error_message = "create_ebs_csi = true (the default) must install the CSI addon and the gp3 StorageClass"
  }
}

run "create_ebs_csi_false_creates_no_storage_resources" {
  command = plan

  variables {
    create_ebs_csi = false
  }

  assert {
    condition     = length(module.controllers.ebs_csi_addon) == 0 && length(module.controllers.gp3_storage_class) == 0
    error_message = "create_ebs_csi = false must create neither the CSI addon nor the gp3 StorageClass"
  }

  # The IAM role and its policy attachment are gated on the same toggle. Their
  # only consumer is the addon's pod_identity_association block, so leaving them
  # unconditional would strand a role carrying AmazonEBSCSIDriverPolicy that
  # nothing can assume, the same way aws_security_group.rds used to be stranded
  # on the external-database path.
  assert {
    condition     = length(module.controllers.ebs_csi_iam_role) == 0 && length(module.controllers.ebs_csi_iam_role_policy_attachment) == 0
    error_message = "create_ebs_csi = false must leave behind neither the EBS CSI IAM role nor its AmazonEBSCSIDriverPolicy attachment"
  }
}

run "create_ebs_csi_false_silences_the_existing_cluster_storage_check" {
  command = plan

  variables {
    create_eks                                   = false
    existing_eks_cluster_name                    = "platform-shared-cluster"
    existing_eks_cluster_prerequisites_confirmed = true
    create_ebs_csi                               = false
  }

  assert {
    condition     = length(module.controllers.ebs_csi_addon) == 0 && length(module.controllers.gp3_storage_class) == 0
    error_message = "create_eks = false with create_ebs_csi = false must still create no storage resources, and the check above must not need listing in expect_failures"
  }
}

run "license_key_reaches_pods_through_the_shared_secret" {
  command = plan

  assert {
    condition     = kubernetes_secret.n8n[0].data["N8N_LICENSE_ACTIVATION_KEY"] == "test-license-key-not-real"
    error_message = "n8n_license_key must reach pods through kubernetes_secret.n8n, not as a literal chart value"
  }
}

run "task_runner_token_is_always_generated" {
  command = plan

  # Asserted on the configured length rather than on .result, which is
  # computed and therefore unknown under `command = plan` even with the
  # random provider mocked. Always generated: there is no override input.
  assert {
    condition     = random_password.task_runner_token.length == 32
    error_message = "The task runner token must always be generated by the module; there is no caller-supplied override."
  }
}

run "task_runner_token_secret_is_independent_of_task_runners_toggle" {
  command = plan

  variables {
    n8n_task_runners_enabled = false
  }

  assert {
    condition     = random_password.task_runner_token.length == 32
    error_message = "The token must still be generated when n8n_task_runners_enabled = false; the sidecar toggle does not gate it."
  }
}

# ── Encryption key override ──────────────────────────────────────────────────

run "encryption_key_defaults_to_generated" {
  command = plan

  assert {
    condition     = length(random_id.n8n_encryption_key) == 1
    error_message = "Leaving n8n_encryption_key null must generate a key exactly as every deployment before this input did"
  }
}

run "encryption_key_override_skips_generation" {
  command = plan

  variables {
    n8n_encryption_key = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
  }

  assert {
    condition     = length(random_id.n8n_encryption_key) == 0
    error_message = "Supplying n8n_encryption_key must skip generating a random one"
  }

  assert {
    condition     = kubernetes_secret.n8n[0].data["N8N_ENCRYPTION_KEY"] == "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
    error_message = "The supplied n8n_encryption_key must reach the N8N_ENCRYPTION_KEY secret key unchanged"
  }
}

run "encryption_key_rejects_wrong_length" {
  command = plan

  variables {
    n8n_encryption_key = "tooshort"
  }

  expect_failures = [var.n8n_encryption_key]
}

run "encryption_key_rejects_non_hex" {
  command = plan

  variables {
    # 64 characters (correct length), but the leading 'g' is not a hex digit.
    n8n_encryption_key = "g0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcde"
  }

  expect_failures = [var.n8n_encryption_key]
}

# ── B3: consuming Secrets you already manage ─────────────────────────────────
# Five *_secret_ref inputs, one per credential, each taking {name, key} instead
# of the value itself, so a caller already running something like External
# Secrets Operator can point the module at a Secret it never reads rather than
# handing over the raw credential.
#
# helm_release.n8n.values is unknown at plan time (see the note near the top
# of this file), so these assert against the resources and locals the chart
# value is built from, the same way the rest of this file tests chart wiring
# it cannot reach directly.

# ── License key secret ref ────────────────────────────────────────────────────
# Lives in the shared kubernetes_secret.n8n. Setting this drops
# N8N_LICENSE_ACTIVATION_KEY from that Secret's data rather than gating the
# Secret itself, since the other three keys it carries are still needed.

run "license_key_secret_ref_defaults_to_null_and_changes_nothing" {
  command = plan

  assert {
    condition     = kubernetes_secret.n8n[0].data["N8N_LICENSE_ACTIVATION_KEY"] == "test-license-key-not-real"
    error_message = "Leaving n8n_license_key_secret_ref null must not change the default license key wiring"
  }
}

run "license_key_secret_ref_drops_the_key_from_the_shared_secret" {
  command = plan

  variables {
    n8n_license_key            = null
    n8n_license_key_secret_ref = { name = "caller-license-secret" }
  }

  assert {
    condition     = !contains(keys(kubernetes_secret.n8n[0].data), "N8N_LICENSE_ACTIVATION_KEY")
    error_message = "N8N_LICENSE_ACTIVATION_KEY must be dropped from kubernetes_secret.n8n's data when n8n_license_key_secret_ref supplies the license key instead"
  }

  assert {
    condition     = !contains(keys(kubernetes_secret.n8n[0].data), "N8N_RUNNERS_AUTH_TOKEN")
    error_message = "The task runner token never rides in kubernetes_secret.n8n; it reaches the chart as a literal Helm value regardless of n8n_license_key_secret_ref"
  }

  assert {
    condition     = local.n8n_license_key_secret_ref_key == "license-key"
    error_message = "n8n_license_key_secret_ref.key must default to \"license-key\", matching the chart's own license.existingSecret.key default"
  }
}

run "license_key_secret_ref_key_can_be_overridden" {
  command = plan

  variables {
    n8n_license_key            = null
    n8n_license_key_secret_ref = { name = "caller-license-secret", key = "n8n-license" }
  }

  assert {
    condition     = local.n8n_license_key_secret_ref_key == "n8n-license"
    error_message = "An explicit key on n8n_license_key_secret_ref must override the \"license-key\" default"
  }
}

run "license_key_secret_ref_rejects_being_set_alongside_the_value" {
  command = plan

  variables {
    n8n_license_key            = "test-license-key-not-real"
    n8n_license_key_secret_ref = { name = "caller-license-secret" }
  }

  expect_failures = [var.n8n_license_key_secret_ref]
}

run "license_key_is_required_when_neither_input_is_set" {
  command = plan

  variables {
    n8n_license_key = null
    # n8n_license_key_secret_ref left at its default (null) too: nothing
    # supplies the license key at all.
  }

  # Owned by n8n_license_key_secret_ref's own validation rather than
  # n8n_license_key's, to avoid a variable-validation dependency cycle between
  # the two; see n8n_license_key_secret_ref's description.
  expect_failures = [var.n8n_license_key_secret_ref]
}


# ── Encryption key secret ref ─────────────────────────────────────────────────
# The exception to the exception: secretRefs.existingSecret takes ONE Secret
# name for all four of N8N_ENCRYPTION_KEY, N8N_HOST, N8N_PORT and
# N8N_PROTOCOL, so setting this gates kubernetes_secret.n8n to zero entirely
# rather than dropping one key from it, unlike the license key and task runner
# token above. That leaves the license key and the task runner token with
# nowhere to live unless both are also caller-supplied through their own
# *_secret_ref inputs; the module rejects the plan otherwise. See
# n8n_encryption_key_secret_ref's description.

run "encryption_key_secret_ref_defaults_to_null_and_changes_nothing" {
  command = plan

  assert {
    condition     = length(kubernetes_secret.n8n) == 1
    error_message = "Leaving n8n_encryption_key_secret_ref null must keep kubernetes_secret.n8n exactly as before"
  }
}

run "encryption_key_secret_ref_gates_the_shared_secret_to_zero" {
  command = plan

  variables {
    n8n_encryption_key_secret_ref = { name = "caller-core-secret" }
    n8n_license_key               = null
    n8n_license_key_secret_ref    = { name = "caller-core-secret" }
  }

  assert {
    condition     = length(kubernetes_secret.n8n) == 0
    error_message = "n8n_encryption_key_secret_ref must gate kubernetes_secret.n8n to zero: secretRefs.existingSecret replaces the whole Secret"
  }

  assert {
    condition     = length(random_id.n8n_encryption_key) == 0
    error_message = "n8n_encryption_key_secret_ref must skip generating a key nothing would read"
  }

  assert {
    condition     = output.n8n_encryption_key == null
    error_message = "n8n_encryption_key output must be null when the key lives in a caller-managed Secret the module never reads"
  }
}

run "encryption_key_secret_ref_requires_the_license_ref_too" {
  command = plan

  variables {
    n8n_encryption_key_secret_ref = { name = "caller-core-secret" }
    # n8n_license_key_secret_ref intentionally left unset, and n8n_license_key
    # stays at its file-level default: kubernetes_secret.n8n no longer exists
    # for it to land in.
  }

  expect_failures = [var.n8n_encryption_key_secret_ref]
}

run "encryption_key_secret_ref_rejects_being_set_alongside_the_value" {
  command = plan

  variables {
    n8n_encryption_key            = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
    n8n_encryption_key_secret_ref = { name = "caller-core-secret" }
    n8n_license_key               = null
    n8n_license_key_secret_ref    = { name = "caller-core-secret" }
  }

  expect_failures = [var.n8n_encryption_key_secret_ref]
}

run "encryption_key_secret_ref_rejects_a_nonstandard_key" {
  command = plan

  variables {
    n8n_encryption_key_secret_ref = { name = "caller-core-secret", key = "custom-key" }
    n8n_license_key               = null
    n8n_license_key_secret_ref    = { name = "caller-core-secret" }
  }

  expect_failures = [var.n8n_encryption_key_secret_ref]
}

# ── Database password secret ref ─────────────────────────────────────────────
# External-database path only: aws_db_instance.n8n needs the password's actual
# value to provision the instance, so this is rejected with create_database =
# true rather than silently ignored.

run "db_password_secret_ref_defaults_to_null_and_changes_nothing" {
  command = plan

  assert {
    condition     = length(kubernetes_secret.n8n_db) == 1
    error_message = "Leaving db_password_secret_ref null must keep kubernetes_secret.n8n_db exactly as before"
  }
}

run "db_password_secret_ref_gates_the_db_secret_to_zero" {
  command = plan

  variables {
    create_database        = false
    db_host                = "aurora-cluster.cluster-abc123.us-east-1.rds.amazonaws.com"
    db_password_secret_ref = { name = "caller-db-secret" }
  }

  assert {
    condition     = length(kubernetes_secret.n8n_db) == 0
    error_message = "db_password_secret_ref must gate kubernetes_secret.n8n_db to zero: the chart points at the caller's Secret instead"
  }

  assert {
    condition     = local.db_password_secret_ref_key == "password"
    error_message = "db_password_secret_ref.key must default to \"password\", matching the chart's database.passwordSecret.key default"
  }

  assert {
    condition     = output.db_password == null
    error_message = "db_password output must be null when the password lives in a caller-managed Secret the module never reads"
  }
}

run "db_password_secret_ref_key_can_be_overridden" {
  command = plan

  variables {
    create_database        = false
    db_host                = "aurora-cluster.cluster-abc123.us-east-1.rds.amazonaws.com"
    db_password_secret_ref = { name = "caller-db-secret", key = "db-password" }
  }

  assert {
    condition     = local.db_password_secret_ref_key == "db-password"
    error_message = "An explicit key on db_password_secret_ref must override the \"password\" default"
  }
}

run "db_password_secret_ref_rejects_module_managed_database" {
  command = plan

  variables {
    # create_database left at its default (true): aws_db_instance.n8n needs
    # the password's actual value, which a Secret name cannot supply.
    db_password_secret_ref = { name = "caller-db-secret" }
  }

  expect_failures = [var.db_password_secret_ref]
}

run "db_password_secret_ref_rejects_being_set_alongside_the_value" {
  command = plan

  variables {
    create_database        = false
    db_host                = "aurora-cluster.cluster-abc123.us-east-1.rds.amazonaws.com"
    db_password            = "external-db-password"
    db_password_secret_ref = { name = "caller-db-secret" }
  }

  expect_failures = [var.db_password_secret_ref]
}

# ── Redis AUTH token secret ref ──────────────────────────────────────────────
# External-Redis path only, mirroring db_password_secret_ref above:
# aws_elasticache_replication_group.n8n needs the token's actual value to
# provision module-managed ElastiCache.

run "redis_auth_token_secret_ref_defaults_to_null_and_changes_nothing" {
  command = plan

  assert {
    condition     = local.redis_auth_active == false
    error_message = "Leaving redis_auth_token_secret_ref null must not activate Redis AUTH on the default (unencrypted, module-managed) path"
  }
}

run "redis_auth_token_secret_ref_activates_auth_without_a_module_managed_secret" {
  command = plan

  variables {
    create_elasticache          = false
    redis_host                  = "redis.internal.example.com"
    redis_auth_token_secret_ref = { name = "caller-redis-secret" }
  }

  assert {
    condition     = local.redis_auth_active == true
    error_message = "redis_auth_token_secret_ref must activate Redis AUTH exactly as redis_auth_token does"
  }

  assert {
    condition     = length(kubernetes_secret.n8n_redis) == 0
    error_message = "redis_auth_token_secret_ref must gate kubernetes_secret.n8n_redis to zero: the chart points at the caller's Secret instead"
  }

  assert {
    condition     = local.redis_auth_token_secret_ref_key == "password"
    error_message = "redis_auth_token_secret_ref.key must default to \"password\", matching the chart's redis.passwordSecret.key default"
  }

  assert {
    condition     = output.redis_auth_token == null
    error_message = "redis_auth_token output must be null when the token lives in a caller-managed Secret the module never reads"
  }
}

run "redis_auth_token_secret_ref_key_can_be_overridden" {
  command = plan

  variables {
    create_elasticache          = false
    redis_host                  = "redis.internal.example.com"
    redis_auth_token_secret_ref = { name = "caller-redis-secret", key = "redis-password" }
  }

  assert {
    condition     = local.redis_auth_token_secret_ref_key == "redis-password"
    error_message = "An explicit key on redis_auth_token_secret_ref must override the \"password\" default"
  }
}

run "redis_auth_token_secret_ref_rejects_module_managed_elasticache" {
  command = plan

  variables {
    # create_elasticache left at its default (true): the replication group
    # needs the token's actual value, which a Secret name cannot supply.
    redis_auth_token_secret_ref = { name = "caller-redis-secret" }
  }

  expect_failures = [var.redis_auth_token_secret_ref]
}

run "redis_auth_token_secret_ref_rejects_being_set_alongside_the_value" {
  command = plan

  variables {
    create_elasticache          = false
    redis_host                  = "redis.internal.example.com"
    redis_auth_token            = "external-redis-token"
    redis_auth_token_secret_ref = { name = "caller-redis-secret" }
  }

  expect_failures = [var.redis_auth_token_secret_ref]
}

# ── HPA: webhook processor scale-up stabilization ────────────────────────────

run "webhook_hpa_scale_up_stabilization_window_defaults_to_zero" {
  command = plan

  assert {
    condition     = kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook[0].spec[0].behavior[0].scale_up[0].stabilization_window_seconds == 0
    error_message = "n8n_webhook_hpa_scale_up_stabilization_window_seconds should default to 0, matching the Kubernetes API's own default."
  }

  # Regression guard: select_policy must be set explicitly. When it is unset,
  # the provider sends selectPolicy: "" and the Kubernetes API rejects the HPA
  # at apply time (`Unsupported value: ""`): mocked tests cannot catch that
  # server-side rejection, only this plan-time value.
  assert {
    condition     = kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook[0].spec[0].behavior[0].scale_up[0].select_policy == "Max"
    error_message = "n8n_webhook HPA scale_up.select_policy must be explicitly \"Max\": an unset value is serialized as \"\" and rejected by the Kubernetes API at apply."
  }
}

run "webhook_hpa_scale_up_stabilization_window_accepts_override" {
  command = plan

  variables {
    n8n_webhook_hpa_scale_up_stabilization_window_seconds = 300
  }

  assert {
    condition     = kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook[0].spec[0].behavior[0].scale_up[0].stabilization_window_seconds == 300
    error_message = "n8n_webhook_hpa_scale_up_stabilization_window_seconds should flow through to the HPA's scale_up.stabilization_window_seconds."
  }
}

run "webhook_hpa_scale_up_stabilization_window_rejects_negative" {
  command = plan

  variables {
    n8n_webhook_hpa_scale_up_stabilization_window_seconds = -1
  }

  expect_failures = [var.n8n_webhook_hpa_scale_up_stabilization_window_seconds]
}

run "webhook_hpa_scale_up_stabilization_window_rejects_above_max" {
  command = plan

  variables {
    n8n_webhook_hpa_scale_up_stabilization_window_seconds = 3601
  }

  expect_failures = [var.n8n_webhook_hpa_scale_up_stabilization_window_seconds]
}

run "rds_hardened_defaults" {
  command = plan

  assert {
    condition     = aws_db_instance.n8n[0].engine == "postgres"
    error_message = "RDS engine should be postgres"
  }

  assert {
    condition     = aws_db_instance.n8n[0].engine_version == "18.4"
    error_message = "RDS engine_version should default to 18.4 (var.db_engine_version)"
  }

  assert {
    condition     = aws_db_instance.n8n[0].instance_class == "db.t3.small"
    error_message = "db_instance_class should default to db.t3.small"
  }

  assert {
    condition     = aws_db_instance.n8n[0].allocated_storage == 50
    error_message = "db_allocated_storage should default to 50 GB"
  }

  assert {
    condition     = aws_db_instance.n8n[0].multi_az == true
    error_message = "db_multi_az should default to true: HA is the point of the multi template"
  }

  assert {
    condition     = aws_db_instance.n8n[0].publicly_accessible == false
    error_message = "RDS must NOT be publicly accessible"
  }

  assert {
    condition     = aws_db_instance.n8n[0].backup_retention_period >= 7
    error_message = "RDS backup retention must be >= 7 days"
  }

  # ── Production hardening defaults ────────────────────────────────────────
  # Each of these clears a Checkov finding that would otherwise ride on
  # soft_fail = true in CI. They are also defenses against silent regression
  # when someone trims the resource down later.

  assert {
    condition     = aws_db_instance.n8n[0].iam_database_authentication_enabled == true
    error_message = "RDS IAM database authentication must be enabled"
  }

  assert {
    condition     = contains(aws_db_instance.n8n[0].enabled_cloudwatch_logs_exports, "postgresql")
    error_message = "RDS must export postgresql logs to CloudWatch"
  }

  assert {
    condition     = aws_db_instance.n8n[0].copy_tags_to_snapshot == true
    error_message = "RDS must copy tags to snapshots so the existing tag set survives backup restores"
  }

  assert {
    condition     = aws_db_instance.n8n[0].auto_minor_version_upgrade == true
    error_message = "RDS auto_minor_version_upgrade must be true (managed patching during maintenance window)"
  }

  assert {
    condition     = aws_db_instance.n8n[0].performance_insights_enabled == true
    error_message = "RDS Performance Insights must be enabled (free tier with default 7-day retention)"
  }

  assert {
    condition     = aws_db_instance.n8n[0].performance_insights_retention_period == 7
    error_message = "PI retention must be pinned to 7 (free-tier window) so a future AWS default change cannot silently make the deployment billable"
  }

  assert {
    condition     = aws_db_instance.n8n[0].monitoring_interval == 60
    error_message = "RDS Enhanced Monitoring interval must be 60s (cheapest billable interval, AWS-recommended production default)"
  }

  # The explicit log group is what keeps RDS from auto-creating it with
  # "Never expire" retention as soon as enabled_cloudwatch_logs_exports fires.
  # Without this resource the operational drift is invisible to Checkov (the
  # auto-created group isn't in Terraform state) but very real: a single
  # busy RDS instance accumulates GB of logs per month with no cap.
  assert {
    condition     = aws_cloudwatch_log_group.rds_postgresql[0].retention_in_days == 365
    error_message = "RDS postgresql log group must have retention pinned (default would be 'Never expire'; clears CKV_AWS_338)"
  }

  # ── CMK encryption (CKV_AWS_16 + CKV_AWS_354 + CKV_AWS_158) ──────────────
  # A single CMK encrypts the RDS storage, Performance Insights data, and the
  # postgresql log group. Mirrors the Aurora pattern (PR #13).

  assert {
    condition     = aws_db_instance.n8n[0].storage_encrypted == true
    error_message = "RDS storage_encrypted must default to true so new deployments get CMK encryption out of the box (clears CKV_AWS_16)"
  }

  assert {
    condition     = length(aws_kms_key.db) == 1
    error_message = "Module must create a CMK when db_storage_encrypted = true (the default)"
  }

  assert {
    condition     = aws_kms_key.db[0].enable_key_rotation == true
    error_message = "CMK key rotation must be enabled: annual rotation is the AWS-recommended default and requires no ongoing operator action"
  }

  # ARN-linkage between aws_kms_key.db[0].arn and its three consumers
  # (aws_db_instance.kms_key_id, performance_insights_kms_key_id, and the
  # postgresql log group's kms_key_id) is verified by the live-apply step
  # documented in README.md → "Upgrading from a pre-CMK apply" rather than at
  # plan time: the ARN is computed and would require terraform >= 1.11's
  # `override_during = plan` to assert against under the mock provider, which
  # exceeds the module's `required_version = ">= 1.11"` floor.
}

run "db_storage_encrypted_false_skips_cmk" {
  command = plan

  variables {
    db_storage_encrypted = false
  }

  assert {
    condition     = length(aws_kms_key.db) == 0
    error_message = "Setting db_storage_encrypted = false must skip CMK creation so existing unencrypted deployments see no plan change"
  }

  assert {
    condition     = length(aws_kms_alias.db) == 0
    error_message = "Setting db_storage_encrypted = false must also skip the KMS alias"
  }

  # storage_encrypted explicitly false on the instance: preserves prior
  # unencrypted behavior on existing applies (no surprise replacement).
  assert {
    condition     = aws_db_instance.n8n[0].storage_encrypted == false
    error_message = "With db_storage_encrypted = false, aws_db_instance.storage_encrypted must also be false so existing unencrypted deployments see no plan change"
  }
}

run "external_db_skips_cmk_too" {
  command = plan

  variables {
    create_database = false
    db_host         = "aurora-cluster.cluster-abc123.us-east-1.rds.amazonaws.com"
    db_password     = "external-db-password"
  }

  assert {
    condition     = length(aws_kms_key.db) == 0
    error_message = "With create_database = false there is no module-managed RDS to encrypt; the CMK must not be created"
  }

  assert {
    condition     = length(aws_kms_alias.db) == 0
    error_message = "With create_database = false the alias must also be skipped"
  }
}

run "external_db_skips_rds_instance" {
  command = plan

  variables {
    create_database = false
    db_host         = "aurora-cluster.cluster-abc123.us-east-1.rds.amazonaws.com"
    db_password     = "external-db-password"
  }

  assert {
    condition     = length(aws_db_instance.n8n) == 0
    error_message = "No RDS instance should be created when create_database = false"
  }

  assert {
    condition     = length(aws_db_subnet_group.n8n) == 0
    error_message = "No RDS subnet group should be created when create_database = false"
  }

  assert {
    condition     = length(aws_security_group.rds) == 0
    error_message = "No RDS security group should be created when create_database = false; it fronts nothing without an instance"
  }
}

# ── Restore from a snapshot ─────────────────────────────────────────────────
# The other half of n8n_encryption_key: a rebuilt stack can now restore the
# database the encryption key belongs to, instead of having to restore it outside
# the module and give up everything the module manages around the instance.
#
# Every check here guards a ForceNew argument, so the failure they prevent is not
# a one-off error but a plan that wants to replace the instance on every apply and
# can never reconcile.

run "db_snapshot_identifier_defaults_to_creating_an_empty_database" {
  command = plan

  # Asserted on the data source rather than on
  # aws_db_instance.n8n[0].snapshot_identifier == null: the argument is
  # Optional+Computed, so an unset value renders as "known after apply" and the
  # comparison fails with "Unknown condition value" rather than passing. Same
  # limitation as redis_apply_immediately, which locals.tf works around the same
  # way. A concrete value IS assertable, which is what the next run does.
  assert {
    condition     = length(data.aws_db_snapshot.restore) == 0
    error_message = "No snapshot should be described, or restored from, when db_snapshot_identifier is null"
  }
}

run "db_snapshot_identifier_restores_the_module_managed_instance" {
  command = plan

  variables {
    db_snapshot_identifier = "n8n-postgres-pre-rebuild"
    # The fixture snapshot is unencrypted, and a restore inherits that, so the
    # configuration has to say so too.
    db_storage_encrypted = false
    # Supplied because restoring without it is the one restore mistake that
    # cannot be seen in the plan; see the dedicated run below.
    n8n_encryption_key = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
  }

  assert {
    condition     = aws_db_instance.n8n[0].snapshot_identifier == "n8n-postgres-pre-rebuild"
    error_message = "db_snapshot_identifier must reach aws_db_instance.n8n.snapshot_identifier"
  }

  # The module still owns everything around the restored instance, which is the
  # whole reason for the input: the create_database = false alternative gives all
  # of this up.
  assert {
    condition = (
      length(aws_db_subnet_group.n8n) == 1 &&
      length(aws_cloudwatch_log_group.rds_postgresql) == 1 &&
      aws_db_instance.n8n[0].monitoring_interval == 60 &&
      aws_db_instance.n8n[0].performance_insights_enabled == true
    )
    error_message = "A restored instance must still get the module-managed subnet group, log group, Enhanced Monitoring and Performance Insights"
  }

  # The generated password reaching a restored instance is not assertable here:
  # random_password.db_password.result is computed, so both sides of that
  # comparison are unknown under `command = plan`. It is a provider behaviour
  # rather than a module one anyway. RestoreDBInstanceFromDBSnapshot takes no
  # password parameter, and the AWS provider issues a ModifyDBInstance with
  # MasterUserPassword immediately after the restore, so the module's credential
  # becomes the restored instance's master password. Verified by reading
  # internal/service/rds/instance.go, and worth re-checking on a provider major
  # bump, because n8n silently cannot connect if it ever stops.
}

run "db_snapshot_restore_accepts_a_matching_encrypted_snapshot" {
  command = plan

  variables {
    db_snapshot_identifier = "n8n-postgres-pre-rebuild"
    create_db_kms_key      = false
    db_kms_key_arn         = "arn:aws:kms:us-east-1:123456789012:key/1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d"
    n8n_encryption_key     = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
  }

  override_data {
    target = data.aws_db_snapshot.restore[0]
    values = {
      engine            = "postgres"
      encrypted         = true
      kms_key_id        = "arn:aws:kms:us-east-1:123456789012:key/1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d"
      allocated_storage = 20
      status            = "available"
    }
  }

  # Only the log-group disclosure fires, which is about db_kms_key_arn and not
  # about the restore. Listing it alone asserts that none of the snapshot checks
  # complain about a correctly-described encrypted snapshot.
  expect_failures = [check.db_kms_key_arn_does_not_encrypt_postgresql_logs]
}

run "db_snapshot_restore_rejects_an_encryption_mismatch" {
  command = plan

  variables {
    db_snapshot_identifier = "n8n-postgres-pre-rebuild"
    # Snapshot fixture is unencrypted; the default db_storage_encrypted = true
    # claims otherwise, and storage_encrypted is ForceNew.
    n8n_encryption_key = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
  }

  expect_failures = [check.db_snapshot_encryption_matches_configuration]
}

run "db_snapshot_restore_rejects_a_key_that_is_not_the_snapshots" {
  command = plan

  variables {
    db_snapshot_identifier = "n8n-postgres-pre-rebuild"
    create_db_kms_key      = false
    db_kms_key_arn         = "arn:aws:kms:us-east-1:123456789012:key/1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d"
    n8n_encryption_key     = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
  }

  override_data {
    target = data.aws_db_snapshot.restore[0]
    values = {
      engine            = "postgres"
      encrypted         = true
      kms_key_id        = "arn:aws:kms:us-east-1:123456789012:key/9f8e7d6c-5b4a-4938-8271-6f5e4d3c2b1a"
      allocated_storage = 20
      status            = "available"
    }
  }

  expect_failures = [
    check.db_snapshot_encryption_matches_configuration,
    check.db_kms_key_arn_does_not_encrypt_postgresql_logs,
  ]
}

run "db_snapshot_restore_rejects_a_non_postgres_snapshot" {
  command = plan

  variables {
    db_snapshot_identifier = "some-mysql-snapshot"
    db_storage_encrypted   = false
    n8n_encryption_key     = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
  }

  override_data {
    target = data.aws_db_snapshot.restore[0]
    values = {
      engine            = "mysql"
      encrypted         = false
      kms_key_id        = ""
      allocated_storage = 20
      status            = "available"
    }
  }

  expect_failures = [check.db_snapshot_engine_is_postgres]
}

run "db_snapshot_restore_rejects_a_snapshot_larger_than_the_allocation" {
  command = plan

  variables {
    db_snapshot_identifier = "n8n-postgres-pre-rebuild"
    db_storage_encrypted   = false
    db_allocated_storage   = 20
    n8n_encryption_key     = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
  }

  override_data {
    target = data.aws_db_snapshot.restore[0]
    values = {
      engine            = "postgres"
      encrypted         = false
      kms_key_id        = ""
      allocated_storage = 200
      status            = "available"
    }
  }

  expect_failures = [check.db_snapshot_fits_allocated_storage]
}

# The restore mistake nothing else can catch. Every other snapshot check compares
# the configuration against something AWS reports about the snapshot; this one
# compares two inputs, because the damage is inside the database and invisible to
# both Terraform and AWS. A restore without the original key applies cleanly and
# leaves every stored credential unreadable.
run "db_snapshot_restore_without_the_encryption_key_warns" {
  command = plan

  variables {
    db_snapshot_identifier = "n8n-postgres-pre-rebuild"
    db_storage_encrypted   = false
    # n8n_encryption_key deliberately left null, which is the whole point.
  }

  expect_failures = [check.db_snapshot_restore_needs_the_original_encryption_key]

  # The module still generates a key, so the failure is a warning about what that
  # means rather than a refusal. Restoring for the workflow data while accepting
  # that the credentials are disposable stays possible.
  assert {
    condition     = length(random_id.n8n_encryption_key) == 1
    error_message = "The warning must not stop the module generating a key; it is a check, not a validation"
  }
}

# The inverse. A supplied key silences it, which is what makes the warning mean
# something rather than being noise on every restore.
run "db_snapshot_restore_with_the_encryption_key_is_quiet" {
  command = plan

  variables {
    db_snapshot_identifier = "n8n-postgres-pre-rebuild"
    db_storage_encrypted   = false
    n8n_encryption_key     = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
  }

  assert {
    condition     = length(random_id.n8n_encryption_key) == 0
    error_message = "A restore with a supplied key must reuse it rather than generating one"
  }
}

# The same inverse, but through B3's Secret reference rather than a direct value.
# The check must recognize this input too: a caller supplying the original key via
# n8n_encryption_key_secret_ref has satisfied the same requirement as n8n_encryption_key,
# and a warning here would be a false positive against a correct B3 usage.
run "db_snapshot_restore_with_the_encryption_key_secret_ref_is_quiet" {
  command = plan

  variables {
    db_snapshot_identifier        = "n8n-postgres-pre-rebuild"
    db_storage_encrypted          = false
    n8n_encryption_key_secret_ref = { name = "byo-encryption-secret" }
    # n8n_encryption_key_secret_ref gates kubernetes_secret.n8n entirely, so this
    # must also be set; not what this test is about, just satisfying that rule.
    # n8n_license_key must be nulled out too: the file-level default in this test
    # file's own variables block sets it, which would otherwise collide with
    # n8n_license_key_secret_ref below.
    n8n_license_key            = null
    n8n_license_key_secret_ref = { name = "byo-license-secret" }
  }

  assert {
    condition     = length(random_id.n8n_encryption_key) == 0
    error_message = "A restore with a supplied key must reuse it rather than generating one"
  }
}

# And it must stay silent where the snapshot is ignored anyway. The
# create_database = false run above already proves this implicitly, since it lists
# only one expected check failure, but stating it here means a regression names
# itself instead of surfacing as a confusing failure in an unrelated run.
run "db_snapshot_encryption_key_warning_respects_create_database" {
  command = plan

  variables {
    create_database        = false
    db_host                = "n8n.example.internal"
    db_password            = "external-password"
    db_snapshot_identifier = "n8n-postgres-pre-rebuild"
  }

  expect_failures = [check.db_snapshot_identifier_requires_module_managed_database]
}

run "db_snapshot_identifier_with_an_external_database_warns" {
  command = plan

  variables {
    db_snapshot_identifier = "n8n-postgres-pre-rebuild"
    create_database        = false
    db_host                = "aurora-cluster.cluster-abc123.us-east-1.rds.amazonaws.com"
    db_password            = "external-db-password"
  }

  expect_failures = [check.db_snapshot_identifier_requires_module_managed_database]

  assert {
    condition     = length(data.aws_db_snapshot.restore) == 0
    error_message = "An ignored db_snapshot_identifier must not even be described, let alone restored"
  }
}

run "db_snapshot_identifier_rejects_a_blank_value" {
  command = plan

  variables {
    db_snapshot_identifier = "  "
  }

  expect_failures = [var.db_snapshot_identifier]
}

# ── BYO KMS key for RDS encryption ──────────────────────────────────────────
# db_kms_key_arn is a purely additive escape hatch: left at its null default,
# behavior must be byte-for-byte identical to before it existed (module still
# mints its own CMK). Setting it must suppress that CMK and thread the
# supplied ARN through to every consumer instead.

run "db_kms_key_arn_defaults_to_module_managed_cmk" {
  command = plan

  assert {
    condition     = length(aws_kms_key.db) == 1
    error_message = "With db_kms_key_arn left at its null default, the module must still create its own CMK (unchanged default behavior)"
  }

  assert {
    condition     = length(aws_kms_alias.db) == 1
    error_message = "With db_kms_key_arn left at its null default, the module must still create the CMK alias (unchanged default behavior)"
  }

  # aws_db_instance.n8n[0].kms_key_id == aws_kms_key.db[0].arn is NOT asserted
  # here: aws_kms_key.db[0].arn is computed, so under the mock provider it is
  # unknown at plan time ("Unknown condition value"). The ARN-linkage between
  # the CMK and its three consumers is verified by the live-apply step
  # documented in README.md → "Upgrading from a pre-CMK apply", same
  # limitation already called out next to the rds_hardened_defaults run above.
}

run "db_kms_key_arn_suppresses_module_managed_cmk" {
  command = plan

  variables {
    create_db_kms_key = false
    db_kms_key_arn    = "arn:aws:kms:us-east-1:123456789012:key/1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d"
  }

  assert {
    condition     = length(aws_kms_key.db) == 0
    error_message = "Setting db_kms_key_arn must suppress module-managed CMK creation (aws_kms_key.db)"
  }

  assert {
    condition     = length(aws_kms_alias.db) == 0
    error_message = "Setting db_kms_key_arn must also suppress the module-managed CMK alias (aws_kms_alias.db)"
  }

  assert {
    condition     = aws_db_instance.n8n[0].kms_key_id == "arn:aws:kms:us-east-1:123456789012:key/1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d"
    error_message = "aws_db_instance.n8n.kms_key_id must use the caller-supplied db_kms_key_arn"
  }

  assert {
    condition     = aws_db_instance.n8n[0].performance_insights_kms_key_id == "arn:aws:kms:us-east-1:123456789012:key/1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d"
    error_message = "performance_insights_kms_key_id must use the caller-supplied db_kms_key_arn"
  }

  # The postgresql log group is deliberately NOT on the caller's key. CloudWatch
  # Logs refuses a key whose policy does not name logs.<region>.amazonaws.com,
  # and no data source lets the module check whether this one does, so it falls
  # back to CloudWatch's AWS-managed encryption rather than failing the apply
  # part-way through. db_logs_kms_key_arn is the opt-in, covered by the next run.
  assert {
    condition     = aws_cloudwatch_log_group.rds_postgresql[0].kms_key_id == null
    error_message = "db_kms_key_arn alone must leave the postgresql log group on CloudWatch's AWS-managed key, not the caller-supplied CMK"
  }

  # And it is disclosed rather than silent. Listing only this check also asserts
  # that no other check fires on this path: terraform test fails a run on any
  # check failure it was not told to expect.
  expect_failures = [check.db_kms_key_arn_does_not_encrypt_postgresql_logs]
}

run "db_logs_kms_key_arn_encrypts_the_postgresql_log_group" {
  command = plan

  variables {
    create_db_kms_key       = false
    db_kms_key_arn          = "arn:aws:kms:us-east-1:123456789012:key/1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d"
    db_logs_kms_key_enabled = true
    db_logs_kms_key_arn     = "arn:aws:kms:us-east-1:123456789012:key/1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d"
  }

  assert {
    condition     = aws_cloudwatch_log_group.rds_postgresql[0].kms_key_id == "arn:aws:kms:us-east-1:123456789012:key/1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d"
    error_message = "Setting db_logs_kms_key_arn must encrypt the postgresql log group with that key"
  }

  # The instance's own two consumers are unaffected by the logs key.
  assert {
    condition     = aws_db_instance.n8n[0].kms_key_id == "arn:aws:kms:us-east-1:123456789012:key/1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d"
    error_message = "db_logs_kms_key_arn must not change which key encrypts RDS storage"
  }
}

run "db_logs_kms_key_arn_is_ignored_without_the_toggle" {
  command = plan

  variables {
    db_logs_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d"
  }

  # The ARN alone changes nothing: db_logs_kms_key_enabled is what opts the log
  # group onto a caller key, and create_db_kms_key is still at its default, so
  # the module mints its own CMK and that is what the log group gets. The check
  # says so rather than failing, since staging the ARN in tfvars ahead of
  # flipping both toggles is a legitimate thing to do.
  assert {
    condition     = length(aws_kms_key.db) == 1
    error_message = "db_logs_kms_key_arn alone must not suppress the module-managed CMK"
  }

  # kms_key_id is not asserted: it resolves to aws_kms_key.db[0].arn, which is
  # computed and therefore unknown at plan time under the mock provider, the same
  # limitation as db_kms_key_arn_defaults_to_module_managed_cmk above.

  expect_failures = [check.db_logs_kms_key_arn_requires_db_logs_kms_key_enabled]
}

# ── The KMS toggles' own validations ──────────────────────────────────────────
# create_db_kms_key / db_logs_kms_key_enabled / create_s3_kms_key exist so the
# module never gates a `count` on whether a caller-supplied ARN is null: an ARN
# wired from a KMS key created in the same configuration is unknown until apply,
# and an unknown count fails the plan outright. See the comment above
# aws_kms_key.db in database.tf. These runs pin the incomplete-configuration
# half of each toggle's contract.

run "create_db_kms_key_false_without_an_arn_is_rejected" {
  command = plan

  variables {
    create_db_kms_key = false
  }

  expect_failures = [var.create_db_kms_key]
}

run "db_logs_kms_key_enabled_without_an_arn_is_rejected" {
  command = plan

  variables {
    create_db_kms_key       = false
    db_kms_key_arn          = "arn:aws:kms:us-east-1:123456789012:key/1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d"
    db_logs_kms_key_enabled = true
  }

  expect_failures = [var.db_logs_kms_key_enabled]
}

# The log-group toggle is meaningless while the module owns the key: its own
# CMK already carries AllowCloudWatchLogsEncrypt and already encrypts the log
# group, so there is nothing to opt into.
run "db_logs_kms_key_enabled_requires_create_db_kms_key_false" {
  command = plan

  variables {
    db_logs_kms_key_enabled = true
    db_logs_kms_key_arn     = "arn:aws:kms:us-east-1:123456789012:key/1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d"
  }

  expect_failures = [var.db_logs_kms_key_enabled]
}

run "create_s3_kms_key_false_without_an_arn_is_rejected" {
  command = plan

  variables {
    create_s3_kms_key = false
  }

  expect_failures = [var.create_s3_kms_key]
}

run "create_s3_kms_key_false_with_an_arn_suppresses_the_module_cmk" {
  command = plan

  variables {
    create_s3_kms_key = false
    s3_kms_key_arn    = "arn:aws:kms:us-east-1:123456789012:key/1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d"
  }

  assert {
    condition     = length(aws_kms_key.s3) == 0
    error_message = "create_s3_kms_key = false must suppress the module-managed S3 CMK"
  }

  assert {
    condition     = length(aws_kms_alias.s3) == 0
    error_message = "create_s3_kms_key = false must also suppress the module-managed S3 CMK alias"
  }

  assert {
    # rule is a set, so it is iterated rather than indexed.
    condition = alltrue([
      for r in aws_s3_bucket_server_side_encryption_configuration.n8n[0].rule :
      alltrue([
        for d in r.apply_server_side_encryption_by_default :
        d.kms_master_key_id == "arn:aws:kms:us-east-1:123456789012:key/1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d" && d.sse_algorithm == "aws:kms"
      ])
    ])
    error_message = "The bucket's encryption configuration must stay SSE-KMS and name the caller-supplied key"
  }
}

# The point of the whole exercise: the ARN is now free to be a value Terraform
# cannot know until apply, because nothing gates a count on it any more.
run "create_s3_kms_key_true_still_creates_the_module_cmk" {
  command = plan

  assert {
    condition     = length(aws_kms_key.s3) == 1
    error_message = "create_s3_kms_key defaults to true, so the module must still create its own CMK (unchanged default behavior)"
  }
}

# An unusable key is caught while planning rather than part-way through the
# apply. Only key_state is exercised here: key_usage and key_spec take the same
# code path through local.db_byo_kms_keys and the same mock_data override, so a
# third and fourth near-identical run would assert the same wiring twice.
run "a_key_pending_deletion_is_reported_at_plan_time" {
  command = plan

  variables {
    create_db_kms_key = false
    db_kms_key_arn    = "arn:aws:kms:us-east-1:123456789012:key/1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d"
  }

  override_data {
    target = data.aws_kms_key.db_byo[0]
    values = {
      key_state = "PendingDeletion"
      key_usage = "ENCRYPT_DECRYPT"
      key_spec  = "SYMMETRIC_DEFAULT"
    }
  }

  expect_failures = [
    check.db_byo_kms_keys_are_usable,
    check.db_kms_key_arn_does_not_encrypt_postgresql_logs,
  ]
}

# A key from another region is rejected from the ARN string alone, with no API
# call, so this holds on every path including the ones where the key is ignored.
run "a_key_in_another_region_is_reported_at_plan_time" {
  command = plan

  variables {
    create_db_kms_key = false
    db_kms_key_arn    = "arn:aws:kms:eu-west-1:123456789012:key/1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d"
  }

  expect_failures = [
    check.db_byo_kms_key_regions_match,
    check.db_kms_key_arn_does_not_encrypt_postgresql_logs,
  ]
}

run "db_logs_kms_key_arn_validator_rejects_malformed_arn" {
  command = plan

  variables {
    db_logs_kms_key_arn = "not-an-arn"
  }

  expect_failures = [var.db_logs_kms_key_arn]
}

run "db_logs_kms_key_arn_validator_rejects_alias_arn" {
  command = plan

  variables {
    # create_db_kms_key = false is required alongside db_logs_kms_key_enabled
    # = true, else db_logs_kms_key_enabled's own second validation
    # (db_logs_kms_key_enabled = true requires create_db_kms_key = false)
    # fails too, at create_db_kms_key's true default, and this run would then
    # have an unexpected failure beyond the alias-ARN one under test. Setting
    # create_db_kms_key = false in turn requires db_kms_key_arn (create_database
    # and db_storage_encrypted are both still at their true defaults here), so
    # a valid key ARN is supplied to keep that validation from firing too.
    create_db_kms_key       = false
    db_kms_key_arn          = "arn:aws:kms:us-east-1:123456789012:key/1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d"
    db_logs_kms_key_enabled = true
    db_logs_kms_key_arn     = "arn:aws:kms:us-east-1:123456789012:alias/my-key"
  }

  expect_failures = [var.db_logs_kms_key_arn]
}

run "db_kms_key_arn_validator_rejects_malformed_arn" {
  command = plan

  variables {
    db_kms_key_arn = "not-an-arn"
  }

  expect_failures = [var.db_kms_key_arn]
}

run "db_kms_key_arn_validator_rejects_alias_arn" {
  command = plan

  variables {
    # An alias ARN, not a key ARN: the validator requires the latter.
    create_db_kms_key = false
    db_kms_key_arn    = "arn:aws:kms:us-east-1:123456789012:alias/my-key"
  }

  expect_failures = [var.db_kms_key_arn]
}

run "db_kms_key_arn_set_with_storage_encryption_disabled_warns" {
  command = plan

  variables {
    create_db_kms_key    = false
    db_kms_key_arn       = "arn:aws:kms:us-east-1:123456789012:key/1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d"
    db_storage_encrypted = false
  }

  expect_failures = [check.db_kms_key_arn_requires_module_managed_encrypted_database]

  # The check above tells the caller their key is unused. These make that true.
  # local.db_kms_key_arn originally returned the BYO key regardless of
  # db_storage_encrypted, so the log group really was encrypted with it while the
  # warning said otherwise, and on a key whose policy probably does not let
  # CloudWatch Logs use it, which fails the apply.
  assert {
    condition     = aws_cloudwatch_log_group.rds_postgresql[0].kms_key_id == null
    error_message = "db_storage_encrypted = false must leave the postgresql log group unencrypted even when db_kms_key_arn is set"
  }

  # Asserted on the local rather than on aws_db_instance.n8n[0].kms_key_id and
  # .performance_insights_kms_key_id: the AWS provider marks both computed, so
  # they stay unknown under `command = plan` whatever is fed in. The local is the
  # single value both arguments read, so it is the thing worth pinning anyway.
  assert {
    condition     = local.db_kms_key_arn == null
    error_message = "db_storage_encrypted = false must resolve local.db_kms_key_arn to null even when db_kms_key_arn is set, so nothing downstream encrypts with the supplied key"
  }
}

# The BYO key reaches storage and Performance Insights on the supported path,
# and stops there: the postgresql log group needs db_logs_kms_key_arn as well,
# because CloudWatch Logs is the one consumer that refuses a key whose policy the
# module cannot inspect (see database.tf and README.md -> "Bring your own KMS key
# for RDS").
run "db_kms_key_arn_reaches_storage_and_pi_but_not_the_log_group" {
  command = plan

  variables {
    create_db_kms_key = false
    db_kms_key_arn    = "arn:aws:kms:us-east-1:123456789012:key/1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d"
  }

  # local.db_kms_key_arn for the same reason as the run above: the instance's own
  # kms_key_id and performance_insights_kms_key_id are computed and stay unknown
  # at plan time. Both read this local and nothing else.
  assert {
    condition     = local.db_kms_key_arn == "arn:aws:kms:us-east-1:123456789012:key/1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d"
    error_message = "The supplied key must be what RDS storage and Performance Insights encrypt with"
  }

  assert {
    condition     = aws_cloudwatch_log_group.rds_postgresql[0].kms_key_id == null
    error_message = "The supplied key must not encrypt the postgresql log group unless db_logs_kms_key_arn opts in"
  }

  expect_failures = [check.db_kms_key_arn_does_not_encrypt_postgresql_logs]
}

run "db_kms_key_arn_set_with_create_database_false_warns" {
  command = plan

  variables {
    create_db_kms_key = false
    db_kms_key_arn    = "arn:aws:kms:us-east-1:123456789012:key/1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d"
    create_database   = false
    db_host           = "aurora-cluster.cluster-abc123.us-east-1.rds.amazonaws.com"
    db_password       = "external-db-password"
  }

  expect_failures = [check.db_kms_key_arn_requires_module_managed_encrypted_database]
}

# db_kms_key_arn on its own trips exactly one check, the log-group disclosure,
# and never the "set but ignored" footgun check. The disclosure is silenceable by
# setting db_logs_kms_key_arn, which is what separates it from noise.
run "db_kms_key_arn_with_defaults_trips_only_the_log_group_disclosure" {
  command = plan

  variables {
    create_db_kms_key = false
    db_kms_key_arn    = "arn:aws:kms:us-east-1:123456789012:key/1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d"
  }

  assert {
    condition     = length(aws_kms_key.db) == 0
    error_message = "db_kms_key_arn alone (with defaults otherwise) must suppress the module-managed CMK without tripping the footgun check"
  }

  expect_failures = [check.db_kms_key_arn_does_not_encrypt_postgresql_logs]
}

# Cross-variable validation: when the caller opts into an external database
# (create_database = false), both db_host and db_password are required at plan
# time. Without these the failure would surface deep inside the n8n Helm release
# at apply time, after EKS and the database resources have already been built.

// RDS counts retention in whole days. Caught on the input so the error names
// db_backup_retention_period and the caller's own line, rather than surfacing
// from aws_db_instance.n8n inside the module where the attribute is called
// backup_retention_period and the file is not one the caller owns.
run "fractional_backup_retention_fails_validation" {
  command = plan

  variables {
    db_backup_retention_period = 7.5
  }

  expect_failures = [var.db_backup_retention_period]
}

run "external_db_missing_host_fails_validation" {
  command = plan

  variables {
    create_database = false
    db_password     = "external-db-password"
    # db_host intentionally unset
  }

  expect_failures = [var.db_host]
}

run "external_db_missing_password_fails_validation" {
  command = plan

  variables {
    create_database = false
    db_host         = "aurora-cluster.cluster-abc123.us-east-1.rds.amazonaws.com"
    # db_password intentionally unset
  }

  # The combined "one of db_password / db_password_secret_ref is required"
  # check lives on db_password_secret_ref's own validation, not db_password's,
  # to avoid a variable-validation dependency cycle between the two; see that
  # variable.
  expect_failures = [var.db_password_secret_ref]
}

# ── Ingress ──────────────────────────────────────────────────────────────────
# create_ingress = false is the bring-your-own-Ingress escape hatch behind the
# two-ALB split (public /webhook + internal admin UI). It must drop the
# module-owned Ingress and, with it, the Route 53 alias record and the ALB
# lookup that record depends on. Otherwise every plan tries to recreate the
# module's Ingress and revert the caller's DNS.

run "ingress_created_by_default" {
  command = plan

  assert {
    condition     = length(kubernetes_ingress_v1.n8n) == 1
    error_message = "The module-managed Ingress must be created by default"
  }

  assert {
    condition     = kubernetes_ingress_v1.n8n[0].metadata[0].annotations["alb.ingress.kubernetes.io/scheme"] == "internet-facing"
    error_message = "The default ALB scheme should remain internet-facing"
  }
}

run "create_ingress_false_skips_ingress" {
  command = plan

  variables {
    create_ingress = false
  }

  assert {
    condition     = length(kubernetes_ingress_v1.n8n) == 0
    error_message = "No Ingress should be created when create_ingress = false"
  }
}

# ── Route 53 automated DNS path ───────────────────────────────────────────────
# The alias record (aws_route53_record.n8n_alias) and the data.aws_lb lookup
# behind it are gated on local.dns_alias_managed = dns_automated &&
# create_ingress, so a bring-your-own-Ingress caller keeps its own DNS instead
# of the module reverting the record to the module's ALB on every plan.
#
# Reaching this path under mocked providers needs one nudge: setting
# route53_zone_id makes aws_route53_record.cert_validation's for_each derive
# its keys from aws_acm_certificate.n8n[0].domain_validation_options, which the
# mock AWS provider reports as known-only-after-apply, and Terraform rejects a
# for_each over an unknown value before any assertion runs. override_resource
# supplies a concrete value for that one attribute so the plan can complete.

run "route53_alias_is_managed_when_the_module_owns_the_ingress" {
  command = plan

  variables {
    certificate_arn = null
    route53_zone_id = "Z0TEST123456789"
  }

  assert {
    condition     = length(aws_acm_certificate.n8n) == 1
    error_message = "route53_zone_id should make the module issue its own ACM certificate"
  }

  assert {
    condition     = length(aws_route53_record.n8n_alias) == 1
    error_message = "The alias record should be managed when the module owns the Ingress"
  }
}

# The regression this pair guards: before create_ingress existed, dns_automated
# alone drove the alias record. A caller bringing its own Ingress would then
# have the module look up an ALB that no longer exists and fight the caller's
# DNS record. Both the record and the data.aws_lb lookup feeding it must drop
# out, while the certificate stays, since it remains useful to the caller's own
# Ingresses.

run "route53_alias_is_skipped_for_a_caller_owned_ingress" {
  command = plan

  variables {
    certificate_arn = null
    route53_zone_id = "Z0TEST123456789"
    create_ingress  = false
  }

  assert {
    condition     = length(aws_acm_certificate.n8n) == 1
    error_message = "The ACM certificate should still be issued for a caller-owned Ingress"
  }

  assert {
    condition     = length(aws_route53_record.n8n_alias) == 0
    error_message = "The module must not manage an alias record it has no ALB for"
  }

  assert {
    condition     = length(data.aws_lb.n8n) == 0
    error_message = "The ALB lookup must be skipped when the module owns no Ingress"
  }
}

run "internal_ingress_scheme_applies" {
  command = plan

  variables {
    ingress_scheme = "internal"
  }

  assert {
    condition     = kubernetes_ingress_v1.n8n[0].metadata[0].annotations["alb.ingress.kubernetes.io/scheme"] == "internal"
    error_message = "ingress_scheme should drive the ALB scheme annotation"
  }
}

run "ingress_scheme_validator_rejects_unknown_value" {
  command = plan

  variables {
    ingress_scheme = "public"
  }

  expect_failures = [var.ingress_scheme]
}

# A bring-your-own Ingress needs the Service coordinates to point at. These
# outputs are the module's contract for that, and must stay in step with the
# backends the module-managed Ingress uses.

run "service_coordinates_match_module_ingress_backends" {
  command = plan

  assert {
    condition     = output.n8n_webhook_service_name == kubernetes_ingress_v1.n8n[0].spec[0].rule[0].http[0].path[0].backend[0].service[0].name
    error_message = "n8n_webhook_service_name must match the backend the module's own Ingress routes the webhook prefixes to"
  }

  # The catch-all "/" is declared last, after the webhook prefixes.
  assert {
    condition     = output.n8n_service_name == one([for p in kubernetes_ingress_v1.n8n[0].spec[0].rule[0].http[0].path : p.backend[0].service[0].name if p.path == "/"])
    error_message = "n8n_service_name must match the backend the module's own Ingress routes / to"
  }

  assert {
    condition     = output.n8n_service_port == 5678
    error_message = "n8n_service_port should be 5678"
  }
}

# n8n disables exactly five endpoint families on the main pods when
# disableProductionWebhooksOnMainProcess = true, which this module always sets:
# form, webhook, form-waiting, webhook-waiting and mcp (see the
# `if (this.webhooksEnabled)` block in packages/cli/src/abstract-server.ts).
# Every one of them must reach the webhook processors instead. Routing only
# /webhook, as this module did before, leaves waiting-webhook resumption,
# Form Trigger nodes and MCP server triggers returning 404 in production.
# The list mirrors charts/n8n/templates/ingress-webhook.yaml upstream.

run "all_webhook_prefixes_route_to_the_webhook_processor" {
  command = plan

  assert {
    condition     = toset(output.n8n_webhook_path_prefixes) == toset(["/webhook", "/webhook-waiting", "/form", "/form-waiting", "/mcp"])
    error_message = "The webhook prefix list must match the endpoint families n8n disables on the main pods"
  }

  assert {
    condition = alltrue([
      for prefix in ["/webhook", "/webhook-waiting", "/form", "/form-waiting", "/mcp"] :
      length([
        for p in kubernetes_ingress_v1.n8n[0].spec[0].rule[0].http[0].path :
        p if p.path == prefix && p.backend[0].service[0].name == "n8n-webhook-processor"
      ]) == 1
    ])
    error_message = "Every webhook path prefix must be routed to the webhook processor Service exactly once"
  }

  assert {
    condition     = alltrue([for p in kubernetes_ingress_v1.n8n[0].spec[0].rule[0].http[0].path : p.path_type == "Prefix"])
    error_message = "All Ingress paths should use pathType Prefix"
  }
}

# ── Ingress annotations ──────────────────────────────────────────────────────
# The escape hatch that keeps callers off a fork: the AWS Load Balancer
# Controller has far more annotations than this module should ever mint
# variables for (WAF, subnet pinning, ALB group sharing, access logs). Caller
# entries merge over the module defaults, last write wins.

run "ingress_annotation_defaults" {
  command = plan

  assert {
    condition     = kubernetes_ingress_v1.n8n[0].metadata[0].annotations["alb.ingress.kubernetes.io/healthcheck-path"] == "/healthz"
    error_message = "The module's default annotations must still be applied when ingress_annotations is empty"
  }

  assert {
    condition     = strcontains(kubernetes_ingress_v1.n8n[0].metadata[0].annotations["alb.ingress.kubernetes.io/target-group-attributes"], "stickiness.enabled=true")
    error_message = "Session stickiness must remain on by default, or WebSockets break"
  }

  assert {
    condition     = kubernetes_ingress_v1.n8n[0].metadata[0].annotations["alb.ingress.kubernetes.io/ssl-policy"] == "ELBSecurityPolicy-TLS13-1-2-2021-06"
    error_message = "The default ssl-policy annotation should be pinned to a current, modern policy"
  }
}

run "ingress_annotations_add_and_override" {
  command = plan

  variables {
    ingress_annotations = {
      "alb.ingress.kubernetes.io/wafv2-acl-arn"    = "arn:aws:wafv2:us-east-1:123456789012:regional/webacl/n8n/abc123"
      "alb.ingress.kubernetes.io/healthcheck-path" = "/healthz-custom"
    }
  }

  assert {
    condition     = kubernetes_ingress_v1.n8n[0].metadata[0].annotations["alb.ingress.kubernetes.io/wafv2-acl-arn"] == "arn:aws:wafv2:us-east-1:123456789012:regional/webacl/n8n/abc123"
    error_message = "ingress_annotations should add annotations the module has no default for"
  }

  assert {
    condition     = kubernetes_ingress_v1.n8n[0].metadata[0].annotations["alb.ingress.kubernetes.io/healthcheck-path"] == "/healthz-custom"
    error_message = "A caller-supplied annotation must win over the module default"
  }

  assert {
    condition     = kubernetes_ingress_v1.n8n[0].metadata[0].annotations["alb.ingress.kubernetes.io/target-type"] == "ip"
    error_message = "Untouched module defaults must survive the merge"
  }
}

# Setting the scheme through ingress_annotations silently beats var.ingress_scheme,
# and getting that backwards can expose an admin UI meant to be internal. The
# check block warns without failing, so the plan still succeeds here.

run "scheme_set_via_annotations_still_plans" {
  command = plan

  variables {
    ingress_scheme = "internal"
    ingress_annotations = {
      "alb.ingress.kubernetes.io/scheme" = "internet-facing"
    }
  }

  expect_failures = [check.ingress_scheme_not_overridden_by_annotations]
}

# ── ALB SSL policy ───────────────────────────────────────────────────────────

run "alb_ssl_policy_applies" {
  command = plan

  variables {
    alb_ssl_policy = "ELBSecurityPolicy-TLS13-1-3-2021-06"
  }

  assert {
    condition     = kubernetes_ingress_v1.n8n[0].metadata[0].annotations["alb.ingress.kubernetes.io/ssl-policy"] == "ELBSecurityPolicy-TLS13-1-3-2021-06"
    error_message = "alb_ssl_policy should drive the ALB ssl-policy annotation"
  }
}

run "alb_ssl_policy_validator_rejects_unknown_prefix" {
  command = plan

  variables {
    alb_ssl_policy = "TLS-1-2-2021-06"
  }

  expect_failures = [var.alb_ssl_policy]
}

# Setting the policy through ingress_annotations silently beats var.alb_ssl_policy.
# The check block warns without failing, so the plan still succeeds here.

run "ssl_policy_set_via_annotations_still_plans" {
  command = plan

  variables {
    alb_ssl_policy = "ELBSecurityPolicy-TLS13-1-2-2021-06"
    ingress_annotations = {
      "alb.ingress.kubernetes.io/ssl-policy" = "ELBSecurityPolicy-2016-08"
    }
  }

  expect_failures = [check.alb_ssl_policy_not_overridden_by_annotations]
}

# ── ALB source restrictions ──────────────────────────────────────────────────
# alb_inbound_cidrs and alb_inbound_prefix_list_ids narrow which sources reach
# the ALB. Both render as annotations the AWS Load Balancer Controller reads at
# reconcile time to build the ALB's security group rules, so these runs prove
# only that the annotation is rendered with the right value. That the controller
# then translates it into an EC2 security group rule is runtime behavior no
# mocked provider can observe.
#
# To verify end to end against a live deployment: apply with alb_inbound_cidrs
# set to a range that excludes your own address, confirm
# `aws elbv2 describe-load-balancers` names a controller-managed group whose
# `aws ec2 describe-security-groups` ingress rules match the list exactly, then
# confirm the editor URL times out from outside the range and still loads from
# inside it. A timeout rather than a 403 is the expected signature, because the
# filtering happens at the security group, before the listener.

run "alb_source_restrictions_absent_by_default" {
  command = plan

  # The upgrade-safety assertion for every existing deployment: with both inputs
  # at their defaults the keys must not appear at all, leaving the controller's
  # own default (0.0.0.0/0). Asserting the keys are absent rather than empty is
  # the point, since an empty-string annotation would restrict the ALB to
  # nothing and black-hole all traffic.
  assert {
    condition     = !contains(keys(kubernetes_ingress_v1.n8n[0].metadata[0].annotations), "alb.ingress.kubernetes.io/inbound-cidrs")
    error_message = "The inbound-cidrs annotation must be omitted entirely when alb_inbound_cidrs is empty, or existing deployments see a plan diff"
  }

  assert {
    condition     = !contains(keys(kubernetes_ingress_v1.n8n[0].metadata[0].annotations), "alb.ingress.kubernetes.io/security-group-prefix-lists")
    error_message = "The security-group-prefix-lists annotation must be omitted entirely when alb_inbound_prefix_list_ids is empty"
  }
}

run "alb_inbound_cidrs_render_comma_joined_in_order" {
  command = plan

  variables {
    alb_inbound_cidrs = ["203.0.113.0/24", "198.51.100.7/32", "10.20.0.0/16"]
  }

  # Order is preserved rather than sorted: the controller treats the list as a
  # set, but a stable order keeps the annotation value, and therefore the plan
  # diff, tied to what the caller wrote.
  assert {
    condition     = kubernetes_ingress_v1.n8n[0].metadata[0].annotations["alb.ingress.kubernetes.io/inbound-cidrs"] == "203.0.113.0/24,198.51.100.7/32,10.20.0.0/16"
    error_message = "alb_inbound_cidrs must render as a comma-separated list in the order given"
  }

  assert {
    condition     = !contains(keys(kubernetes_ingress_v1.n8n[0].metadata[0].annotations), "alb.ingress.kubernetes.io/security-group-prefix-lists")
    error_message = "Setting only alb_inbound_cidrs must not emit the prefix-list annotation"
  }

  assert {
    condition     = kubernetes_ingress_v1.n8n[0].metadata[0].annotations["alb.ingress.kubernetes.io/scheme"] == "internet-facing"
    error_message = "Restricting sources must not change the ALB scheme; it narrows a public ALB rather than making it internal"
  }
}

run "alb_inbound_prefix_list_ids_render_comma_joined" {
  command = plan

  variables {
    alb_inbound_prefix_list_ids = ["pl-63a5400a", "pl-0123456789abcdef0"]
  }

  assert {
    condition     = kubernetes_ingress_v1.n8n[0].metadata[0].annotations["alb.ingress.kubernetes.io/security-group-prefix-lists"] == "pl-63a5400a,pl-0123456789abcdef0"
    error_message = "alb_inbound_prefix_list_ids must render as a comma-separated list, accepting both AWS-managed (8 hex) and customer-managed (17 hex) IDs"
  }

  assert {
    condition     = !contains(keys(kubernetes_ingress_v1.n8n[0].metadata[0].annotations), "alb.ingress.kubernetes.io/inbound-cidrs")
    error_message = "Setting only alb_inbound_prefix_list_ids must not emit the inbound-cidrs annotation"
  }
}

run "alb_source_restrictions_combine" {
  command = plan

  variables {
    alb_inbound_cidrs           = ["203.0.113.0/24"]
    alb_inbound_prefix_list_ids = ["pl-63a5400a"]
  }

  assert {
    condition     = kubernetes_ingress_v1.n8n[0].metadata[0].annotations["alb.ingress.kubernetes.io/inbound-cidrs"] == "203.0.113.0/24"
    error_message = "Both source-restriction annotations must render when both inputs are set"
  }

  assert {
    condition     = kubernetes_ingress_v1.n8n[0].metadata[0].annotations["alb.ingress.kubernetes.io/security-group-prefix-lists"] == "pl-63a5400a"
    error_message = "Both source-restriction annotations must render when both inputs are set"
  }

  assert {
    condition     = strcontains(kubernetes_ingress_v1.n8n[0].metadata[0].annotations["alb.ingress.kubernetes.io/target-group-attributes"], "stickiness.enabled=true")
    error_message = "Module defaults must survive alongside the source-restriction annotations"
  }
}

# ingress_annotations is merged last, so the raw annotation still wins over the
# dedicated input. That precedence is deliberate (it keeps working for callers
# who restricted their ALB before these inputs existed) but a half-finished
# migration leaves the ALB on the stale range, so the check warns.

run "inbound_cidrs_annotation_overrides_the_input" {
  command = plan

  variables {
    alb_inbound_cidrs = ["203.0.113.0/24"]
    ingress_annotations = {
      "alb.ingress.kubernetes.io/inbound-cidrs" = "198.51.100.0/24"
    }
  }

  assert {
    condition     = kubernetes_ingress_v1.n8n[0].metadata[0].annotations["alb.ingress.kubernetes.io/inbound-cidrs"] == "198.51.100.0/24"
    error_message = "ingress_annotations must stay the last write, matching its documented contract"
  }

  expect_failures = [check.alb_source_restrictions_not_overridden_by_annotations]
}

run "prefix_list_annotation_overrides_the_input" {
  command = plan

  variables {
    alb_inbound_prefix_list_ids = ["pl-63a5400a"]
    ingress_annotations = {
      "alb.ingress.kubernetes.io/security-group-prefix-lists" = "pl-0123456789abcdef0"
    }
  }

  expect_failures = [check.alb_source_restrictions_not_overridden_by_annotations]
}

# An annotation carrying only the *other* restriction key is not a conflict, so
# the check must stay quiet. This guards against the check being written as a
# blanket "any inbound-related annotation" test.

run "unrelated_annotations_alongside_source_restrictions_are_quiet" {
  command = plan

  variables {
    alb_inbound_cidrs = ["203.0.113.0/24"]
    ingress_annotations = {
      "alb.ingress.kubernetes.io/wafv2-acl-arn" = "arn:aws:wafv2:us-east-1:123456789012:regional/webacl/n8n/abc123"
    }
  }

  assert {
    condition     = kubernetes_ingress_v1.n8n[0].metadata[0].annotations["alb.ingress.kubernetes.io/inbound-cidrs"] == "203.0.113.0/24"
    error_message = "An unrelated annotation must not disturb the rendered source restriction"
  }
}

# The silent one: the controller ignores both restrictions when the caller
# supplies its own security groups, so the annotations render, the apply
# succeeds, and the ALB is still open.

run "source_restrictions_with_caller_owned_security_groups_warn" {
  command = plan

  variables {
    alb_inbound_cidrs = ["203.0.113.0/24"]
    ingress_annotations = {
      "alb.ingress.kubernetes.io/security-groups" = "sg-0123456789abcdef0"
    }
  }

  expect_failures = [check.alb_source_restrictions_require_controller_managed_security_group]
}

run "prefix_lists_with_caller_owned_security_groups_warn" {
  command = plan

  variables {
    alb_inbound_prefix_list_ids = ["pl-63a5400a"]
    ingress_annotations = {
      "alb.ingress.kubernetes.io/security-groups" = "sg-0123456789abcdef0"
    }
  }

  expect_failures = [check.alb_source_restrictions_require_controller_managed_security_group]
}

# Source restrictions set with create_ingress = false are inert: the caller owns
# the Ingress and this module has nothing to annotate. Believing the ALB is
# VPN-only when it is wide open is the worst of the tuning-input mistakes, so it
# folds into the existing tuning check rather than passing silently.

run "source_restrictions_with_create_ingress_false_warn" {
  command = plan

  variables {
    create_ingress    = false
    alb_inbound_cidrs = ["203.0.113.0/24"]
  }

  expect_failures = [check.ingress_tuning_requires_module_managed_ingress]
}

run "prefix_lists_with_create_ingress_false_warn" {
  command = plan

  variables {
    create_ingress              = false
    alb_inbound_prefix_list_ids = ["pl-63a5400a"]
  }

  expect_failures = [check.ingress_tuning_requires_module_managed_ingress]
}

# Validator coverage. A CIDR with host bits set is the interesting case: it
# passes cidrhost, so Terraform accepts it, then EC2 rejects the security group
# rule the controller builds from it. That surfaces as a stuck reconcile well
# after a clean apply, which is why it is rejected at plan time.

run "alb_inbound_cidrs_rejects_a_missing_prefix_length" {
  command = plan

  variables {
    alb_inbound_cidrs = ["203.0.113.0"]
  }

  expect_failures = [var.alb_inbound_cidrs]
}

run "alb_inbound_cidrs_rejects_a_non_cidr_string" {
  command = plan

  variables {
    alb_inbound_cidrs = ["not-a-cidr"]
  }

  expect_failures = [var.alb_inbound_cidrs]
}

run "alb_inbound_cidrs_rejects_host_bits" {
  command = plan

  variables {
    alb_inbound_cidrs = ["203.0.113.5/24"]
  }

  expect_failures = [var.alb_inbound_cidrs]
}

# IPv6 is rejected rather than accepted-and-ignored. The module leaves the ALB
# at the controller's default ipv4 address type, so an IPv6 rule could never
# match a client. Worse, the controller applies its 0.0.0.0/0 default only when
# no inbound CIDR of either family is set (pkg/ingress/model_builder.go), so an
# IPv6-only list would suppress the IPv4 default without replacing it and take
# the ALB offline for everyone. Rejecting the family removes that failure mode
# instead of warning about it. A dualstack caller sets the annotation directly.

run "alb_inbound_cidrs_rejects_ipv6" {
  command = plan

  variables {
    alb_inbound_cidrs = ["2001:db8::/32"]
  }

  expect_failures = [var.alb_inbound_cidrs]
}

run "alb_inbound_cidrs_rejects_a_mixed_family_list" {
  command = plan

  variables {
    alb_inbound_cidrs = ["203.0.113.0/24", "2001:db8::/32"]
  }

  expect_failures = [var.alb_inbound_cidrs]
}

run "alb_inbound_prefix_list_ids_rejects_a_malformed_id" {
  command = plan

  variables {
    alb_inbound_prefix_list_ids = ["pl-XYZ"]
  }

  expect_failures = [var.alb_inbound_prefix_list_ids]
}

# AWS only issues 8- or 17-hex-character IDs, so an in-between length is a
# typo (usually a dropped character in a 17-hex ID) rather than a real list.
run "alb_inbound_prefix_list_ids_rejects_an_intermediate_length" {
  command = plan

  variables {
    alb_inbound_prefix_list_ids = ["pl-0123456789ab"]
  }

  expect_failures = [var.alb_inbound_prefix_list_ids]
}

run "alb_inbound_prefix_list_ids_rejects_a_non_prefix_list_id" {
  command = plan

  variables {
    alb_inbound_prefix_list_ids = ["sg-0123456789abcdef0"]
  }

  expect_failures = [var.alb_inbound_prefix_list_ids]
}

# The namespace output must come from kubernetes_namespace.n8n, not from
# var.namespace. As a plain variable it is a plan-time constant, so a caller's
# own kubernetes_* resources get no dependency edge to the namespace, Terraform
# schedules them concurrently, and they fail at apply with
# `namespaces "n8n" not found`. This was hit for real on the create_ingress =
# false path, where a caller's Ingresses are the first thing to consume it.
#
# A plan-time assert cannot see dependency edges directly, but it can pin the
# observable consequence: sourced from the resource the value is unknown until
# apply under the mock provider, whereas var.namespace would echo back the
# input string. If someone reverts the output, this assert starts failing.

run "namespace_output_carries_a_dependency_on_the_namespace_resource" {
  command = plan

  variables {
    namespace = "n8n-custom"
  }

  assert {
    condition     = kubernetes_namespace.n8n[0].metadata[0].name == "n8n-custom"
    error_message = "var.namespace must still drive the namespace the module creates"
  }
}

# create_namespace = false: the caller's namespace already exists, so the
# module must not create one, and everything that used to read the resource
# attribute must fall back to var.namespace directly instead.

run "create_namespace_false_creates_no_namespace" {
  command = plan

  variables {
    create_namespace = false
    namespace        = "platform-managed"
  }

  assert {
    condition     = length(kubernetes_namespace.n8n) == 0
    error_message = "No namespace should be created when create_namespace = false"
  }

  assert {
    condition     = output.namespace == "platform-managed"
    error_message = "The namespace output must fall back to var.namespace when the module does not create the namespace"
  }
}

# ── RDS retention + extra ingress CIDRs ──────────────────────────────────────
# Both were hardcoded before. Out-of-band changes to either were reverted on the
# next plan, which is why they are inputs now rather than root-level overrides.

run "db_backup_retention_defaults_to_seven_days" {
  command = plan

  assert {
    condition     = aws_db_instance.n8n[0].backup_retention_period == 7
    error_message = "Default backup retention must stay at 7 days to preserve existing behavior"
  }
}

run "db_backup_retention_is_configurable" {
  command = plan

  variables {
    db_backup_retention_period = 30
  }

  assert {
    condition     = aws_db_instance.n8n[0].backup_retention_period == 30
    error_message = "db_backup_retention_period should drive the RDS backup retention window"
  }
}

run "db_backup_retention_validator_rejects_above_aws_maximum" {
  command = plan

  variables {
    db_backup_retention_period = 36
  }

  expect_failures = [var.db_backup_retention_period]
}

run "rds_security_group_allows_vpc_cidr_only_by_default" {
  command = plan

  assert {
    condition     = tolist(aws_security_group.rds[0].ingress)[0].cidr_blocks == tolist(["10.0.0.0/16"])
    error_message = "By default only the VPC CIDR should reach the database"
  }
}

run "db_allowed_cidr_blocks_are_appended_to_vpc_cidr" {
  command = plan

  variables {
    db_allowed_cidr_blocks = ["10.20.0.0/16", "192.168.100.0/24"]
  }

  assert {
    condition     = tolist(aws_security_group.rds[0].ingress)[0].cidr_blocks == tolist(["10.0.0.0/16", "10.20.0.0/16", "192.168.100.0/24"])
    error_message = "db_allowed_cidr_blocks should be appended to the always-allowed VPC CIDR"
  }
}

run "db_allowed_cidr_blocks_validator_rejects_non_cidr" {
  command = plan

  variables {
    db_allowed_cidr_blocks = ["not-a-cidr"]
  }

  expect_failures = [var.db_allowed_cidr_blocks]
}

# Repeating the VPC CIDR, or an entry, is an easy mistake: the plan looks clean
# and AWS rejects the duplicate rule at apply. distinct() collapses it instead.

run "duplicate_cidrs_are_collapsed_not_passed_through" {
  command = plan

  variables {
    # 10.0.0.0/16 is the test VPC CIDR, deliberately repeated here.
    db_allowed_cidr_blocks = ["10.0.0.0/16", "10.20.0.0/16", "10.20.0.0/16"]
  }

  assert {
    condition     = tolist(aws_security_group.rds[0].ingress)[0].cidr_blocks == tolist(["10.0.0.0/16", "10.20.0.0/16"])
    error_message = "Duplicate CIDRs must be collapsed, including a repeat of the VPC CIDR itself"
  }
}

# ── RDS ingress by security group ────────────────────────────────────────────
# Allowing by security group beats allowing by CIDR inside the VPC: membership
# follows the instances, so the rule survives subnet changes and IP reuse.

run "no_security_group_rule_when_list_is_empty" {
  command = plan

  assert {
    condition     = length(aws_security_group.rds[0].ingress) == 1
    error_message = "With db_allowed_security_group_ids empty there must be exactly one ingress rule, the CIDR one. A second empty rule would be a spurious diff for every existing deployment"
  }
}

run "security_group_ingress_rule_is_added_when_set" {
  command = plan

  variables {
    db_allowed_security_group_ids = ["sg-0123456789abcdef0", "sg-abcdef0123456789a"]
  }

  assert {
    condition     = length(aws_security_group.rds[0].ingress) == 2
    error_message = "Setting db_allowed_security_group_ids must add a second ingress rule"
  }

  # security_groups is null on the CIDR rule, so it has to be guarded before
  # length() rather than compared directly.
  assert {
    condition = length([
      for r in tolist(aws_security_group.rds[0].ingress) : r
      if try(length(r.security_groups), 0) == 2 && r.from_port == 5432 && r.to_port == 5432
    ]) == 1
    error_message = "The security group rule must allow both groups on port 5432"
  }

  # The CIDR rule must be untouched by the addition.
  assert {
    condition = length([
      for r in tolist(aws_security_group.rds[0].ingress) : r
      if r.cidr_blocks == tolist(["10.0.0.0/16"])
    ]) == 1
    error_message = "Adding security group sources must not disturb the VPC CIDR rule"
  }
}

run "security_group_id_validator_rejects_malformed_ids" {
  command = plan

  variables {
    db_allowed_security_group_ids = ["not-a-sg-id"]
  }

  expect_failures = [var.db_allowed_security_group_ids]
}

# ── Diagnostic checks ────────────────────────────────────────────────────────
# check blocks warn without failing, so `expect_failures` on the check is how a
# plan-time warning is asserted.

run "backup_retention_zero_warns" {
  command = plan

  variables {
    db_backup_retention_period = 0
  }

  expect_failures = [check.db_backup_retention_disabled]
}

run "backup_retention_default_does_not_warn" {
  command = plan

  assert {
    condition     = aws_db_instance.n8n[0].backup_retention_period == 7
    error_message = "The default must keep backups enabled"
  }
}

# ingress_scheme, alb_ssl_policy and ingress_annotations only reach an Ingress
# this module creates. Silently ignoring them would let a caller believe an
# internal scheme, a pinned TLS policy, or a WAF association had taken effect
# when their own Ingress carries neither.

run "ingress_tuning_with_create_ingress_false_warns" {
  command = plan

  variables {
    create_ingress = false
    ingress_scheme = "internal"
  }

  expect_failures = [check.ingress_tuning_requires_module_managed_ingress]
}

run "alb_ssl_policy_with_create_ingress_false_warns" {
  command = plan

  variables {
    create_ingress = false
    alb_ssl_policy = "ELBSecurityPolicy-TLS13-1-3-2021-06"
  }

  expect_failures = [check.ingress_tuning_requires_module_managed_ingress]
}

run "create_ingress_false_alone_does_not_warn" {
  command = plan

  variables {
    create_ingress = false
  }

  assert {
    condition     = length(kubernetes_ingress_v1.n8n) == 0
    error_message = "create_ingress = false on its own is a supported configuration and must not trip the tuning check"
  }
}

# Replacing target-group-attributes silently drops the stickiness that pins a
# browser to one main pod, which surfaces as dropped editor WebSockets rather
# than as an obvious config error.

run "overriding_target_group_attributes_without_stickiness_warns" {
  command = plan

  variables {
    ingress_annotations = {
      "alb.ingress.kubernetes.io/target-group-attributes" = "deregistration_delay.timeout_seconds=30"
    }
  }

  expect_failures = [check.ingress_annotations_preserve_session_stickiness]
}

run "overriding_target_group_attributes_keeping_stickiness_is_quiet" {
  command = plan

  variables {
    ingress_annotations = {
      "alb.ingress.kubernetes.io/target-group-attributes" = "stickiness.enabled=true,deregistration_delay.timeout_seconds=60"
    }
  }

  assert {
    condition     = strcontains(kubernetes_ingress_v1.n8n[0].metadata[0].annotations["alb.ingress.kubernetes.io/target-group-attributes"], "deregistration_delay.timeout_seconds=60")
    error_message = "A deliberate override that keeps stickiness must apply cleanly"
  }
}

# The module already enforces "db_host is required when create_database = false"
# as a hard validation error. These cover the inverse direction, where a
# supplied value is silently ignored rather than rejected.

run "external_db_inputs_with_create_database_true_warns" {
  command = plan

  variables {
    # create_database defaults to true, so this database is never used.
    db_host = "aurora-cluster.cluster-abc123.us-east-1.rds.amazonaws.com"
  }

  expect_failures = [check.external_db_inputs_require_create_database_false]
}

run "rds_tuning_with_create_database_false_warns" {
  command = plan

  variables {
    create_database   = false
    db_host           = "aurora-cluster.cluster-abc123.us-east-1.rds.amazonaws.com"
    db_password       = "external-db-password"
    db_instance_class = "db.r6g.xlarge"
  }

  expect_failures = [check.rds_tuning_requires_module_managed_database]
}

# A correct external-database configuration must trip neither check, or the
# warnings become noise that trains people to ignore them.

run "clean_external_db_config_is_quiet" {
  command = plan

  variables {
    create_database = false
    db_host         = "aurora-cluster.cluster-abc123.us-east-1.rds.amazonaws.com"
    db_password     = "external-db-password"
  }

  assert {
    condition     = length(aws_db_instance.n8n) == 0
    error_message = "No RDS instance should be created for an external database"
  }
}

run "alb_hostname_is_null_without_a_module_managed_ingress" {
  command = plan

  variables {
    create_ingress = false
  }

  assert {
    condition     = output.alb_hostname == null
    error_message = "alb_hostname must be null when the module owns no Ingress, rather than a stale or misleading string"
  }
}

run "redis_private_and_sized" {
  command = plan

  assert {
    condition     = aws_elasticache_cluster.n8n[0].engine == "redis"
    error_message = "ElastiCache engine should be redis"
  }

  assert {
    condition     = aws_elasticache_cluster.n8n[0].node_type == "cache.t3.medium"
    error_message = "redis_node_type should default to cache.t3.medium"
  }

  assert {
    condition     = one(aws_security_group.redis[0].ingress).from_port == 6379
    error_message = "Redis SG should allow ingress on port 6379"
  }

  assert {
    condition     = one(aws_security_group.redis[0].ingress).to_port == 6379
    error_message = "Redis SG should allow ingress on port 6379 only"
  }

  assert {
    condition     = one(aws_security_group.redis[0].ingress).protocol == "tcp"
    error_message = "Redis SG should restrict ingress to TCP"
  }
}

# ── Redis high availability ──────────────────────────────────────────────────
# The default must stay the single-node cluster: this feature is opt-in, and
# switching topologies replaces the cache. If this pair ever inverts, every
# existing deployment loses its queue on the next apply.

run "redis_defaults_to_a_single_node_cluster" {
  command = plan

  assert {
    condition     = length(aws_elasticache_cluster.n8n) == 1
    error_message = "The single-node cluster must remain the default topology"
  }

  assert {
    condition     = length(aws_elasticache_replication_group.n8n) == 0
    error_message = "No replication group should be created unless redis_high_availability_enabled, redis_transit_encryption_enabled or redis_kms_encryption_enabled is set"
  }

  assert {
    condition     = aws_elasticache_cluster.n8n[0].num_cache_nodes == 1
    error_message = "The default cluster should still be a single node"
  }

  assert {
    condition     = aws_elasticache_cluster.n8n[0].snapshot_retention_limit == 1
    error_message = "The default single-node cluster must retain one daily snapshot"
  }

  assert {
    condition     = length(aws_kms_key.redis) == 0
    error_message = "redis_kms_encryption_enabled must default to false so existing standalone clusters are not replaced by a replication group and lose their queue"
  }
}

run "redis_high_availability_creates_a_failover_capable_replication_group" {
  command = plan

  variables {
    redis_high_availability_enabled = true
  }

  assert {
    condition     = length(aws_elasticache_replication_group.n8n) == 1
    error_message = "redis_high_availability_enabled = true must create the replication group"
  }

  assert {
    condition     = length(aws_elasticache_cluster.n8n) == 0
    error_message = "The two topologies are mutually exclusive: the single-node cluster must not also be created"
  }

  # The three attributes that make this HA rather than just a second resource
  # type. automatic_failover_enabled is what promotes the replica; without
  # multi_az_enabled both nodes can land in one AZ, which survives a node
  # failure but not the AZ event that is the more common cause.
  assert {
    condition     = aws_elasticache_replication_group.n8n[0].automatic_failover_enabled == true
    error_message = "The replication group must enable automatic failover, or it is not HA"
  }

  assert {
    condition     = aws_elasticache_replication_group.n8n[0].multi_az_enabled == true
    error_message = "The replication group must be Multi-AZ, or an AZ event still takes the queue down"
  }

  assert {
    condition     = aws_elasticache_replication_group.n8n[0].num_cache_clusters == 2
    error_message = "Automatic failover needs a primary and at least one replica"
  }

  assert {
    condition     = aws_elasticache_replication_group.n8n[0].node_type == "cache.t3.medium"
    error_message = "The replication group must honour redis_node_type"
  }

  assert {
    condition     = aws_elasticache_replication_group.n8n[0].snapshot_retention_limit == 1
    error_message = "The replication-group topology must retain one daily snapshot by default"
  }

  # Existing HA deployments already carry this exact description in state.
  # Preserve it so adopting TLS support with every new input left at its default
  # does not produce an unrelated ElastiCache modification.
  assert {
    condition     = aws_elasticache_replication_group.n8n[0].description == "n8n Bull queue and multi-main coordination (HA) for n8n-cluster"
    error_message = "The HA description must remain stable so existing replication groups receive a no-op module upgrade"
  }

  # ForceNew, so it has to be right in the release that introduces this
  # resource. Adding it later replaces the cache for everyone already on HA.
  #
  # Compared against the STRING "true": the AWS provider types this attribute as
  # a string, unlike transit_encryption_enabled next door which is a real bool.
  # `== true` silently fails against "true", which is how this assert was first
  # written and what the pinned-version CI run caught.
  assert {
    condition     = tostring(aws_elasticache_replication_group.n8n[0].at_rest_encryption_enabled) == "true"
    error_message = "The replication group must encrypt at rest. It is free on the AWS-managed key, and at_rest_encryption_enabled is ForceNew, so turning it on after release would cost every existing HA caller their queue."
  }

  # Both topologies share the subnet group and the security group, so the HA
  # path must not quietly drop the private placement or the VPC-only firewall.
  assert {
    condition     = length(aws_elasticache_subnet_group.n8n) == 1
    error_message = "The HA path must still place Redis in the private subnet group"
  }

  assert {
    condition     = one(aws_security_group.redis[0].ingress).from_port == 6379
    error_message = "The HA path must still restrict Redis ingress to 6379"
  }
}

run "redis_snapshot_retention_rejects_fractional_days" {
  command = plan

  variables {
    redis_snapshot_retention_limit = 1.5
  }

  expect_failures = [var.redis_snapshot_retention_limit]
}

# The identifier collision is the one failure mode that cannot be recovered
# inside a single apply: ElastiCache shares one namespace between cache cluster
# IDs and replication group IDs, so if these two ever matched, the apply that
# flips the toggle would destroy the cluster and then fail to create the
# replacement, leaving the deployment with no queue backend at all. Asserting
# the suffix is cheap insurance against someone "tidying up" the names.
run "redis_topologies_use_distinct_elasticache_identifiers" {
  command = plan

  variables {
    redis_high_availability_enabled = true
  }

  assert {
    condition     = aws_elasticache_replication_group.n8n[0].replication_group_id == "n8n-cluster-redis-rg"
    error_message = "The replication group ID must not collide with the single-node cluster_id, because ElastiCache shares one identifier namespace across both"
  }
}

# ── Redis at-rest encryption with a customer-managed key (opt-in) ───────────
# The third feature that selects the replication group, independent of the
# other two: kms_key_id exists only on that resource type, same reason
# auth_token does. Unlike HA and TLS, this one changes nothing about node
# count, failover, or encryption/AUTH; it only ever swaps which key (AWS- or
# customer-managed) protects whatever topology the other two variables chose.

run "redis_kms_encryption_alone_selects_the_replication_group_with_a_cmk" {
  command = plan

  variables {
    redis_kms_encryption_enabled = true
  }

  assert {
    condition     = length(aws_elasticache_cluster.n8n) == 0
    error_message = "The cluster resource has no kms_key_id argument, so opting into a CMK must move Redis onto the replication group"
  }

  assert {
    condition     = length(aws_elasticache_replication_group.n8n) == 1
    error_message = "The CMK-only path must create the replication group, the only ElastiCache resource that accepts kms_key_id"
  }

  # A CMK alone must not also buy a replica or TLS. Doubling the bill or
  # changing the network posture on a caller who only asked to swap keys
  # would be the same silent-side-effect defect HA and TLS already guard.
  assert {
    condition = (
      aws_elasticache_replication_group.n8n[0].num_cache_clusters == 1 &&
      aws_elasticache_replication_group.n8n[0].automatic_failover_enabled == false &&
      aws_elasticache_replication_group.n8n[0].transit_encryption_enabled == false
    )
    error_message = "Enabling redis_kms_encryption_enabled alone must not also enable HA or transit encryption"
  }

  assert {
    condition     = length(aws_kms_key.redis) == 1 && length(aws_kms_alias.redis) == 1
    error_message = "redis_kms_encryption_enabled = true must create the CMK and its alias"
  }

  assert {
    condition     = aws_kms_key.redis[0].enable_key_rotation == true
    error_message = "The Redis CMK must rotate annually, matching aws_kms_key.db and aws_kms_key.eks"
  }

  # The ARN-linkage between aws_kms_key.redis[0].arn and the replication
  # group's kms_key_id is not assertable here, for the same reason noted above
  # the RDS CMK tests: the ARN is computed and unknown at plan time under the
  # mock provider. That the CMK exists at all, with the right count and
  # rotation, is what this run covers; the linkage itself needs a live apply.
}

run "redis_high_availability_without_kms_encryption_uses_the_aws_managed_key" {
  command = plan

  variables {
    redis_high_availability_enabled = true
  }

  # This is the negative case for the assertion above: HA does not imply a
  # CMK, so a caller who enables only HA must still see zero key resources.
  assert {
    condition     = length(aws_kms_key.redis) == 0 && length(aws_kms_alias.redis) == 0
    error_message = "redis_high_availability_enabled alone must not create a CMK; the two variables are independent"
  }
}

run "redis_high_availability_and_kms_encryption_compose" {
  command = plan

  variables {
    redis_high_availability_enabled = true
    redis_kms_encryption_enabled    = true
  }

  assert {
    condition = (
      aws_elasticache_replication_group.n8n[0].automatic_failover_enabled == true &&
      aws_elasticache_replication_group.n8n[0].multi_az_enabled == true &&
      length(aws_kms_key.redis) == 1
    )
    error_message = "HA and a CMK must compose on the same replication group without either one dropping the other"
  }
}

run "redis_kms_encryption_disabled_skips_cmk_on_an_otherwise_opted_in_deployment" {
  command = plan

  variables {
    redis_transit_encryption_enabled = true
    redis_kms_encryption_enabled     = false
  }

  # Mirrors db_storage_encrypted_false_skips_cmk: turning the CMK off must
  # never depend on which other feature put the deployment on the
  # replication group in the first place.
  assert {
    condition     = length(aws_kms_key.redis) == 0 && length(aws_kms_alias.redis) == 0
    error_message = "redis_kms_encryption_enabled = false must skip CMK creation even when TLS independently selects the replication group"
  }

  assert {
    condition     = aws_elasticache_replication_group.n8n[0].transit_encryption_enabled == true
    error_message = "Disabling the CMK must not disturb transit encryption, which is what put this deployment on the replication group"
  }
}

# ── Redis transit encryption + AUTH (opt-in) ─────────────────────────────────
# The second feature that selects the replication group, for a reason unrelated
# to availability: auth_token exists ONLY on that resource type, and AWS
# requires transit encryption before AUTH can be enabled at all.
#
# The pair is independent in both directions, and these runs pin all four
# corners: neither, each alone, and both. The two failure modes worth catching
# are a caller who asks for encryption and silently gets a doubled bill, and a
# caller who asks for availability and silently gets a credential they were
# never told about.

run "redis_transit_encryption_defaults_off" {
  command = plan

  assert {
    condition     = var.redis_transit_encryption_enabled == false
    error_message = "redis_transit_encryption_enabled must default to false. The network-trust posture is the accepted as-built behaviour and enabling it replaces the cache."
  }

  assert {
    condition     = length(random_password.redis_auth_token) == 0
    error_message = "No AUTH token should be generated on the default path. An unconditional random_password would put `1 to add` in the plan of every caller who never opted in."
  }

  assert {
    condition     = length(kubernetes_secret.n8n_redis) == 0
    error_message = "No Redis secret should exist when there is no AUTH token to hold"
  }
}

run "redis_transit_encryption_on_swaps_to_replication_group" {
  command = plan

  variables {
    redis_transit_encryption_enabled = true
  }

  assert {
    condition     = length(aws_elasticache_cluster.n8n) == 0
    error_message = "The cluster resource cannot carry an auth_token, so the opt-in path must not create one"
  }

  assert {
    condition     = length(aws_elasticache_replication_group.n8n) == 1
    error_message = "The opt-in path must create the replication group, the only ElastiCache resource that accepts an auth_token"
  }

  assert {
    condition     = aws_elasticache_replication_group.n8n[0].transit_encryption_enabled == true
    error_message = "transit_encryption_enabled must be true, because AWS rejects an AUTH token without it"
  }

  # Encryption must not quietly also buy a second node. Availability is a
  # separate decision behind redis_high_availability_enabled, and a caller who
  # asked only for TLS should not discover it in the bill.
  assert {
    condition     = aws_elasticache_replication_group.n8n[0].num_cache_clusters == 1
    error_message = "Transit encryption alone must stay single-node. This variable buys encryption, not a second node and a doubled bill."
  }

  assert {
    condition = (
      aws_elasticache_replication_group.n8n[0].automatic_failover_enabled == false &&
      aws_elasticache_replication_group.n8n[0].multi_az_enabled == false
    )
    error_message = "Transit encryption alone must not enable failover or Multi-AZ. Those belong to redis_high_availability_enabled and AWS bills for the replica they require."
  }

  assert {
    condition     = length(random_password.redis_auth_token) == 1
    error_message = "An AUTH token must be generated on the opt-in path"
  }

  assert {
    condition     = length(kubernetes_secret.n8n_redis) == 1
    error_message = "The AUTH token must be published as a Kubernetes secret for the chart to mount as QUEUE_BULL_REDIS_PASSWORD"
  }

  # Same identifier as the HA path asserts above. Both features land on ONE
  # replication group, so a caller who enables the second one later modifies
  # what they have rather than replacing it. Two suffixes here would mean two
  # forced Redis replacements for anyone who ends up wanting both.
  assert {
    condition     = aws_elasticache_replication_group.n8n[0].replication_group_id == "n8n-cluster-redis-rg"
    error_message = "Both features must converge on one replication group identifier, or enabling the second one destroys the cache the first one created"
  }
}

# The inverse of the run above: availability must not smuggle in a credential.
# A caller who enables HA and nothing else should get exactly the topology
# change they asked for, on a plaintext endpoint, with no token in state and
# nothing new mounted into the pods.
run "redis_high_availability_alone_provisions_no_credential" {
  command = plan

  variables {
    redis_high_availability_enabled = true
  }

  assert {
    condition     = aws_elasticache_replication_group.n8n[0].transit_encryption_enabled == false
    error_message = "High availability alone must leave the endpoint plaintext. Enabling encryption here would break every existing client at the same moment the topology changes."
  }

  assert {
    condition     = length(random_password.redis_auth_token) == 0
    error_message = "No AUTH token should be generated for the HA-only path"
  }

  assert {
    condition     = length(kubernetes_secret.n8n_redis) == 0
    error_message = "No Redis secret should exist on the HA-only path"
  }

  # The provider rejects auth_token_update_strategy when no auth_token is set,
  # failing the HA-only plan outright. terraform test cannot see this (its
  # mocked provider skips the real argument validation), so this assert stands
  # in for the live plan that did catch it.
  assert {
    condition     = aws_elasticache_replication_group.n8n[0].auth_token_update_strategy == null
    error_message = "auth_token_update_strategy must be unset when there is no token. The AWS provider errors with '\"auth_token_update_strategy\": \"auth_token\" must be specified' and the HA-only path never plans."
  }

  assert {
    condition     = length(local.keda_redis_auth_metadata) == 0
    error_message = "KEDA's triggers must stay plaintext on the HA-only path, matching the endpoint they read"
  }
}

# All four corners covered: this is the both-on case. One resource carries both
# feature sets, which is the whole reason the two counts were collapsed into
# local.redis_needs_replication_group.
run "redis_high_availability_and_transit_encryption_compose" {
  command = plan

  variables {
    redis_high_availability_enabled  = true
    redis_transit_encryption_enabled = true
  }

  assert {
    condition     = length(aws_elasticache_replication_group.n8n) == 1 && length(aws_elasticache_cluster.n8n) == 0
    error_message = "Both features select the same single replication group. Two resources here would mean two caches and a split queue."
  }

  assert {
    condition = (
      aws_elasticache_replication_group.n8n[0].num_cache_clusters == 2 &&
      aws_elasticache_replication_group.n8n[0].automatic_failover_enabled == true &&
      aws_elasticache_replication_group.n8n[0].multi_az_enabled == true
    )
    error_message = "The HA attributes must survive being combined with transit encryption"
  }

  assert {
    condition = (
      aws_elasticache_replication_group.n8n[0].transit_encryption_enabled == true &&
      length(random_password.redis_auth_token) == 1
    )
    error_message = "The encryption attributes must survive being combined with high availability"
  }
}

# The AUTH token charset is not a free choice: ElastiCache rejects anything
# outside ! & # $ ^ < > - at create time, and the failure surfaces as an opaque
# InvalidParameterValue from AWS well into the apply. Asserting the generator's
# inputs catches a careless edit at plan time instead.
run "redis_auth_token_respects_elasticache_charset" {
  command = plan

  variables {
    redis_transit_encryption_enabled = true
  }

  assert {
    condition     = random_password.redis_auth_token[0].override_special == "!&#$^<>-"
    error_message = "AUTH token special characters must be limited to the set ElastiCache permits (! & # $ ^ < > -)"
  }

  assert {
    condition = (
      random_password.redis_auth_token[0].length >= 16 &&
      random_password.redis_auth_token[0].length <= 128
    )
    error_message = "ElastiCache AUTH tokens must be 16-128 characters"
  }
}

# The resource asserts above cover whether the token is generated. These cover
# whether the caller can actually reach it, which is a separate contract: the
# output is the only supported way to retrieve the credential, and it carries
# its own count-index expression that could drift from the resource guard
# without any of the above noticing.

run "redis_auth_token_output_is_null_by_default" {
  command = plan

  assert {
    condition     = output.redis_auth_token == null
    error_message = "The default posture has no credential, so the output must be null rather than an empty string"
  }
}

# Guards the pairing specifically. HA alone selects the same replication group
# but generates no token, so an output keyed on the wrong condition would fail
# here and nowhere else.
run "redis_auth_token_output_is_null_for_ha_without_tls" {
  command = plan

  variables {
    redis_high_availability_enabled = true
  }

  assert {
    condition     = output.redis_auth_token == null
    error_message = "High availability alone generates no AUTH token, so the output must stay null"
  }
}

# The positive case is deliberately absent. random_password.result is unknown
# at plan time, so both `output.redis_auth_token == random_password...result`
# and a bare `!= null` resolve to an unknown condition and fail the run rather
# than passing. command = apply is not the escape hatch either: the mocked
# providers fail ARN validation, which is why this file has only one apply run.
#
# What that leaves uncovered is narrow. The two runs above pin the half that
# can actually drift, which is the output returning a token on a path that has
# none, and the [0] index the true branch takes is guarded by the
# length(random_password.redis_auth_token) == 1 assert further up. The value
# itself is verified live instead: `terraform output -raw redis_auth_token`
# has to authenticate against the real endpoint.

# The module cannot put TLS or a token on a Redis it does not manage, and the
# combination is worse than merely ignored: the Helm values would still render
# tls = true plus a generated password, pointing every pod at the caller's
# plaintext endpoint with a credential it has never heard of. That applies
# cleanly and fails at runtime, so it is a hard validation rather than one of
# the `check` warnings below.
# ── External Redis: TLS and AUTH ─────────────────────────────────────────────
# create_elasticache = false no longer requires an unauthenticated, plaintext
# endpoint. redis_transit_encryption_enabled and redis_auth_token each describe
# a property of the caller's own Redis on this path, independent of the
# module-managed replication group's migration lever.

run "external_redis_defaults_to_plaintext_no_auth" {
  command = plan

  variables {
    create_elasticache = false
    redis_host         = "redis.example.internal"
  }

  assert {
    condition     = local.redis_tls_active == false
    error_message = "Leaving redis_transit_encryption_enabled at its default must not claim the external endpoint speaks TLS"
  }

  assert {
    condition     = local.redis_auth_active == false
    error_message = "Leaving redis_auth_token null must not claim there is a credential"
  }

  assert {
    condition     = length(kubernetes_secret.n8n_redis) == 0
    error_message = "No Secret should exist when the external Redis needs neither TLS nor AUTH"
  }
}

run "external_redis_tls_only_is_supported" {
  command = plan

  variables {
    create_elasticache               = false
    redis_host                       = "redis.example.internal"
    redis_transit_encryption_enabled = true
  }

  # This combination used to fail plan-time validation outright. It is now a
  # supported configuration: the caller is declaring that their own Redis
  # speaks TLS, not asking the module to configure TLS on infrastructure it
  # does not manage.
  assert {
    condition     = local.redis_tls_active == true
    error_message = "redis_transit_encryption_enabled must be honored on the external path as 'this endpoint speaks TLS'"
  }

  assert {
    condition     = local.redis_auth_active == false
    error_message = "TLS alone must not imply a credential when redis_auth_token is left null"
  }

  assert {
    condition     = length(random_password.redis_auth_token) == 0
    error_message = "The module must never generate a token for a Redis it does not manage"
  }

  assert {
    condition     = length(kubernetes_secret.n8n_redis) == 0
    error_message = "No password Secret should exist without an AUTH token"
  }
}

run "external_redis_auth_only_is_supported" {
  command = plan

  variables {
    create_elasticache = false
    redis_host         = "redis.example.internal"
    redis_auth_token   = "s3cr3t-external-password"
  }

  assert {
    condition     = local.redis_tls_active == false
    error_message = "Supplying an AUTH token must not imply TLS: a plain self-hosted Redis can require AUTH without TLS"
  }

  assert {
    condition     = local.redis_auth_active == true
    error_message = "Supplying redis_auth_token must mark AUTH as active on the external path"
  }

  assert {
    condition     = local.redis_auth_token_value == "s3cr3t-external-password"
    error_message = "The caller-supplied token, not a generated one, must reach the resolved local"
  }

  assert {
    condition = (
      length(random_password.redis_auth_token) == 0 &&
      length(kubernetes_secret.n8n_redis) == 1 &&
      kubernetes_secret.n8n_redis[0].data["password"] == "s3cr3t-external-password"
    )
    error_message = "The module must wire the caller's own token into the Secret rather than generating one"
  }
}

run "external_redis_tls_and_auth_together" {
  command = plan

  variables {
    create_elasticache               = false
    redis_host                       = "redis.example.internal"
    redis_transit_encryption_enabled = true
    redis_auth_token                 = "s3cr3t-external-password"
  }

  assert {
    condition = (
      local.redis_tls_active == true &&
      local.redis_auth_active == true &&
      kubernetes_secret.n8n_redis[0].data["password"] == "s3cr3t-external-password" &&
      local.keda_redis_auth_metadata["enableTLS"] == "true" &&
      local.keda_redis_auth_metadata["passwordFromEnv"] == "QUEUE_BULL_REDIS_PASSWORD"
    )
    error_message = "TLS and AUTH must compose on the external path exactly as they do on the module-managed one"
  }
}

run "redis_auth_token_ignored_with_module_managed_elasticache_warns" {
  command = plan

  variables {
    redis_auth_token = "should-be-ignored"
  }

  expect_failures = [check.redis_auth_token_requires_external_redis]

  assert {
    condition     = length(random_password.redis_auth_token) == 0
    error_message = "redis_transit_encryption_enabled is false by default, so no token should be generated regardless of the ignored input"
  }
}

# ── Redis 6+ ACL username on the external path ───────────────────────────────
# A named ACL user is the one authentication shape the external hook could not
# express: redis_auth_token carries a password, and without a username it is the
# default user's password. Both consumers have to learn the username or half the
# deployment authenticates as the wrong user, so the assertions below cover the
# chart value and the KEDA trigger metadata, not just the input.

run "external_redis_acl_username_reaches_both_consumers" {
  command = plan

  variables {
    create_elasticache               = false
    redis_host                       = "redis.example.internal"
    redis_transit_encryption_enabled = true
    redis_auth_token                 = "s3cr3t-external-password"
    redis_username                   = "n8n-queue"
  }

  assert {
    condition     = local.redis_username_value == "n8n-queue"
    error_message = "redis_username must resolve through to the value the chart and KEDA read"
  }

  # username is a literal in the trigger metadata, unlike the password, which is
  # referenced with passwordFromEnv so it never lands in the ScaledObject. A
  # username is not a credential, and the literal does not depend on KEDA
  # resolving the chart's QUEUE_BULL_REDIS_USERNAME env var.
  assert {
    condition = (
      local.keda_redis_auth_metadata["username"] == "n8n-queue" &&
      local.keda_redis_auth_metadata["passwordFromEnv"] == "QUEUE_BULL_REDIS_PASSWORD" &&
      local.keda_redis_auth_metadata["enableTLS"] == "true"
    )
    error_message = "The KEDA worker triggers must authenticate as the same ACL user n8n does, over the same TLS setting"
  }

  assert {
    condition     = !contains(keys(local.keda_redis_auth_metadata), "usernameFromEnv")
    error_message = "The username is passed literally; usernameFromEnv would add a resolution step for a value that is not secret"
  }
}

run "external_redis_without_a_username_stays_on_the_default_user" {
  command = plan

  variables {
    create_elasticache = false
    redis_host         = "redis.example.internal"
    redis_auth_token   = "s3cr3t-external-password"
  }

  assert {
    condition     = local.redis_username_value == null
    error_message = "Leaving redis_username null must authenticate as Redis's default user"
  }

  # Omitted, not sent as null: the chart guards on `if .Values.redis.username`,
  # and every release that does not set it must render byte-identically to before
  # the input existed.
  assert {
    condition     = !contains(keys(local.keda_redis_auth_metadata), "username")
    error_message = "No username must appear in the KEDA trigger metadata when redis_username is null"
  }
}

run "redis_username_ignored_with_module_managed_elasticache_warns" {
  command = plan

  variables {
    redis_username = "should-be-ignored"
  }

  expect_failures = [check.redis_username_requires_external_redis]

  # Ignored means ignored. Passing a username to ElastiCache AUTH breaks a
  # working connection, so the local must resolve it away rather than merely
  # warn about it.
  assert {
    condition     = local.redis_username_value == null
    error_message = "redis_username must not reach the chart or KEDA when the module manages ElastiCache"
  }
}

run "redis_username_rejects_a_blank_value" {
  command = plan

  variables {
    create_elasticache = false
    redis_host         = "redis.example.internal"
    redis_username     = "   "
  }

  expect_failures = [var.redis_username]
}

run "redis_username_rejects_whitespace" {
  command = plan

  variables {
    create_elasticache = false
    redis_host         = "redis.example.internal"
    redis_username     = "n8n queue"
  }

  expect_failures = [var.redis_username]
}

run "redis_username_rejects_a_padded_value" {
  command = plan

  variables {
    create_elasticache = false
    redis_host         = "redis.example.internal"
    redis_username     = " n8n-queue "
  }

  expect_failures = [var.redis_username]
}

# redis_key_prefix: N8N_REDIS_KEY_PREFIX/QUEUE_BULL_PREFIX/KEDA listName all
# live inside helm_release.n8n's single yamlencode'd values string (like the
# OTEL block above), so these assert at the variable/local contract level
# rather than parsing that string.
run "redis_key_prefix_defaults_to_null_and_keeps_bulls_own_prefix" {
  command = plan

  assert {
    condition     = var.redis_key_prefix == null
    error_message = "redis_key_prefix must default to null: n8n and Bull keep their own default prefixes unless a caller opts in."
  }

  assert {
    condition     = local.redis_key_prefix_value == "bull"
    error_message = "local.redis_key_prefix_value must fall back to Bull's own default prefix (\"bull\") when redis_key_prefix is null, so the KEDA listName values stay byte-identical to before this variable existed."
  }
}

run "redis_key_prefix_resolves_into_the_shared_local" {
  command = plan

  variables {
    create_elasticache = false
    redis_host         = "redis.example.internal"
    redis_key_prefix   = "tenant-a"
  }

  assert {
    condition     = local.redis_key_prefix_value == "tenant-a"
    error_message = "local.redis_key_prefix_value must resolve to the caller-supplied prefix, which n8n.tf's env var, redis.prefix, and both KEDA listName values all read from"
  }
}

run "redis_key_prefix_rejects_a_blank_value" {
  command = plan

  variables {
    redis_key_prefix = "   "
  }

  expect_failures = [var.redis_key_prefix]
}

run "redis_key_prefix_rejects_a_colon" {
  command = plan

  variables {
    # ":" is n8n's and Bull's own key-segment delimiter (e.g.
    # "<prefix>:n8n.commands"), so a prefix containing one would produce a
    # confusing or malformed key namespace rather than a clean second segment.
    redis_key_prefix = "tenant:a"
  }

  expect_failures = [var.redis_key_prefix]
}

run "redis_key_prefix_rejects_whitespace" {
  command = plan

  variables {
    redis_key_prefix = "tenant a"
  }

  expect_failures = [var.redis_key_prefix]
}

run "redis_mode_tuning_ignored_on_external_redis_warns" {
  command = plan

  variables {
    create_elasticache            = false
    redis_host                    = "redis.example.internal"
    redis_transit_encryption_mode = "preferred"
  }

  expect_failures = [check.redis_tuning_requires_module_managed_elasticache]
}

# ── Staged migration inputs ──────────────────────────────────────────────────
# redis_transit_encryption_mode and redis_apply_immediately exist so that TLS can
# be added to a replication group that already exists, which AWS refuses as a
# single modification. The contract these pin is the one that matters to callers
# who are NOT migrating: both must be invisible at their defaults, because every
# deployment already running redis_high_availability_enabled will re-plan against
# this version of the module, and a spurious in-place update on Redis is exactly
# the kind of diff that stops an upgrade from being adopted.

run "redis_transit_encryption_mode_defaults_to_required" {
  command = plan

  variables {
    redis_transit_encryption_enabled = true
  }

  assert {
    condition     = aws_elasticache_replication_group.n8n[0].transit_encryption_mode == "required"
    error_message = "A first-time create with transit encryption on must land on required, i.e. TLS only. preferred is a migration state and leaves the endpoint accepting cleartext."
  }
}

run "redis_transit_encryption_mode_is_unset_without_tls" {
  command = plan

  variables {
    redis_high_availability_enabled = true
  }

  # Read through the local rather than the resource attribute. Both arguments
  # are Optional+Computed, so an unset one plans as "known after apply" and a
  # `== null` assertion against the resource fails with "Unknown condition
  # value" rather than passing. Where a concrete value IS set the resource is
  # assertable, and the runs below do read it there.
  assert {
    condition     = local.redis_transit_encryption_mode == null
    error_message = "The HA-only path must leave transit_encryption_mode unset. Writing the default onto a plaintext group would put a value in the plan for every deployment that enabled HA before this input existed."
  }
}

run "redis_transit_encryption_mode_accepts_preferred_for_the_migration" {
  command = plan

  variables {
    redis_high_availability_enabled  = true
    redis_transit_encryption_enabled = true
    redis_transit_encryption_mode    = "preferred"
    redis_apply_immediately          = true
  }

  assert {
    condition     = aws_elasticache_replication_group.n8n[0].transit_encryption_mode == "preferred"
    error_message = "preferred must reach the resource: it is the only mode AWS accepts when turning transit encryption on for a group that already exists"
  }

  assert {
    condition     = aws_elasticache_replication_group.n8n[0].transit_encryption_enabled == true
    error_message = "preferred is a mode OF transit encryption, not an alternative to it, so the enable flag must still be set alongside it"
  }

  # Warns for as long as the deployment sits in preferred, by design.
  expect_failures = [check.redis_transit_encryption_mode_preferred_is_transitional]
}

# ── preferred means TLS without a credential, everywhere ─────────────────────
# AWS rejects an AUTH token on a group in preferred, both on its own and bundled
# into the call that moves the group to required:
#
#   InvalidParameterValue: The AUTH token modification is only supported when
#   encryption-in-transit is enabled.
#
# So the module must not generate, publish or reference a token in this mode.
# These runs pin every place the credential would otherwise leak out, because a
# miss in any one of them turns the migration's first apply back into the AWS
# rejection this feature exists to avoid, or points the clients at a credential
# the server does not have.

run "preferred_generates_no_auth_token_at_all" {
  command = plan

  variables {
    redis_high_availability_enabled  = true
    redis_transit_encryption_enabled = true
    redis_transit_encryption_mode    = "preferred"
    redis_apply_immediately          = true
  }

  expect_failures = [check.redis_transit_encryption_mode_preferred_is_transitional]

  assert {
    condition     = length(random_password.redis_auth_token) == 0
    error_message = "No token may be generated in preferred mode. AWS will not accept one, so generating it would put a value in the plan that can never reach the resource."
  }

  assert {
    condition     = length(kubernetes_secret.n8n_redis) == 0
    error_message = "The Secret must not exist in preferred mode either. It would hold a password no ElastiCache node is configured with, and the chart would mount it onto every pod."
  }

  assert {
    condition     = length(local.redis_pod_annotations) == 0
    error_message = "There is no token to checksum in preferred mode, so there is no rollout to force"
  }
}

run "preferred_still_puts_the_clients_on_tls" {
  command = plan

  variables {
    redis_high_availability_enabled  = true
    redis_transit_encryption_enabled = true
    redis_transit_encryption_mode    = "preferred"
    redis_apply_immediately          = true
  }

  expect_failures = [check.redis_transit_encryption_mode_preferred_is_transitional]

  assert {
    condition     = local.redis_tls_active == true
    error_message = "preferred accepts TLS as well as plaintext, and rolling the pods onto TLS during this window is the whole reason the migration is non-disruptive. Dropping them back to plaintext here would make the move to required an outage."
  }

  assert {
    condition     = local.redis_auth_active == false
    error_message = "TLS without a credential is exactly the state preferred supports, and the only state it supports"
  }

  assert {
    # enableTLS but NOT passwordFromEnv. A trigger naming an environment
    # variable that does not exist resolves to an empty credential and then
    # authenticates against a server with no password configured.
    condition = (
      local.keda_redis_auth_metadata["enableTLS"] == "true" &&
      !contains(keys(local.keda_redis_auth_metadata), "passwordFromEnv")
    )
    error_message = "KEDA must speak TLS without looking for a password while the group is in preferred"
  }
}

run "preferred_reports_no_auth_token_output" {
  command = plan

  variables {
    redis_high_availability_enabled  = true
    redis_transit_encryption_enabled = true
    redis_transit_encryption_mode    = "preferred"
    redis_apply_immediately          = true
  }

  expect_failures = [check.redis_transit_encryption_mode_preferred_is_transitional]

  assert {
    condition     = output.redis_auth_token == null
    error_message = "The output must be null while there is no token, rather than reporting one that AWS never accepted"
  }
}

run "required_is_what_restores_the_credential" {
  command = plan

  variables {
    redis_high_availability_enabled  = true
    redis_transit_encryption_enabled = true
    redis_transit_encryption_mode    = "required"
  }

  assert {
    condition     = local.redis_auth_active == true
    error_message = "required is the only mode AWS accepts an AUTH token in, so it is the mode the credential comes back on"
  }

  assert {
    condition = (
      length(random_password.redis_auth_token) == 1 &&
      length(kubernetes_secret.n8n_redis) == 1 &&
      length(local.redis_pod_annotations) == 1 &&
      contains(keys(local.keda_redis_auth_metadata), "passwordFromEnv")
    )
    error_message = "Moving to required must restore the token, the Secret, the rollout annotation and the KEDA credential together. Any one of them lagging leaves that client authenticating against a server that now demands a password."
  }
}

run "redis_transit_encryption_mode_rejects_an_unknown_value" {
  command = plan

  variables {
    redis_transit_encryption_enabled = true
    redis_transit_encryption_mode    = "disabled"
  }

  expect_failures = [var.redis_transit_encryption_mode]
}

run "redis_transit_encryption_mode_without_transit_encryption_warns" {
  command = plan

  variables {
    # The migration's first step, with the enable flag forgotten. This applies
    # cleanly and leaves Redis exactly as plaintext as it was, which is why it
    # warns rather than passing silently.
    redis_high_availability_enabled = true
    redis_transit_encryption_mode   = "preferred"
  }

  expect_failures = [check.redis_transit_encryption_mode_requires_transit_encryption]

  assert {
    condition     = aws_elasticache_replication_group.n8n[0].transit_encryption_enabled == false
    error_message = "The mode alone must not turn encryption on. If it did, the check would be wrong rather than the input."
  }
}

run "redis_apply_immediately_is_unset_by_default" {
  command = plan

  variables {
    redis_high_availability_enabled = true
  }

  assert {
    condition     = local.redis_apply_immediately == null
    error_message = "apply_immediately must be null rather than false at its default. It is a request-time flag the API never reports back, so a group created before this input existed has it null in state and an explicit false would render as an in-place update that changes nothing."
  }
}

run "redis_apply_immediately_reaches_the_replication_group" {
  command = plan

  variables {
    redis_high_availability_enabled = true
    redis_apply_immediately         = true
  }

  assert {
    condition     = aws_elasticache_replication_group.n8n[0].apply_immediately == true
    error_message = "AWS rejects every transit-encryption modification without this, so the migration cannot proceed if the input does not reach the resource"
  }
}

# The single-node cluster is the DEFAULT topology, and it ignored this input
# entirely until the resource gained the argument: a redis_node_type resize
# reported "Apply complete" while AWS queued it for the maintenance window
# (measured: the forced resize then took 41 minutes). The replication-group
# assertion above passing is exactly why that went unnoticed, so this asserts
# the other topology explicitly.
run "redis_apply_immediately_reaches_the_single_node_cluster" {
  command = plan

  variables {
    redis_apply_immediately = true
  }

  assert {
    condition     = aws_elasticache_cluster.n8n[0].apply_immediately == true
    error_message = "redis_apply_immediately must reach the default single-node aws_elasticache_cluster, not only the replication group, or a node_type resize on the default topology defers silently."
  }
}

run "redis_apply_immediately_is_unset_by_default_on_the_single_node_cluster" {
  command = plan

  assert {
    condition     = local.redis_apply_immediately == null
    error_message = "The default must stay null rather than false on the single-node path too, so existing clusters see no in-place update for a flag that changes nothing."
  }
}

# ── RDS apply_immediately ─────────────────────────────────────────────────────
# Same request-time-flag reasoning as the Redis pair above, on the database.
# Without it a db_instance_class change reports "Apply complete" while AWS
# queues the class change in PendingModifiedValues for a window days out.

run "db_apply_immediately_is_unset_by_default" {
  command = plan

  assert {
    condition     = aws_db_instance.n8n[0].apply_immediately == null
    error_message = "apply_immediately must be null rather than false at its default. It is a request-time flag the API never reports back, so an instance created before this input existed has it null in state and an explicit false would render as an in-place update that changes nothing."
  }
}

run "db_apply_immediately_reaches_the_instance" {
  command = plan

  variables {
    db_apply_immediately = true
  }

  assert {
    condition     = aws_db_instance.n8n[0].apply_immediately == true
    error_message = "db_apply_immediately must reach aws_db_instance, or a resize defers to the maintenance window while Terraform reports it applied."
  }
}

run "redis_apply_immediately_with_external_redis_warns" {
  command = plan

  variables {
    create_elasticache      = false
    redis_host              = "shared-redis.abc123.ng.0001.use1.cache.amazonaws.com"
    redis_apply_immediately = true
  }

  expect_failures = [check.redis_tuning_requires_module_managed_elasticache]
}

# ── AUTH token rotation rollout ──────────────────────────────────────────────
# The token reaches pods through a Secret referenced by name, so rotating it
# produces no Helm diff and nothing restarts. local.redis_pod_annotations is
# what forces the rollout, and it is assertable here because helm_release.values
# is not (it embeds the Redis endpoint and so is unknown at plan time).
#
# The hash itself is unknown at plan time, since random_password.result is. What
# these pin is the shape: which paths carry the annotation at all, and that it
# is a checksum key rather than the token.

run "no_pod_annotations_by_default" {
  command = plan

  assert {
    condition     = length(local.redis_pod_annotations) == 0
    error_message = "The default path must emit no podAnnotations key at all. An empty map is not the same as omitting it: the rendered values change and every existing release sees a Helm diff on upgrade."
  }
}

run "no_pod_annotations_for_ha_without_tls" {
  command = plan

  variables {
    redis_high_availability_enabled = true
  }

  assert {
    condition     = length(local.redis_pod_annotations) == 0
    error_message = "High availability alone generates no AUTH token, so there is nothing to checksum and no rollout to force"
  }
}

run "pod_annotations_carry_the_token_checksum_when_enabled" {
  command = plan

  variables {
    redis_transit_encryption_enabled = true
  }

  assert {
    # contains + length rather than comparing keys() to a literal: keys()
    # returns a list and the literal is a tuple, so == is a type mismatch that
    # reads as a genuine assertion failure.
    condition = (
      length(local.redis_pod_annotations) == 1 &&
      contains(keys(local.redis_pod_annotations), "checksum/redis-auth-token")
    )
    error_message = "Transit encryption must add exactly the token checksum annotation, so a rotation rolls main, worker and webhook processor pods"
  }
}

# ── KEDA trigger auth metadata ───────────────────────────────────────────────
# The KEDA triggers live inside helm_release.n8n.values, which is unknown at
# plan time (it embeds the Redis endpoint). local.keda_redis_auth_metadata is
# the merged-in fragment that decides what those triggers carry, and it is
# known from the variables alone, so it is the layer where this is assertable.

run "keda_triggers_carry_no_auth_metadata_by_default" {
  command = plan

  assert {
    condition     = length(local.keda_redis_auth_metadata) == 0
    error_message = "The default path must add nothing to the KEDA trigger metadata. Any extra key here changes the rendered ScaledObject for every existing caller who never opted in."
  }
}

# Both keys matter, and TLS is the one that has to land. Without enableTLS, KEDA
# opens a plaintext connection to a TLS-only endpoint and hangs on `connection
# to redis failed: i/o timeout` before authentication is ever attempted, so the
# credential alone would look like no fix at all. Observed on a live cluster.
run "keda_triggers_carry_tls_and_auth_when_enabled" {
  command = plan

  variables {
    redis_transit_encryption_enabled = true
  }

  assert {
    condition     = local.keda_redis_auth_metadata["enableTLS"] == "true"
    error_message = "KEDA's Redis trigger must enable TLS when the backend is TLS-only, otherwise the metric read hangs until it times out and the HPA reports <unknown>."
  }

  # passwordFromEnv names an environment variable; KEDA resolves it against the
  # scale target's first container, following the secretKeyRef the chart sets
  # there. Pinning the exact env var name matters: a typo resolves to empty and
  # fails as an auth error at runtime, which no plan can catch.
  assert {
    condition     = local.keda_redis_auth_metadata["passwordFromEnv"] == "QUEUE_BULL_REDIS_PASSWORD"
    error_message = "The KEDA trigger must reference the same env var the chart mounts the AUTH token into (QUEUE_BULL_REDIS_PASSWORD) on the worker container."
  }

  # The token must reach KEDA by reference only. A literal value here would be
  # readable by anyone who can get the ScaledObject.
  assert {
    condition     = !contains(keys(local.keda_redis_auth_metadata), "password")
    error_message = "The AUTH token must not be written into trigger metadata as a literal, which puts the credential in a readable ScaledObject manifest."
  }
}

# ── Redis failover timeout threshold ─────────────────────────────────────────
# The value lands inside helm_release.n8n.values, which is unknown at plan time,
# so local.redis_timeout_values is the assertable layer. What matters most is
# that it stays EMPTY by default: the module has never set redis.timeout, and
# emitting the key at all, even with the chart's own 10000, re-renders the
# values for every existing release and turns an upgrade into a Helm diff.

run "redis_timeout_threshold_is_absent_by_default" {
  command = plan

  assert {
    condition     = var.n8n_redis_timeout_threshold == null
    error_message = "n8n_redis_timeout_threshold must default to null so the chart's own 10000 applies untouched"
  }

  assert {
    condition     = length(local.redis_timeout_values) == 0
    error_message = "The default path must emit no redis.timeout key at all. Setting it to the chart default is not the same as omitting it: the rendered values change and every existing release sees a Helm diff on upgrade."
  }
}

run "redis_timeout_threshold_reaches_the_chart_when_set" {
  command = plan

  variables {
    n8n_redis_timeout_threshold = 60000
  }

  assert {
    condition     = local.redis_timeout_values["timeout"] == 60000
    error_message = "n8n_redis_timeout_threshold must reach the chart's redis.timeout, which maps to QUEUE_BULL_REDIS_TIMEOUT_THRESHOLD"
  }
}

# Below ~2s a single ioredis connect timeout (10s, which n8n does not override)
# exceeds the whole budget before DNS has been re-resolved once, so the process
# exits on any blip instead of reconnecting. That is worse than the default.
run "redis_timeout_threshold_rejects_a_value_below_one_connect_attempt" {
  command = plan

  variables {
    n8n_redis_timeout_threshold = 500
  }

  expect_failures = [var.n8n_redis_timeout_threshold]
}

run "redis_timeout_threshold_rejects_a_fractional_value" {
  command = plan

  variables {
    n8n_redis_timeout_threshold = 30000.5
  }

  expect_failures = [var.n8n_redis_timeout_threshold]
}

# The upper bound is a typo guard, not a capability limit: 600000 is ten
# minutes, well past any managed failover, and a value above it is far more
# likely to be a misplaced digit than an intent. Untested, a regression that
# dropped the clamp would let 6000000 through and leave a pod wedged against a
# dead Redis for over an hour before Kubernetes restarted it.
run "redis_timeout_threshold_rejects_a_value_above_the_typo_guard" {
  command = plan

  variables {
    n8n_redis_timeout_threshold = 600001
  }

  expect_failures = [var.n8n_redis_timeout_threshold]
}

# Both bounds are inclusive. Asserting the exact edges is what distinguishes
# >= from > if either comparison is ever edited, which the rejection runs above
# cannot see: 500 and 600001 stay rejected under both operators.
run "redis_timeout_threshold_accepts_the_exact_lower_bound" {
  command = plan

  variables {
    n8n_redis_timeout_threshold = 2000
  }

  assert {
    condition     = local.redis_timeout_values["timeout"] == 2000
    error_message = "2000 is the documented lower bound and must be accepted, not rejected as off-by-one"
  }
}

run "redis_timeout_threshold_accepts_the_exact_upper_bound" {
  command = plan

  variables {
    n8n_redis_timeout_threshold = 600000
  }

  assert {
    condition     = local.redis_timeout_values["timeout"] == 600000
    error_message = "600000 is the documented upper bound and must be accepted, not rejected as off-by-one"
  }
}

# ── External Redis (create_elasticache = false) ──────────────────────────────
# The hook the cross-region HA/DR design depends on: both regions point at one
# shared, replication-capable Redis. Mirrors create_database.

run "external_redis_skips_the_whole_redis_tier" {
  command = plan

  variables {
    create_elasticache = false
    redis_host         = "shared-redis.abc123.ng.0001.use1.cache.amazonaws.com"
  }

  assert {
    condition     = length(aws_elasticache_cluster.n8n) == 0
    error_message = "No ElastiCache cluster should be created when create_elasticache = false"
  }

  assert {
    condition     = length(aws_elasticache_replication_group.n8n) == 0
    error_message = "No replication group should be created when create_elasticache = false"
  }

  assert {
    condition     = length(aws_elasticache_subnet_group.n8n) == 0
    error_message = "No ElastiCache subnet group should be created when create_elasticache = false"
  }

  # Unlike the RDS security group, which stays behind unattached because
  # db_allowed_cidr_blocks writes caller rules into it, nothing in the module
  # attaches to the Redis SG. Leaving it would be a resource no caller asked for.
  assert {
    condition     = length(aws_security_group.redis) == 0
    error_message = "No Redis security group should be created when create_elasticache = false, because nothing in the module would attach to it"
  }

  assert {
    condition     = output.redis_endpoint == "shared-redis.abc123.ng.0001.use1.cache.amazonaws.com"
    error_message = "redis_endpoint must echo back the caller-supplied host when create_elasticache = false"
  }
}

run "external_redis_honours_a_non_default_port" {
  command = plan

  variables {
    create_elasticache = false
    redis_host         = "redis.internal.example.com"
    redis_port         = 6380
  }

  assert {
    condition     = output.redis_port == 6380
    error_message = "redis_port must reach the endpoint the module wires when create_elasticache = false"
  }
}

run "module_managed_redis_reports_6379_by_default" {
  command = plan

  assert {
    condition     = output.redis_port == 6379
    error_message = "Module-managed ElastiCache must report 6379"
  }
}

run "external_redis_missing_host_fails_validation" {
  command = plan

  variables {
    create_elasticache = false
    # redis_host intentionally unset
  }

  expect_failures = [var.redis_host]
}

# A blank host satisfies "is set" but is not a host. Without this the module
# plans cleanly and then hands n8n and KEDA an empty address, so the failure
# surfaces at runtime instead of at plan time.
run "external_redis_blank_host_fails_validation" {
  command = plan

  variables {
    create_elasticache = false
    redis_host         = ""
  }

  expect_failures = [var.redis_host]
}

# Whitespace-only is the same mistake wearing a disguise, and is what makes
# trimspace rather than a bare != "" the right test.
run "external_redis_whitespace_host_fails_validation" {
  command = plan

  variables {
    create_elasticache = false
    redis_host         = "   "
  }

  expect_failures = [var.redis_host]
}

# Non-empty after trimming, so the blank test passes it, but the module wires
# the raw value into KEDA as " redis.internal.example.com :6379". Caught at plan
# time rather than trimmed away, so the caller fixes the tfvars.
run "external_redis_padded_host_fails_validation" {
  command = plan

  variables {
    create_elasticache = false
    redis_host         = " redis.internal.example.com "
  }

  expect_failures = [var.redis_host]
}

run "external_redis_leading_whitespace_host_fails_validation" {
  command = plan

  variables {
    create_elasticache = false
    redis_host         = "\tredis.internal.example.com"
  }

  expect_failures = [var.redis_host]
}

# The guard rejects padding, not interior structure: a legitimate host still
# plans. Guards that overreach are as bad as guards that miss.
run "external_redis_clean_host_still_passes_validation" {
  command = plan

  variables {
    create_elasticache = false
    redis_host         = "redis.internal.example.com"
  }

  assert {
    condition     = local.redis_host == "redis.internal.example.com"
    error_message = "An unpadded external host must survive validation and reach local.redis_host unchanged"
  }
}

run "redis_port_rejects_a_value_outside_the_tcp_range" {
  command = plan

  variables {
    redis_port = 70000
  }

  expect_failures = [var.redis_port]
}

# ── Redis diagnostic checks ──────────────────────────────────────────────────
# Both cover the "X is ignored when Y" direction, which plans and applies
# cleanly while discarding what the caller asked for. See the check blocks in
# redis.tf for why each one warns rather than fails.

# Both halves of the mistake in one plan: the check warns, AND the inputs are
# genuinely discarded. Asserting the second is what makes the warning worth
# having. Module-managed ElastiCache always listens on 6379, so a redis_port
# that leaked through to the Helm values or the KEDA triggers would silently
# point n8n at a closed port.
run "external_redis_inputs_with_create_elasticache_true_warns_and_are_ignored" {
  command = plan

  variables {
    # create_elasticache defaults to true, so this Redis is never used.
    redis_host = "shared-redis.abc123.ng.0001.use1.cache.amazonaws.com"
    redis_port = 6380
  }

  expect_failures = [check.external_redis_inputs_require_create_elasticache_false]

  assert {
    condition     = output.redis_port == 6379
    error_message = "redis_port must not reach the endpoint the module wires while create_elasticache = true"
  }

  assert {
    condition     = length(aws_elasticache_cluster.n8n) == 1
    error_message = "Setting redis_host while create_elasticache = true must still create the module-managed cluster, which is exactly why the check warns"
  }
}

run "redis_tuning_with_create_elasticache_false_warns" {
  command = plan

  variables {
    create_elasticache              = false
    redis_host                      = "shared-redis.abc123.ng.0001.use1.cache.amazonaws.com"
    redis_node_type                 = "cache.r6g.large"
    redis_high_availability_enabled = true
  }

  expect_failures = [check.redis_tuning_requires_module_managed_elasticache]
}

run "redis_kms_encryption_with_create_elasticache_false_warns" {
  command = plan

  variables {
    create_elasticache           = false
    redis_host                   = "shared-redis.abc123.ng.0001.use1.cache.amazonaws.com"
    redis_kms_encryption_enabled = true
  }

  expect_failures = [check.redis_tuning_requires_module_managed_elasticache]
}

run "redis_snapshot_retention_with_create_elasticache_false_warns" {
  command = plan

  variables {
    create_elasticache             = false
    redis_host                     = "shared-redis.abc123.ng.0001.use1.cache.amazonaws.com"
    redis_snapshot_retention_limit = 3
  }

  expect_failures = [check.redis_tuning_requires_module_managed_elasticache]
}

run "s3_bucket_is_private" {
  command = plan

  assert {
    condition     = aws_s3_bucket_public_access_block.n8n[0].block_public_acls == true
    error_message = "S3 bucket must block public ACLs"
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.n8n[0].block_public_policy == true
    error_message = "S3 bucket must block public bucket policies"
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.n8n[0].ignore_public_acls == true
    error_message = "S3 bucket must ignore public ACLs"
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.n8n[0].restrict_public_buckets == true
    error_message = "S3 bucket must restrict public access"
  }

  # force_destroy lets terraform destroy drop the bucket even when n8n has
  # written attachments: without it, destroy fails with BucketNotEmpty.
  assert {
    condition     = aws_s3_bucket.n8n[0].force_destroy == true
    error_message = "S3 bucket must have force_destroy=true so teardown is clean"
  }

  # Bucket name: n8n-<cluster_name>-<last 6 of account ID>. With the default
  # cluster_name "n8n-cluster" and mocked account 123456789012 → 789012.
  assert {
    condition     = aws_s3_bucket.n8n[0].bucket == "n8n-n8n-cluster-789012"
    error_message = "S3 bucket name should be n8n-<cluster_name>-<account_suffix>"
  }

  assert {
    condition     = local.s3_bucket_name == "n8n-n8n-cluster-789012"
    error_message = "local.s3_bucket_name should track the module-managed bucket by default"
  }
}

# ── Server-side encryption ────────────────────────────────────────────────────

# s3_kms_encryption_enabled defaults to true, so the bucket's own default is
# SSE-KMS with a module-created CMK, covered by "s3_kms_encryption_defaults"
# and "s3_kms_encryption_can_be_disabled" further down (sse_algorithm,
# bucket_key_enabled, and that the CMK itself gets created). The specific
# claim that kms_master_key_id resolves to that CMK's own ARN and not to
# s3_kms_key_arn is a plan-time-unknown-vs-unknown comparison the mocked
# providers here cannot resolve under `command = plan`; it follows directly
# from local.s3_kms_key_arn's definition in locals.tf instead.

run "s3_sse_kms_input_switches_algorithm" {
  command = plan

  variables {
    # create_s3_kms_key = false is what tells the module not to mint its own
    # CMK; the ARN alone is ignored (and warned about by
    # check.s3_kms_key_arn_requires_create_s3_kms_key_false). See the comment
    # above aws_kms_key.db in database.tf for why the toggle is a boolean
    # rather than an inference from this ARN being non-null.
    create_s3_kms_key = false
    s3_kms_key_arn    = "arn:aws:kms:us-east-1:123456789012:key/1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d"
  }

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.n8n[0].rule).apply_server_side_encryption_by_default).sse_algorithm == "aws:kms"
    error_message = "Setting s3_kms_key_arn should switch the bucket to SSE-KMS"
  }

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.n8n[0].rule).apply_server_side_encryption_by_default).kms_master_key_id == "arn:aws:kms:us-east-1:123456789012:key/1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d"
    error_message = "kms_master_key_id should be set to s3_kms_key_arn"
  }

  assert {
    condition     = one(aws_s3_bucket_server_side_encryption_configuration.n8n[0].rule).bucket_key_enabled == true
    error_message = "bucket_key_enabled should be true under SSE-KMS"
  }
}

run "s3_kms_key_arn_validator_rejects_malformed_arn" {
  command = plan

  variables {
    s3_kms_key_arn = "not-an-arn"
  }

  expect_failures = [var.s3_kms_key_arn]
}

# ── Bring your own S3 bucket ──────────────────────────────────────────────────

run "existing_s3_bucket_skips_module_managed_resources" {
  command = plan

  variables {
    create_s3_bucket        = false
    existing_s3_bucket_name = "my-existing-n8n-bucket"
  }

  assert {
    condition     = length(aws_s3_bucket.n8n) == 0
    error_message = "No S3 bucket should be created when create_s3_bucket = false"
  }

  assert {
    condition     = length(aws_s3_bucket_public_access_block.n8n) == 0
    error_message = "No public access block should be created when create_s3_bucket = false"
  }

  assert {
    condition     = length(aws_s3_bucket_server_side_encryption_configuration.n8n) == 0
    error_message = "No SSE configuration should be created when create_s3_bucket = false: the caller's bucket is the caller's to secure"
  }

  assert {
    condition     = local.s3_bucket_name == "my-existing-n8n-bucket"
    error_message = "local.s3_bucket_name should track existing_s3_bucket_name when create_s3_bucket = false"
  }

  assert {
    condition     = local.s3_bucket_arn == "arn:aws:s3:::my-existing-n8n-bucket"
    error_message = "local.s3_bucket_arn should be derived from existing_s3_bucket_name when create_s3_bucket = false"
  }
}

run "existing_s3_bucket_missing_name_fails_validation" {
  command = plan

  variables {
    create_s3_bucket = false
    # existing_s3_bucket_name intentionally unset
  }

  expect_failures = [var.existing_s3_bucket_name]
}

run "create_s3_bucket_default_behavior_is_unchanged" {
  command = plan

  assert {
    condition     = aws_s3_bucket.n8n[0].bucket == "n8n-n8n-cluster-789012"
    error_message = "create_s3_bucket defaulting to true should preserve the module-managed bucket naming"
  }

  assert {
    condition     = aws_iam_policy.s3.policy != null
    error_message = "S3 IAM policy should still be created when create_s3_bucket defaults to true"
  }
}

# ── BYO-bucket diagnostic checks ──────────────────────────────────────────────
# Same shape as the external-database checks: setting an input that a sibling
# toggle causes the module to ignore plans and applies cleanly while silently
# discarding what the caller asked for, so these warn rather than fail.

run "existing_s3_bucket_name_with_create_s3_bucket_true_warns" {
  command = plan

  variables {
    # create_s3_bucket defaults to true, so this bucket is never used.
    existing_s3_bucket_name = "unused-bucket-name"
  }

  expect_failures = [check.existing_s3_bucket_name_requires_create_s3_bucket_false]
}

# s3_kms_key_arn alongside create_s3_bucket = false used to trip a check block
# warning that the input was ignored. It is not ignored any more: it is how a
# caller tells the module that the bucket they supplied is SSE-KMS encrypted, so
# the pod role gets key permissions. Asserting on the policy JSON is possible
# here (and not on the module-managed path) because local.s3_bucket_arn is a
# static string when the bucket name comes from a variable, leaving the whole
# document known at plan time.
run "existing_s3_bucket_with_sse_kms_grants_key_permissions_to_pod_role" {
  command = plan

  variables {
    create_s3_bucket        = false
    existing_s3_bucket_name = "my-existing-n8n-bucket"
    s3_kms_key_arn          = "arn:aws:kms:us-east-1:123456789012:key/1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d"
  }

  assert {
    condition     = length(jsondecode(aws_iam_policy.s3.policy).Statement) == 2
    error_message = "The pod role policy must carry a second statement granting KMS access when s3_kms_key_arn is set"
  }

  # kms:Decrypt covers GetObject, kms:GenerateDataKey covers PutObject. Missing
  # either one turns every binary-data operation into an AccessDenied.
  assert {
    condition = alltrue([
      for action in ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"] :
      contains(jsondecode(aws_iam_policy.s3.policy).Statement[1].Action, action)
    ])
    error_message = "The KMS statement must grant kms:Decrypt, kms:GenerateDataKey and kms:DescribeKey"
  }

  # Scoped to the one key, never "*".
  assert {
    condition     = jsondecode(aws_iam_policy.s3.policy).Statement[1].Resource == ["arn:aws:kms:us-east-1:123456789012:key/1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d"]
    error_message = "The KMS statement must be scoped to the supplied key ARN alone"
  }
}

run "existing_s3_bucket_without_kms_key_grants_no_key_permissions" {
  command = plan

  variables {
    create_s3_bucket        = false
    existing_s3_bucket_name = "my-existing-n8n-bucket"
  }

  # SSE-S3 needs no key permissions, so the policy must stay exactly as narrow
  # as it was before s3_kms_key_arn existed.
  assert {
    condition     = length(jsondecode(aws_iam_policy.s3.policy).Statement) == 1
    error_message = "The pod role policy must carry no KMS statement when s3_kms_key_arn is null"
  }
}

run "s3_kms_key_arn_validator_rejects_alias_arn" {
  command = plan

  variables {
    # An alias ARN cannot appear in an IAM policy Resource element, so a grant
    # written against one would match nothing and the AccessDenied would look
    # like a bug in the module rather than a bad input.
    s3_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:alias/n8n-s3"
  }

  expect_failures = [var.s3_kms_key_arn]
}

run "clean_existing_s3_bucket_config_is_quiet" {
  command = plan

  variables {
    create_s3_bucket        = false
    existing_s3_bucket_name = "my-existing-n8n-bucket"
  }

  assert {
    condition     = local.s3_bucket_name == "my-existing-n8n-bucket"
    error_message = "Sanity check that the plan succeeded with a clean BYO-bucket config"
  }
}

# ── External Secrets ──────────────────────────────────────────────────────────
# Layer 1 (n8n_external_secrets_enabled, n8n_external_secrets_update_interval)
# is asserted at the local/variable level, not against helm_release.n8n.values:
# that field is unknown at plan time under the mock provider (see "Known mock
# provider limitations" in AGENTS.md, and the execution_data_storage_mode runs
# above for the same pattern). To verify end-to-end, run a real `terraform
# plan` from examples/small/ with n8n_external_secrets_enabled = false and
# confirm N8N_DISABLED_MODULES=external-secrets appears in the helm_release.n8n
# values.

run "external_secrets_layer_one_defaults_to_no_env_vars" {
  command = plan

  assert {
    condition     = length(local.n8n_disabled_modules) == 0
    error_message = "local.n8n_disabled_modules must be empty by default, so N8N_DISABLED_MODULES is never emitted for an existing deployment"
  }

  assert {
    condition     = var.n8n_external_secrets_update_interval == null
    error_message = "n8n_external_secrets_update_interval must default to null, so N8N_EXTERNAL_SECRETS_UPDATE_INTERVAL is omitted and n8n's own default applies"
  }
}

run "n8n_external_secrets_enabled_false_disables_the_module" {
  command = plan

  variables {
    n8n_external_secrets_enabled = false
  }

  assert {
    condition     = length(local.n8n_disabled_modules) == 1 && local.n8n_disabled_modules[0] == "external-secrets"
    error_message = "n8n_external_secrets_enabled = false must add exactly \"external-secrets\" to local.n8n_disabled_modules"
  }
}

run "n8n_external_secrets_update_interval_rejects_zero" {
  command = plan

  variables {
    n8n_external_secrets_update_interval = 0
  }

  expect_failures = [var.n8n_external_secrets_update_interval]
}

run "external_secrets_aws_grant_disabled_by_default" {
  command = plan

  assert {
    condition = (
      length(aws_iam_policy.external_secrets) == 0 && length(aws_iam_role_policy_attachment.external_secrets) == 0 &&
      length(aws_iam_policy.external_secrets_kms) == 0 && length(aws_iam_role_policy_attachment.external_secrets_kms) == 0
    )
    error_message = "n8n_external_secrets_aws_enabled = false must create no IAM policy and no attachment, so an existing deployment plans unchanged"
  }
}

run "external_secrets_aws_grant_enabled_creates_the_expected_policy_shape" {
  command = plan

  variables {
    n8n_external_secrets_aws_enabled      = true
    n8n_external_secrets_aws_secret_names = ["n8n/workflow-vault"]
  }

  assert {
    condition = (
      length(aws_iam_policy.external_secrets) == 1 && length(aws_iam_role_policy_attachment.external_secrets) == 1 &&
      length(aws_iam_policy.external_secrets_kms) == 1 && length(aws_iam_role_policy_attachment.external_secrets_kms) == 1
    )
    error_message = "n8n_external_secrets_aws_enabled = true must create exactly one Secrets Manager policy, one KMS policy, and one attachment each"
  }

  assert {
    condition = (
      aws_iam_role_policy_attachment.external_secrets[0].role == aws_iam_role.s3.name &&
      aws_iam_role_policy_attachment.external_secrets_kms[0].role == aws_iam_role.s3.name
    )
    error_message = "Both the External Secrets policy and its KMS policy must attach to the same Pod Identity role S3 already uses, not a second role"
  }

  assert {
    condition = (
      jsondecode(aws_iam_policy.external_secrets[0].policy).Statement[0].Effect == "Allow" &&
      contains(jsondecode(aws_iam_policy.external_secrets[0].policy).Statement[0].Action, "secretsmanager:ListSecrets") &&
      contains(jsondecode(aws_iam_policy.external_secrets[0].policy).Statement[0].Action, "secretsmanager:BatchGetSecretValue") &&
      jsondecode(aws_iam_policy.external_secrets[0].policy).Statement[0].Resource == "*"
    )
    error_message = "ListSecrets and BatchGetSecretValue must be granted on \"*\": AWS defines no resource-level permissions on either action"
  }

  assert {
    condition = (
      jsondecode(aws_iam_policy.external_secrets[0].policy).Statement[1].Effect == "Allow" &&
      jsondecode(aws_iam_policy.external_secrets[0].policy).Statement[1].Action == ["secretsmanager:GetSecretValue"] &&
      jsondecode(aws_iam_policy.external_secrets[0].policy).Statement[1].Resource == ["arn:aws:secretsmanager:us-east-1:123456789012:secret:mock-AbCdEf"]
    )
    error_message = "GetSecretValue must be scoped to exactly the resolved ARNs of the named secrets, never a wildcard"
  }

  assert {
    condition = (
      jsondecode(aws_iam_policy.external_secrets[0].policy).Statement[2].Effect == "Deny" &&
      jsondecode(aws_iam_policy.external_secrets[0].policy).Statement[2].Condition.StringEquals["aws:ResourceTag/ManagedBy"] == "terraform"
    )
    error_message = "The policy must carry an explicit Deny on anything tagged ManagedBy = terraform, so the grant can never widen to cover a module-managed secret"
  }

  # Without this statement an allow-listed secret encrypted with a customer
  # managed KMS key is unreadable: Secrets Manager decrypts as the calling
  # principal, so GetSecretValue fails on kms:Decrypt regardless of the
  # secret's own policy. Lives in its own policy document (external_secrets_kms),
  # not as a fourth statement on aws_iam_policy.external_secrets above, so the
  # allow-listed ARNs embedded here (via kms:EncryptionContext:SecretARN) don't
  # count against the same 6,144-character policy-size cap as the ARNs already
  # embedded in that policy's own GetSecretValue statement.
  assert {
    condition = (
      jsondecode(aws_iam_policy.external_secrets_kms[0].policy).Statement[0].Effect == "Allow" &&
      jsondecode(aws_iam_policy.external_secrets_kms[0].policy).Statement[0].Action == ["kms:Decrypt"] &&
      jsondecode(aws_iam_policy.external_secrets_kms[0].policy).Statement[0].Condition.StringEquals["kms:ViaService"] == "secretsmanager.us-east-1.amazonaws.com" &&
      jsondecode(aws_iam_policy.external_secrets_kms[0].policy).Statement[0].Condition.StringEquals["kms:EncryptionContext:SecretARN"] == ["arn:aws:secretsmanager:us-east-1:123456789012:secret:mock-AbCdEf"]
    )
    error_message = "The KMS policy must grant kms:Decrypt scoped by kms:ViaService AND kms:EncryptionContext:SecretARN pinned to the resolved allow-list, or a CMK-encrypted allow-listed secret returns AccessDenied at runtime, or KMS enforces a wider boundary than GetSecretValue's own Resource list does"
  }
}

run "external_secrets_aws_grant_requires_at_least_one_secret_name" {
  command = plan

  variables {
    n8n_external_secrets_aws_enabled = true
  }

  expect_failures = [var.n8n_external_secrets_aws_secret_names]
}

run "external_secrets_aws_secret_names_rejects_a_wildcard" {
  command = plan

  variables {
    n8n_external_secrets_aws_enabled      = true
    n8n_external_secrets_aws_secret_names = ["n8n/workflow-*"]
  }

  expect_failures = [var.n8n_external_secrets_aws_secret_names]
}

run "external_secrets_allow_list_check_is_quiet_by_default" {
  command = plan

  variables {
    n8n_external_secrets_aws_enabled      = true
    n8n_external_secrets_aws_secret_names = ["n8n/workflow-vault"]
  }

  # module_managed.arns defaults to [] (see mock_data above), so there is
  # nothing to intersect and the check must stay quiet.
  assert {
    condition     = length(aws_iam_policy.external_secrets) == 1
    error_message = "Sanity check that the plan succeeded with no module-managed secrets in the test account"
  }
}

run "external_secrets_allow_list_check_fires_on_intersection" {
  command = plan

  variables {
    n8n_external_secrets_aws_enabled      = true
    n8n_external_secrets_aws_secret_names = ["n8n/workflow-vault"]
  }

  # Same fixture ARN data.aws_secretsmanager_secret always resolves to (see
  # mock_data above), now echoed back as a "module-managed" secret. That is
  # the intersection the check exists to catch.
  override_data {
    target = data.aws_secretsmanager_secrets.module_managed[0]
    values = {
      arns  = ["arn:aws:secretsmanager:us-east-1:123456789012:secret:mock-AbCdEf"]
      names = ["mock-module-secret"]
    }
  }

  expect_failures = [check.external_secrets_allow_list_excludes_module_managed_secrets]
}

run "pod_identity_bindings_use_correct_service_accounts" {
  command = plan

  # create_eks and install_lbc/install_cluster_autoscaler are all left at
  # their true defaults on this run, so both associations exist (count = 1)
  # and [0] is safe; see the create_eks_false_* runs below for the skipped
  # (count = 0) case this compound gate exists for.
  assert {
    condition     = module.controllers.lbc_pod_identity_association[0].namespace == "kube-system"
    error_message = "LBC pod identity binding must target kube-system"
  }

  assert {
    condition     = module.controllers.lbc_pod_identity_association[0].service_account == "aws-load-balancer-controller"
    error_message = "LBC pod identity must bind to the aws-load-balancer-controller SA"
  }

  assert {
    condition     = aws_eks_pod_identity_association.s3.service_account == "n8n-enterprise"
    error_message = "S3 pod identity must bind to the n8n-enterprise SA"
  }

  assert {
    condition     = module.controllers.cluster_autoscaler_pod_identity_association[0].service_account == "cluster-autoscaler"
    error_message = "Cluster autoscaler pod identity must bind to the cluster-autoscaler SA"
  }
}

# EBS CSI addon + default gp3 StorageClass (issue #22, solutions-catalog
# ADR-0041). All inputs here are static, so plan-time assertions work under
# the mocked providers; only the Pod Identity role_arn is mock-unknown, so we
# assert the service account and the role's static trust policy instead.
run "ebs_csi_and_default_storage_class" {
  command = plan

  assert {
    condition     = module.controllers.ebs_csi_addon[0].addon_name == "aws-ebs-csi-driver"
    error_message = "EBS CSI managed addon must be installed, without it no PVC can bind (issue #22)"
  }

  assert {
    # pod_identity_association is a set of objects, so it cannot be indexed.
    condition     = anytrue([for a in module.controllers.ebs_csi_addon[0].pod_identity_association : a.service_account == "ebs-csi-controller-sa"])
    error_message = "EBS CSI addon must bind Pod Identity to the ebs-csi-controller-sa SA"
  }

  assert {
    condition     = strcontains(module.controllers.ebs_csi_iam_role[0].assume_role_policy, "pods.eks.amazonaws.com")
    error_message = "EBS CSI role must trust pods.eks.amazonaws.com (Pod Identity, not IRSA)"
  }

  assert {
    condition     = module.controllers.ebs_csi_iam_role_policy_attachment[0].policy_arn == "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
    error_message = "EBS CSI role must attach the AWS-managed AmazonEBSCSIDriverPolicy"
  }

  assert {
    condition     = module.controllers.gp3_storage_class[0].metadata[0].name == "gp3"
    error_message = "Default StorageClass must be named gp3"
  }

  assert {
    condition     = module.controllers.gp3_storage_class[0].metadata[0].annotations["storageclass.kubernetes.io/is-default-class"] == "true"
    error_message = "gp3 StorageClass must carry the default-class annotation so unqualified PVCs bind"
  }

  assert {
    condition     = module.controllers.gp3_storage_class[0].storage_provisioner == "ebs.csi.aws.com"
    error_message = "gp3 StorageClass must use the EBS CSI provisioner, not the removed in-tree one"
  }

  assert {
    condition     = module.controllers.gp3_storage_class[0].volume_binding_mode == "WaitForFirstConsumer"
    error_message = "gp3 StorageClass must use WaitForFirstConsumer so volumes land in the consumer pod's AZ"
  }

  assert {
    condition     = module.controllers.gp3_storage_class[0].reclaim_policy == "Delete"
    error_message = "gp3 StorageClass must use the Delete reclaim policy to limit orphaned EBS volumes"
  }

  assert {
    condition     = module.controllers.gp3_storage_class[0].allow_volume_expansion == true
    error_message = "gp3 StorageClass must allow volume expansion"
  }

  assert {
    condition     = module.controllers.gp3_storage_class[0].parameters["type"] == "gp3"
    error_message = "gp3 StorageClass must provision gp3 volumes"
  }

  assert {
    condition     = module.controllers.gp3_storage_class[0].parameters["encrypted"] == "true"
    error_message = "gp3 StorageClass must encrypt volumes at rest"
  }
}

run "keda_installed_in_multi" {
  command = plan

  assert {
    condition     = module.controllers.keda_helm_release[0].chart == "keda"
    error_message = "KEDA helm release must exist in the multi template: worker autoscaling depends on it"
  }

  assert {
    condition     = module.controllers.keda_helm_release[0].namespace == "keda"
    error_message = "KEDA must be installed in its own 'keda' namespace"
  }
}

run "custom_database_sizing" {
  command = plan

  variables {
    db_instance_class    = "db.r6g.large"
    db_allocated_storage = 200
    db_multi_az          = true
    db_engine_version    = "16.13"
  }

  assert {
    condition     = aws_db_instance.n8n[0].instance_class == "db.r6g.large"
    error_message = "db_instance_class variable did not propagate"
  }

  assert {
    condition     = aws_db_instance.n8n[0].allocated_storage == 200
    error_message = "db_allocated_storage variable did not propagate"
  }

  assert {
    condition     = aws_db_instance.n8n[0].engine_version == "16.13"
    error_message = "db_engine_version variable did not propagate to aws_db_instance.engine_version"
  }
}

run "custom_namespace_propagates_to_s3_binding" {
  command = plan

  variables {
    namespace = "n8n-prod"
  }

  assert {
    condition     = aws_eks_pod_identity_association.s3.namespace == "n8n-prod"
    error_message = "S3 pod identity namespace should track var.namespace"
  }
}

# ── Logging variables ────────────────────────────────────────────────────────
# N8N_LOG_OUTPUT was previously a hardcoded "json", which is not a valid value
# (it controls log destinations, not format). With an invalid value Winston
# attaches no transport and silently drops every log line. These tests pin the
# corrected defaults and the validators that prevent the regression. The Helm
# values blob itself is unknown at plan time under the helm mock provider, so
# we assert at the variable contract level: n8n.tf wires both vars through
# verbatim into the extraEnv list.

run "log_defaults" {
  command = plan

  assert {
    # Regression guard: the previous hardcoded value was "json". Anything other
    # than a console/file combination here breaks logging entirely.
    condition     = var.n8n_log_output == "console"
    error_message = "n8n_log_output must default to 'console': 'json' (the previous value) silently drops all logs."
  }

  assert {
    condition     = var.n8n_log_level == "info"
    error_message = "n8n_log_level must default to 'info'."
  }
}

run "log_level_validator_rejects_invalid_value" {
  command = plan

  variables {
    n8n_log_level = "trace"
  }

  expect_failures = [var.n8n_log_level]
}

run "log_output_validator_rejects_json" {
  command = plan

  variables {
    # The original bug: "json" is not a valid N8N_LOG_OUTPUT value. The
    # validator must catch this at plan time so the regression cannot recur.
    n8n_log_output = "json"
  }

  expect_failures = [var.n8n_log_output]
}

run "log_output_accepts_console_and_file_combination" {
  command = plan

  variables {
    n8n_log_output = "console,file"
  }

  assert {
    condition     = var.n8n_log_output == "console,file"
    error_message = "n8n_log_output validator should accept comma-separated console,file."
  }
}

# ── Community packages ───────────────────────────────────────────────────────
# Both toggles map straight to n8n env vars and default to false so the env var
# is omitted (n8n's own default applies). The Helm values blob is unknown at
# plan time under the mock provider, so we assert at the variable contract
# level; that the entries land in config.extraEnv is verified by a real
# terraform plan from the Terraform Cloud workspace.

run "community_package_toggles_default_false" {
  command = plan

  assert {
    condition     = var.n8n_reinstall_missing_packages == false
    error_message = "n8n_reinstall_missing_packages must default to false so n8n's own default applies."
  }

  assert {
    condition     = var.n8n_community_packages_prevent_loading == false
    error_message = "n8n_community_packages_prevent_loading must default to false so n8n's own default applies."
  }
}

run "community_package_toggles_accept_true" {
  command = plan

  variables {
    n8n_reinstall_missing_packages         = true
    n8n_community_packages_prevent_loading = true
    # Sized above the webhook_resources_sized_for_reinstall_missing_packages
    # thresholds so this run, which is only exercising the toggles, doesn't
    # also trip that check. See the dedicated runs below.
    n8n_webhook_cpu_request    = "800m"
    n8n_webhook_cpu_limit      = "1500m"
    n8n_webhook_memory_request = "1Gi"
    n8n_webhook_memory_limit   = "2Gi"
  }

  assert {
    condition     = var.n8n_reinstall_missing_packages == true
    error_message = "n8n_reinstall_missing_packages should accept true."
  }

  assert {
    condition     = var.n8n_community_packages_prevent_loading == true
    error_message = "n8n_community_packages_prevent_loading should accept true."
  }
}

# ── Webhook resources vs. reinstall_missing_packages ─────────────────────────
# See https://github.com/n8n-io/terraform-aws-n8n/issues/52: every pod runs npm
# installs at boot when n8n_reinstall_missing_packages = true, and n8n
# rebroadcasts installs to all pods, so the webhook processor's default
# CPU/memory is too low to absorb a rolling restart without HPA thrash or
# OOMKills.

run "webhook_resources_below_reinstall_thresholds_triggers_check_warning" {
  command = plan

  variables {
    n8n_reinstall_missing_packages = true
    # Module defaults (300m/800m CPU, 512Mi/1Gi memory) are deliberately below
    # the check's thresholds.
  }

  expect_failures = [check.webhook_resources_sized_for_reinstall_missing_packages]
}

run "webhook_resources_at_reinstall_thresholds_plans_cleanly" {
  command = plan

  variables {
    n8n_reinstall_missing_packages = true
    n8n_webhook_cpu_request        = "800m"
    n8n_webhook_cpu_limit          = "1500m"
    n8n_webhook_memory_request     = "1Gi"
    n8n_webhook_memory_limit       = "2Gi"
  }

  assert {
    condition     = var.n8n_webhook_cpu_limit == "1500m"
    error_message = "Webhook resources at or above the reporter's stable production values must plan cleanly."
  }
}

run "webhook_resources_decimal_cpu_below_threshold_triggers_check_warning" {
  command = plan

  variables {
    n8n_reinstall_missing_packages = true
    # "0.5" (500m, decimal-core form) must parse rather than being treated as
    # unreadable: an unreadable quantity silently skips the check.
    n8n_webhook_cpu_request    = "0.5"
    n8n_webhook_cpu_limit      = "1500m"
    n8n_webhook_memory_request = "1Gi"
    n8n_webhook_memory_limit   = "2Gi"
  }

  expect_failures = [check.webhook_resources_sized_for_reinstall_missing_packages]
}

# ── OpenTelemetry tracing toggles ─────────────────────────────────────────────
# n8n_otel_enabled is the master switch (default false, contractually).
# Each tuning variable defaults to null so that, when n8n_otel_enabled is
# false, the whole config.extraEnv OTEL block collapses to []. The actual
# extraEnv list lives inside helm_release.n8n.values (a JSON-encoded string)
# and is awkward to inspect in plan-time tests; we assert at the variable
# contract layer, plus we keep a regression guard that the master toggle's
# default is false.

run "otel_defaults_off" {
  command = plan

  assert {
    condition     = var.n8n_otel_enabled == false
    error_message = "n8n_otel_enabled must default to false: OpenTelemetry tracing is opt-in."
  }

  assert {
    condition = (
      var.n8n_otel_exporter_otlp_endpoint == null &&
      var.n8n_otel_exporter_otlp_headers == null &&
      var.n8n_otel_exporter_service_name == null &&
      var.n8n_otel_traces_sample_rate == null &&
      var.n8n_otel_traces_include_node_spans == null &&
      var.n8n_otel_traces_inject_outbound == null &&
      var.n8n_otel_traces_production_only == null
    )
    error_message = "All n8n_otel_* tuning variables must default to null so an individual unset value falls back to n8n's own default."
  }
}

run "otel_sample_rate_validator_rejects_negative" {
  command = plan

  variables {
    n8n_otel_traces_sample_rate = -0.1
  }

  expect_failures = [var.n8n_otel_traces_sample_rate]
}

run "otel_sample_rate_validator_rejects_above_one" {
  command = plan

  variables {
    n8n_otel_traces_sample_rate = 1.5
  }

  expect_failures = [var.n8n_otel_traces_sample_rate]
}

run "otel_sample_rate_validator_accepts_zero_one_and_fractional" {
  command = plan

  variables {
    # Master toggle on so this run isn't tripped by the
    # `check "otel_tuning_requires_master_switch"` block in n8n.tf: the
    # purpose of this run is to exercise the sample-rate validator, not the
    # master/tuning interaction (which has its own runs below).
    n8n_otel_enabled            = true
    n8n_otel_traces_sample_rate = 0.25
  }

  assert {
    condition     = var.n8n_otel_traces_sample_rate == 0.25
    error_message = "n8n_otel_traces_sample_rate validator must accept fractional values in [0, 1]."
  }
}

run "otel_enabled_with_endpoint_propagates_through_variables" {
  command = plan

  variables {
    n8n_otel_enabled                = true
    n8n_otel_exporter_otlp_endpoint = "http://otel-collector.observability.svc.cluster.local:4318"
  }

  assert {
    condition = (
      var.n8n_otel_enabled == true &&
      var.n8n_otel_exporter_otlp_endpoint == "http://otel-collector.observability.svc.cluster.local:4318"
    )
    error_message = "Master toggle + endpoint variables must accept their typical opt-in values."
  }
}

# Regression guards for the `check "otel_tuning_requires_master_switch"`
# block in n8n.tf. Check blocks emit warnings on interactive plan/apply but
# are treated as failures by `terraform test`. We use that property:
# `expect_failures = [check.otel_tuning_requires_master_switch]` turns the
# warning-path test into an explicit "this check is supposed to fire here"
# assertion. If someone deletes the check block, this test fails (no
# failure to match the expectation), making the regression visible.
#
# The companion run `otel_tuning_set_with_master_on_plans_cleanly` covers
# the clean path (master on + tuning set, check happy) to make sure the
# check block also doesn't false-positive.

run "otel_tuning_set_with_master_off_triggers_check_warning" {
  command = plan

  variables {
    n8n_otel_enabled                = false
    n8n_otel_exporter_otlp_endpoint = "http://otel-collector.observability.svc.cluster.local:4318"
    n8n_otel_traces_sample_rate     = 0.1
  }

  expect_failures = [check.otel_tuning_requires_master_switch]
}

run "otel_tuning_set_with_master_on_plans_cleanly" {
  command = plan

  variables {
    n8n_otel_enabled                   = true
    n8n_otel_exporter_otlp_endpoint    = "http://otel-collector.observability.svc.cluster.local:4318"
    n8n_otel_exporter_service_name     = "n8n-prod"
    n8n_otel_traces_sample_rate        = 0.5
    n8n_otel_traces_include_node_spans = false
    n8n_otel_traces_inject_outbound    = true
  }

  assert {
    condition = (
      var.n8n_otel_enabled == true &&
      var.n8n_otel_exporter_otlp_endpoint != null &&
      var.n8n_otel_exporter_service_name == "n8n-prod" &&
      var.n8n_otel_traces_sample_rate == 0.5 &&
      var.n8n_otel_traces_include_node_spans == false &&
      var.n8n_otel_traces_inject_outbound == true
    )
    error_message = "Full opt-in path (master on + multiple tuning vars set) must remain plan-able."
  }
}

# ── n8n feature toggles (templates and personalization) ───────────────────────
# Both toggles default to true (feature enabled, no env var set). When disabled
# (false), they inject N8N_TEMPLATES_ENABLED=false or N8N_PERSONALIZATION_ENABLED=false.
# The Helm values blob is unknown at plan time under the mock provider, so we
# assert at the variable contract level; that the entries land in config.extraEnv
# is verified by a real terraform plan from the Terraform Cloud workspace.

run "feature_toggles_default_enabled" {
  command = plan

  assert {
    condition     = var.n8n_templates_enabled == true
    error_message = "n8n_templates_enabled must default to true to preserve current behavior."
  }

  assert {
    condition     = var.n8n_personalization_enabled == true
    error_message = "n8n_personalization_enabled must default to true to preserve current behavior."
  }
}

run "feature_toggles_accept_false" {
  command = plan

  variables {
    n8n_templates_enabled       = false
    n8n_personalization_enabled = false
  }

  assert {
    condition     = var.n8n_templates_enabled == false
    error_message = "n8n_templates_enabled should accept false to disable workflow templates."
  }

  assert {
    condition     = var.n8n_personalization_enabled == false
    error_message = "n8n_personalization_enabled should accept false to disable personalization."
  }
}

# ── Log streaming (Enterprise, managed via env vars) ──────────────────────────
# n8n_log_streaming_managed_by_env is the master switch (default false). The
# destinations list is typed `any` (webhook/syslog/sentry shapes differ) and is
# JSON-encoded into N8N_LOG_STREAMING_DESTINATIONS only when the master switch
# is on. The Helm values blob is unknown at plan time under the mock provider,
# so we assert at the variable contract level; the wiring into config.extraEnv
# is verified by a real terraform plan.

run "log_streaming_defaults_off" {
  command = plan

  assert {
    condition     = var.n8n_log_streaming_managed_by_env == false
    error_message = "n8n_log_streaming_managed_by_env must default to false: env-managed log streaming is opt-in."
  }

  assert {
    condition     = length(var.n8n_log_streaming_destinations) == 0
    error_message = "n8n_log_streaming_destinations must default to an empty list."
  }
}

run "log_streaming_rejects_invalid_destination_type" {
  command = plan

  variables {
    n8n_log_streaming_managed_by_env = true
    n8n_log_streaming_destinations = [
      { type = "kafka", label = "not-a-real-destination" },
    ]
  }

  expect_failures = [var.n8n_log_streaming_destinations]
}

run "log_streaming_rejects_string_instead_of_list" {
  command = plan

  variables {
    n8n_log_streaming_managed_by_env = true
    n8n_log_streaming_destinations   = "[{\"type\":\"webhook\"}]"
  }

  expect_failures = [var.n8n_log_streaming_destinations]
}

run "log_streaming_accepts_mixed_destinations" {
  command = plan

  variables {
    n8n_log_streaming_managed_by_env = true
    n8n_log_streaming_destinations = [
      {
        type             = "webhook"
        label            = "Audit"
        enabled          = true
        subscribedEvents = ["n8n.audit", "n8n.workflow"]
        url              = "https://hooks.example.com/n8n"
        method           = "POST"
      },
      {
        type  = "syslog"
        label = "SIEM"
      },
    ]
  }

  assert {
    condition     = length(var.n8n_log_streaming_destinations) == 2
    error_message = "n8n_log_streaming_destinations should accept a heterogeneous list of webhook/syslog/sentry objects."
  }
}

run "log_streaming_destinations_with_master_off_triggers_check_warning" {
  command = plan

  variables {
    n8n_log_streaming_managed_by_env = false
    n8n_log_streaming_destinations = [
      { type = "webhook", url = "https://hooks.example.com/n8n" },
    ]
  }

  expect_failures = [check.log_streaming_destinations_require_managed_by_env]
}

run "log_streaming_full_opt_in_plans_cleanly" {
  command = plan

  variables {
    n8n_log_streaming_managed_by_env = true
    n8n_log_streaming_destinations = [
      { type = "sentry", label = "Errors" },
    ]
  }

  assert {
    condition     = var.n8n_log_streaming_managed_by_env == true
    error_message = "Full opt-in path (master on + destinations set) must remain plan-able."
  }
}

# ── n8n_license_detach_floating_on_shutdown ─────────────────────────────────
# N8N_LICENSE_DETACH_FLOATING_ON_SHUTDOWN is asserted at the variable-contract
# level only: the Helm values blob is unknown at plan time under the mock
# provider (helm_release depends on kubernetes_namespace, which is "(known
# after apply)"), so the env var's actual value in config.extraEnv cannot be
# asserted here. Verify the wiring with a real terraform plan against
# n8n.tf's base env list.

run "license_detach_floating_on_shutdown_defaults_to_false" {
  command = plan

  assert {
    # Regression guard: n8n's upstream default is true, which zeroes the
    # shared floating license cert on leader shutdown in multi-main
    # deployments and crash-loops fresh main pods (issue #49). The module
    # must keep defaulting this to false.
    condition     = var.n8n_license_detach_floating_on_shutdown == false
    error_message = "n8n_license_detach_floating_on_shutdown must default to false to prevent multi-main crash-loops (see issue #49)."
  }
}

# ── n8n_extra_env ────────────────────────────────────────────────────────────
# Asserted at the variable-contract level: defaults, accepted shape, and the
# three validation guards (non-empty name, no duplicates, no collision with
# module-managed env vars). End-to-end wiring into config.extraEnv can't be
# checked here: helm_release.values depends on kubernetes_namespace (unknown at
# plan time), and command = apply under the mock providers fails ARN validation
# across IAM/RDS. Verify the wiring with a real terraform plan.

run "extra_env_defaults_to_empty" {
  command = plan

  assert {
    condition     = length(var.n8n_extra_env) == 0
    error_message = "n8n_extra_env must default to an empty list."
  }
}

run "extra_env_accepts_valid_entries" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_DEFAULT_LOCALE", value = "de" },
      { name = "N8N_PAYLOAD_SIZE_MAX", value = "32" },
    ]
  }

  assert {
    condition     = length(var.n8n_extra_env) == 2
    error_message = "n8n_extra_env should accept a list of {name, value} objects."
  }

  assert {
    condition     = var.n8n_extra_env[0].name == "N8N_DEFAULT_LOCALE"
    error_message = "n8n_extra_env entry name should propagate correctly."
  }

  assert {
    condition     = var.n8n_extra_env[0].value == "de"
    error_message = "n8n_extra_env entry value should propagate correctly."
  }
}

run "extra_env_rejects_empty_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "", value = "x" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

# Whitespace-padded names must be rejected: otherwise a name like " DB_HOST"
# would pass the duplicate and module-managed guards (which match on the raw
# string) while Kubernetes renders it as a distinct, ignored env var.
run "extra_env_rejects_whitespace_padded_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = " DB_POSTGRESDB_HOST", value = "evil.example.com" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "extra_env_rejects_duplicate_names" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_DEFAULT_LOCALE", value = "de" },
      { name = "N8N_DEFAULT_LOCALE", value = "en" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "extra_env_rejects_module_managed_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_LOG_LEVEL", value = "debug" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

# Regression guards: env vars the module started managing after this input was
# first written (templates/personalization, OTEL, log streaming) must also be
# rejected by the escape hatch: keep local.n8n_managed_env_names in sync.
run "extra_env_rejects_feature_toggle_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_PERSONALIZATION_ENABLED", value = "false" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "extra_env_rejects_otel_managed_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_OTEL_ENABLED", value = "false" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "extra_env_rejects_log_streaming_managed_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_LOG_STREAMING_MANAGED_BY_ENV", value = "true" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

# Prefix-family guards: connection, license, and AWS-credential vars the chart
# renders from module values must be rejected, because config.extraEnv is
# appended last and Kubernetes resolves duplicate env names last-wins: an
# override here would silently repoint the DB, disable Enterprise, or hijack
# storage credentials.
run "extra_env_rejects_db_connection_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "DB_POSTGRESDB_HOST", value = "evil.example.com" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "extra_env_rejects_queue_connection_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "QUEUE_BULL_REDIS_HOST", value = "evil.example.com" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "extra_env_rejects_license_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_LICENSE_ACTIVATION_KEY", value = "stolen-key" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "extra_env_rejects_aws_credentials_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "AWS_ACCESS_KEY_ID", value = "AKIAEXAMPLE" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

# Regression guard: N8N_LICENSE_DETACH_FLOATING_ON_SHUTDOWN became
# module-managed alongside the n8n_license_detach_floating_on_shutdown input
# (issue #49): an override here would silently re-enable n8n's unsafe
# upstream default and reintroduce the multi-main crash-loop.
run "extra_env_rejects_license_detach_floating_on_shutdown_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_LICENSE_DETACH_FLOATING_ON_SHUTDOWN", value = "true" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

# A genuinely non-managed var that happens to be timezone-related stays allowed:
# the chart sets TZ (blocked) but not GENERIC_TIMEZONE, so callers can set it.
run "extra_env_accepts_generic_timezone" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "GENERIC_TIMEZONE", value = "Europe/Berlin" },
    ]
  }

  assert {
    condition     = var.n8n_extra_env[0].name == "GENERIC_TIMEZONE"
    error_message = "GENERIC_TIMEZONE is not module-managed and should be accepted."
  }
}

run "image_tag_defaults_to_null" {
  command = plan

  assert {
    condition     = var.n8n_image_tag == null
    error_message = "n8n_image_tag should default to null so the chart's own stable tag applies by default."
  }
}

run "image_tag_accepts_concrete_version" {
  command = plan

  # Asserts at the variable contract level only: helm_release.values is
  # unknown at plan time under the mock provider (it depends on
  # kubernetes_namespace, which is "(known after apply)"), so the merge()
  # wiring of image.tag into the Helm values cannot be verified here.
  # To verify end-to-end: run `terraform plan` from examples/small/ with
  # n8n_image_tag = "2.27.4" and confirm `image.tag` appears in the
  # helm_release.n8n plan output.
  variables {
    n8n_image_tag = "2.27.4"
  }

  assert {
    condition     = var.n8n_image_tag == "2.27.4"
    error_message = "n8n_image_tag should accept a concrete version string."
  }
}

run "image_tag_rejects_empty_string" {
  command = plan

  variables {
    n8n_image_tag = ""
  }

  expect_failures = [var.n8n_image_tag]
}

run "image_tag_rejects_whitespace_padded_value" {
  command = plan

  variables {
    n8n_image_tag = " 1.2.3 "
  }

  expect_failures = [var.n8n_image_tag]
}

run "image_tag_accepts_leading_underscore" {
  command = plan

  variables {
    n8n_image_tag = "_1.2.3"
  }

  assert {
    condition     = var.n8n_image_tag == "_1.2.3"
    error_message = "n8n_image_tag should accept a leading underscore: valid per Docker tag spec."
  }
}

run "image_tag_rejects_overlong_tag" {
  command = plan

  variables {
    # 129 characters: one over the Docker limit of 128
    n8n_image_tag = "a${join("", [for i in range(128) : "b"])}"
  }

  expect_failures = [var.n8n_image_tag]
}

# ── n8n_image_repository ──────────────────────────────────────────────────────
# Same coverage shape as n8n_image_tag above, and for the same reason limited to
# the variable contract: helm_release.values is unknown at plan time under the
# mock provider, so the merge() of image.repository into the Helm values cannot
# be asserted here. To verify end-to-end: run `terraform plan` from
# examples/small/ with n8n_image_repository set and confirm `image.repository`
# appears in the helm_release.n8n plan output.

run "image_repository_defaults_to_null" {
  command = plan

  assert {
    condition     = var.n8n_image_repository == null
    error_message = "n8n_image_repository should default to null so the chart's own repository (docker.n8n.io/n8nio/n8n) applies by default."
  }
}

run "image_repository_accepts_ecr_reference" {
  command = plan

  # A complete custom-image config: repository, tag, and the runner tag the
  # chart cannot derive from a non-version tag. This is the shape the three
  # custom-image check blocks are all satisfied by, so it must plan clean.
  variables {
    n8n_image_repository      = "123456789012.dkr.ecr.eu-west-1.amazonaws.com/n8n"
    n8n_image_tag             = "2.27.4-mypackages"
    n8n_task_runner_image_tag = "2.27.4"
  }

  assert {
    condition     = var.n8n_image_repository == "123456789012.dkr.ecr.eu-west-1.amazonaws.com/n8n"
    error_message = "n8n_image_repository should accept a registry-qualified ECR repository."
  }
}

run "image_repository_accepts_registry_port" {
  command = plan

  variables {
    n8n_image_repository      = "registry.internal:5000/n8n/n8n"
    n8n_image_tag             = "2.27.4"
    n8n_task_runner_image_tag = "2.27.4"
  }

  assert {
    condition     = var.n8n_image_repository == "registry.internal:5000/n8n/n8n"
    error_message = "n8n_image_repository should accept a registry host with an explicit port; the colon only appears in the host segment."
  }
}

run "image_repository_rejects_empty_string" {
  command = plan

  variables {
    n8n_image_repository = ""
  }

  expect_failures = [var.n8n_image_repository]
}

run "image_repository_rejects_whitespace_padded_value" {
  command = plan

  variables {
    n8n_image_repository = " myregistry.example.com/n8n "
  }

  expect_failures = [var.n8n_image_repository]
}

# The chart renders `{{ .Values.image.repository }}:{{ .Values.image.tag }}`, so
# an inlined tag would yield "myregistry.example.com/n8n:2.27.4:stable".
run "image_repository_rejects_inline_tag" {
  command = plan

  variables {
    n8n_image_repository = "myregistry.example.com/n8n:2.27.4"
  }

  expect_failures = [var.n8n_image_repository]
}

run "image_repository_rejects_digest" {
  command = plan

  variables {
    n8n_image_repository = "myregistry.example.com/n8n@sha256:0123456789abcdef"
  }

  expect_failures = [var.n8n_image_repository]
}

# A URL is the intuitive thing to paste in, and a character whitelist accepted
# it: the scheme's own characters are all legal in a repository reference. It
# then reaches the chart and fails as an unpullable image after the cluster is
# already up, which is exactly what plan-time validation is for.
run "image_repository_rejects_scheme_prefix" {
  command = plan

  variables {
    n8n_image_repository = "https://myregistry.example.com/n8n"
  }

  expect_failures = [var.n8n_image_repository]
}

# Only the first segment may carry a port. A second colon is a typo, not a
# reference the registry could resolve.
run "image_repository_rejects_multiple_colons" {
  command = plan

  variables {
    n8n_image_repository = "registry.internal:5000:bad/n8n"
  }

  expect_failures = [var.n8n_image_repository]
}

# An empty path component renders as "myregistry.example.com/n8n/:2.27.4" once
# the chart appends the tag.
run "image_repository_rejects_trailing_slash" {
  command = plan

  variables {
    n8n_image_repository = "myregistry.example.com/n8n/"
  }

  expect_failures = [var.n8n_image_repository]
}

run "image_repository_rejects_consecutive_slashes" {
  command = plan

  variables {
    n8n_image_repository = "myregistry.example.com//n8n"
  }

  expect_failures = [var.n8n_image_repository]
}

# Docker rejects this itself: "repository name (N8N) must be lowercase".
run "image_repository_rejects_uppercase_path_component" {
  command = plan

  variables {
    n8n_image_repository = "myregistry.example.com/N8N"
  }

  expect_failures = [var.n8n_image_repository]
}

# The mirror image of the rule above: DNS is case-insensitive and Docker does
# accept an uppercase registry host, so the validation must not reject one.
run "image_repository_accepts_uppercase_registry_host" {
  command = plan

  variables {
    n8n_image_repository      = "MyRegistry.example.com/n8n"
    n8n_image_tag             = "2.27.4"
    n8n_task_runner_image_tag = "2.27.4"
  }

  assert {
    condition     = var.n8n_image_repository == "MyRegistry.example.com/n8n"
    error_message = "n8n_image_repository should accept an uppercase registry host, which Docker resolves case-insensitively; only path components must be lowercase."
  }
}

# Docker Hub short form, where the first segment is a namespace rather than a
# registry host. It has no dot and no port, so it must satisfy the lowercase
# path-component rule rather than the host rule.
run "image_repository_accepts_docker_hub_short_form" {
  command = plan

  variables {
    n8n_image_repository      = "n8nio/n8n"
    n8n_image_tag             = "2.27.4"
    n8n_task_runner_image_tag = "2.27.4"
  }

  assert {
    condition     = var.n8n_image_repository == "n8nio/n8n"
    error_message = "n8n_image_repository should accept the Docker Hub short form (namespace/repository) with no registry host."
  }
}

# Docker's path-component separator is `[._] | __ | -+`, so a doubled hyphen or
# underscore is legal even though a doubled dot is not. An earlier attempt at
# this validation allowed only a single separator character and rejected these,
# which is the worse failure: a plan-time rejection blocks a caller outright,
# with no override, over an image the registry would have served.
run "image_repository_accepts_doubled_separators" {
  command = plan

  variables {
    n8n_image_repository      = "myregistry.example.com/my--repo__v2"
    n8n_image_tag             = "2.27.4"
    n8n_task_runner_image_tag = "2.27.4"
  }

  assert {
    condition     = var.n8n_image_repository == "myregistry.example.com/my--repo__v2"
    error_message = "n8n_image_repository should accept doubled hyphen and underscore separators in a path component, which Docker's name grammar permits."
  }
}

# The counterpart to the rule above: a doubled dot is not a legal separator, in
# a path component or in a host label.
run "image_repository_rejects_doubled_dot_in_path" {
  command = plan

  variables {
    n8n_image_repository = "myregistry.example.com/a..b"
  }

  expect_failures = [var.n8n_image_repository]
}

run "image_repository_rejects_empty_host_label" {
  command = plan

  variables {
    n8n_image_repository = "a..b.example.com/n8n"
  }

  expect_failures = [var.n8n_image_repository]
}

# A host label may contain hyphens but may not end in one, so an internal
# doubled hyphen is fine (xn-- punycode relies on it) and a trailing one is not.
run "image_repository_rejects_host_label_ending_in_hyphen" {
  command = plan

  variables {
    n8n_image_repository = "foo-.example.com/n8n"
  }

  expect_failures = [var.n8n_image_repository]
}

run "image_repository_accepts_punycode_host" {
  command = plan

  variables {
    n8n_image_repository      = "xn--bcher-kva.example.com/n8n"
    n8n_image_tag             = "2.27.4"
    n8n_task_runner_image_tag = "2.27.4"
  }

  assert {
    condition     = var.n8n_image_repository == "xn--bcher-kva.example.com/n8n"
    error_message = "n8n_image_repository should accept a punycode registry host, whose labels legitimately contain a doubled hyphen."
  }
}

# Docker's splitDockerDomain treats a first component as a registry host when it
# contains a dot or a colon, is localhost, *or contains an uppercase letter*.
# So this is a host named N8NIO, not an illegally-uppercase namespace, and
# docker pulls it. Reading the lowercase rule as applying to the first component
# too rejects a reference that works.
run "image_repository_accepts_uppercase_single_label_host" {
  command = plan

  variables {
    n8n_image_repository      = "N8NIO/n8n"
    n8n_image_tag             = "2.27.4"
    n8n_task_runner_image_tag = "2.27.4"
  }

  assert {
    condition     = var.n8n_image_repository == "N8NIO/n8n"
    error_message = "n8n_image_repository should accept an uppercase single-label registry host: Docker promotes any uppercase first component to a host rather than treating it as a path component."
  }
}

# The boundary of the rule above. FOO is promoted to a host, which leaves BAR as
# a path component, and that one really must be lowercase.
run "image_repository_rejects_uppercase_after_promoted_host" {
  command = plan

  variables {
    n8n_image_repository = "FOO/BAR"
  }

  expect_failures = [var.n8n_image_repository]
}

# A registry reachable only over IPv6 is addressed with a bracketed literal.
run "image_repository_accepts_bracketed_ipv6_host" {
  command = plan

  variables {
    n8n_image_repository      = "[2001:db8::1]:5000/n8n"
    n8n_image_tag             = "2.27.4"
    n8n_task_runner_image_tag = "2.27.4"
  }

  assert {
    condition     = var.n8n_image_repository == "[2001:db8::1]:5000/n8n"
    error_message = "n8n_image_repository should accept a bracketed IPv6 registry host, which Docker's reference grammar allows."
  }
}

# A zone ID is valid in a URI host but not in a Docker reference.
run "image_repository_rejects_ipv6_zone_id" {
  command = plan

  variables {
    n8n_image_repository = "[fe80::1%25eth0]:5000/n8n"
  }

  expect_failures = [var.n8n_image_repository]
}

# Docker's bracketed host is hex and colons only. A dot inside the brackets is
# rejected even in the IPv4-mapped form that looks like it ought to work.
run "image_repository_rejects_ipv4_mapped_ipv6_host" {
  command = plan

  variables {
    n8n_image_repository = "[::ffff:1.2.3.4]:5000/n8n"
  }

  expect_failures = [var.n8n_image_repository]
}

run "image_repository_rejects_non_hex_ipv6_host" {
  command = plan

  variables {
    n8n_image_repository = "[gggg::1]/n8n"
  }

  expect_failures = [var.n8n_image_repository]
}

# Not a typo in the test: docker accepts this, so the validation must too.
# Tightening past docker would reject an address a registry would answer on,
# and a variable validation has no override.
run "image_repository_accepts_what_docker_accepts_in_brackets" {
  command = plan

  variables {
    n8n_image_repository      = "[::::]:5000/n8n"
    n8n_image_tag             = "2.27.4"
    n8n_task_runner_image_tag = "2.27.4"
  }

  assert {
    condition     = var.n8n_image_repository == "[::::]:5000/n8n"
    error_message = "n8n_image_repository should accept any bracketed hex-and-colon host that docker accepts, including structurally meaningless ones; this validation deliberately does not out-strict docker."
  }
}

# ── n8n_task_runner_image_tag ─────────────────────────────────────────────────
# The chart derives the runner sidecar's tag from image.tag, so a custom
# application-image tag that is not a published n8n version needs this override
# or main and worker pods land in ImagePullBackOff.

run "task_runner_image_tag_defaults_to_null" {
  command = plan

  assert {
    condition     = var.n8n_task_runner_image_tag == null
    error_message = "n8n_task_runner_image_tag should default to null so the chart keeps inheriting the n8n application image's tag."
  }
}

run "task_runner_image_tag_accepts_concrete_version" {
  command = plan

  variables {
    n8n_image_repository      = "myregistry.example.com/n8n"
    n8n_image_tag             = "2.27.4-mypackages"
    n8n_task_runner_image_tag = "2.27.4"
  }

  assert {
    condition     = var.n8n_task_runner_image_tag == "2.27.4"
    error_message = "n8n_task_runner_image_tag should accept the underlying n8n version when the app image tag is custom."
  }
}

run "task_runner_image_tag_rejects_empty_string" {
  command = plan

  variables {
    n8n_task_runner_image_tag = ""
  }

  expect_failures = [var.n8n_task_runner_image_tag]
}

run "task_runner_image_tag_rejects_whitespace_padded_value" {
  command = plan

  variables {
    n8n_task_runner_image_tag = " 2.27.4 "
  }

  expect_failures = [var.n8n_task_runner_image_tag]
}

# ── Custom image check blocks ─────────────────────────────────────────────────
# These warn rather than fail, so expect_failures on the check is how a warning
# is asserted (same pattern as the ingress and RDS tuning checks above).

# A repository with no tag resolves to "<repo>:stable" via the chart default,
# which a private registry almost never publishes.
run "custom_image_repository_without_tag_warns" {
  command = plan

  variables {
    n8n_image_repository = "myregistry.example.com/n8n"
  }

  expect_failures = [check.custom_image_repository_needs_an_explicit_tag]
}

# A custom image tag with task runners enabled and no runner tag is the
# ImagePullBackOff case: the sidecar inherits a tag that does not exist upstream.
run "custom_image_without_task_runner_tag_warns" {
  command = plan

  variables {
    n8n_image_repository = "myregistry.example.com/n8n"
    n8n_image_tag        = "2.27.4-mypackages"
  }

  expect_failures = [check.custom_image_tag_needs_a_task_runner_tag]
}

run "task_runner_image_tag_without_task_runners_warns" {
  command = plan

  variables {
    n8n_task_runners_enabled  = false
    n8n_task_runner_image_tag = "2.27.4"
  }

  expect_failures = [check.task_runner_image_tag_requires_task_runners]
}

# The chart's own repository with a plain version pin is the common case and
# must not trip the custom-image checks: no repository override means the runner
# sidecar's inherited tag is a published n8n version.
run "chart_repository_with_version_pin_does_not_warn" {
  command = plan

  variables {
    n8n_image_tag = "2.27.4"
  }

  assert {
    condition     = var.n8n_image_repository == null
    error_message = "Pinning only n8n_image_tag must stay a clean configuration with no custom-image warnings."
  }
}

# ── n8n_custom_extensions_path ────────────────────────────────────────────────
# The supported way to load nodes baked into a custom image: since n8n 1.0 the
# loader ignores the image's global node_modules, so N8N_CUSTOM_EXTENSIONS is
# what makes baked nodes visible.

run "custom_extensions_path_defaults_to_null" {
  command = plan

  assert {
    condition     = var.n8n_custom_extensions_path == null
    error_message = "n8n_custom_extensions_path should default to null so N8N_CUSTOM_EXTENSIONS is omitted entirely."
  }
}

run "custom_extensions_path_accepts_absolute_path" {
  command = plan

  variables {
    n8n_image_repository       = "myregistry.example.com/n8n"
    n8n_image_tag              = "2.27.4-mypackages"
    n8n_task_runner_image_tag  = "2.27.4"
    n8n_custom_extensions_path = "/opt/n8n-nodes"
  }

  assert {
    condition     = var.n8n_custom_extensions_path == "/opt/n8n-nodes"
    error_message = "n8n_custom_extensions_path should accept an absolute container path."
  }
}

run "custom_extensions_path_rejects_relative_path" {
  command = plan

  variables {
    n8n_custom_extensions_path = "opt/n8n-nodes"
  }

  expect_failures = [var.n8n_custom_extensions_path]
}

# n8n splits N8N_CUSTOM_EXTENSIONS on ";" and registers every custom directory
# under the same CUSTOM key, so all but the last are silently dropped. Reject
# the separator rather than let a caller lose nodes to it.
run "custom_extensions_path_rejects_semicolon_separated_list" {
  command = plan

  variables {
    n8n_custom_extensions_path = "/opt/n8n-nodes;/opt/more-nodes"
  }

  expect_failures = [var.n8n_custom_extensions_path]
}

# The chart mounts an emptyDir at /home/node/.n8n on main pods only, so a path
# under it loads on workers and webhook processors but not on mains.
run "custom_extensions_path_rejects_the_shadowed_n8n_home" {
  command = plan

  variables {
    n8n_custom_extensions_path = "/home/node/.n8n/custom"
  }

  expect_failures = [var.n8n_custom_extensions_path]
}

run "custom_extensions_path_rejects_n8n_home_itself" {
  command = plan

  variables {
    n8n_custom_extensions_path = "/home/node/.n8n"
  }

  expect_failures = [var.n8n_custom_extensions_path]
}

# The shadowing check is a string comparison, so these three spellings of the
# mounted directory would pass it while resolving inside the mount in the
# container. The canonical-path rule is what closes that gap.
run "custom_extensions_path_rejects_a_doubled_slash" {
  command = plan

  variables {
    n8n_custom_extensions_path = "/home/node//.n8n/custom"
  }

  expect_failures = [var.n8n_custom_extensions_path]
}

run "custom_extensions_path_rejects_a_dot_component" {
  command = plan

  variables {
    n8n_custom_extensions_path = "/home/node/./.n8n/custom"
  }

  expect_failures = [var.n8n_custom_extensions_path]
}

run "custom_extensions_path_rejects_a_parent_component" {
  command = plan

  variables {
    n8n_custom_extensions_path = "/opt/../home/node/.n8n/custom"
  }

  expect_failures = [var.n8n_custom_extensions_path]
}

# A component may legitimately begin with a dot (.n8n is one), so the canonical
# rule must reject only the exact "." and ".." components, not any leading dot.
run "custom_extensions_path_accepts_a_dotfile_component" {
  command = plan

  variables {
    n8n_image_repository       = "myregistry.example.com/n8n"
    n8n_image_tag              = "2.27.4-mypackages"
    n8n_task_runner_image_tag  = "2.27.4"
    n8n_custom_extensions_path = "/opt/.n8n-nodes"
  }

  assert {
    condition     = var.n8n_custom_extensions_path == "/opt/.n8n-nodes"
    error_message = "A leading dot is an ordinary directory name and must not trip the canonical-path rule."
  }
}

# Nothing places files at the path: no custom image and no volume mount.
run "custom_extensions_path_without_a_source_warns" {
  command = plan

  variables {
    n8n_custom_extensions_path = "/opt/n8n-nodes"
  }

  expect_failures = [check.custom_extensions_path_requires_a_source]
}

run "extra_env_rejects_custom_extensions_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_CUSTOM_EXTENSIONS", value = "/opt/n8n-nodes" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

# ── n8n_image_pull_secrets ────────────────────────────────────────────────────
# The chart renders imagePullSecrets nowhere, so these reach the pods only
# because the module takes the ServiceAccount over. The load-bearing assertion
# is the negative one: an existing deployment must not find the chart's account
# swapped out from under it just because this input now exists.

run "image_pull_secrets_default_to_empty_and_leave_the_account_to_the_chart" {
  command = plan

  assert {
    condition     = length(var.n8n_image_pull_secrets) == 0
    error_message = "n8n_image_pull_secrets must default to an empty list."
  }

  assert {
    condition     = length(kubernetes_service_account_v1.n8n) == 0
    error_message = "With no pull secrets the module must create no ServiceAccount, leaving serviceAccount.create = true and the chart in charge."
  }
}

run "image_pull_secrets_move_the_account_to_the_module" {
  command = plan

  variables {
    n8n_image_repository      = "myregistry.example.com/n8n"
    n8n_image_tag             = "2.27.4-mypackages"
    n8n_task_runner_image_tag = "2.27.4"
    n8n_image_pull_secrets    = ["registry-creds", "fallback-registry-creds"]
  }

  assert {
    condition     = length(kubernetes_service_account_v1.n8n) == 1
    error_message = "A non-empty n8n_image_pull_secrets must make the module create the ServiceAccount, because the chart has no way to carry the secrets."
  }

  # image_pull_secret is a set in the provider schema, so order proves nothing.
  assert {
    condition = toset([
      for secret in kubernetes_service_account_v1.n8n[0].image_pull_secret : secret.name
    ]) == toset(["registry-creds", "fallback-registry-creds"])
    error_message = "Every name in n8n_image_pull_secrets must land on the ServiceAccount; a dropped one is an ImagePullBackOff at pod start."
  }

  # The name is the contract between three places: the chart's
  # serviceAccount.name, this resource, and the Pod Identity association that
  # grants S3 access. Drift here costs the pods their AWS credentials, and the
  # symptom (binary data writes failing) points nowhere near the cause.
  assert {
    condition     = kubernetes_service_account_v1.n8n[0].metadata[0].name == aws_eks_pod_identity_association.s3.service_account
    error_message = "The module's ServiceAccount must carry the same name the S3 Pod Identity association binds to."
  }

  # The provider defaults this to false, which the chart never does. Left
  # unset, taking over the account would quietly stop mounting the token.
  assert {
    condition     = kubernetes_service_account_v1.n8n[0].automount_service_account_token
    error_message = "The module's ServiceAccount must mount its token, matching what the chart-created account does."
  }
}

run "image_pull_secrets_reject_a_non_dns_name" {
  command = plan

  variables {
    n8n_image_pull_secrets = ["Not_A_Secret_Name"]
  }

  expect_failures = [var.n8n_image_pull_secrets]
}

run "image_pull_secrets_reject_an_overlong_name" {
  command = plan

  variables {
    # 254 characters, one past the Kubernetes limit.
    n8n_image_pull_secrets = ["a-${join("", [for i in range(84) : "abc"])}"]
  }

  expect_failures = [var.n8n_image_pull_secrets]
}

run "image_pull_secrets_reject_a_repeated_name" {
  command = plan

  variables {
    n8n_image_pull_secrets = ["registry-creds", "registry-creds"]
  }

  expect_failures = [var.n8n_image_pull_secrets]
}

# Pointless rather than harmful, but it costs the caller the chart-owned
# ServiceAccount for nothing, so it warns instead of passing silently.
run "image_pull_secrets_without_custom_image_warns" {
  command = plan

  variables {
    n8n_image_pull_secrets = ["registry-creds"]
  }

  expect_failures = [check.image_pull_secrets_need_a_custom_image]
}

# Turning the input on for a deployment that already exists is the case worth
# protecting. The module's account is created before the Helm upgrade runs, so
# reusing the chart's name would try to create an object the release still
# owns and stop the apply at "already exists" with nothing changed.
run "the_module_service_account_does_not_reuse_the_charts_name" {
  command = plan

  variables {
    n8n_image_repository      = "myregistry.example.com/n8n"
    n8n_image_tag             = "2.27.4-mypackages"
    n8n_task_runner_image_tag = "2.27.4"
    n8n_image_pull_secrets    = ["registry-creds"]
  }

  assert {
    condition     = kubernetes_service_account_v1.n8n[0].metadata[0].name != "n8n-enterprise"
    error_message = "The module-created ServiceAccount must not take the name the chart uses when it creates its own, or enabling n8n_image_pull_secrets on a live deployment fails before Helm can hand the account over."
  }
}

# ── n8n_extra_volumes / n8n_extra_volume_mounts ───────────────────────────────
# Every rejection below is something Kubernetes would refuse at pod admission,
# or worse accept and then behave unexpectedly. The point of checking at plan
# time is that the alternative is a cluster that applies and then does not run.

run "extra_volumes_default_to_empty" {
  command = plan

  assert {
    condition     = length(var.n8n_extra_volumes) == 0 && length(var.n8n_extra_volume_mounts) == 0
    error_message = "Both extra volume inputs must default to an empty list, matching the chart's own defaults so an unset caller sees no change."
  }
}

# The wiring test. snake_case in, chart camelCase out, and the octal string
# converted to the integer Kubernetes wants: 0644 is 420, not 644.
run "extra_volumes_translate_to_the_chart_shape" {
  command = plan

  variables {
    n8n_extra_volumes = [
      {
        name       = "custom-nodes"
        config_map = { name = "n8n-custom-nodes", default_mode = "0644" }
      },
      {
        name                    = "shared-nodes"
        persistent_volume_claim = { claim_name = "n8n-nodes-efs", read_only = true }
      },
    ]
    n8n_extra_volume_mounts = [
      { name = "custom-nodes", mount_path = "/opt/n8n-nodes" },
      { name = "shared-nodes", mount_path = "/opt/shared-nodes", sub_path = "nodes" },
    ]
  }

  assert {
    condition = local.n8n_extra_volumes[0] == {
      name      = "custom-nodes"
      configMap = { name = "n8n-custom-nodes", defaultMode = 420 }
    }
    error_message = "A config_map volume must render as configMap with defaultMode as the integer Kubernetes expects; \"0644\" is 420, and emitting 644 would be octal 1204."
  }

  assert {
    condition = local.n8n_extra_volumes[1] == {
      name                  = "shared-nodes"
      persistentVolumeClaim = { claimName = "n8n-nodes-efs", readOnly = true }
    }
    error_message = "A persistent_volume_claim volume must render as persistentVolumeClaim/claimName."
  }

  assert {
    condition = local.n8n_extra_volume_mounts == [
      { name = "custom-nodes", mountPath = "/opt/n8n-nodes", readOnly = true },
      { name = "shared-nodes", mountPath = "/opt/shared-nodes", readOnly = true, subPath = "nodes" },
    ]
    error_message = "Mounts must render as camelCase, keep their order, default readOnly to true, and omit subPath when it is unset rather than emitting null."
  }
}

# The reason this input exists: nodes from a volume instead of from an image.
# With a mount covering the path there is no warning, which is what makes the
# volume route a supported alternative rather than a tolerated one.
run "extra_volume_mount_satisfies_the_custom_extensions_path" {
  command = plan

  variables {
    n8n_custom_extensions_path = "/opt/n8n-nodes"
    n8n_extra_volumes = [
      { name = "custom-nodes", config_map = { name = "n8n-custom-nodes" } },
    ]
    n8n_extra_volume_mounts = [
      { name = "custom-nodes", mount_path = "/opt/n8n-nodes" },
    ]
  }

  assert {
    condition     = local.n8n_extra_volume_mounts[0].mountPath == var.n8n_custom_extensions_path
    error_message = "The mount must land on the path n8n scans, otherwise the nodes are present in the pod and still never loaded."
  }
}

# A mount above the path counts too: /opt carries /opt/n8n-nodes with it.
run "extra_volume_mount_above_the_custom_extensions_path_satisfies_it" {
  command = plan

  variables {
    n8n_custom_extensions_path = "/opt/n8n-nodes"
    n8n_extra_volumes = [
      { name = "custom-nodes", config_map = { name = "n8n-custom-nodes" } },
    ]
    n8n_extra_volume_mounts = [
      { name = "custom-nodes", mount_path = "/opt" },
    ]
  }

  assert {
    condition     = length(local.n8n_extra_volume_mounts) == 1
    error_message = "The mount must reach the chart values for the check above it to mean anything."
  }
}

run "extra_volumes_reject_a_reserved_name" {
  command = plan

  variables {
    n8n_extra_volumes = [
      { name = "data", config_map = { name = "n8n-custom-nodes" } },
    ]
  }

  expect_failures = [var.n8n_extra_volumes]
}

run "extra_volumes_reject_a_repeated_name" {
  command = plan

  variables {
    n8n_extra_volumes = [
      { name = "custom-nodes", config_map = { name = "one" } },
      { name = "custom-nodes", config_map = { name = "two" } },
    ]
  }

  expect_failures = [var.n8n_extra_volumes]
}

run "extra_volumes_reject_a_volume_with_no_source" {
  command = plan

  variables {
    n8n_extra_volumes = [{ name = "custom-nodes" }]
  }

  expect_failures = [var.n8n_extra_volumes]
}

run "extra_volumes_reject_a_volume_with_two_sources" {
  command = plan

  variables {
    n8n_extra_volumes = [
      {
        name       = "custom-nodes"
        config_map = { name = "n8n-custom-nodes" }
        secret     = { secret_name = "n8n-custom-nodes" }
      },
    ]
  }

  expect_failures = [var.n8n_extra_volumes]
}

run "extra_volumes_reject_a_non_octal_default_mode" {
  command = plan

  variables {
    n8n_extra_volumes = [
      { name = "custom-nodes", config_map = { name = "n8n-custom-nodes", default_mode = "0999" } },
    ]
  }

  expect_failures = [var.n8n_extra_volumes]
}

run "extra_volume_mounts_reject_an_undeclared_volume" {
  command = plan

  variables {
    n8n_extra_volumes = [
      { name = "custom-nodes", config_map = { name = "n8n-custom-nodes" } },
    ]
    n8n_extra_volume_mounts = [
      { name = "custom-noeds", mount_path = "/opt/n8n-nodes" },
    ]
  }

  expect_failures = [var.n8n_extra_volume_mounts]
}

run "extra_volume_mounts_reject_a_relative_path" {
  command = plan

  variables {
    n8n_extra_volumes = [
      { name = "custom-nodes", config_map = { name = "n8n-custom-nodes" } },
    ]
    n8n_extra_volume_mounts = [
      { name = "custom-nodes", mount_path = "opt/n8n-nodes" },
    ]
  }

  expect_failures = [var.n8n_extra_volume_mounts]
}

# The chart mounts its own `data` volume there on main pods, and two mounts on
# one path is a pod spec the API server rejects outright.
run "extra_volume_mounts_reject_the_chart_data_mount_path" {
  command = plan

  variables {
    n8n_extra_volumes = [
      { name = "custom-nodes", config_map = { name = "n8n-custom-nodes" } },
    ]
    n8n_extra_volume_mounts = [
      { name = "custom-nodes", mount_path = "/home/node/.n8n" },
    ]
  }

  expect_failures = [var.n8n_extra_volume_mounts]
}

# The same directory under a second spelling. Without this rule it would slip
# past the check above, which is a string comparison.
run "extra_volume_mounts_reject_a_trailing_slash" {
  command = plan

  variables {
    n8n_extra_volumes = [
      { name = "custom-nodes", config_map = { name = "n8n-custom-nodes" } },
    ]
    n8n_extra_volume_mounts = [
      { name = "custom-nodes", mount_path = "/home/node/.n8n/" },
    ]
  }

  expect_failures = [var.n8n_extra_volume_mounts]
}

run "extra_volume_mounts_reject_a_repeated_path" {
  command = plan

  variables {
    n8n_extra_volumes = [
      { name = "custom-nodes", config_map = { name = "one" } },
      { name = "other-nodes", config_map = { name = "two" } },
    ]
    n8n_extra_volume_mounts = [
      { name = "custom-nodes", mount_path = "/opt/n8n-nodes" },
      { name = "other-nodes", mount_path = "/opt/n8n-nodes" },
    ]
  }

  expect_failures = [var.n8n_extra_volume_mounts]
}

# Accepted by Kubernetes, so it warns rather than fails: the pods come up and
# the files are simply not where the caller expected them.
run "unmounted_extra_volume_warns" {
  command = plan

  variables {
    n8n_extra_volumes = [
      { name = "custom-nodes", config_map = { name = "n8n-custom-nodes" } },
    ]
  }

  expect_failures = [check.extra_volumes_should_be_mounted]
}

# ── n8n_community_packages_registry ───────────────────────────────────────────

run "community_packages_registry_defaults_to_null" {
  command = plan

  assert {
    condition     = var.n8n_community_packages_registry == null
    error_message = "n8n_community_packages_registry should default to null so the env var is omitted and n8n's own default (https://registry.npmjs.org) applies."
  }
}

run "community_packages_registry_accepts_private_mirror" {
  command = plan

  variables {
    n8n_community_packages_registry = "https://npm.internal.example.com"
  }

  assert {
    condition     = var.n8n_community_packages_registry == "https://npm.internal.example.com"
    error_message = "n8n_community_packages_registry should accept a private HTTPS mirror URL."
  }
}

run "community_packages_registry_rejects_bare_hostname" {
  command = plan

  variables {
    n8n_community_packages_registry = "npm.internal.example.com"
  }

  expect_failures = [var.n8n_community_packages_registry]
}

run "community_packages_registry_rejects_whitespace_padded_value" {
  command = plan

  variables {
    n8n_community_packages_registry = " https://npm.internal.example.com "
  }

  expect_failures = [var.n8n_community_packages_registry]
}

# A scheme check alone passed this, and n8n only surfaces it when a caller
# first tries to install a package.
run "community_packages_registry_rejects_scheme_without_host" {
  command = plan

  variables {
    n8n_community_packages_registry = "https://"
  }

  expect_failures = [var.n8n_community_packages_registry]
}

run "community_packages_registry_rejects_non_numeric_port" {
  command = plan

  variables {
    n8n_community_packages_registry = "https://npm.internal.example.com:notaport"
  }

  expect_failures = [var.n8n_community_packages_registry]
}

run "community_packages_registry_accepts_port_and_path" {
  command = plan

  variables {
    n8n_community_packages_registry = "https://npm.internal.example.com:4873/repository/npm-group"
  }

  assert {
    condition     = var.n8n_community_packages_registry == "https://npm.internal.example.com:4873/repository/npm-group"
    error_message = "n8n_community_packages_registry should accept a mirror URL carrying an explicit port and a repository path, which Nexus and Artifactory both use."
  }
}

# Regression guard: N8N_COMMUNITY_PACKAGES_REGISTRY became module-managed
# alongside the n8n_community_packages_registry input, so the escape hatch must
# reject it and send callers to the dedicated input.
run "extra_env_rejects_community_packages_registry_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_COMMUNITY_PACKAGES_REGISTRY", value = "https://npm.internal.example.com" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

# The private-registry auth token stays caller-managed (it is a credential the
# module deliberately does not render), so it must remain accepted here.
run "extra_env_accepts_community_packages_auth_token" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_COMMUNITY_PACKAGES_AUTH_TOKEN", value = "npm-token-placeholder" },
    ]
  }

  assert {
    condition     = var.n8n_extra_env[0].name == "N8N_COMMUNITY_PACKAGES_AUTH_TOKEN"
    error_message = "N8N_COMMUNITY_PACKAGES_AUTH_TOKEN is not module-managed and should stay settable via n8n_extra_env."
  }
}

# ── Autoscaling capacity against the node group ──────────────────────────────
# The autoscaler ceilings, the per-pod CPU requests, and node_max ×
# node_instance_type have to be sized together: nothing in Kubernetes couples
# them, so a ceiling above what the node group can hold just produces Pending
# pods once the Cluster Autoscaler runs out of nodes (issue #51). scaling.tf
# models the CPU arithmetic and warns; these runs pin both the shipped defaults
# and the warning's boundaries.
#
# The model reads vCPU off the instance size rather than the EC2 API, so these
# numbers are deterministic under mocks with nothing to override. At the default
# t3.xlarge: 6 nodes × (4,000m − 80m kubelet reserve − 180m of per-node
# DaemonSets) − 720m of cluster add-ons ≈ 21,720m available to n8n, against
# 16,600m requested at the default ceilings. The remainder is headroom for a
# rollout surge. scaling.tf documents where each constant in that sum comes from.

run "autoscaling_defaults_fit_the_default_node_group" {
  command = plan

  # No expect_failures: a warning from the capacity check would fail this run,
  # which is the assertion that matters here. The replica asserts pin the
  # defaults that make it hold.
  assert {
    condition     = kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook[0].spec[0].max_replicas == 8
    error_message = "The webhook HPA ceiling must default to 8, which the default node group can schedule alongside the main and worker ceilings"
  }

  assert {
    condition     = kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook[0].spec[0].min_replicas == 2
    error_message = "The webhook HPA floor must stay at 2 for multi-replica availability"
  }

  assert {
    condition     = aws_eks_node_group.n8n[0].scaling_config[0].max_size == 6
    error_message = "node_max must default to 6; the HPA and KEDA ceilings are sized against it"
  }
}

# The pre-fix defaults: 20 mains at 1,200m each (pod + task runner sidecar) is
# 24,000m on its own, more than the whole node group can ever schedule.
run "pre_fix_main_hpa_maximum_warns" {
  command = plan

  variables {
    n8n_main_hpa_max_replicas = 20
  }

  expect_failures = [check.autoscaling_maxima_fit_node_group_capacity]
}

run "pre_fix_webhook_hpa_maximum_warns" {
  command = plan

  variables {
    n8n_webhook_hpa_max_replicas = 50
  }

  expect_failures = [check.autoscaling_maxima_fit_node_group_capacity]
}

# Workers are not on an HPA but compete for the same CPU, so their KEDA ceiling
# is part of the same budget.
run "worker_keda_maximum_counts_against_the_same_budget" {
  command = plan

  variables {
    n8n_worker_keda_max_replicas = 40
  }

  expect_failures = [check.autoscaling_maxima_fit_node_group_capacity]
}

# Task runner sidecars ride on main and worker pods only, so turning them off
# frees 200m per main and per worker. 12 mains is over the line with them
# (23,800m) and under it without (19,400m). The pair pins that accounting.
run "main_maximum_of_twelve_warns_with_task_runners_enabled" {
  command = plan

  variables {
    n8n_main_hpa_max_replicas = 12
  }

  expect_failures = [check.autoscaling_maxima_fit_node_group_capacity]
}

run "main_maximum_of_twelve_fits_without_task_runners" {
  command = plan

  variables {
    n8n_main_hpa_max_replicas = 12
    n8n_task_runners_enabled  = false
  }

  assert {
    condition     = kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook[0].spec[0].max_replicas == 8
    error_message = "Disabling task runners must not disturb the webhook ceiling"
  }
}

# Raising node_max is the other side of the same equation: the maxima that warn
# above are fine once there is somewhere to put the pods.
run "raising_node_max_admits_higher_maxima" {
  command = plan

  variables {
    node_max                     = 14
    n8n_main_hpa_max_replicas    = 20
    n8n_webhook_hpa_max_replicas = 50
  }

  assert {
    condition     = aws_eks_node_group.n8n[0].scaling_config[0].max_size == 14
    error_message = "node_max must reach the node group so the capacity model reflects it"
  }
}

# A bigger instance type buys the same headroom as more nodes. m6i.2xlarge is
# 8 vCPU off the size ladder, so 6 of them roughly doubles what 6 t3.xlarge give.
run "a_larger_instance_type_admits_higher_maxima" {
  command = plan

  variables {
    node_instance_type           = "m6i.2xlarge"
    n8n_main_hpa_max_replicas    = 20
    n8n_webhook_hpa_max_replicas = 20
  }

  assert {
    condition     = one(aws_eks_node_group.n8n[0].instance_types) == "m6i.2xlarge"
    error_message = "node_instance_type must reach the node group so the capacity model reflects it"
  }
}

# ...and the ladder has to be read, not assumed. 4 × m6i.2xlarge is 8 vCPU × 4,
# which the same maxima do not fit into, so this run proves the size suffix is
# actually parsed rather than treated as a constant.
run "the_instance_size_ladder_is_read_not_assumed" {
  command = plan

  variables {
    node_instance_type           = "m6i.2xlarge"
    node_max                     = 4
    n8n_main_hpa_max_replicas    = 20
    n8n_webhook_hpa_max_replicas = 20
  }

  expect_failures = [check.autoscaling_maxima_fit_node_group_capacity]
}

# Sizes off the standard ladder ("metal" and its variants) have no derivable vCPU
# count, so the model goes unreadable and the check stays silent rather than
# warning off a guess. The ceiling here would warn loudly on any ladder size.
run "an_off_ladder_instance_size_silences_the_capacity_check" {
  command = plan

  variables {
    node_instance_type        = "m5.metal"
    n8n_main_hpa_max_replicas = 200
  }

  assert {
    condition     = one(aws_eks_node_group.n8n[0].instance_types) == "m5.metal"
    error_message = "An instance size the model cannot read must still reach the node group"
  }
}

# The CPU quantity is a different case from the instance size above, and used
# to behave the same way. An unparseable request made
# local.n8n_cpu_requests_readable false, which collapsed the peak-CPU figure to
# zero and let the capacity check pass on a configuration nothing had measured:
# a maximum of 200 main pods reported as fitting. Since the quantity inputs
# validate their own syntax, that state is unreachable and the value is
# rejected before any of it is computed.
#
# The instance size above still degrades to silence, deliberately: the module
# reads a ladder of sizes it knows, and an unlisted one is a gap in that ladder
# rather than a caller error. A CPU quantity has one correct grammar, so a
# value outside it is always a mistake.
run "unparseable_cpu_request_is_rejected_rather_than_silencing_the_capacity_check" {
  command = plan

  variables {
    n8n_main_cpu_request      = "one and a half cores"
    n8n_main_hpa_max_replicas = 200
  }

  expect_failures = [var.n8n_main_cpu_request]
}

# ── Autoscaler floors drive the deployments' own replica counts ───────────────
# The chart renders spec.replicas unconditionally on all three deployments,
# ignoring whether an HPA or a KEDA ScaledObject also owns the field. Left at a
# constant, every helm upgrade would scale down to it and make the autoscaler
# climb back, erasing a warm floor exactly when a rollout needs it. n8n.tf wires
# each replica count to its floor so Helm's write is a no-op.
#
# helm_release.values is unknown at plan under mocks (see "Known mock provider
# limitations" in AGENTS.md), so the wiring itself cannot be asserted here. These
# runs pin the floors as inputs and the one autoscaler the module owns directly;
# examples/medium and examples/large exercise raised floors end to end.

run "autoscaler_floors_default_to_warm_multi_replica_values" {
  command = plan

  assert {
    condition     = var.n8n_main_hpa_min_replicas == 2 && var.n8n_webhook_hpa_min_replicas == 2
    error_message = "Main and webhook floors must default to 2; a floor of 1 leaves no replica available during a node drain under the module's PodDisruptionBudget"
  }

  assert {
    condition     = kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook[0].spec[0].min_replicas == var.n8n_webhook_hpa_min_replicas
    error_message = "The webhook HPA floor must track n8n_webhook_hpa_min_replicas, which is also what the chart writes to spec.replicas"
  }
}

run "raised_floors_reach_the_module_owned_webhook_hpa" {
  command = plan

  variables {
    n8n_webhook_hpa_min_replicas = 5
    n8n_worker_keda_min_replicas = 5
    n8n_main_hpa_min_replicas    = 3
  }

  assert {
    condition     = kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook[0].spec[0].min_replicas == 5
    error_message = "A raised webhook floor must reach the HPA the module creates in scaling.tf"
  }
}

# A floor above the ceiling is rejected by Kubernetes and KEDA at apply, which is
# a slow way to find a typo now that the floors also drive spec.replicas.

run "main_floor_above_its_ceiling_fails_validation" {
  command = plan

  variables {
    n8n_main_hpa_min_replicas = 8
    n8n_main_hpa_max_replicas = 6
  }

  expect_failures = [var.n8n_main_hpa_min_replicas]
}

run "webhook_floor_above_its_ceiling_fails_validation" {
  command = plan

  variables {
    n8n_webhook_hpa_min_replicas = 10
    n8n_webhook_hpa_max_replicas = 8
  }

  expect_failures = [var.n8n_webhook_hpa_min_replicas]
}

run "worker_floor_above_its_ceiling_fails_validation" {
  command = plan

  variables {
    n8n_worker_keda_min_replicas = 20
    n8n_worker_keda_max_replicas = 10
  }

  expect_failures = [var.n8n_worker_keda_min_replicas]
}

# ── Not testable here: null passed as a module argument ──────────────────────
# The nine inputs the capacity model reads carry nullable = false. On a nullable
# variable, a caller passing null in a module block propagates that null instead
# of falling back to the default, and the check's error_message is evaluated
# alongside its condition rather than lazily, so a null aborted the plan from
# inside a block whose whole purpose is to warn without failing.
#
# This suite cannot cover it. A run block's `variables` treats `x = null` as
# *unset*, so the variable takes its default and no error is raised: the two
# semantics differ, and only the module-call one is the bug. An earlier attempt
# here failed with "Missing expected failure" for exactly that reason. See
# "Known mock provider limitations" in AGENTS.md.

# Equal floor and ceiling pins the replica count with no autoscaling range, which
# is a legitimate way to run a fixed-size deployment.
run "equal_floor_and_ceiling_is_accepted" {
  command = plan

  variables {
    n8n_webhook_hpa_min_replicas = 4
    n8n_webhook_hpa_max_replicas = 4
  }

  assert {
    condition     = kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook[0].spec[0].min_replicas == kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook[0].spec[0].max_replicas
    error_message = "A floor equal to its ceiling must be accepted as a fixed-size deployment"
  }
}

# ── n8n_execution_data_storage_mode ──────────────────────────────────────────
# Execution-data offload to S3 (issue #47). Asserted at the variable contract
# level: the env var goes into config.extraEnv inside helm_release.n8n.values,
# which is unknown at plan time under the mock provider (see "Known mock
# provider limitations" in AGENTS.md). To verify end-to-end, run a real
# `terraform plan` from examples/small/ with
# n8n_execution_data_storage_mode = "s3" and confirm
# N8N_EXECUTION_DATA_STORAGE_MODE=s3 appears in the helm_release.n8n values.
run "execution_data_storage_mode_defaults_to_database" {
  command = plan

  assert {
    condition     = var.n8n_execution_data_storage_mode == "database"
    error_message = "n8n_execution_data_storage_mode should default to \"database\", matching n8n's own default, so no env var is emitted unless a caller opts in."
  }
}

run "execution_data_storage_mode_accepts_s3" {
  command = plan

  variables {
    n8n_execution_data_storage_mode = "s3"
    # Pinned at the floor the feature requires so the version check in n8n.tf
    # stays quiet for this run.
    n8n_image_tag = "2.27.4"
  }

  assert {
    condition     = var.n8n_execution_data_storage_mode == "s3"
    error_message = "n8n_execution_data_storage_mode should accept \"s3\"."
  }
}

# filesystem is a valid n8n value but not a valid one here: pod filesystems are
# ephemeral and unshared in this module's queue-mode topology, so execution data
# written there is lost on reschedule and invisible to the other pods.
run "execution_data_storage_mode_rejects_filesystem" {
  command = plan

  variables {
    n8n_execution_data_storage_mode = "filesystem"
  }

  expect_failures = [var.n8n_execution_data_storage_mode]
}

run "execution_data_storage_mode_rejects_unknown_value" {
  command = plan

  variables {
    n8n_execution_data_storage_mode = "postgres"
  }

  expect_failures = [var.n8n_execution_data_storage_mode]
}

# The version check only compares tags shaped like MAJOR.MINOR.<rest>, so it
# warns on 2.26.9 but stays silent on 2.27.0 (exercised by the accepts_s3 run
# above), on a null tag (the chart's floating `stable`), and on channel tags,
# both exercised by the runs below.
run "execution_data_s3_with_pre_2_27_image_tag_triggers_check_warning" {
  command = plan

  variables {
    n8n_execution_data_storage_mode = "s3"
    n8n_image_tag                   = "2.26.9"
  }

  expect_failures = [check.execution_data_s3_requires_n8n_2_27]
}

# The chart-default case most callers hit: s3 mode with n8n_image_tag left at
# null (the floating `stable` tag). There is no version to compare, so the
# check must stay quiet rather than block the plan.
run "execution_data_s3_with_null_image_tag_plans_cleanly" {
  command = plan

  variables {
    n8n_execution_data_storage_mode = "s3"
  }

  assert {
    condition     = var.n8n_image_tag == null
    error_message = "A null image tag (chart default, floating stable) should be accepted without the version check firing."
  }
}

run "execution_data_s3_with_unparseable_image_tag_plans_cleanly" {
  command = plan

  variables {
    n8n_execution_data_storage_mode = "s3"
    # No MAJOR.MINOR.<rest> to compare, so the check leaves channel tags alone
    # rather than guessing what version they resolve to.
    n8n_image_tag = "beta"
  }

  assert {
    condition     = var.n8n_image_tag == "beta"
    error_message = "A channel tag should be accepted without the version check firing."
  }
}

# Regression guard: N8N_EXECUTION_DATA_STORAGE_MODE became module-managed
# alongside the input above, so the escape hatch must reject it. An override
# here would flip execution data onto S3 (or off it) without the input saying
# so, and on an unlicensed n8n every pod refuses to start in s3 mode.
run "extra_env_rejects_execution_data_storage_mode_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_EXECUTION_DATA_STORAGE_MODE", value = "s3" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

# ── EKS control-plane hardening (issue #27) ───────────────────────────────────
# These assertions exist because checkov no longer covers them. CKV_AWS_58
# (secrets encryption) carries a checkov:skip in eks.tf: the check reads
# encryption_config straight from the HCL and cannot expand the dynamic block
# the conditional KMS key requires, so it reports a false negative either way.
# Skipping it means nothing in CI would notice if the block were dropped, hence
# the coverage here instead.

run "eks_control_plane_hardening_defaults" {
  command = plan

  assert {
    condition     = length(aws_eks_cluster.n8n[0].encryption_config) == 1
    error_message = "eks_secrets_encryption_enabled defaults to true, so the cluster should plan with an encryption_config block."
  }

  assert {
    condition     = aws_eks_cluster.n8n[0].encryption_config[0].resources == toset(["secrets"])
    error_message = "encryption_config should envelope-encrypt secrets, the only resource type EKS supports here."
  }

  # All five types, so an audit trail exists from the first apply rather than
  # being switched on after the incident that needed it.
  assert {
    condition = aws_eks_cluster.n8n[0].enabled_cluster_log_types == toset([
      "api", "audit", "authenticator", "controllerManager", "scheduler",
    ])
    error_message = "All five EKS control-plane log types should be enabled by default."
  }

  # The log group is module-managed precisely so retention is not "Never
  # expire", which is what EKS picks when it auto-creates the group.
  assert {
    condition     = aws_cloudwatch_log_group.eks_cluster[0].name == "/aws/eks/n8n-cluster/cluster"
    error_message = "The control-plane log group must use the name EKS writes to, or EKS auto-creates its own alongside it."
  }

  assert {
    condition     = aws_cloudwatch_log_group.eks_cluster[0].retention_in_days == 365
    error_message = "Control-plane log retention should be finite and explicit."
  }

  assert {
    condition     = aws_eks_cluster.n8n[0].vpc_config[0].endpoint_public_access
    error_message = "cluster_endpoint_public_access should default to true (kubectl works right after apply)."
  }

  assert {
    condition     = aws_eks_cluster.n8n[0].vpc_config[0].public_access_cidrs == toset(["0.0.0.0/0"])
    error_message = "cluster_endpoint_public_access_cidrs should default to unrestricted, preserving pre-#27 behavior."
  }
}

# The opt-out has to actually opt out: the KMS key is what makes the cluster
# unreplaceable-in-place, so a caller disabling it must get neither the key nor
# the encryption_config block referencing it.
run "eks_secrets_encryption_can_be_disabled" {
  command = plan

  variables {
    eks_secrets_encryption_enabled = false
  }

  assert {
    condition     = length(aws_eks_cluster.n8n[0].encryption_config) == 0
    error_message = "eks_secrets_encryption_enabled = false should plan no encryption_config block."
  }

  assert {
    condition     = length(aws_kms_key.eks) == 0
    error_message = "eks_secrets_encryption_enabled = false should create no KMS key."
  }
}

run "endpoint_access_cidrs_flow_through" {
  command = plan

  variables {
    cluster_endpoint_public_access_cidrs = ["203.0.113.0/24"]
    cluster_endpoint_private_access      = true
  }

  assert {
    condition     = aws_eks_cluster.n8n[0].vpc_config[0].public_access_cidrs == toset(["203.0.113.0/24"])
    error_message = "cluster_endpoint_public_access_cidrs should reach vpc_config.public_access_cidrs."
  }

  assert {
    condition     = aws_eks_cluster.n8n[0].vpc_config[0].endpoint_private_access
    error_message = "cluster_endpoint_private_access should reach vpc_config.endpoint_private_access."
  }
}

run "endpoint_access_cidrs_reject_malformed_cidr" {
  command = plan

  variables {
    cluster_endpoint_public_access_cidrs = ["203.0.113.0"]
  }

  expect_failures = [var.cluster_endpoint_public_access_cidrs]
}

# An empty list reads like "allow nothing" but EKS falls back to 0.0.0.0/0 when
# the public endpoint is on and no CIDRs are given, so it is the one input value
# whose plain meaning is the opposite of what it does.
run "endpoint_access_cidrs_reject_empty_list" {
  command = plan

  variables {
    cluster_endpoint_public_access_cidrs = []
  }

  expect_failures = [var.cluster_endpoint_public_access_cidrs]
}

# The empty-list rule only matters while the public endpoint is enabled. A
# private-only caller may pass [] explicitly because EKS ignores public CIDRs
# when public access is disabled.
run "endpoint_access_cidrs_empty_list_accepted_when_public_access_is_off" {
  command = plan

  variables {
    cluster_endpoint_public_access       = false
    cluster_endpoint_private_access      = true
    cluster_endpoint_public_access_cidrs = []
  }

  assert {
    condition     = length(aws_eks_cluster.n8n[0].vpc_config[0].public_access_cidrs) == 0
    error_message = "An empty CIDR list must reach the cluster's vpc_config when the public endpoint is disabled"
  }
}

# Both endpoints off leaves an unreachable control plane. EKS refuses it, but
# only several minutes into the apply.
run "endpoint_access_requires_one_enabled_path" {
  command = plan

  variables {
    cluster_endpoint_public_access  = false
    cluster_endpoint_private_access = false
  }

  expect_failures = [var.cluster_endpoint_private_access]
}

# ── S3 bucket encryption (issue #27) ──────────────────────────────────────────
# Covers the bucket side of SSE-KMS. The other half of it, the n8n pod role's
# kms:Decrypt / kms:GenerateDataKey grant, is deliberately not asserted here:
# aws_iam_policy.s3.policy is jsonencode()d from the bucket and key ARNs, so it
# stays unknown through a mocked plan, and command = apply is not an option in
# this suite (see the n8n_extra_env section above). That grant is the pairing
# that breaks n8n at runtime rather than at plan time if it is ever dropped, so
# it belongs on the live-validation checklist, not in a plan-time assertion.

run "s3_kms_encryption_defaults" {
  command = plan

  assert {
    condition     = length(aws_s3_bucket_server_side_encryption_configuration.n8n) == 1
    error_message = "s3_kms_encryption_enabled defaults to true, so the bucket should plan a default-encryption configuration."
  }

  # rule and apply_server_side_encryption_by_default are both sets, so they have
  # to be walked rather than indexed.
  assert {
    condition = one(flatten([
      for r in aws_s3_bucket_server_side_encryption_configuration.n8n[0].rule :
      [for d in r.apply_server_side_encryption_by_default : d.sse_algorithm]
    ])) == "aws:kms"
    error_message = "The bucket default should be SSE-KMS; SSE-S3 is what this setting exists to move away from."
  }

  # Without Bucket Keys, KMS is called once per object and the request bill
  # scales with execution volume.
  assert {
    condition = one([
      for r in aws_s3_bucket_server_side_encryption_configuration.n8n[0].rule : r.bucket_key_enabled
    ])
    error_message = "S3 Bucket Keys should be enabled so KMS is called per bucket, not per object."
  }

  assert {
    condition     = length(aws_kms_key.s3) == 1
    error_message = "s3_kms_encryption_enabled defaults to true, so the bucket CMK should be created."
  }

  assert {
    condition     = aws_kms_key.s3[0].enable_key_rotation
    error_message = "The bucket CMK should rotate, matching the module's other CMKs."
  }
}

# The opt-out drops the CMK, not the SSE configuration resource itself: the
# bucket still needs an explicit encryption default (now SSE-S3/AES256) rather
# than reverting to no aws_s3_bucket_server_side_encryption_configuration at
# all, since create_s3_bucket = true always manages one.
run "s3_kms_encryption_can_be_disabled" {
  command = plan

  variables {
    s3_kms_encryption_enabled = false
  }

  assert {
    condition = one(flatten([
      for r in aws_s3_bucket_server_side_encryption_configuration.n8n[0].rule :
      [for d in r.apply_server_side_encryption_by_default : d.sse_algorithm]
    ])) == "AES256"
    error_message = "s3_kms_encryption_enabled = false should leave the bucket on SSE-S3 (AES256), not aws:kms."
  }

  assert {
    condition = !one([
      for r in aws_s3_bucket_server_side_encryption_configuration.n8n[0].rule : r.bucket_key_enabled
    ])
    error_message = "S3 Bucket Keys are meaningless under SSE-S3 and should not be enabled when s3_kms_encryption_enabled = false."
  }

  assert {
    condition     = length(aws_kms_key.s3) == 0
    error_message = "s3_kms_encryption_enabled = false should create no bucket CMK."
  }
}

# ── RDS parameter group (issue #27) ───────────────────────────────────────────
# The safe default matters more than the logging default: engine_version is
# ignored on the instance, so a live PostgreSQL 16 deployment can coexist with
# var.db_engine_version = 18.4. Attaching the derived postgres18 group in that
# state fails at the RDS API. The group is therefore an explicit opt-in.

run "db_parameter_group_defaults_to_absent" {
  command = plan

  assert {
    condition     = length(aws_db_parameter_group.n8n) == 0
    error_message = "db_query_logging_enabled must default to false so module upgrades do not attach a parameter group from the wrong PostgreSQL major family."
  }
}

run "db_parameter_group_opt_in" {
  command = plan

  variables {
    db_query_logging_enabled = true
  }

  # Two assertions, and the literal one is deliberate rather than redundant.
  # The first pins the coupling: the family has to be derived from
  # db_engine_version, not hardcoded, so a version bump carries it along. The
  # second pins what that derivation currently resolves to, which means bumping
  # db_engine_version fails here on purpose. That is the point: a family only
  # exists if AWS publishes it, so whoever bumps the version has to confirm the
  # new one is real (`aws rds describe-db-engine-versions --engine postgres
  # --engine-version <new> --query 'DBEngineVersions[].DBParameterGroupFamily'`)
  # instead of finding out when the apply fails. postgres18 was confirmed that
  # way for the current 18.4 default.
  assert {
    condition     = aws_db_parameter_group.n8n[0].family == "postgres${split(".", var.db_engine_version)[0]}"
    error_message = "The parameter group family must be derived from db_engine_version, not hardcoded, or a version bump leaves it pointing at the wrong family."
  }

  assert {
    condition     = aws_db_parameter_group.n8n[0].family == "postgres18"
    error_message = "The parameter group family resolved to something other than postgres18. If db_engine_version was bumped deliberately, confirm the new family exists in the target region with `aws rds describe-db-engine-versions` and update this assertion."
  }

  assert {
    condition = { for p in aws_db_parameter_group.n8n[0].parameter : p.name => p.value } == {
      "log_statement"              = "ddl"
      "log_min_duration_statement" = "1000"
      "rds.force_ssl"              = "1"
    }
    error_message = "The parameter group should log DDL and slow queries and require TLS, and specifically not log_statement = all, which would copy workflow payloads into CloudWatch."
  }

  # The attachment itself is not assertable here: name_prefix means the group's
  # name is generated at apply time, so both sides of the comparison are unknown
  # through a mocked plan. What is checked above is the content that makes the
  # attachment worth having.
}

# create_database = false means an external database, so none of the module's
# own database resources should exist -- including this group.
run "db_parameter_group_absent_without_module_database" {
  command = plan

  variables {
    create_database          = false
    db_host                  = "external.example.com"
    db_password              = "external-password-not-real"
    db_query_logging_enabled = true
  }

  assert {
    condition     = length(aws_db_parameter_group.n8n) == 0
    error_message = "create_database = false should create no parameter group."
  }
}

# ── iam_permissions_boundary_arn ──────────────────────────────────────────────
# Every aws_iam_role this module creates: aws_iam_role.cluster and
# aws_iam_role.nodes (eks.tf), aws_iam_role.s3 (s3.tf), and
# module.controllers.lbc_iam_role, module.controllers.cluster_autoscaler_iam_role,
# module.controllers.ebs_csi_iam_role (modules/controllers/iam.tf).
# permissions_boundary = var.iam_permissions_boundary_arn is set on all six
# regardless of the toggle that gates them, so both directions are asserted
# across all six roles rather than just one, to catch a future new IAM role
# that forgets to wire the boundary.
run "iam_permissions_boundary_defaults_to_null_on_every_role" {
  command = plan

  assert {
    condition     = aws_iam_role.cluster[0].permissions_boundary == null
    error_message = "aws_iam_role.cluster must have no permissions_boundary by default"
  }

  assert {
    condition     = aws_iam_role.nodes[0].permissions_boundary == null
    error_message = "aws_iam_role.nodes must have no permissions_boundary by default"
  }

  assert {
    condition     = aws_iam_role.s3.permissions_boundary == null
    error_message = "aws_iam_role.s3 must have no permissions_boundary by default"
  }

  assert {
    condition     = module.controllers.lbc_iam_role[0].permissions_boundary == null
    error_message = "aws_iam_role.lbc must have no permissions_boundary by default"
  }

  assert {
    condition     = module.controllers.cluster_autoscaler_iam_role[0].permissions_boundary == null
    error_message = "aws_iam_role.cluster_autoscaler must have no permissions_boundary by default"
  }

  assert {
    condition     = module.controllers.ebs_csi_iam_role[0].permissions_boundary == null
    error_message = "aws_iam_role.ebs_csi must have no permissions_boundary by default"
  }

  # The seventh role, and the one originally missed. Count-gated on
  # create_database, which is what made it easy to skip: it is the only role
  # that disappears on a path the other six all survive.
  assert {
    condition     = aws_iam_role.rds_enhanced_monitoring[0].permissions_boundary == null
    error_message = "aws_iam_role.rds_enhanced_monitoring must have no permissions_boundary by default"
  }
}

# These two runs enumerate roles by hand, which is what let the seventh role
# ship unwired: the test agreed with the code because both were written from the
# same incomplete list. Terraform's test language cannot enumerate resources, so
# there is no assertion that closes the gap structurally. When adding an
# aws_iam_role to this module, set permissions_boundary on it, add it to both
# runs here, and name it in the iam_permissions_boundary_arn description.
# `grep -c 'resource "aws_iam_role"' *.tf` is the check; it must equal 7.

run "iam_permissions_boundary_propagates_to_every_role" {
  command = plan

  variables {
    iam_permissions_boundary_arn = "arn:aws:iam::123456789012:policy/ExamplePermissionsBoundary"
  }

  assert {
    condition     = aws_iam_role.cluster[0].permissions_boundary == "arn:aws:iam::123456789012:policy/ExamplePermissionsBoundary"
    error_message = "aws_iam_role.cluster must carry the configured permissions boundary"
  }

  assert {
    condition     = aws_iam_role.nodes[0].permissions_boundary == "arn:aws:iam::123456789012:policy/ExamplePermissionsBoundary"
    error_message = "aws_iam_role.nodes must carry the configured permissions boundary"
  }

  assert {
    condition     = aws_iam_role.s3.permissions_boundary == "arn:aws:iam::123456789012:policy/ExamplePermissionsBoundary"
    error_message = "aws_iam_role.s3 must carry the configured permissions boundary"
  }

  assert {
    condition     = module.controllers.lbc_iam_role[0].permissions_boundary == "arn:aws:iam::123456789012:policy/ExamplePermissionsBoundary"
    error_message = "aws_iam_role.lbc must carry the configured permissions boundary"
  }

  assert {
    condition     = module.controllers.cluster_autoscaler_iam_role[0].permissions_boundary == "arn:aws:iam::123456789012:policy/ExamplePermissionsBoundary"
    error_message = "aws_iam_role.cluster_autoscaler must carry the configured permissions boundary"
  }

  assert {
    condition     = module.controllers.ebs_csi_iam_role[0].permissions_boundary == "arn:aws:iam::123456789012:policy/ExamplePermissionsBoundary"
    error_message = "aws_iam_role.ebs_csi must carry the configured permissions boundary"
  }

  # The seventh role. In an account whose SCP requires a boundary on every role,
  # this one missing is enough to fail the whole apply.
  assert {
    condition     = aws_iam_role.rds_enhanced_monitoring[0].permissions_boundary == "arn:aws:iam::123456789012:policy/ExamplePermissionsBoundary"
    error_message = "aws_iam_role.rds_enhanced_monitoring must carry the configured permissions boundary"
  }
}

run "iam_permissions_boundary_rejects_malformed_arn" {
  command = plan

  variables {
    # Missing the policy/ resource segment entirely: not a policy ARN at all.
    iam_permissions_boundary_arn = "arn:aws:iam::123456789012:role/NotAPolicy"
  }

  expect_failures = [var.iam_permissions_boundary_arn]
}

# AWS permits an AWS managed policy to be used as a permissions boundary, and
# those carry `aws` in the account field rather than a 12-digit ID. The
# validation has to accept that shape, or the module fails the plan on a
# configuration AWS itself accepts.
run "iam_permissions_boundary_accepts_an_aws_managed_policy" {
  command = plan

  variables {
    iam_permissions_boundary_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
  }

  assert {
    condition     = aws_iam_role.s3.permissions_boundary == "arn:aws:iam::aws:policy/PowerUserAccess"
    error_message = "An AWS managed policy ARN must be accepted as a permissions boundary and reach every role"
  }
}

# ── n8n defaults scheduled to change ──────────────────────────────────────────
# n8n warns on every pod start that four of its defaults will move in a future
# version. The module pins one of them and exposes the other three, which is a
# deliberate asymmetry: see the block comment above n8n_task_runner_timeout in
# variables.tf.
#
# These runs assert on the inputs rather than on the rendered env list, for the
# same reason the execution-data runs do: config.extraEnv lives inside
# helm_release.n8n.values, which is unknown at plan, so the emitted names are not
# assertable under `command = plan`. The collision-guard runs below are what
# prove the module considers these names its own.

run "task_runner_timeout_pins_n8ns_current_default" {
  command = plan

  # 300 is n8n's own current default, so pinning it changes nothing today. That
  # is the point: the value is emitted unconditionally, so when n8n drops its
  # default to 60 an upgrade cannot silently abort every Code node task that
  # runs longer than a minute.
  assert {
    condition     = var.n8n_task_runner_timeout == 300
    error_message = "n8n_task_runner_timeout must default to 300, n8n's current default, so an n8n upgrade cannot move it"
  }
}

run "task_runner_timeout_accepts_n8ns_future_default" {
  command = plan

  variables {
    n8n_task_runner_timeout = 60
  }

  assert {
    condition     = var.n8n_task_runner_timeout == 60
    error_message = "n8n_task_runner_timeout must accept 60, so a caller can adopt n8n's future default early"
  }
}

run "task_runner_timeout_rejects_zero" {
  command = plan

  variables {
    n8n_task_runner_timeout = 0
  }

  expect_failures = [var.n8n_task_runner_timeout]
}

run "the_tightening_defaults_are_left_to_n8n" {
  command = plan

  # All three are n8n hardening a security default rather than changing
  # behaviour arbitrarily, so the module leaves them unset and lets n8n's
  # default apply, today's and tomorrow's alike.
  assert {
    condition = (
      var.n8n_unverified_packages_enabled == null &&
      var.n8n_compression_max_decompressed_size_bytes == null &&
      var.n8n_compression_max_zip_entries == null
    )
    error_message = "The three tightening defaults must be null by default, so the module freezes none of them on a caller's behalf"
  }
}

run "the_tightening_defaults_are_settable" {
  command = plan

  variables {
    n8n_unverified_packages_enabled             = true
    n8n_compression_max_decompressed_size_bytes = 2147483648
    n8n_compression_max_zip_entries             = 5000
  }

  assert {
    condition = (
      var.n8n_unverified_packages_enabled == true &&
      var.n8n_compression_max_decompressed_size_bytes == 2147483648 &&
      var.n8n_compression_max_zip_entries == 5000
    )
    error_message = "A caller must be able to pin today's values explicitly when their workflows depend on them"
  }
}

run "compression_decompressed_size_rejects_zero" {
  command = plan

  variables {
    n8n_compression_max_decompressed_size_bytes = 0
  }

  expect_failures = [var.n8n_compression_max_decompressed_size_bytes]
}

run "compression_zip_entries_rejects_zero" {
  command = plan

  variables {
    n8n_compression_max_zip_entries = 0
  }

  expect_failures = [var.n8n_compression_max_zip_entries]
}

# The collision guard. n8n_extra_env is appended last and wins on duplicate
# names, so an override here would unpin the task timeout or move a limit the
# module deliberately leaves to n8n, with no input saying so.

run "extra_env_rejects_the_task_runner_timeout_name" {
  command = plan

  variables {
    # Covered by the N8N_RUNNERS_ prefix rather than by an exact-name entry.
    n8n_extra_env = [
      { name = "N8N_RUNNERS_TASK_TIMEOUT", value = "60" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "extra_env_rejects_the_tightening_default_names" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_UNVERIFIED_PACKAGES_ENABLED", value = "true" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "extra_env_rejects_the_compression_limit_names" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_COMPRESSION_NODE_MAX_ZIP_ENTRIES", value = "5000" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

# ── Cluster controller install toggles ───────────────────────────────────────

run "install_lbc_false_creates_no_lbc_release" {
  command = plan

  variables {
    install_lbc    = false
    create_ingress = false
  }

  assert {
    condition     = length(module.controllers.lbc_helm_release) == 0
    error_message = "No LBC Helm release should be created when install_lbc = false"
  }

  # create_eks is left at its true default here: on a freshly created
  # cluster, nothing can already be bound to the aws-load-balancer-controller
  # ServiceAccount, so the association is still created even with
  # install_lbc = false, letting an externally-installed LBC on the new
  # cluster still get its IAM binding.
  assert {
    condition     = length(module.controllers.lbc_pod_identity_association) == 1
    error_message = "LBC Pod Identity association must still be created on create_eks = true even when install_lbc = false, so an externally-installed LBC on the new cluster gets its IAM binding"
  }
}

run "install_lbc_false_rejects_create_ingress_true" {
  command = plan

  variables {
    install_lbc    = false
    create_ingress = true
  }

  expect_failures = [var.install_lbc]
}

# Regression test for the 409 ResourceInUseException confirmed in live
# testing: create_eks = false against an existing cluster that already
# carries the aws-load-balancer-controller ServiceAccount's Pod Identity
# association (e.g. from a previous invocation of this exact module) must
# not attempt to create a second one when install_lbc = false attests that
# an association already exists there.
run "create_eks_false_install_lbc_false_skips_lbc_pod_identity_association" {
  command = plan

  variables {
    create_eks                                   = false
    existing_eks_cluster_name                    = "platform-shared-cluster"
    existing_eks_cluster_prerequisites_confirmed = true
    create_ebs_csi                               = false
    install_lbc                                  = false
    create_ingress                               = false
  }

  assert {
    condition     = length(module.controllers.lbc_pod_identity_association) == 0
    error_message = "create_eks = false with install_lbc = false must skip the LBC Pod Identity association, not collide with one that may already exist on the shared cluster"
  }

  # The role goes with the association. Left unconditional it would be an IAM
  # role carrying AWSLoadBalancerControllerIAMPolicy that no principal can
  # assume, since the association is the only thing that binds it to a
  # ServiceAccount, and its deterministic cluster_name-derived name would
  # collide with a second modules/controllers call sharing that cluster_name
  # (examples/customer-managed-everything is exactly that shape).
  assert {
    condition     = length(module.controllers.lbc_iam_role) == 0
    error_message = "create_eks = false with install_lbc = false must skip the LBC IAM role too, not strand a role nothing can assume"
  }

  # The gate is per-controller, so leaving install_cluster_autoscaler at its
  # default here proves the LBC gate does not drag its neighbour with it.
  assert {
    condition     = length(module.controllers.cluster_autoscaler_iam_role) == 1
    error_message = "install_lbc = false must not gate the Cluster Autoscaler IAM role: each controller's resources follow its own toggle"
  }
}

# The Cluster Autoscaler half of the run above.
run "create_eks_false_install_cluster_autoscaler_false_skips_its_iam_role" {
  command = plan

  variables {
    create_eks                                   = false
    existing_eks_cluster_name                    = "platform-shared-cluster"
    existing_eks_cluster_prerequisites_confirmed = true
    create_ebs_csi                               = false
    install_cluster_autoscaler                   = false
    create_ingress                               = false
  }

  assert {
    condition     = length(module.controllers.cluster_autoscaler_pod_identity_association) == 0
    error_message = "create_eks = false with install_cluster_autoscaler = false must skip the Cluster Autoscaler Pod Identity association"
  }

  assert {
    condition     = length(module.controllers.cluster_autoscaler_iam_role) == 0
    error_message = "create_eks = false with install_cluster_autoscaler = false must skip the Cluster Autoscaler IAM role too, not strand a role nothing can assume"
  }
}

# Complements the run above: create_eks = false does not, on its own, skip
# the association -- only install_lbc = false alongside it does. This is the
# "this invocation owns installing LBC on the existing cluster" case.
run "create_eks_false_install_lbc_true_still_creates_lbc_pod_identity_association" {
  command = plan

  variables {
    create_eks                                   = false
    existing_eks_cluster_name                    = "platform-shared-cluster"
    existing_eks_cluster_prerequisites_confirmed = true
    create_ebs_csi                               = false
    install_lbc                                  = true
  }

  assert {
    condition     = length(module.controllers.lbc_pod_identity_association) == 1
    error_message = "create_eks = false with install_lbc = true must still create the LBC Pod Identity association: this invocation owns installing LBC on the existing cluster"
  }

  assert {
    condition     = length(module.controllers.lbc_iam_role) == 1
    error_message = "create_eks = false with install_lbc = true must create the LBC IAM role: the association it is bound to exists on this path"
  }
}

# The default path, stated explicitly so the gate's other half is covered:
# create_eks = true creates the LBC and Cluster Autoscaler IAM roles whether
# or not the module installs the controllers itself. Nothing can already be
# bound to those ServiceAccounts on a cluster this apply just created, so the
# roles exist for an externally installed controller to use.
run "create_eks_true_creates_controller_iam_roles_regardless_of_install_toggles" {
  command = plan

  variables {
    install_lbc                = false
    install_cluster_autoscaler = false
    create_ingress             = false
  }

  assert {
    condition     = length(module.controllers.lbc_iam_role) == 1
    error_message = "create_eks = true must create the LBC IAM role even with install_lbc = false, so an externally installed controller still gets its IAM binding"
  }

  assert {
    condition     = length(module.controllers.cluster_autoscaler_iam_role) == 1
    error_message = "create_eks = true must create the Cluster Autoscaler IAM role even with install_cluster_autoscaler = false"
  }
}

run "install_cluster_autoscaler_false_creates_no_release" {
  command = plan

  variables {
    install_cluster_autoscaler = false
  }

  assert {
    condition     = length(module.controllers.cluster_autoscaler_pod_identity_association) == 1
    error_message = "Cluster Autoscaler Pod Identity association must still be created on create_eks = true even when install_cluster_autoscaler = false, so an externally-installed Cluster Autoscaler on the new cluster gets its IAM binding"
  }

  assert {
    condition     = length(module.controllers.cluster_autoscaler_helm_release) == 0
    error_message = "No Cluster Autoscaler Helm release should be created when install_cluster_autoscaler = false"
  }
}

# Same regression pair as the LBC runs above, for Cluster Autoscaler.
run "create_eks_false_install_cluster_autoscaler_false_skips_pod_identity_association" {
  command = plan

  variables {
    create_eks                                   = false
    existing_eks_cluster_name                    = "platform-shared-cluster"
    existing_eks_cluster_prerequisites_confirmed = true
    create_ebs_csi                               = false
    install_cluster_autoscaler                   = false
  }

  assert {
    condition     = length(module.controllers.cluster_autoscaler_pod_identity_association) == 0
    error_message = "create_eks = false with install_cluster_autoscaler = false must skip the Cluster Autoscaler Pod Identity association, not collide with one that may already exist on the shared cluster"
  }
}

run "create_eks_false_install_cluster_autoscaler_true_still_creates_pod_identity_association" {
  command = plan

  variables {
    create_eks                                   = false
    existing_eks_cluster_name                    = "platform-shared-cluster"
    existing_eks_cluster_prerequisites_confirmed = true
    create_ebs_csi                               = false
    install_cluster_autoscaler                   = true
  }

  assert {
    condition     = length(module.controllers.cluster_autoscaler_pod_identity_association) == 1
    error_message = "create_eks = false with install_cluster_autoscaler = true must still create the Cluster Autoscaler Pod Identity association: this invocation owns installing it on the existing cluster"
  }
}

run "install_metrics_server_false_creates_no_release" {
  command = plan

  variables {
    install_metrics_server = false
  }

  assert {
    condition     = length(module.controllers.metrics_server_helm_release) == 0
    error_message = "No metrics-server Helm release should be created when install_metrics_server = false"
  }

  # The webhook HPA is CPU-based and always present, so disabling
  # metrics-server always trips this warning too.
  expect_failures = [check.webhook_hpa_needs_metrics_server_somewhere]
}

run "install_keda_false_creates_no_release" {
  command = plan

  variables {
    install_keda = false
  }

  assert {
    condition     = length(module.controllers.keda_helm_release) == 0
    error_message = "No KEDA Helm release should be created when install_keda = false"
  }
}

run "controllers_all_installed_by_default" {
  command = plan

  assert {
    condition     = length(module.controllers.lbc_helm_release) == 1
    error_message = "LBC should be installed by default"
  }

  assert {
    condition     = length(module.controllers.cluster_autoscaler_helm_release) == 1
    error_message = "Cluster Autoscaler should be installed by default"
  }

  assert {
    condition     = length(module.controllers.metrics_server_helm_release) == 1
    error_message = "metrics-server should be installed by default"
  }

  assert {
    condition     = length(module.controllers.keda_helm_release) == 1
    error_message = "KEDA should be installed by default"
  }
}

# ── Chart repository overrides ───────────────────────────────────────────────

run "chart_repositories_default_to_the_public_upstreams" {
  command = plan

  assert {
    condition     = helm_release.n8n.repository == "oci://ghcr.io/n8n-io/n8n-helm-chart"
    error_message = "n8n_chart_repository must default to the public n8n chart repository"
  }

  assert {
    condition     = module.controllers.lbc_helm_release[0].repository == "https://aws.github.io/eks-charts"
    error_message = "lbc_chart_repository must default to the public LBC chart repository"
  }

  assert {
    condition     = module.controllers.cluster_autoscaler_helm_release[0].repository == "https://kubernetes.github.io/autoscaler"
    error_message = "cluster_autoscaler_chart_repository must default to the public Cluster Autoscaler chart repository"
  }

  assert {
    condition     = module.controllers.metrics_server_helm_release[0].repository == "https://kubernetes-sigs.github.io/metrics-server/"
    error_message = "metrics_server_chart_repository must default to the public metrics-server chart repository"
  }

  assert {
    condition     = module.controllers.keda_helm_release[0].repository == "https://kedacore.github.io/charts"
    error_message = "keda_chart_repository must default to the public KEDA chart repository"
  }
}

run "chart_repositories_can_be_mirrored" {
  command = plan

  variables {
    n8n_chart_repository                = "oci://123456789012.dkr.ecr.eu-west-1.amazonaws.com/n8n-chart-mirror"
    lbc_chart_repository                = "https://charts.internal.example.com/eks-charts"
    cluster_autoscaler_chart_repository = "https://charts.internal.example.com/autoscaler"
    metrics_server_chart_repository     = "https://charts.internal.example.com/metrics-server"
    keda_chart_repository               = "https://charts.internal.example.com/keda"
  }

  assert {
    condition     = helm_release.n8n.repository == "oci://123456789012.dkr.ecr.eu-west-1.amazonaws.com/n8n-chart-mirror"
    error_message = "n8n_chart_repository must reach the n8n Helm release"
  }

  assert {
    condition     = module.controllers.lbc_helm_release[0].repository == "https://charts.internal.example.com/eks-charts"
    error_message = "lbc_chart_repository must reach the LBC Helm release"
  }

  assert {
    condition     = module.controllers.cluster_autoscaler_helm_release[0].repository == "https://charts.internal.example.com/autoscaler"
    error_message = "cluster_autoscaler_chart_repository must reach the Cluster Autoscaler Helm release"
  }

  assert {
    condition     = module.controllers.metrics_server_helm_release[0].repository == "https://charts.internal.example.com/metrics-server"
    error_message = "metrics_server_chart_repository must reach the metrics-server Helm release"
  }

  assert {
    condition     = module.controllers.keda_helm_release[0].repository == "https://charts.internal.example.com/keda"
    error_message = "keda_chart_repository must reach the KEDA Helm release"
  }
}

run "n8n_chart_repository_rejects_a_bare_hostname" {
  command = plan

  variables {
    n8n_chart_repository = "ghcr.io/n8n-io/n8n-helm-chart"
  }

  expect_failures = [var.n8n_chart_repository]
}

run "lbc_chart_repository_rejects_whitespace" {
  command = plan

  variables {
    lbc_chart_repository = "https://charts.internal.example.com/eks charts"
  }

  expect_failures = [var.lbc_chart_repository]
}

run "cluster_autoscaler_chart_repository_rejects_an_unsupported_scheme" {
  command = plan

  variables {
    cluster_autoscaler_chart_repository = "ftp://charts.internal.example.com/autoscaler"
  }

  expect_failures = [var.cluster_autoscaler_chart_repository]
}

run "metrics_server_chart_repository_rejects_an_unsupported_scheme" {
  command = plan

  variables {
    metrics_server_chart_repository = "http://charts.internal.example.com/metrics-server"
  }

  expect_failures = [var.metrics_server_chart_repository]
}

run "keda_chart_repository_rejects_an_unsupported_scheme" {
  command = plan

  variables {
    keda_chart_repository = "http://charts.internal.example.com/keda"
  }

  expect_failures = [var.keda_chart_repository]
}

# ── Webhook HPA opt-out ───────────────────────────────────────────────────────

run "webhook_hpa_created_by_default" {
  command = plan

  assert {
    condition     = length(kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook) == 1
    error_message = "The webhook processor HPA should be created by default"
  }
}

run "n8n_webhook_hpa_enabled_false_creates_no_hpa" {
  command = plan

  variables {
    n8n_webhook_hpa_enabled = false
  }

  assert {
    condition     = length(kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook) == 0
    error_message = "No webhook processor HPA should be created when n8n_webhook_hpa_enabled = false"
  }
}

run "n8n_webhook_hpa_enabled_false_silences_the_metrics_server_check" {
  command = plan

  variables {
    n8n_webhook_hpa_enabled = false
    install_metrics_server  = false
  }

  # With no webhook HPA at all, there is nothing left needing metrics-server
  # on this front, so the check that fires when only install_metrics_server is
  # false must not fire here.
}

# ── Malformed-input rejection ─────────────────────────────────────────────────
# One run per input that previously accepted a value it could not use. Each of
# these used to plan cleanly and fail later: at apply against the Kubernetes or
# AWS API, or, worse, not at all. Grouped here rather than beside each feature
# because what they have in common is the failure mode, not the subsystem.

run "namespace_rejects_a_non_dns1123_name" {
  command = plan

  variables {
    # Uppercase and an underscore, both of which Kubernetes rejects on a
    # namespace. The kubernetes provider does catch this one at plan time, but
    # as an opaque metadata.0.name schema error that names neither the input
    # nor the namespace; the name also reaches
    # aws_eks_pod_identity_association, which has no such schema check.
    namespace = "N8N_Prod"
  }

  expect_failures = [var.namespace]
}

run "certificate_arn_rejects_a_non_acm_arn" {
  command = plan

  variables {
    certificate_arn = "arn:aws:iam::123456789012:server-certificate/legacy"
  }

  expect_failures = [var.certificate_arn]
}

# The ARN is well-formed, so the shape validation passes and the region one is
# what catches it. us-east-1 is the reflex here because CloudFront requires it;
# an ALB does not, and cannot use a certificate from another region.
run "certificate_arn_in_another_region_is_rejected" {
  command = plan

  variables {
    aws_region      = "eu-west-1"
    certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/12345678-1234-1234-1234-123456789012"
    route53_zone_id = null
  }

  expect_failures = [var.certificate_arn]
}

run "certificate_arn_in_the_deployment_region_is_accepted" {
  command = plan

  variables {
    aws_region      = "eu-west-1"
    certificate_arn = "arn:aws:acm:eu-west-1:123456789012:certificate/12345678-1234-1234-1234-123456789012"
    route53_zone_id = null
  }

  assert {
    condition     = local.certificate_arn == "arn:aws:acm:eu-west-1:123456789012:certificate/12345678-1234-1234-1234-123456789012"
    error_message = "A certificate in the deployment region must be used as-is"
  }
}

run "webhook_url_rejects_a_plaintext_scheme" {
  command = plan

  variables {
    n8n_webhook_url = "http://webhooks.example.com"
  }

  expect_failures = [var.n8n_webhook_url]
}

# A memory suffix on a CPU field. This is the case that mattered most: an
# unreadable CPU quantity collapsed local.n8n_peak_cpu_request_millis to zero,
# which made check.autoscaling_maxima_fit_node_capacity pass vacuously. The
# plan then asserted the maxima fit when nothing had been measured.
run "cpu_request_rejects_a_memory_quantity" {
  command = plan

  variables {
    n8n_main_cpu_request = "2Gi"
  }

  expect_failures = [var.n8n_main_cpu_request]
}

run "memory_limit_rejects_a_non_kubernetes_suffix" {
  command = plan

  variables {
    n8n_webhook_memory_limit = "2GB"
  }

  expect_failures = [var.n8n_webhook_memory_limit]
}

# The decimal suffixes are legal Kubernetes and now parse, where before they
# fell through to null and silenced the advisory entirely. 1G is 953.67Mi,
# under the 1024Mi request threshold, so the advisory must fire on it.
run "decimal_memory_suffix_still_reaches_the_webhook_sizing_advisory" {
  command = plan

  variables {
    n8n_reinstall_missing_packages = true
    n8n_webhook_cpu_request        = "800m"
    n8n_webhook_cpu_limit          = "1500m"
    n8n_webhook_memory_request     = "1G"
    n8n_webhook_memory_limit       = "2Gi"
  }

  assert {
    condition     = local.n8n_webhook_memory_mebibytes["request"] < 1024
    error_message = "1G must parse to 953.67Mi, not to 1024Mi and not to null: the decimal suffixes are not their binary namesakes"
  }

  expect_failures = [check.webhook_resources_sized_for_reinstall_missing_packages]
}

# Each floor is tested on its own, with the other side of the pair left at a
# value that keeps the pre-existing min <= max validation satisfied. Setting
# both to 0 would trip three validations at once and prove nothing about which.
run "hpa_min_replicas_rejects_zero" {
  command = plan

  variables {
    n8n_main_hpa_min_replicas = 0
  }

  expect_failures = [var.n8n_main_hpa_min_replicas]
}

run "hpa_max_replicas_rejects_a_fractional_count" {
  command = plan

  variables {
    n8n_main_hpa_min_replicas = 2
    n8n_main_hpa_max_replicas = 2.5
  }

  expect_failures = [var.n8n_main_hpa_max_replicas]
}

# KEDA scales to zero natively, so its floor is the one place 0 is legitimate.
run "keda_min_replicas_accepts_zero" {
  command = plan

  variables {
    n8n_worker_keda_min_replicas = 0
  }

  assert {
    condition     = var.n8n_worker_keda_min_replicas == 0
    error_message = "n8n_worker_keda_min_replicas must accept 0: KEDA scales a ScaledObject to zero, unlike an HPA on EKS"
  }
}

run "hpa_cpu_threshold_rejects_a_value_outside_one_to_a_hundred" {
  command = plan

  variables {
    n8n_webhook_hpa_cpu_threshold = 150
  }

  expect_failures = [var.n8n_webhook_hpa_cpu_threshold]
}

run "keda_jobs_per_replica_rejects_zero" {
  command = plan

  variables {
    n8n_worker_keda_jobs_per_replica = 0
  }

  expect_failures = [var.n8n_worker_keda_jobs_per_replica]
}

# node_min, node_max and node_desired were each floored at 1 on their own, but
# never checked against each other. AWS rejects the resulting scaling config.
run "node_max_below_node_min_is_rejected" {
  command = plan

  variables {
    node_min     = 6
    node_desired = 6
    node_max     = 3
  }

  # Only node_max is listed even though node_desired is also out of range here.
  # Terraform skips a validation whose condition references a variable that has
  # already failed its own, so node_desired's bounds check never runs once
  # node_max is invalid. The run below covers node_desired on its own, with a
  # node_max that validates.
  expect_failures = [var.node_max]
}

# node_max stays at or above the default here on purpose. Dropping it to 4
# would also trip check.autoscaling_maxima_fit_node_group_capacity, and a run
# that fails two unrelated things proves neither.
run "node_desired_outside_the_scaling_bounds_is_rejected" {
  command = plan

  variables {
    node_min     = 2
    node_desired = 9
    node_max     = 8
  }

  expect_failures = [var.node_desired]
}

run "fractional_node_count_is_rejected" {
  command = plan

  variables {
    node_max = 6.5
  }

  expect_failures = [var.node_max]
}

# ── Chart version pinning ─────────────────────────────────────────────────────
# The four controller charts had no `version` at all, so the installed version
# was whatever the repository index served at first apply.

run "controller_charts_are_version_pinned" {
  command = plan

  assert {
    condition     = module.controllers.lbc_helm_release[0].version == var.lbc_chart_version
    error_message = "helm_release.lbc must pin its chart version rather than floating on the repository index"
  }

  assert {
    condition     = module.controllers.cluster_autoscaler_helm_release[0].version == var.cluster_autoscaler_chart_version
    error_message = "helm_release.cluster_autoscaler must pin its chart version"
  }

  assert {
    condition     = module.controllers.metrics_server_helm_release[0].version == var.metrics_server_chart_version
    error_message = "helm_release.metrics_server must pin its chart version"
  }

  assert {
    condition     = module.controllers.keda_helm_release[0].version == var.keda_chart_version
    error_message = "helm_release.keda must pin its chart version"
  }

  assert {
    condition     = helm_release.n8n.version == var.n8n_chart_version
    error_message = "helm_release.n8n must keep pinning its chart version"
  }
}

# Helm resolves these literally, so a constraint string is not a version it can
# fetch. Rejecting it here beats an apply-time "chart not found".
run "chart_version_rejects_a_constraint_rather_than_a_version" {
  command = plan

  variables {
    keda_chart_version = ">= 2.20"
  }

  expect_failures = [var.keda_chart_version]
}

run "chart_version_rejects_a_leading_v" {
  command = plan

  variables {
    lbc_chart_version = "v3.5.0"
  }

  expect_failures = [var.lbc_chart_version]
}
