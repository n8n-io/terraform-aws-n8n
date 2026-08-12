# Customer-managed infrastructure

This module defaults to greenfield: it creates the EKS cluster, RDS,
ElastiCache Redis, S3, and the cluster controllers. Most layers can
instead be pointed at infrastructure you already run, which is the shape
an enterprise with an existing platform team most often needs: consume
existing infrastructure rather than duplicate it.

See [README.md → "Customer-managed infrastructure"](../README.md#customer-managed-infrastructure)
for the current per-layer table (what's supported today and which
variables each layer takes). This doc covers the convention itself, for
anyone adding a new customer-managed layer or reviewing a PR that does.

## The convention

Every layer follows the same three-part shape:

1. **A `create_<x>` (or `install_<x>`) boolean, default `true`.** Flipping
   it to `false` skips every resource that layer owns and switches the
   module onto a caller-supplied reference instead. Existing deployments
   are unaffected by the addition of a new toggle, since the default
   always reproduces today's behavior.
2. **One or more reference inputs**, required only when the toggle is
   `false`, e.g. `existing_eks_cluster_name`, `redis_host`,
   `existing_s3_bucket_name`. Ignored (and flagged by a `check` block, not
   a hard error) when the toggle is `true`, since supplying a reference
   the module isn't using is a likely sign of a misconfigured deployment
   rather than a deliberate no-op.
3. **Cross-variable `validation` and `check` blocks** that catch the
   incomplete-configuration cases at plan time: the toggle is `false` but
   the reference is missing (hard error), or the toggle is `true` but a
   reference was supplied anyway (warning, since it plans and applies
   clean while silently discarding what the caller asked for).

## Why a static boolean, not `x == null` inference

Terraform's `count` (and `for_each`) cannot depend on a value that's only
known at apply time, and inferring "does the caller want this
customer-managed" from whether a reference variable is null gets
uncomfortably close to that boundary in several of this module's own
variables (e.g. computed defaults, `try()`-wrapped fallbacks). A plain
boolean sidesteps the whole class of problem: `count = var.create_x ? 1 : 0`
is always knowable at plan time, no matter what expression backs
`var.create_x`'s default. Follow `create_database` (`database.tf`,
`variables.tf`) as the reference implementation: it's the oldest of
these toggles and the one every later one was modeled on.

## Adding a new customer-managed layer

1. Add the boolean and reference variable(s) to `variables.tf`, following
   the naming precedent: `create_<x>` for something the module can fully
   own or not, `install_<x>` for an optional Helm-installed controller,
   `existing_<x>_name` (not `<x>_name`) for a reference to something the
   caller already runs.
2. Gate every resource that layer owns with `count = var.create_<x> ? 1 : 0`
   (or the `install_<x>` equivalent). Gate *all* of it: a layer that
   creates an IAM role, a security group, and a Helm release needs all
   three gated, not just the most visible resource. The Load Balancer
   Controller and Cluster Autoscaler toggles are the cautionary example
   here, and a subtler one than "forgot to add a `count`": their
   `helm_release` was correctly gated on `install_lbc`/
   `install_cluster_autoscaler`, but their Pod Identity association was
   left fully unconditional, on the deliberate (and, for a freshly
   created cluster, correct) reasoning that an externally-installed
   controller still needs the IAM binding. That reasoning silently broke
   down on `create_eks = false`: pointed at an existing cluster that
   already carries that ServiceAccount's association (e.g. from a
   previous invocation of this exact module against the same cluster),
   the unconditional association collided with EKS's one-role-per-
   ServiceAccount constraint (`409 ResourceInUseException`), confirmed
   live. The fix (`modules/controllers/iam.tf`) is a compound gate,
   `var.create_eks || var.install_<x>`, not a bare toggle: a resource
   whose "should I exist" answer depends on more than its own layer's
   toggle is a sign the layer isn't as independent as the three-part
   convention above assumes, and deserves the same scrutiny before
   shipping, not just a `count` on the most visible resource.
3. Add the "ignored when both are set"/"required when toggle is false"
   `check`/`validation` blocks, following `database.tf`'s or `redis.tf`'s
   `check` blocks as the template.
4. Re-expose whatever the module can create as an output too (reference +
   output symmetry), so a downstream consumer or an external worker fleet
   can wire to the same coordinates regardless of who owns the resource.
5. Add `tftest` coverage in `tests/defaults.tftest.hcl` for both the
   happy path (toggle `false`, references supplied, resources skipped)
   and the failure path (toggle `false`, references missing, plan
   rejected).
6. Regenerate `README.md` with `terraform-docs .` and add a row to the
   "Customer-managed infrastructure" table if the layer is one an
   external caller would look for.

## `create_eks = false` + `create_ingress = true`: no supported path when the existing cluster's LBC wasn't installed by this invocation

`install_lbc = false` is hard-rejected at plan time whenever `create_ingress
= true` (`variables.tf`'s validation on `install_lbc`), with no exception
for `create_eks = false`. This means that today, pointing this module at an
existing cluster that already runs a working AWS Load Balancer Controller
(installed by a platform team, by a previous invocation of this exact
module, or by anything else) gives exactly two options, not three:

1. **`install_lbc = true`.** This module installs its own, second LBC
   release alongside the one already running. **Not recommended** when the
   existing cluster already has one: two independent LBC controllers
   watching the same `IngressClass` and validating-webhook configuration is
   a real conflict risk, not a theoretical one: this is why the live EKS-
   layer validation for this PR deliberately set `install_lbc = false`
   rather than attempt it. Only reach for this option if the existing LBC
   is scoped to a different `IngressClass` this module's `create_ingress`
   path won't touch.
2. **`create_ingress = false`.** This module creates and manages no Ingress
   resource for n8n at all. Bring your own `kubernetes_ingress_v1` (or
   equivalent) pointed at the already-running LBC, outside this module.
   This is the only path validated live for this PR's `create_eks = false`
   layer, and the one the validation's own error message already points
   to.

There is currently no third option of "trust the existing cluster's LBC and
let this module still manage the n8n Ingress resource," even though that is
arguably the more natural ask on an existing, shared cluster.
`existing_eks_cluster_prerequisites_confirmed`'s own four attestations
(`variables.tf`) don't cover "there is already a working Ingress
controller here" either, worth adding as a fifth if this gap is ever
closed. Relaxing `install_lbc`'s validation to allow `install_lbc = false`
together with `create_ingress = true`, specifically when `create_eks =
false` (reading that combination as "an LBC already exists and is healthy,
wire my Ingress to it"), is a reasonable future enhancement; it is not
implemented here, and
is left as a known limitation rather than fixed under this pass, since it
touches the module's plan-time validation contract and deserves its own
review rather than a same-pass bundling with the Pod Identity gating fix
above.

## What's deliberately not supported

**Adoption via `terraform import`.** Pulling pre-existing,
non-Terraform-managed infrastructure under this module's management is
intentionally out of scope. `terraform import` is brittle at the scale
this module operates across, and `terraform plan -generate-config-out`
config generation is error-prone over the many resources it owns.
Bring infrastructure under Terraform management in your own
configuration first, then reference it here with the toggles above.

**Data-source verification of a customer-managed resource's security
configuration**, in general. It's tempting to add a `data` source that
reads back a caller-supplied bucket's encryption configuration or a
caller-supplied Redis's TLS settings and warns if it looks unsafe, and
this has been considered and rejected more than once (see the comment
above `check "s3_kms_key_arn_region_matches"` in `s3.tf` for the fullest
writeup). The cost is real on both counts: it's an AWS API call at plan
time, which hard-fails for anyone whose Terraform credentials can't read
that specific resource (a cross-account bucket, a Redis in another
account entirely), and it only ever proves presence, not that the
protection is configured the way the caller intends. Where a security
property genuinely can be checked from the caller's own inputs, this
module does check it (e.g. warning when `redis_auth_token` is empty on
the customer-managed Redis path). Where it can't be checked without a
plan-time AWS call, the module documents the expectation instead of
asserting it.
