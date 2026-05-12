# Plan-time tests for the large example using mocked providers.
#
# Run: terraform test
#   (from examples/large/ — requires terraform >= 1.7)

# NOTE on the certificate path used by these tests:
#
# Production usage of examples/large/ is the Route53 path: set route53_zone_id
# and the module issues an ACM cert and writes the alias record automatically.
# We deliberately use the BYO-cert path here (certificate_arn = stub) because
# the module's dns.tf does `for_each` over
# aws_acm_certificate.n8n[0].domain_validation_options, an attribute that is
# unknown at plan time under a mocked AWS provider. mock_resource defaults and
# override_resource both silently no-op for this specific computed-set-of-
# object attribute (verified locally with Terraform 1.15.x). The BYO-cert
# branch of dns.tf is gated by `local.dns_automated = var.route53_zone_id !=
# null`, so leaving route53_zone_id null and supplying certificate_arn keeps
# the for_each empty and unblocks the rest of the architecture asserts below.

mock_provider "aws" {
  override_data {
    target = data.aws_availability_zones.available
    values = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }
}

mock_provider "kubernetes" {}
mock_provider "helm" {}

variables {
  n8n_domain      = "n8n.test.example.com"
  n8n_license_key = "test-license-key-not-real"
  # route53_zone_id is set to null explicitly so a developer's terraform.tfvars
  # cannot fall through and re-enable the dns.tf for_each path that the
  # certificate_arn stub is meant to bypass.
  route53_zone_id = null
  certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/test-cert"
}

run "cluster_name_length_validation_rejects_long_names" {
  command = plan

  variables {
    cluster_name = "this-cluster-name-is-definitely-too-long"
  }

  expect_failures = [var.cluster_name]
}

run "aurora_instance_class_validation_rejects_invalid" {
  command = plan

  variables {
    aurora_instance_class = "r6g.8xlarge"
  }

  expect_failures = [var.aurora_instance_class]
}

run "cert_xor_validation_rejects_both" {
  command = plan

  variables {
    route53_zone_id = "Z00000000000000000000"
    certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/test-cert"
  }

  expect_failures = [var.certificate_arn]
}

run "cert_xor_validation_rejects_neither" {
  command = plan

  variables {
    route53_zone_id = null
    certificate_arn = null
  }

  expect_failures = [var.certificate_arn]
}

# ── Aurora topology ──────────────────────────────────────────────────────────

run "aurora_cluster_topology" {
  command = plan

  assert {
    condition     = aws_rds_cluster.n8n.engine == "aurora-postgresql"
    error_message = "Aurora cluster engine must be aurora-postgresql"
  }

  assert {
    condition     = aws_rds_cluster.n8n.storage_type == "aurora-iopt1"
    error_message = "Aurora cluster must use I/O-Optimized storage at this throughput tier"
  }

  assert {
    condition     = aws_rds_cluster.n8n.engine_version == "16.4"
    error_message = "Aurora engine_version pinned to 16.4 (validated against PgBouncer + n8n TypeORM)"
  }
}

run "aurora_writer_and_reader_match_cluster_engine" {
  command = plan

  # The instances' `cluster_identifier` field references aws_rds_cluster.n8n.id,
  # which is computed and unknown at plan time. Asserting the wiring requires
  # `command = apply`, but applying triggers downstream module validations
  # (ARN format, JSON policy bodies) that the mocked AWS provider does not
  # satisfy. Pinning the engine on both instances instead catches the most
  # common writer/reader-misconfigured regression (someone forgetting to
  # propagate engine/engine_version on one of the two replicas) without
  # needing apply.

  assert {
    condition     = aws_rds_cluster_instance.writer.engine == "aurora-postgresql"
    error_message = "Writer engine must be aurora-postgresql"
  }

  assert {
    condition     = aws_rds_cluster_instance.reader.engine == "aurora-postgresql"
    error_message = "Reader engine must be aurora-postgresql"
  }

  assert {
    condition     = aws_rds_cluster_instance.writer.engine_version == aws_rds_cluster_instance.reader.engine_version
    error_message = "Writer and reader must run the same engine_version"
  }
}

run "aurora_instance_class_propagates_to_both_instances" {
  command = plan

  variables {
    aurora_instance_class = "db.r6g.2xlarge"
  }

  assert {
    condition     = aws_rds_cluster_instance.writer.instance_class == "db.r6g.2xlarge"
    error_message = "var.aurora_instance_class must reach writer.instance_class"
  }

  assert {
    condition     = aws_rds_cluster_instance.reader.instance_class == "db.r6g.2xlarge"
    error_message = "var.aurora_instance_class must reach reader.instance_class"
  }
}

# ── VPC CNI warm-IP tuning ────────────────────────────────────────────────────
# Subnet exhaustion at 10+ m7i.4xlarge nodes is gated entirely by these knobs.
# A regression here silently breaks scaling past ~10 nodes long before any
# user notices an IP-allocation error.

run "vpc_cni_addon_warm_ip_tuning" {
  command = plan

  assert {
    condition     = aws_eks_addon.vpc_cni.addon_name == "vpc-cni"
    error_message = "vpc_cni addon must target the vpc-cni addon, not amazon-vpc-cni"
  }

  assert {
    condition     = jsondecode(aws_eks_addon.vpc_cni.configuration_values).env.WARM_ENI_TARGET == "0"
    error_message = "WARM_ENI_TARGET must be 0 (default 1 exhausts /20 subnets at scale)"
  }

  assert {
    condition     = jsondecode(aws_eks_addon.vpc_cni.configuration_values).env.WARM_IP_TARGET == "2"
    error_message = "WARM_IP_TARGET must be 2 (limits warm pool to 2 IPs per node)"
  }

  assert {
    condition     = jsondecode(aws_eks_addon.vpc_cni.configuration_values).env.MINIMUM_IP_TARGET == "2"
    error_message = "MINIMUM_IP_TARGET must be 2 to pair with WARM_IP_TARGET"
  }
}

# ── PgBouncer ────────────────────────────────────────────────────────────────
# Required anti-affinity, two replicas, and the PDB together guarantee that
# no single-node failure or voluntary drain can take all n8n DB traffic down.
# These were the live-validated fixes from PR #4; pinning them at plan time
# means a future refactor can't silently regress to `preferred` anti-affinity
# or a single replica.

run "pgbouncer_namespace_and_replicas" {
  command = plan

  assert {
    condition     = kubernetes_namespace.pgbouncer.metadata[0].name == "pgbouncer"
    error_message = "PgBouncer must run in its own 'pgbouncer' namespace, not in the n8n namespace"
  }

  assert {
    # The kubernetes provider returns replicas as a string per its schema, not
    # an int — compare to "2" rather than 2.
    condition     = kubernetes_deployment.pgbouncer.spec[0].replicas == "2"
    error_message = "PgBouncer must run 2 replicas; a single replica is a single point of failure for all n8n DB traffic"
  }
}

run "pgbouncer_required_anti_affinity" {
  command = plan

  # Anti-affinity must be REQUIRED, not preferred. A preferred rule was
  # observed losing the race against node-group startup ordering, co-locating
  # both replicas on the first Ready node — a single-node failure then took
  # out all n8n DB traffic.
  assert {
    condition = length(
      kubernetes_deployment.pgbouncer.spec[0].template[0].spec[0].affinity[0].pod_anti_affinity[0].required_during_scheduling_ignored_during_execution
    ) == 1
    error_message = "PgBouncer pod anti-affinity must be REQUIRED, not preferred"
  }

  assert {
    condition = (
      kubernetes_deployment.pgbouncer.spec[0].template[0].spec[0].affinity[0]
      .pod_anti_affinity[0].required_during_scheduling_ignored_during_execution[0]
      .topology_key == "kubernetes.io/hostname"
    )
    error_message = "PgBouncer anti-affinity topology_key must be kubernetes.io/hostname (spreads replicas across nodes)"
  }
}

run "pgbouncer_pdb_and_clusterip_service" {
  command = plan

  assert {
    # The kubernetes provider returns min_available as a string per its schema
    # (the field also accepts percentages like "20%") — compare to "1" not 1.
    condition     = kubernetes_pod_disruption_budget_v1.pgbouncer.spec[0].min_available == "1"
    error_message = "PgBouncer PDB must require at least 1 replica available during voluntary disruptions"
  }

  assert {
    condition     = kubernetes_service.pgbouncer.spec[0].type == "ClusterIP"
    error_message = "PgBouncer service must be ClusterIP — it is only reached from in-cluster n8n pods"
  }

  assert {
    condition     = one(kubernetes_service.pgbouncer.spec[0].port).port == 5432
    error_message = "PgBouncer service must listen on the PostgreSQL port (5432)"
  }
}


