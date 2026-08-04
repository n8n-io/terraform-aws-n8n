# Post-deployment scripts

Two manual verification scripts. Neither runs in CI: both need a live cluster, which a pull request check cannot provide.

| Script | Use it when |
|---|---|
| [`smoke-test.sh`](#smoke-test) | Always, after any deploy. Checks the deployment is healthy end to end. |
| [`verify-custom-image.sh`](#custom-image-verification) | The deployment sets `n8n_image_repository` and `n8n_custom_extensions_path` to bake community packages into the image. |

## Smoke test

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

## Custom image verification

`verify-custom-image.sh` covers what `smoke-test.sh` cannot: a deployment can be perfectly healthy and still have its baked nodes silently unloaded. The specific failure it exists to catch is **asymmetric loading**, where a node type resolves on main pods but not on workers. That looks correct in the editor and fails only when a production execution reaches the node.

```bash
cd examples/small
../../tests/scripts/verify-custom-image.sh
```

### What it covers

| Check | What it verifies |
|---|---|
| Image consistency | Every pod type runs the same image, so a half-finished rollout is not mistaken for a loading bug |
| Task runner sidecar | The runner image resolves and nothing is stuck in `ImagePullBackOff`, the symptom of a custom `n8n_image_tag` with no `n8n_task_runner_image_tag` |
| Extensions path | `N8N_CUSTOM_EXTENSIONS` is set, and set *identically*, on main, worker, and webhook-processor |
| Shadowed directory | The path is outside `/home/node/.n8n`, which the chart mounts over on main pods only |
| Baked files on disk | At least one `*.node.js` exists under the path, on every pod type |
| Loaded node types | n8n's generated type list contains at least one `CUSTOM.*` type. This is the difference between present on disk and actually loaded |
| Boot-time installs | Warns if `N8N_REINSTALL_MISSING_PACKAGES=true`, which reintroduces the per-pod npm install that baking exists to remove |
| Execution (opt-in) | Runs a workflow using a baked node through the queue, proving a *worker* resolved the type |

### The execution check

Everything above proves main loaded the nodes. None of it proves a worker did, because workers serve no type list. Only executing a workflow that uses a baked node settles that, and it needs a workflow specific to whichever node you baked, so you supply one:

```bash
CUSTOM_NODE_WORKFLOW=./my-node-test.json \
  ../../tests/scripts/verify-custom-image.sh
```

The file is a workflow JSON with two requirements: a webhook trigger, which is what routes the execution to a worker instead of the main process, and at least one node whose `type` starts with `CUSTOM.`. The script rewrites the webhook path to a unique value, creates and activates the workflow, fires it, waits for the execution, then deactivates and deletes it.

```json
{
  "nodes": [
    { "id": "a", "name": "Webhook", "type": "n8n-nodes-base.webhook", "typeVersion": 2,
      "position": [0, 0],
      "parameters": { "httpMethod": "POST", "path": "placeholder", "responseMode": "lastNode" } },
    { "id": "b", "name": "Baked", "type": "CUSTOM.myNode", "typeVersion": 1,
      "position": [220, 0], "parameters": {} }
  ],
  "connections": { "Webhook": { "main": [[{ "node": "Baked", "type": "main", "index": 0 }]] } },
  "settings": { "executionOrder": "v1" }
}
```

Use the type name *as n8n loaded it*. A package installed from npm as `n8n-nodes-example.myNode` becomes `CUSTOM.myNode` once baked, because the custom directory loader registers everything under the package name `CUSTOM`. Run the script once without a workflow and it lists the loaded `CUSTOM.*` types.

A workflow with no `CUSTOM.*` node is rejected rather than run. It would execute and report success while proving nothing, which is worse than not running it at all.

### Settings

| Variable | Effect |
|---|---|
| `CUSTOM_NODE_WORKFLOW` | Path to the workflow JSON above. Enables the execution check (also needs `N8N_URL` and `N8N_API_KEY`) |
| `EXPECT_IMAGE_REPOSITORY` | Assert the deployed repository matches this exactly |
| `EXPECT_EXTENSIONS_PATH` | Assert `N8N_CUSTOM_EXTENSIONS` matches this exactly |

Against a deployment that sets no custom extensions path, the script warns and exits 0 rather than failing, so it is safe to run anywhere.

## Exit codes

Both scripts share these.

| Code | Meaning |
|---|---|
| `0` | All checks passed (warnings are non-fatal) |
| `1` | One or more checks failed |

The summary line always prints the counts: `Passed: X  Failed: Y  Warnings: Z  Skipped: W`.
