# shellcheck shell=bash
# tf-defaults.sh: shared awk helper for reading a variable's string default
# out of a .tf file. Sourced by check-version-drift.sh and
# chart-values-diff.sh — keep this the one place that knows the format, so a
# change to how variables.tf defaults are parsed doesn't need to land twice.
# Not executable on its own: no shebang, meant to be `source`d.

read_default() {
  # $1: variable name, $2: file. Prints its string default's contents.
  awk -v name="$1" '
    $0 ~ "variable \"" name "\"" { in_block = 1 }
    in_block && /default[ \t]*=/ {
      if (match($0, /"[^"]*"/)) {
        print substr($0, RSTART + 1, RLENGTH - 2)
        exit
      }
    }
    in_block && /^}/ { exit }
  ' "$2"
}
