# Releasing Moddex

How a maintainer cuts a Moddex release. The goal is that every published release
has reproducible artifacts **and** clear notes, so users see what changed and
which limitations still apply.

## Versioning

Moddex follows [Semantic Versioning](https://semver.org/): `vMAJOR.MINOR.PATCH`.
Tags are prefixed with `v` (e.g. `v0.4.0`). The same tag is applied to **all
three** repositories — `Moddex` (this one), `Moddex-Backend` and
`Moddex-Frontend` — because the release pipeline checks them out at that ref.

## What produces the release notes

Two layers, by design:

1. **Auto-generated, exhaustive.** `release.yml` passes
   `generate_release_notes: true` to the GitHub Release step, so GitHub lists
   every merged pull request since the previous tag. Pull requests are grouped
   into categories (Features, Bug Fixes, Security, Documentation, …) according to
   their labels — configured in [`.github/release.yml`](../.github/release.yml).
   Label your PRs accordingly so they land in the right section.
2. **Human-curated, high-level.** [`CHANGELOG.md`](../CHANGELOG.md) summarizes the
   noteworthy changes per version in Keep a Changelog format. Keep an
   `[Unreleased]` section at the top and add entries as features land, rather than
   reconstructing them at release time.

## Cutting a release

1. **Pass the release gate.** Work through
   [`docs/qa/release-checklist.md`](qa/release-checklist.md): CI green on the
   source branches, fresh-host install + `release-smoke-test.sh`, the
   `recovery-checklist.md` blocker rows, and update-resistance (a second installer
   run preserves config + data). A release is **blocked** if any checked smoke
   step fails or any 🚫 recovery row regresses.
2. **Finalize the changelog.** In `CHANGELOG.md`, rename the `[Unreleased]`
   section to the new version with today's date, add a fresh empty `[Unreleased]`
   above it, and update the compare links at the bottom.
3. **Note known limitations.** Make sure the changelog / release call out
   experimental features and platform status (the auto-notes do not). See the
   "known limitations" rows in `recovery-checklist.md`.
4. **Tag all three repos** with the same tag and push:
   ```bash
   TAG=v0.4.0
   for repo in Moddex Moddex-Backend Moddex-Frontend; do
     git -C "../$repo" tag -a "$TAG" -m "Moddex $TAG" && git -C "../$repo" push origin "$TAG"
   done
   ```
   Pushing the tag to `Moddex` triggers [`release.yml`](../.github/workflows/release.yml),
   which builds the Linux bundle and (in a dependent job) the Windows bundle, then
   publishes the GitHub Release with checksums and the generated notes.
   Alternatively, run the `release` workflow via **workflow_dispatch** and pass the
   tag explicitly.
5. **Verify the published release.** Confirm both the Linux tarball and the
   Windows zip (plus their `.sha256` files) are attached and that the notes
   rendered. Spot-check a checksum.

## Prerequisites

- A repository/organization secret `MODDEX_CHECKOUT_TOKEN` with read access to all
  three repos (the backend/frontend repos are private). See [`docs/ci.md`](ci.md).

## Related

- [Release checklist](qa/release-checklist.md) — the pre-tag smoke gate.
- [CHANGELOG](../CHANGELOG.md).
- [Upgrade & rollback guide](upgrade.md) — what users do with a new release.
