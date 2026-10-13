# Variable values for the second checkov pass in tests/scripts/check-checkov.sh.
#
# checkov evaluates `count` from variable defaults and answers every check on
# a count-0 resource with UNKNOWN, which it omits from the report. Any
# resource whose toggle is false in the module defaults and in every example
# is therefore invisible to the default scan (see AGENTS.md, "Known gap" under
# Static analysis). This file turns those toggles on so the same checks reach
# them. Add a line here whenever you add an opt-in Kubernetes resource, and
# add its address to OPT_IN_RESOURCES in the script so the pass fails loudly
# if the scan stops reaching it.
#
# Not a terraform.tfvars: Terraform never reads this file, only checkov does,
# and only when the script passes it with --var-file.
redis_exporter_enabled = true
