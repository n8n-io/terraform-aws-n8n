<!--
Thanks for the contribution. Filling out this template makes review
much faster. Anything you don't need, delete.
-->

## Summary

<!-- One paragraph: what does this PR change, and why? -->

## Linked issue

<!-- Closes #123, or "N/A" for trivial fixes. -->

## Stability impact

<!--
See README.md → Stability & versioning for the contract.
Tick exactly one. If "minor", call out specifically what changes (input
renames, default changes that move infra, resource-address refactors,
provider-version bumps, etc.).
-->

- [ ] **Patch-eligible** — additive only (new optional input, new output, new resource that doesn't disturb existing state, bug fix, docs).
- [ ] **Minor-only** — changes existing defaults, renames or removes inputs, refactors resource addresses, or bumps provider version floors.

## Checklist

- [ ] `terraform fmt -recursive` is clean.
- [ ] `terraform validate` passes at the module root.
- [ ] `terraform test -verbose` passes at the module root and on any example I touched.
- [ ] `tflint --format compact` is clean at any directory I touched.
- [ ] If I added or renamed an input/output, I ran `terraform-docs markdown table --output-file README.md --output-mode inject .` and committed the refreshed README.
- [ ] If I added a non-trivial new behavior, I added a plan-time assertion in the relevant `.tftest.hcl` file.
- [ ] If this is a minor-only change, I updated `CHANGELOG.md` under `[Unreleased]` with an upgrade note.
- [ ] Conventional Commits style on the commit subject (`feat`, `fix`, `docs`, `refactor`, `test`, `chore`, …).

## Notes for the reviewer

<!-- Anything else: design decisions, things you considered and dropped, areas you want extra eyes on. -->
