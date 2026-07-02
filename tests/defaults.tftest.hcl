# Plan-time tests for the terraform-aws-n8n module using mocked providers.
#
# Exercises the module end-to-end (EKS, RDS, Redis, S3, KEDA, n8n Helm release)
# without contacting AWS. Providers are mocked and network-backed data sources
# are overridden with fixed values.
#
# Run: terraform test
#   (from the module root — requires terraform >= 1.7)

mock_provider "aws" {
  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/test"
      user_id    = "AIDATESTUSER"
    }
  }

  override_data {
    target = data.aws_iam_policy_document.lbc
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
    condition     = aws_eks_cluster.n8n.name == "n8n-cluster"
    error_message = "var.cluster_name should flow through to aws_eks_cluster.name"
  }

  assert {
    condition     = aws_eks_cluster.n8n.version == "1.35"
    error_message = "kubernetes_version should default to 1.35"
  }

  # Multi-main sizes nodes larger than single (6 n8n pods + overhead).
  assert {
    condition     = aws_eks_node_group.n8n.instance_types[0] == "t3.xlarge"
    error_message = "node_instance_type default should be t3.xlarge for multi-main workload"
  }

  assert {
    condition     = aws_eks_node_group.n8n.scaling_config[0].desired_size == 3
    error_message = "node_desired should default to 3 (multi-main minimum)"
  }

  assert {
    condition     = aws_eks_node_group.n8n.scaling_config[0].min_size == 3
    error_message = "node_min should default to 3"
  }

  assert {
    condition     = aws_eks_node_group.n8n.scaling_config[0].max_size == 6
    error_message = "node_max should default to 6"
  }

  # Cluster Autoscaler relies on these tags for ASG discovery.
  assert {
    condition     = aws_eks_node_group.n8n.tags["k8s.io/cluster-autoscaler/enabled"] == "true"
    error_message = "node group must carry k8s.io/cluster-autoscaler/enabled tag"
  }

  assert {
    condition     = aws_eks_node_group.n8n.tags["k8s.io/cluster-autoscaler/n8n-cluster"] == "owned"
    error_message = "node group must carry cluster-specific autoscaler ownership tag"
  }
}

run "rds_hardened_defaults" {
  command = plan

  assert {
    condition     = aws_db_instance.n8n[0].engine == "postgres"
    error_message = "RDS engine should be postgres"
  }

  assert {
    condition     = aws_db_instance.n8n[0].engine_version == "16.9"
    error_message = "RDS engine_version should default to 16.9 (var.db_engine_version)"
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
    error_message = "db_multi_az should default to true — HA is the point of the multi template"
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
  # auto-created group isn't in Terraform state) but very real — a single
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
    error_message = "CMK key rotation must be enabled — annual rotation is the AWS-recommended default and requires no ongoing operator action"
  }

  # ARN-linkage between aws_kms_key.db[0].arn and its three consumers
  # (aws_db_instance.kms_key_id, performance_insights_kms_key_id, and the
  # postgresql log group's kms_key_id) is verified by the live-apply step
  # documented in README.md → "Upgrading from a pre-CMK apply" rather than at
  # plan time — the ARN is computed and would require terraform >= 1.11's
  # `override_during = plan` to assert against under the mock provider, which
  # exceeds the module's `required_version = ">= 1.9"` floor.
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

  # storage_encrypted explicitly false on the instance — preserves prior
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
}

# Cross-variable validation: when the caller opts into an external database
# (create_database = false), both db_host and db_password are required at plan
# time. Without these the failure would surface deep inside the n8n Helm release
# at apply time, after EKS and the database resources have already been built.

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

  expect_failures = [var.db_password]
}

run "redis_private_and_sized" {
  command = plan

  assert {
    condition     = aws_elasticache_cluster.n8n.engine == "redis"
    error_message = "ElastiCache engine should be redis"
  }

  assert {
    condition     = aws_elasticache_cluster.n8n.node_type == "cache.t3.medium"
    error_message = "redis_node_type should default to cache.t3.medium"
  }

  assert {
    condition     = one(aws_security_group.redis.ingress).from_port == 6379
    error_message = "Redis SG should allow ingress on port 6379"
  }

  assert {
    condition     = one(aws_security_group.redis.ingress).to_port == 6379
    error_message = "Redis SG should allow ingress on port 6379 only"
  }

  assert {
    condition     = one(aws_security_group.redis.ingress).protocol == "tcp"
    error_message = "Redis SG should restrict ingress to TCP"
  }
}

run "s3_bucket_is_private" {
  command = plan

  assert {
    condition     = aws_s3_bucket_public_access_block.n8n.block_public_acls == true
    error_message = "S3 bucket must block public ACLs"
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.n8n.block_public_policy == true
    error_message = "S3 bucket must block public bucket policies"
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.n8n.ignore_public_acls == true
    error_message = "S3 bucket must ignore public ACLs"
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.n8n.restrict_public_buckets == true
    error_message = "S3 bucket must restrict public access"
  }

  # force_destroy lets terraform destroy drop the bucket even when n8n has
  # written attachments — without it, destroy fails with BucketNotEmpty.
  assert {
    condition     = aws_s3_bucket.n8n.force_destroy == true
    error_message = "S3 bucket must have force_destroy=true so teardown is clean"
  }

  # Bucket name: n8n-<cluster_name>-<last 6 of account ID>. With the default
  # cluster_name "n8n-cluster" and mocked account 123456789012 → 789012.
  assert {
    condition     = aws_s3_bucket.n8n.bucket == "n8n-n8n-cluster-789012"
    error_message = "S3 bucket name should be n8n-<cluster_name>-<account_suffix>"
  }
}

run "pod_identity_bindings_use_correct_service_accounts" {
  command = plan

  assert {
    condition     = aws_eks_pod_identity_association.lbc.namespace == "kube-system"
    error_message = "LBC pod identity binding must target kube-system"
  }

  assert {
    condition     = aws_eks_pod_identity_association.lbc.service_account == "aws-load-balancer-controller"
    error_message = "LBC pod identity must bind to the aws-load-balancer-controller SA"
  }

  assert {
    condition     = aws_eks_pod_identity_association.s3.service_account == "n8n-enterprise"
    error_message = "S3 pod identity must bind to the n8n-enterprise SA"
  }

  assert {
    condition     = aws_eks_pod_identity_association.cluster_autoscaler.service_account == "cluster-autoscaler"
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
    condition     = aws_eks_addon.ebs_csi.addon_name == "aws-ebs-csi-driver"
    error_message = "EBS CSI managed addon must be installed, without it no PVC can bind (issue #22)"
  }

  assert {
    # pod_identity_association is a set of objects, so it cannot be indexed.
    condition     = anytrue([for a in aws_eks_addon.ebs_csi.pod_identity_association : a.service_account == "ebs-csi-controller-sa"])
    error_message = "EBS CSI addon must bind Pod Identity to the ebs-csi-controller-sa SA"
  }

  assert {
    condition     = strcontains(aws_iam_role.ebs_csi.assume_role_policy, "pods.eks.amazonaws.com")
    error_message = "EBS CSI role must trust pods.eks.amazonaws.com (Pod Identity, not IRSA)"
  }

  assert {
    condition     = aws_iam_role_policy_attachment.ebs_csi.policy_arn == "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
    error_message = "EBS CSI role must attach the AWS-managed AmazonEBSCSIDriverPolicy"
  }

  assert {
    condition     = kubernetes_storage_class_v1.gp3.metadata[0].name == "gp3"
    error_message = "Default StorageClass must be named gp3"
  }

  assert {
    condition     = kubernetes_storage_class_v1.gp3.metadata[0].annotations["storageclass.kubernetes.io/is-default-class"] == "true"
    error_message = "gp3 StorageClass must carry the default-class annotation so unqualified PVCs bind"
  }

  assert {
    condition     = kubernetes_storage_class_v1.gp3.storage_provisioner == "ebs.csi.aws.com"
    error_message = "gp3 StorageClass must use the EBS CSI provisioner, not the removed in-tree one"
  }

  assert {
    condition     = kubernetes_storage_class_v1.gp3.volume_binding_mode == "WaitForFirstConsumer"
    error_message = "gp3 StorageClass must use WaitForFirstConsumer so volumes land in the consumer pod's AZ"
  }

  assert {
    condition     = kubernetes_storage_class_v1.gp3.reclaim_policy == "Delete"
    error_message = "gp3 StorageClass must use the Delete reclaim policy to limit orphaned EBS volumes"
  }

  assert {
    condition     = kubernetes_storage_class_v1.gp3.allow_volume_expansion == true
    error_message = "gp3 StorageClass must allow volume expansion"
  }

  assert {
    condition     = kubernetes_storage_class_v1.gp3.parameters["type"] == "gp3"
    error_message = "gp3 StorageClass must provision gp3 volumes"
  }

  assert {
    condition     = kubernetes_storage_class_v1.gp3.parameters["encrypted"] == "true"
    error_message = "gp3 StorageClass must encrypt volumes at rest"
  }
}

run "keda_installed_in_multi" {
  command = plan

  assert {
    condition     = helm_release.keda.chart == "keda"
    error_message = "KEDA helm release must exist in the multi template — worker autoscaling depends on it"
  }

  assert {
    condition     = helm_release.keda.namespace == "keda"
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
# we assert at the variable contract level — n8n.tf wires both vars through
# verbatim into the extraEnv list.

run "log_defaults" {
  command = plan

  assert {
    # Regression guard: the previous hardcoded value was "json". Anything other
    # than a console/file combination here breaks logging entirely.
    condition     = var.n8n_log_output == "console"
    error_message = "n8n_log_output must default to 'console' — 'json' (the previous value) silently drops all logs."
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
    error_message = "n8n_otel_enabled must default to false — OpenTelemetry tracing is opt-in."
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
    # `check "otel_tuning_requires_master_switch"` block in n8n.tf — the
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
    error_message = "n8n_log_streaming_managed_by_env must default to false — env-managed log streaming is opt-in."
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
# rejected by the escape hatch — keep local.n8n_managed_env_names in sync.
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
# appended last and Kubernetes resolves duplicate env names last-wins — an
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

run "image_tag_when_set_flows_through" {
  command = plan

  variables {
    n8n_image_tag = "2.27.4"
  }

  assert {
    condition     = var.n8n_image_tag == "2.27.4"
    error_message = "n8n_image_tag should be passed through when explicitly set."
  }
}

run "image_tag_rejects_empty_string" {
  command = plan

  variables {
    n8n_image_tag = ""
  }

  expect_failures = [var.n8n_image_tag]
}
