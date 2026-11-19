provider "aws" {
  region = var.aws_region
}

# No kubernetes or helm provider block, on purpose. With
# create_kubernetes_resources = false the module creates no resource of either
# provider, so there is nothing for them to connect to and this configuration
# needs no cluster credentials. terraform init still downloads both, because
# the module declares them in its required_providers.
#
# Checked in an isolated configuration with the provider versions this
# repository locks (kubernetes 3.2.1, helm 3.3.0): with no provider block, no
# kubeconfig and every resource of those providers at count = 0, terraform
# plan and terraform apply both succeed. Both providers only build a cluster
# client when a resource needs one. Not repeated for this whole example
# against a real AWS account; do that before relying on it.
