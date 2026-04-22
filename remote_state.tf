# ── Prerequisites state ───────────────────────────────────────────────────────
# The VPC and ACM certificate live in the sibling `prerequisites` workspace so
# the manual DNS validation step stays out of the application stack and the
# two stacks can move to separate HCP Terraform workspaces later.
#
# Apply `prerequisites/` before running `terraform apply` here — see the
# top-level README for the full flow.
#
# To move to HCP Terraform later, replace this data source with:
#   data "terraform_remote_state" "prerequisites" {
#     backend = "remote"
#     config = {
#       organization = "your-org"
#       workspaces = { name = "n8n-eks-prerequisites" }
#     }
#   }

data "terraform_remote_state" "prerequisites" {
  backend = "local"

  config = {
    path = "../prerequisites/terraform.tfstate"
  }
}

locals {
  aws_region      = data.terraform_remote_state.prerequisites.outputs.aws_region
  cluster_name    = data.terraform_remote_state.prerequisites.outputs.cluster_name
  n8n_domain      = data.terraform_remote_state.prerequisites.outputs.n8n_domain
  vpc_id          = data.terraform_remote_state.prerequisites.outputs.vpc_id
  private_subnets = data.terraform_remote_state.prerequisites.outputs.private_subnets
  public_subnets  = data.terraform_remote_state.prerequisites.outputs.public_subnets
  vpc_cidr_block  = data.terraform_remote_state.prerequisites.outputs.vpc_cidr_block
  certificate_arn = data.terraform_remote_state.prerequisites.outputs.certificate_arn
}
