# Contributing

Thanks for considering a contribution to `terraform-aws-n8n`.

## Before you start

- Open an [issue](https://github.com/n8n-io/terraform-aws-n8n/issues)
  for anything non-trivial before opening a PR. Aligning on the
  approach first avoids wasted work on both sides.
- For security findings, **do not** open a public issue. See
  [`SECURITY.md`](./SECURITY.md).
- For general n8n questions (not specific to this module), use the
  [n8n community forum](https://community.n8n.io/) instead.

## Development setup

The deep guide for working in this repo lives in [`AGENTS.md`](./AGENTS.md)
— read it before making changes. It covers the local validation loop,
the test framework, and the quality bar this module is held to.

The short version:

```bash
# Stub credentials so the veksh/godaddy-dns provider initializes during
# `terraform test`. Required once per shell session.
export GODADDY_API_KEY=stub GODADDY_API_SECRET=stub

terraform fmt -recursive
terraform init -backend=false
terraform validate
terraform test -verbose
tflint --init && tflint --format compact
terraform-docs --output-check .
```

Repeat the `init / validate / test / tflint / terraform-docs` block
under each example directory (`examples/small`, `examples/medium`,
`examples/large`, `examples/cloudflare`, `examples/godaddy`) — that
mirrors the CI matrix exactly. CI will run the same matrix on your PR.

## Commit messages

We follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<optional scope>): <imperative summary, <72 chars>

<optional body explaining the why>
```

Common types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`.
Scope is optional but useful (e.g. `feat(database): add Aurora
Multi-AZ option`). Use the imperative mood ("add", not "added" or
"adds").

## Pull requests

- Open PRs against `main`. Don't push directly to `main`; it's
  protected.
- One logical change per PR. Smaller PRs review faster.
- If you add a new input, surface it through a `terraform-docs`
  regeneration (`terraform-docs markdown table --output-file README.md
  --output-mode inject .`) — CI checks that the README is in sync.
- If you add a non-trivial new resource or behavior, add a plan-time
  assertion in `tests/defaults.tftest.hcl` (or the relevant example's
  test suite).
- All CI checks must be green before merge.

See [`AGENTS.md`](./AGENTS.md) for details on adding inputs, adding
resources, and what *not* to change.
