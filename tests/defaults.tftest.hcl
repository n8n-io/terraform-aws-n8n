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

  # Confirms desired_size still plans from var.node_desired on create. The
  # lifecycle.ignore_changes = [scaling_config[0].desired_size] added for issue
  # #50 only suppresses drift against *real* state once the Cluster Autoscaler
  # has changed the live desired_size out-of-band — a mocked plan-time test has
  # no prior state to diverge from, so it cannot exercise that behavior. It is
  # verified by a live apply, a manual scale event (or CA-driven scale), and a
  # follow-up `terraform plan` showing no changes to desired_size.
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

# ── HPA: webhook processor scale-up stabilization ────────────────────────────

run "webhook_hpa_scale_up_stabilization_window_defaults_to_zero" {
  command = plan

  assert {
    condition     = kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook.spec[0].behavior[0].scale_up[0].stabilization_window_seconds == 0
    error_message = "n8n_webhook_hpa_scale_up_stabilization_window_seconds should default to 0, matching the Kubernetes API's own default."
  }

  # Regression guard: select_policy must be set explicitly. When it is unset,
  # the provider sends selectPolicy: "" and the Kubernetes API rejects the HPA
  # at apply time (`Unsupported value: ""`) — mocked tests cannot catch that
  # server-side rejection, only this plan-time value.
  assert {
    condition     = kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook.spec[0].behavior[0].scale_up[0].select_policy == "Max"
    error_message = "n8n_webhook HPA scale_up.select_policy must be explicitly \"Max\" — an unset value is serialized as \"\" and rejected by the Kubernetes API at apply."
  }
}

run "webhook_hpa_scale_up_stabilization_window_accepts_override" {
  command = plan

  variables {
    n8n_webhook_hpa_scale_up_stabilization_window_seconds = 300
  }

  assert {
    condition     = kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook.spec[0].behavior[0].scale_up[0].stabilization_window_seconds == 300
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

  expect_failures = [var.db_password]
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
# variables for (WAF, SSL policy, subnet pinning, ALB group sharing, access
# logs). Caller entries merge over the module defaults, last write wins.

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
}

run "ingress_annotations_add_and_override" {
  command = plan

  variables {
    ingress_annotations = {
      "alb.ingress.kubernetes.io/wafv2-acl-arn"    = "arn:aws:wafv2:us-east-1:123456789012:regional/webacl/n8n/abc123"
      "alb.ingress.kubernetes.io/ssl-policy"       = "ELBSecurityPolicy-TLS13-1-2-2021-06"
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
    condition     = kubernetes_namespace.n8n.metadata[0].name == "n8n-custom"
    error_message = "var.namespace must still drive the namespace the module creates"
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
    condition     = tolist(aws_security_group.rds.ingress)[0].cidr_blocks == tolist(["10.0.0.0/16"])
    error_message = "By default only the VPC CIDR should reach the database"
  }
}

run "db_allowed_cidr_blocks_are_appended_to_vpc_cidr" {
  command = plan

  variables {
    db_allowed_cidr_blocks = ["10.20.0.0/16", "192.168.100.0/24"]
  }

  assert {
    condition     = tolist(aws_security_group.rds.ingress)[0].cidr_blocks == tolist(["10.0.0.0/16", "10.20.0.0/16", "192.168.100.0/24"])
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
    condition     = tolist(aws_security_group.rds.ingress)[0].cidr_blocks == tolist(["10.0.0.0/16", "10.20.0.0/16"])
    error_message = "Duplicate CIDRs must be collapsed, including a repeat of the VPC CIDR itself"
  }
}

# ── RDS ingress by security group ────────────────────────────────────────────
# Allowing by security group beats allowing by CIDR inside the VPC: membership
# follows the instances, so the rule survives subnet changes and IP reuse.

run "no_security_group_rule_when_list_is_empty" {
  command = plan

  assert {
    condition     = length(aws_security_group.rds.ingress) == 1
    error_message = "With db_allowed_security_group_ids empty there must be exactly one ingress rule, the CIDR one. A second empty rule would be a spurious diff for every existing deployment"
  }
}

run "security_group_ingress_rule_is_added_when_set" {
  command = plan

  variables {
    db_allowed_security_group_ids = ["sg-0123456789abcdef0", "sg-abcdef0123456789a"]
  }

  assert {
    condition     = length(aws_security_group.rds.ingress) == 2
    error_message = "Setting db_allowed_security_group_ids must add a second ingress rule"
  }

  # security_groups is null on the CIDR rule, so it has to be guarded before
  # length() rather than compared directly.
  assert {
    condition = length([
      for r in tolist(aws_security_group.rds.ingress) : r
      if try(length(r.security_groups), 0) == 2 && r.from_port == 5432 && r.to_port == 5432
    ]) == 1
    error_message = "The security group rule must allow both groups on port 5432"
  }

  # The CIDR rule must be untouched by the addition.
  assert {
    condition = length([
      for r in tolist(aws_security_group.rds.ingress) : r
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

# ingress_scheme and ingress_annotations only reach an Ingress this module
# creates. Silently ignoring them would let a caller believe an internal scheme
# or a WAF association had taken effect when their own Ingress carries neither.

run "ingress_tuning_with_create_ingress_false_warns" {
  command = plan

  variables {
    create_ingress = false
    ingress_scheme = "internal"
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
    # unreadable — an unreadable quantity silently skips the check.
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

# Regression guard: N8N_LICENSE_DETACH_FLOATING_ON_SHUTDOWN became
# module-managed alongside the n8n_license_detach_floating_on_shutdown input
# (issue #49) — an override here would silently re-enable n8n's unsafe
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

  # Asserts at the variable contract level only — helm_release.values is
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
    error_message = "n8n_image_tag should accept a leading underscore — valid per Docker tag spec."
  }
}

run "image_tag_rejects_overlong_tag" {
  command = plan

  variables {
    # 129 characters — one over the Docker limit of 128
    n8n_image_tag = "a${join("", [for i in range(128) : "b"])}"
  }

  expect_failures = [var.n8n_image_tag]
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
    condition     = kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook.spec[0].max_replicas == 8
    error_message = "The webhook HPA ceiling must default to 8, which the default node group can schedule alongside the main and worker ceilings"
  }

  assert {
    condition     = kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook.spec[0].min_replicas == 2
    error_message = "The webhook HPA floor must stay at 2 for multi-replica availability"
  }

  assert {
    condition     = aws_eks_node_group.n8n.scaling_config[0].max_size == 6
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
    condition     = kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook.spec[0].max_replicas == 8
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
    condition     = aws_eks_node_group.n8n.scaling_config[0].max_size == 14
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
    condition     = one(aws_eks_node_group.n8n.instance_types) == "m6i.2xlarge"
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
    condition     = one(aws_eks_node_group.n8n.instance_types) == "m5.metal"
    error_message = "An instance size the model cannot read must still reach the node group"
  }
}

# Likewise for a CPU request in a form the module cannot parse: the ceiling here
# would warn loudly if the quantity had parsed.
run "unparseable_cpu_request_silences_the_capacity_check" {
  command = plan

  variables {
    n8n_main_cpu_request      = "one and a half cores"
    n8n_main_hpa_max_replicas = 200
  }

  assert {
    condition     = kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook.spec[0].max_replicas == 8
    error_message = "An unreadable CPU quantity must leave the rest of the plan intact"
  }
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
    condition     = kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook.spec[0].min_replicas == var.n8n_webhook_hpa_min_replicas
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
    condition     = kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook.spec[0].min_replicas == 5
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
    condition     = kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook.spec[0].min_replicas == kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook.spec[0].max_replicas
    error_message = "A floor equal to its ceiling must be accepted as a fixed-size deployment"
  }
}
