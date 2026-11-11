#!/usr/bin/env bash
# Offline regression test for tests/scripts/check-webhook-routes.sh.
#
# That script reads n8n's TypeScript source by text matching and compares the
# routes it finds with local.n8n_webhook_path_prefixes. Most of its outcomes
# cannot be produced on demand from real n8n source: a stale entry, a
# reformatted block, a token it cannot resolve. Without this test, the
# "PARSE FAILED" path would first run for real on the day n8n changes the
# block, which is the day it has to work.
#
# Every case writes small fixture files into a temporary directory, runs the
# real script against them through its test hooks (N8N_SOURCE_DIR,
# LOCALS_FILE, RETAINED_PREFIXES), and asserts the exit code and one line of
# the output. No network, no Helm, no Terraform.
#
# The fixtures are hand-written stubs. They copy only the shape the parser
# reads, a few lines each, and no n8n file: n8n's source is under the
# Sustainable Use License and this repository is MIT. Whether the parser still
# understands the real file is the live check's job, which runs in the same
# CI job right after this test.
#
# Usage: tests/scripts/test-check-webhook-routes.sh
# Requires: bash, awk, grep, sed.

set -euo pipefail

cd "$(dirname "$0")/../.."

SCRIPT="tests/scripts/check-webhook-routes.sh"
SERVER_PATH="packages/cli/src/abstract-server.ts"
ENDPOINTS_PATH="packages/@n8n/config/src/configs/endpoints.config.ts"
CONSTANTS_PATH="packages/core/src/utils/hitl-callback-reference.ts"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

FAILURES=0

fail() {
  echo "FAIL: $1" >&2
  FAILURES=$((FAILURES + 1))
}

pass() {
  echo "PASS: $1"
}

# ── Fixtures ──────────────────────────────────────────────────────────────────
# new_case <name>: creates $tmp/<name>/ with a matching set of files and points
# SRC and LOCALS at it. A case then overwrites the one file it wants to break.
# The baseline registers four routes: two prefix families, and two fixed paths
# built from a suffix constant (the shape behind #211).
new_case() {
  SRC="$tmp/$1/src"
  LOCALS="$tmp/$1/locals.tf"
  mkdir -p "$SRC/$(dirname "$SERVER_PATH")" "$SRC/$(dirname "$ENDPOINTS_PATH")" "$SRC/$(dirname "$CONSTANTS_PATH")"
  write_server
  write_endpoints
  write_constants
  write_locals
}

# write_server [extra statement]: the optional argument is inserted as the
# last statement of the production block.
write_server() {
  cat >"$SRC/$SERVER_PATH" <<EOF
export abstract class StubServer {
  constructor() {
    const { endpoints } = this.globalConfig;
    this.endpointWebhook = endpoints.webhook;
    this.endpointWebhookTest = endpoints.webhookTest;
    this.endpointWebhookWaiting = endpoints.webhookWaiting;
  }

  async start(): Promise<void> {
    if (this.webhooksEnabled) {
      const liveWebhooks = Container.get(LiveWebhooks);

      // A comment line, which the parser skips.
      this.app.all(\`/\${this.endpointWebhook}/*path\`, createWebhookHandlerFor(liveWebhooks, 'webhook'));

      this.app.all(
        \`/\${this.endpointWebhookWaiting}/:path{/:suffix}\`,
        createWebhookHandlerFor(Container.get(WaitingWebhooks)),
      );

      this.app.all(
        \`/\${this.endpointWebhookWaiting}\${SLACK_STUB_SUFFIX}\`,
        createWebhookHandlerFor(Container.get(SlackStub)),
      );
      ${1:-}
    }

    if (this.testWebhooksEnabled) {
      const testWebhooks = Container.get(TestWebhooks);
      this.app.all(\`/\${this.endpointWebhookTest}/*path\`, createWebhookHandlerFor(testWebhooks, 'webhook'));
    }
  }
}
EOF
}

write_endpoints() {
  cat >"$SRC/$ENDPOINTS_PATH" <<'EOF'
class StubEndpointsConfig {
  @Env('STUB_ENDPOINT_WEBHOOK')
  webhook: string = 'webhook';

  @Env('STUB_ENDPOINT_WEBHOOK_TEST')
  webhookTest: string = 'webhook-test';

  @Env('STUB_ENDPOINT_WEBHOOK_WAIT')
  webhookWaiting: string = 'webhook-waiting';
}
EOF
}

write_constants() {
  cat >"$SRC/$CONSTANTS_PATH" <<'EOF'
export const SLACK_STUB_SUFFIX = '-slack';
EOF
}

# write_locals <line>...: each argument becomes one line inside the list.
write_locals() {
  if [ "$#" -eq 0 ]; then
    set -- '"/webhook",' '"/webhook-waiting",' '"/webhook-waiting-slack",'
  fi
  {
    echo 'locals {'
    echo '  n8n_service_port = 5678'
    echo ''
    echo '  # A comment above the list.'
    echo '  n8n_webhook_path_prefixes = ['
    for line in "$@"; do
      echo "    $line"
    done
    echo '  ]'
    echo '}'
  } >"$LOCALS"
}

# ── Harness ───────────────────────────────────────────────────────────────────
# check_case <label> <expected exit> <text the output must contain> [line]
# Runs the real script against SRC and LOCALS. RETAINED is passed through as
# RETAINED_PREFIXES and reset after every case. With "line" as the fourth
# argument the text must be a whole output line, which is how the cases that
# name a path tell "/webhook" from "/webhook-waiting".
RETAINED=""
check_case() {
  local label="$1" expected="$2" needle="$3" match="-qF" actual output
  [ "${4:-}" = "line" ] && match="-qxF"
  if output="$(LOCALS_FILE="$LOCALS" N8N_SOURCE_DIR="$SRC" RETAINED_PREFIXES="$RETAINED" bash "$SCRIPT" 2>&1)"; then
    actual=0
  else
    actual=$?
  fi
  RETAINED=""
  if [ "$actual" != "$expected" ]; then
    fail "$label: exit $actual, expected $expected. Output: $output"
  elif ! grep "$match" -- "$needle" <<<"$output"; then
    fail "$label: exit $actual as expected, but the output does not contain '$needle'. Output: $output"
  else
    pass "$label -> exit $actual"
  fi
}

# ── Exit 0: the lists agree ───────────────────────────────────────────────────
new_case match
check_case "lists match" 0 "OK:"

new_case retained
write_locals '"/webhook",' '"/webhook-waiting",' '"/webhook-waiting-slack",' '"/legacy",'
RETAINED="/legacy"
check_case "a stale entry named in RETAINED_PREFIXES is accepted and reported" 0 "  /legacy" line

# ── Exit 1: the lists disagree ────────────────────────────────────────────────
new_case uncovered
write_locals '"/webhook-waiting",' '"/webhook-waiting-slack",'
check_case "a registered route no entry covers is named" 1 "  /webhook" line

# The #211 regression: under pathType Prefix, "/webhook-waiting" matches
# "/webhook-waiting" and "/webhook-waiting/...", not "/webhook-waiting-slack".
new_case prefix_semantics
write_locals '"/webhook",' '"/webhook-waiting",'
check_case "/webhook-waiting does not cover /webhook-waiting-slack" 1 "  /webhook-waiting-slack" line

new_case stale
write_locals '"/webhook",' '"/webhook-waiting",' '"/webhook-waiting-slack",' '"/legacy",'
check_case "a stale entry is named" 1 "  /legacy" line

new_case commented_entry
write_locals '"/webhook",' '"/webhook-waiting",' '# "/webhook-waiting-slack",'
check_case "a commented-out entry is not coverage" 1 "  /webhook-waiting-slack" line

# ── Exit 2: could not check ───────────────────────────────────────────────────
new_case block_missing
sed 's/this\.webhooksEnabled/this.productionWebhooks/' "$SRC/$SERVER_PATH" >"$SRC/$SERVER_PATH.new"
mv "$SRC/$SERVER_PATH.new" "$SRC/$SERVER_PATH"
check_case "a missing production block" 2 "PARSE FAILED"

new_case concatenation
write_server "this.app.all(\`/\${this.endpointWebhook}\` + '-new', createWebhookHandlerFor(liveWebhooks, 'webhook'));"
check_case "a path built by concatenation" 2 "PARSE FAILED"

# A chained registration is one statement that registers two routes. Reading
# only the first would report OK for a route nobody compared.
new_case chained_all
write_server "this.app.all(\`/\${this.endpointWebhook}/*path\`, createWebhookHandlerFor(liveWebhooks)).all(\`/new/*path\`, createWebhookHandlerFor(liveWebhooks));"
check_case "a second route chained onto a registration" 2 "PARSE FAILED"

new_case chained_other_method
write_server "this.app.all(\`/\${this.endpointWebhook}/*path\`, createWebhookHandlerFor(liveWebhooks)).get('/new', createWebhookHandlerFor(liveWebhooks));"
check_case "another method chained onto a registration" 2 "PARSE FAILED"

new_case helper_call
write_server "this.registerMoreWebhooks();"
check_case "an unrecognized statement in the block" 2 "this.registerMoreWebhooks()"

new_case unresolved_token
write_server "this.app.all(\`/\${this.endpointWebhook}\${UNKNOWN_SUFFIX}\`, createWebhookHandlerFor(liveWebhooks, 'webhook'));"
check_case "an unresolvable token is named" 2 "UNKNOWN_SUFFIX"

new_case ambiguous_default
cat >>"$SRC/$ENDPOINTS_PATH" <<'EOF'
class AnotherStubConfig {
  webhook: string = 'hook';
}
EOF
check_case "a name with two definitions is ambiguous" 2 "found 2"

new_case empty_list
{
  echo 'locals {'
  echo '  n8n_webhook_path_prefixes = ['
  echo '  ]'
  echo '}'
} >"$LOCALS"
check_case "an empty list" 2 "PARSE FAILED"

new_case expression_in_list
write_locals '"/webhook",' 'local.extra_prefix,'
check_case "an expression in the list instead of a literal" 2 "local.extra_prefix"

new_case missing_source_file
rm "$SRC/$CONSTANTS_PATH"
check_case "a source file that is not there" 2 "FETCH FAILED"

# ── Self-check: prove a wrong expectation is actually caught ──────────────────
# Runs one case with a deliberately wrong expected exit code in a subshell, so
# its FAILURES increment stays out of the real count, and confirms the harness
# reports it. Same idea as test-version-drift-constraints.sh.
new_case selfcheck
SELFTEST_OUTPUT="$(
  FAILURES=0
  fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }
  pass() { echo "PASS: $1"; }
  check_case "self-check" 1 "OK:"
  echo "FAILURES=$FAILURES"
)"

if grep -q "^FAILURES=1$" <<<"$SELFTEST_OUTPUT"; then
  pass "self-check: a deliberately wrong expected exit code is caught as a failure"
else
  fail "self-check: a deliberately wrong expected exit code was NOT caught (harness has no teeth): ${SELFTEST_OUTPUT}"
fi

echo ""
if [ "$FAILURES" -gt 0 ]; then
  echo "test-check-webhook-routes.sh: ${FAILURES} case(s) failed" >&2
  exit 1
fi

echo "test-check-webhook-routes.sh: all cases passed"
