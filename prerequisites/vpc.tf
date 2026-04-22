# EKS requires subnets in at least two availability zones.
# The VPC module handles the subnet tagging that EKS and the
# AWS Load Balancer Controller require automatically.
#
# Public subnets:  tagged kubernetes.io/role/elb=1  (ALB lives here)
# Private subnets: tagged kubernetes.io/role/internal-elb=1 (nodes live here)
#
# A single NAT Gateway is used to keep costs low. For production HA,
# set single_nat_gateway = false and one_nat_gateway_per_az = true.

data "aws_availability_zones" "available" {
  state = "available"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = "10.0.0.0/16"

  azs             = slice(data.aws_availability_zones.available.names, 0, 2)
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.10.0/24", "10.0.11.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  tags = local.common_tags
}
