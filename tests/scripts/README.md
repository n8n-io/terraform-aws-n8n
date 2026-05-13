# Smoke test

Post-deployment smoke test for `terraform-aws-n8n`. Verifies the multi-main deployment is healthy end to end — pod health, queue mode, KEDA, HTTPS, API, and a full webhook → worker execution.

## What it covers

| Check | What it verifies |
|---|---|
| kubectl cluster connectivity | kubectl can reach the EKS cluster |
| Namespace exists | The configured namespace is present |
| Main / worker / webhook-processor pod health | Each deployment is at the expected ready replica count |
| Task runner sidecar (workers) | Runner sidecar is present on worker pods and connected to the broker |
| Multi-main leader election | `N8N_MULTI_MAIN_SETUP_ENABLED=true` and leadership activity in main logs |
| Autoscalers | KEDA `ScaledObject` (workers, queue-depth) and HPAs (main, webhook-processor) |
| Redis connectivity | Worker pods see `QUEUE_BULL_REDIS_HOST` and queue-related log activity |
| HTTPS reachability | `/healthz` returns HTTP 200 over the ALB hostname |
| HTTP → HTTPS redirect | Port 80 redirects to HTTPS |
| API connectivity (if API key set) | `/api/v1/workflows` responds with 200 |
| Workflow execution (if API key set) | Creates a webhook → set workflow, fires it, confirms success, deletes it |
| Worker scaling (opt-in) | Queues CPU-burning executions and confirms workers scale up |

## Quick start

The script reads `namespace`, `n8n_url`, and `kubectl_config_command` automatically from `terraform output`.

```bash
cd examples/small              # or wherever your terraform.tfstate lives
../../tests/scripts/smoke-test.sh
```

The script automatically:

1. Reads `namespace` and `n8n_url` from Terraform state
2. Runs the `kubectl_config_command` output to point kubectl at the right cluster
3. Runs all checks and prints a pass / fail / warn / skip summary

> **Note:** Run the script from the directory that holds `terraform.tfstate` (e.g. `examples/small/`), not from `tests/scripts/`. The script calls `terraform output` against the current working directory by default.

## API key (required for API and execution tests)

The API connectivity and workflow execution checks need an n8n API key. Without one, those checks are skipped with a warning.

1. Open your n8n instance in a browser.
2. Go to **Settings → API → Create API Key**.
3. Copy the key.

Set it before running the script:

```bash
N8N_API_KEY=your-key-here ../../tests/scripts/smoke-test.sh
```

Or persist it in a `.env` file. The script looks for `.env` next to itself first, then in the current working directory:

```bash
cp ../../tests/scripts/.env.example ../../tests/scripts/.env
# edit .env, set N8N_API_KEY, then:
../../tests/scripts/smoke-test.sh
```

## Configuration

All settings can be overridden via environment variables or a `.env` file.

| Variable | Default | Description |
|---|---|---|
| `TERRAFORM_DIR` | `$(pwd)` | Path to Terraform directory to read state from |
| `N8N_URL` | *(from `terraform output`)* | Base URL of the n8n deployment |
| `NAMESPACE` | *(from `terraform output`)* | Kubernetes namespace |
| `N8N_API_KEY` | — | API key for API and workflow execution tests |
| `DEPLOY_MODE` | *(auto-detect)* | Force `multi` (or `single`) and skip detection |
| `LOAD_TEST` | `false` | Set to `true` to run the worker scaling test |
| `LOAD_REQUESTS` | `100` | Webhook executions to fire during the load test |
| `LOAD_CONCURRENCY` | `20` | Concurrent in-flight webhook calls |
| `LOAD_SEED_JOBS` | `20` | Jobs queued in phase 1 to trigger the autoscaler |
| `LOAD_JOB_DURATION_SECS` | `10` | CPU burn per worker job (seconds) |
| `SCALE_WAIT_SECS` | `180` | Seconds to wait for the autoscaler to react |

**Priority:** `.env` values → environment variables → Terraform outputs → built-in defaults.

## Worker scaling test (opt-in)

The scaling test creates real load and is therefore opt-in:

```bash
LOAD_TEST=true N8N_API_KEY=your-key ../../tests/scripts/smoke-test.sh
```

What it does:

1. Pre-checks the autoscaler — KEDA `ScaledObject` (preferred for workers) or CPU-based HPA. Skips if neither is found, or if HPA metrics are `<unknown>` (metrics-server not ready).
2. Creates a temporary n8n workflow with a Code node that burns CPU for `LOAD_JOB_DURATION_SECS` seconds per execution.
3. Activates it and queues `LOAD_SEED_JOBS` webhook calls in phase 1 to trigger the autoscaler.
4. Polls every 15 seconds for up to `SCALE_WAIT_SECS` seconds, watching worker replicas climb.
5. Once scale-up is detected, queues the remaining `LOAD_REQUESTS - LOAD_SEED_JOBS` calls (phase 2) so the new workers visibly pick up jobs.
6. Deactivates and deletes the test workflow (cleanup runs even on failure).

If workers don't scale within the wait window, the script warns and suggests increasing `LOAD_REQUESTS` or `LOAD_JOB_DURATION_SECS`.

## Running against a remote deployment

You can run without local Terraform state — for example against a cluster managed by someone else — by setting everything explicitly:

```bash
NAMESPACE=n8n \
N8N_URL=https://n8n.example.com \
N8N_API_KEY=your-key \
./tests/scripts/smoke-test.sh
```

You're responsible for pointing kubectl at the right cluster yourself in that case (the script only switches contexts when it can read `kubectl_config_command` from Terraform).

## Exit codes

| Code | Meaning |
|---|---|
| `0` | All checks passed (warnings are non-fatal) |
| `1` | One or more checks failed |

The summary line always prints the counts: `Passed: X  Failed: Y  Warnings: Z  Skipped: W`.
