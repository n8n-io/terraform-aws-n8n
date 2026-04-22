locals {
  common_tags = merge(
    {
      ManagedBy = "terraform"
      Project   = "n8n"
    },
    var.tags,
  )

  # cluster_name + last 6 digits of the account ID keeps names unique across
  # both clusters in the same account and accounts with the same cluster name.
  s3_bucket_name = "n8n-${local.cluster_name}-${substr(data.aws_caller_identity.current.account_id, 6, 6)}"
}
