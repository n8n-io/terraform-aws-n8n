locals {
  common_tags = merge(
    {
      ManagedBy = "terraform"
      Project   = "n8n"
    },
    var.tags,
  )
}
