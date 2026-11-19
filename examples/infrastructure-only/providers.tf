provider "aws" {
  region = var.aws_region
}

# No kubernetes or helm provider block, on purpose. With
# create_kubernetes_resources = false the module creates no resource of either
# provider, so there is nothing for them to connect to and this configuration
# needs no cluster credentials. terraform init still downloads both, because
# the module declares them in its required_providers.
