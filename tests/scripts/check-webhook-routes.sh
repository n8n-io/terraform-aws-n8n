#!/usr/bin/env bash
# check-webhook-routes.sh: compare local.n8n_webhook_path_prefixes with the
# routes n8n registers.
#
# The module runs n8n with disableProductionWebhooksOnMainProcess = true, so
# the main pods do not serve the production webhook routes. The Ingress sends
# every entry of local.n8n_webhook_path_prefixes to the webhook processors
# instead. That list is written by hand, and it has been wrong twice (0.3.0,
# and #211 for the Slack and Telegram callback paths). Both times a user found
# the gap in production, because no check ever looked at n8n. This script is
# that check:
#
#   1. Read n8n_chart_version's default from variables.tf and resolve the
#      chart's appVersion, the n8n version the module deploys by default.
#   2. Download three source files from n8n-io/n8n at the tag n8n@<appVersion>.
#   3. Extract every route registered inside the `if (this.webhooksEnabled)`
#      block of packages/cli/src/abstract-server.ts, the block that setting
#      turns off on the mains, and resolve each one to a literal path prefix.
#   4. Compare both ways, with Kubernetes pathType Prefix semantics, the path
#      type n8n.tf renders for every entry: an entry covers a route when the
#      route equals the entry or starts with the entry plus "/". That is why
#      "/webhook-waiting" does not cover "/webhook-waiting-slack".
#
# Exit codes:
#   0  Every registered route is covered, and every entry covers a route (or
#      is named in RETAINED_PREFIXES below).
#   1  Mismatch. Each route no entry covers and each entry that covers no
#      route is named.
#   2  Could not check, so nothing was compared. The message starts with
#      "FETCH FAILED" (Helm or a download failed: re-run) or "PARSE FAILED"
#      (a file no longer has the shape this script reads: compare by hand,
#      then update this script). The one exception is a missing helm or
#      curl, which says "Required tool missing".
#
# The parser is strict on purpose. It reads TypeScript with text matching, so
# every statement in the block must be one of three known forms, and every
# name must resolve to exactly one definition. Anything else is PARSE FAILED,
# never a guess: a wrong "OK" is the one outcome this script must not have. The
# cost is that an edit n8n makes to the block, even a harmless one, can turn
# the next chart bump red until this script is updated in the same PR.
#
# What this cannot see:
#   - A custom n8n_image_tag. It checks only the n8n version the pinned chart
#     ships. A caller on a newer n8n can run routes this list does not have.
#   - N8N_ENDPOINT_* overrides passed through n8n_extra_env. They rename the
#     paths at runtime; this script reads n8n's defaults.
#   - Routes registered anywhere but this block, and n8n's runtime behavior.
#     Source text is not a running server.
#   - The test routes (webhook-test, form-test, mcp-test). The mains serve
#     them, and n8n registers them in a separate block,
#     `if (this.testWebhooksEnabled)`, which this script does not read. If n8n
#     ever moves one into the production block, it is reported as a route no
#     entry covers, which is the right question to raise.
#
# Test hooks, used by tests/scripts/test-check-webhook-routes.sh. They are not
# a supported way to run the check:
#   LOCALS_FILE        File that holds the list. Default: locals.tf.
#   N8N_SOURCE_DIR     Directory with the three n8n files at their upstream
#                      relative paths. Skips Helm and the download.
#   RETAINED_PREFIXES  Replaces the retained list below.
#
# Usage: tests/scripts/check-webhook-routes.sh
# Requires: helm, curl. No terraform, no AWS credentials, no cluster.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

# ── Repository-specific settings ──────────────────────────────────────────────
# Everything a port to a sibling module has to change is here, plus the
# read_default calls further down if that module's helper has another name.
VARS_FILE="variables.tf"
LOCALS_FILE="${LOCALS_FILE:-locals.tf}"
LOCAL_NAME="n8n_webhook_path_prefixes"

N8N_RAW_URL="https://raw.githubusercontent.com/n8n-io/n8n"
SERVER_PATH="packages/cli/src/abstract-server.ts"
ENDPOINTS_PATH="packages/@n8n/config/src/configs/endpoints.config.ts"
CONSTANTS_PATH="packages/core/src/utils/hitl-callback-reference.ts"

# Entries that stay in the list on purpose although the chart-default n8n no
# longer registers a route they cover. The list is a public output and callers
# can pin an older n8n through n8n_image_tag, so when n8n drops a route,
# removing its entry can break their routing. Decide per entry: remove it
# (a change to a public output, with a CHANGELOG note), or keep it and name it
# here. One entry per line inside the quotes, each with a comment above the
# assignment saying why it stays and from which n8n version it is unused.
RETAINED_PREFIXES_DEFAULT=""
RETAINED_PREFIXES="${RETAINED_PREFIXES-$RETAINED_PREFIXES_DEFAULT}"

# ── Failure helpers ───────────────────────────────────────────────────────────
source_ref=""

fetch_failed() {
  {
    echo "FETCH FAILED: $1"
    echo "Nothing was compared. This is not a route mismatch: re-run the check."
  } >&2
  exit 2
}

parse_failed() {
  {
    echo "PARSE FAILED: $1"
    echo "Nothing was compared. This is not a route mismatch: a file no longer has the shape"
    echo "this script reads. Compare $LOCAL_NAME in $LOCALS_FILE by hand with the routes in the"
    echo "\`if (this.webhooksEnabled)\` block of $SERVER_PATH${source_ref:+ ($source_ref)},"
    echo "then update tests/scripts/check-webhook-routes.sh and its test to the new shape."
  } >&2
  exit 2
}

# ── Locate the n8n source ─────────────────────────────────────────────────────
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if [[ -n "${N8N_SOURCE_DIR:-}" ]]; then
  src_dir="$N8N_SOURCE_DIR"
  source_ref="N8N_SOURCE_DIR=$N8N_SOURCE_DIR"
  subject="the n8n source in N8N_SOURCE_DIR (test hook, not a live check)"
  for path in "$SERVER_PATH" "$ENDPOINTS_PATH" "$CONSTANTS_PATH"; do
    [[ -f "$src_dir/$path" ]] || fetch_failed "$src_dir/$path does not exist."
  done
else
  for tool in helm curl; do
    command -v "$tool" >/dev/null 2>&1 || { echo "Required tool missing: $tool" >&2; exit 2; }
  done

  # shellcheck disable=SC1091 # path is $SCRIPT_DIR-relative, resolved at runtime, not statically
  source "$SCRIPT_DIR/lib/tf-defaults.sh"

  pinned_version="$(read_default n8n_chart_version "$VARS_FILE")"
  pinned_repository="$(read_default n8n_chart_repository "$VARS_FILE")"
  if [[ -z "$pinned_version" || -z "$pinned_repository" ]]; then
    parse_failed "could not read the n8n_chart_version and n8n_chart_repository defaults from $VARS_FILE."
  fi

  # The chart's appVersion is the n8n version the module deploys by default
  # only while n8n_image_tag defaults to null. If the module ever pins a tag
  # itself, this script would compare against the wrong n8n and could report
  # OK for it. Read the default's value as text: read_default prints only
  # quoted strings, so it cannot tell null from a variable that is not there.
  image_tag_default="$(awk '
    /^variable "n8n_image_tag"/ { in_block = 1; next }
    in_block && /^[ \t]*default[ \t]*=/ {
      sub(/^[ \t]*default[ \t]*=[ \t]*/, "")
      sub(/[ \t]+$/, "")
      print
      exit
    }
    in_block && /^}/ { exit }
  ' "$VARS_FILE")"
  if [[ "$image_tag_default" != "null" ]]; then
    parse_failed "n8n_image_tag's default in $VARS_FILE is '${image_tag_default:-not found}', not null. This script assumes the module deploys the pinned chart's appVersion by default, so it must now read the n8n version from that default instead."
  fi

  chart_meta="$(helm show chart "${pinned_repository}/n8n" --version "$pinned_version" 2>"$tmp/helm.err")" \
    || fetch_failed "helm show chart ${pinned_repository}/n8n --version $pinned_version failed: $(tr '\n' ' ' <"$tmp/helm.err")"

  app_version="$(sed -n 's/^appVersion:[[:space:]]*//p' <<<"$chart_meta" | tr -d "\"'")"
  if [[ ! "$app_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    parse_failed "chart $pinned_version has appVersion '$app_version', which is not one plain X.Y.Z version, so there is no n8n release tag to read."
  fi

  src_dir="$tmp/src"
  source_ref="${N8N_RAW_URL}/n8n@${app_version}/${SERVER_PATH}"
  subject="chart-default n8n $app_version (chart $pinned_version)"
  for path in "$SERVER_PATH" "$ENDPOINTS_PATH" "$CONSTANTS_PATH"; do
    mkdir -p "$src_dir/$(dirname "$path")"
    url="${N8N_RAW_URL}/n8n@${app_version}/${path}"
    curl -sfL --max-time 15 -o "$src_dir/$path" "$url" || fetch_failed "could not download $url"
    [[ -s "$src_dir/$path" ]] || fetch_failed "$url returned an empty file."
  done
fi

server_file="$src_dir/$SERVER_PATH"
endpoints_file="$src_dir/$ENDPOINTS_PATH"
constants_file="$src_dir/$CONSTANTS_PATH"

# ── Read the module's list ────────────────────────────────────────────────────
# Accepts one shape only: a single `NAME = [` line, then lines that are blank,
# a comment, or one quoted path, then `]`. A commented-out entry is not an
# entry. Anything else (an expression, two entries on a line, a second
# assignment) stops the check: an element this parser skipped would vanish
# from both comparisons below.
[[ -f "$LOCALS_FILE" ]] || parse_failed "$LOCALS_FILE does not exist."

entries_status=0
entries="$(awk -v name="$LOCAL_NAME" '
  BEGIN {
    assignment = "^[ \t]*" name "[ \t]*="
    opening    = "^[ \t]*" name "[ \t]*=[ \t]*[[][ \t]*$"
    entry      = "^[ \t]*\"/[A-Za-z0-9._~/-]*\",?[ \t]*$"
  }
  $0 ~ assignment {
    assignments++
    if ($0 !~ opening) { print "not a literal list: " $0; bad = 1; exit }
    in_list = 1
    next
  }
  in_list && /^[ \t]*[]][ \t]*$/ { in_list = 0; closed = 1; next }
  in_list && /^[ \t]*$/ { next }
  in_list && /^[ \t]*(#|\/\/)/ { next }
  in_list && $0 ~ entry {
    line = $0
    sub(/^[ \t]*"/, "", line)
    sub(/",?[ \t]*$/, "", line)
    print line
    next
  }
  in_list { print "not a quoted path on its own line: " $0; bad = 1; exit }
  END {
    if (bad) exit 3
    if (assignments != 1) { print "expected exactly one assignment, found " assignments + 0; exit 3 }
    if (!closed) { print "the list is never closed with a ] on its own line"; exit 3 }
  }
' "$LOCALS_FILE")" || entries_status=$?

if [[ "$entries_status" -ne 0 ]]; then
  parse_failed "could not read $LOCAL_NAME from $LOCALS_FILE: $(tail -1 <<<"$entries")"
fi
[[ -n "$entries" ]] || parse_failed "$LOCAL_NAME in $LOCALS_FILE is an empty list."

duplicates="$(sort <<<"$entries" | uniq -d)"
[[ -z "$duplicates" ]] || parse_failed "$LOCAL_NAME in $LOCALS_FILE lists an entry twice: $(tr '\n' ' ' <<<"$duplicates")"

# ── Extract the statements of the production block ────────────────────────────
# From the single `if (this.webhooksEnabled) {` line to the `}` at the same
# indentation. Comment lines and blank lines are dropped, the rest is joined
# and split on ";", which gives one statement per line whether n8n's formatter
# wrapped a call over several lines or not.
statements_status=0
statements="$(awk '
  !in_block && /^[ \t]*if \(this\.webhooksEnabled\) [{]$/ {
    starts++
    indent = $0
    sub(/if .*$/, "", indent)
    in_block = 1
    next
  }
  in_block && $0 == indent "}" { in_block = 0; closed++; next }
  in_block {
    line = $0
    sub(/^[ \t]+/, "", line)
    sub(/[ \t]+$/, "", line)
    if (line == "" || line ~ /^\/\//) next
    buffer = buffer line
  }
  END {
    if (starts != 1 || closed != 1) exit 3
    count = split(buffer, parts, ";")
    for (i = 1; i <= count; i++) if (parts[i] != "") print parts[i]
  }
' "$server_file")" || statements_status=$?

if [[ "$statements_status" -ne 0 ]]; then
  parse_failed "expected exactly one \`if (this.webhooksEnabled) {\` block, closed at the same indentation, in $SERVER_PATH."
fi

# ── Resolve each route to a literal prefix ────────────────────────────────────
# lookup_one <file> <ERE with one group> <what>: prints the group from the one
# line that matches. No match, or more than one, stops the check: taking the
# first of two definitions would be a guess.
lookup_one() {
  local file="$1" pattern="$2" what="$3" matches count
  matches="$(grep -E -- "$pattern" "$file" || true)"
  count="$(grep -c . <<<"$matches" || true)"
  if [[ "$count" != "1" ]]; then
    parse_failed "could not resolve $what: expected exactly one definition in ${file#"$src_dir"/}, found $count."
  fi
  sed -E "s/$pattern/\\1/" <<<"$matches"
}

# The three statement forms the block may contain. In the route form, the
# backtick template must be the whole first argument: it is followed directly
# by a comma. A template with something appended to it does not match.
#
# The handler argument is matched with balanced parentheses, one level of
# nesting deep, and no backtick. A looser ".*" there would also swallow a call
# chained onto the registration, `this.app.all(...).all(...)`, read only the
# first route, and report OK for a second route nobody compared.
re_const='^const [A-Za-z_][A-Za-z0-9_]* = Container\.get\([A-Za-z_][A-Za-z0-9_]*\)$'
re_route='^this\.app\.all\(`([^`]*)`, ?createWebhookHandlerFor\(([^()`]|\([^()`]*\))*\),?\)$'
re_endpoint='^this\.(endpoint[A-Za-z0-9]+)$'
re_constant='^[A-Z][A-Z0-9_]*$'
re_prefix='^(/[A-Za-z0-9._~-]+)+$'

routes=""
while IFS= read -r statement; do
  [[ -n "$statement" ]] || continue
  [[ "$statement" =~ $re_const ]] && continue
  if [[ ! "$statement" =~ $re_route ]]; then
    parse_failed "unrecognized statement in the \`if (this.webhooksEnabled)\` block: $statement"
  fi
  template="${BASH_REMATCH[1]}"

  # The prefix is the literal part before the first path parameter, which
  # Express writes as "/*name" or "/:name".
  prefix="${template%%/\**}"
  prefix="${prefix%%/:*}"

  # Replace each ${...} with its literal value, left to right.
  while [[ "$prefix" == *'${'* ]]; do
    before="${prefix%%\$\{*}"
    rest="${prefix#*\$\{}"
    if [[ "$rest" != *'}'* ]]; then
      parse_failed "unterminated \${ in route template \`$template\`."
    fi
    token="${rest%%\}*}"
    rest="${rest#*\}}"
    if [[ "$token" =~ $re_endpoint ]]; then
      property="${BASH_REMATCH[1]}"
      key="$(lookup_one "$server_file" "^[[:space:]]*this\\.${property} = endpoints\\.([A-Za-z0-9]+);\$" "\${$token}")" || exit $?
      value="$(lookup_one "$endpoints_file" "^[[:space:]]*${key}: string = '([^']*)';\$" "\${$token} (endpoints.$key)")" || exit $?
    elif [[ "$token" =~ $re_constant ]]; then
      value="$(lookup_one "$constants_file" "^export const ${token} = '([^']*)';\$" "\${$token}")" || exit $?
    else
      parse_failed "could not resolve \${$token} in route template \`$template\`: not a this.endpoint* property or an UPPER_CASE constant."
    fi
    prefix="${before}${value}${rest}"
  done

  if [[ ! "$prefix" =~ $re_prefix ]]; then
    parse_failed "route template \`$template\` resolves to '$prefix', which is not a plain literal path."
  fi
  routes+="$prefix"$'\n'
done <<<"$statements"

routes="$(sort -u <<<"$routes" | grep . || true)"
[[ -n "$routes" ]] || parse_failed "found no route registration in the \`if (this.webhooksEnabled)\` block of $SERVER_PATH."

# ── Compare ───────────────────────────────────────────────────────────────────
# covers <entry> <route>: Kubernetes pathType Prefix, element-wise. A trailing
# slash on the entry is ignored, as Kubernetes ignores it.
covers() {
  local entry="${1%/}" route="$2"
  [[ "$route" == "$entry" || "$route" == "$entry/"* ]]
}

missing=""
while IFS= read -r route; do
  covered=false
  while IFS= read -r entry; do
    if covers "$entry" "$route"; then covered=true; break; fi
  done <<<"$entries"
  $covered || missing+="  $route"$'\n'
done <<<"$routes"

stale=""
retained=""
while IFS= read -r entry; do
  used=false
  while IFS= read -r route; do
    if covers "$entry" "$route"; then used=true; break; fi
  done <<<"$routes"
  $used && continue
  if grep -qxF -- "$entry" <<<"$RETAINED_PREFIXES"; then
    retained+="  $entry"$'\n'
  else
    stale+="  $entry"$'\n'
  fi
done <<<"$entries"

if [[ -n "$retained" ]]; then
  echo "Retained on purpose (RETAINED_PREFIXES), although no registered route needs them:"
  printf '%s' "$retained"
fi

if [[ -n "$missing" || -n "$stale" ]]; then
  {
    echo "MISMATCH: $LOCAL_NAME in $LOCALS_FILE does not match the production webhook routes of $subject."
    if [[ -n "$missing" ]]; then
      echo
      echo "n8n registers these routes, and no entry covers them. The Ingress sends them to the"
      echo "main pods, which do not serve them, so the workflow never runs (a POST returns 404,"
      echo "a GET returns the editor page):"
      printf '%s' "$missing"
      echo "Append an entry for each to $LOCAL_NAME."
    fi
    if [[ -n "$stale" ]]; then
      echo
      echo "These entries cover no route n8n registers in that block. The Ingress sends them to"
      echo "the webhook processors, which may no longer serve them:"
      printf '%s' "$stale"
      echo "For each, either remove it (the list is a public output, so that is a change callers"
      echo "see, and callers who pin an older n8n_image_tag may still need it), or keep it and"
      echo "name it in RETAINED_PREFIXES_DEFAULT in tests/scripts/check-webhook-routes.sh."
    fi
    echo
    echo "Source: $source_ref"
  } >&2
  exit 1
fi

echo "OK: $LOCAL_NAME in $LOCALS_FILE matches the $(grep -c . <<<"$routes") production webhook routes of $subject."
