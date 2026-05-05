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
    condition     = aws_db_instance.n8n.engine == "postgres"
    error_message = "RDS engine should be postgres"
  }

  assert {
    condition     = aws_db_instance.n8n.engine_version == "16.3"
    error_message = "RDS engine_version should be pinned to 16.3"
  }

  assert {
    condition     = aws_db_instance.n8n.instance_class == "db.t3.small"
    error_message = "db_instance_class should default to db.t3.small"
  }

  assert {
    condition     = aws_db_instance.n8n.allocated_storage == 50
    error_message = "db_allocated_storage should default to 50 GB"
  }

  assert {
    condition     = aws_db_instance.n8n.multi_az == true
    error_message = "db_multi_az should default to true — HA is the point of the multi template"
  }

  assert {
    condition     = aws_db_instance.n8n.publicly_accessible == false
    error_message = "RDS must NOT be publicly accessible"
  }

  assert {
    condition     = aws_db_instance.n8n.backup_retention_period >= 7
    error_message = "RDS backup retention must be >= 7 days"
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
  }

  assert {
    condition     = aws_db_instance.n8n.instance_class == "db.r6g.large"
    error_message = "db_instance_class variable did not propagate"
  }

  assert {
    condition     = aws_db_instance.n8n.allocated_storage == 200
    error_message = "db_allocated_storage variable did not propagate"
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
