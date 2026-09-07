# Main maintenance policy is asserted through locals because helm_release.values
# is unknown at plan time under mocks. check-main-chart.sh renders these values
# with the pinned chart. Verify rollout ordering and node eviction on a live
# staging cluster before production; neither mocks nor rendering run controllers.
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
  n8n_domain      = "n8n.test.example.com"
  vpc_id          = "vpc-test12345"
  private_subnets = ["subnet-priv1", "subnet-priv2"]
  public_subnets  = ["subnet-pub1", "subnet-pub2"]
  vpc_cidr_block  = "10.0.0.0/16"
  certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/test-cert"
  n8n_license_key = "test-license-key-not-real"
}

run "multi_main_keeps_chart_strategy_and_protects_one_main" {
  command = plan

  assert {
    condition     = length(local.n8n_main_strategy) == 0
    error_message = "Multi-main must retain the chart's default rollout strategy."
  }
  assert {
    condition     = local.n8n_main_pdb_min_available == 1
    error_message = "Multi-main must protect one available main during voluntary eviction."
  }
}

run "single_main_recreates_and_allows_eviction" {
  command = plan

  variables {
    n8n_main_hpa_min_replicas = 1
    n8n_main_hpa_max_replicas = 6
  }

  assert {
    condition     = local.n8n_main_strategy.type == "Recreate" && local.n8n_main_strategy.rollingUpdate == null
    error_message = "Single-main must use Recreate and clear previous rollingUpdate settings to prevent upgrade overlap."
  }
  assert {
    condition     = local.n8n_main_pdb_min_available == 0
    error_message = "A single main must permit voluntary eviction, accepting maintenance downtime."
  }
  assert {
    condition     = local.n8n_main_hpa_effective_max_replicas == 1 && !local.n8n_multi_main_enabled
    error_message = "Single-main maintenance must pair with disabled leader election and an HPA ceiling of one."
  }
}
