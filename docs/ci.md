# CI & Release pipeline

Moddex ships as three repositories that are assembled into a single installable
Linux bundle:

| Repo | Visibility | Role |
|------|-----------|------|
| `aklozyp/Moddex` (this repo) | public | packaging, installer, CLI, workflows |
| `aklozyp/Moddex-Backend` | private | Kotlin/Spring Boot backend (`app.jar`) |
| `aklozyp/Moddex-Frontend` | private | Angular frontend (static assets) |

Two GitHub Actions workflows cover build validation and releases.

## Required secret: `MODDEX_CHECKOUT_TOKEN`

Both workflows check out all three repositories into the sibling layout that
[`scripts/build-bundle.sh`](../scripts/build-bundle.sh) expects
(`<workspace>/{Moddex-build,Moddex-Backend,Moddex-Frontend}`).

Because **Moddex-Backend and Moddex-Frontend are private**, the default
`GITHUB_TOKEN` (scoped to this public repo only) cannot read them. Provide a
token with read access to all three repositories:

1. Create a fine-grained PAT (or classic PAT with `repo` scope) that can read
   `aklozyp/Moddex`, `aklozyp/Moddex-Backend` and `aklozyp/Moddex-Frontend`.
2. Add it as a repository (or organization) secret named `MODDEX_CHECKOUT_TOKEN`.

The workflows fall back to `GITHUB_TOKEN` when the secret is absent, so they
still parse and run, but the private checkouts then fail with a clear
permission error.

## `ci.yml` — build validation

Triggers: push and pull requests to `develop`, `tests`, `main`, plus manual
dispatch.

For every change it runs, across a runner matrix:

- backend tests (`mvnw -Pci test`),
- frontend tests (`ChromeHeadless`, `--watch=false`),
- the full bundle assembly (`build-bundle.sh`), which also runs the production
  backend package and frontend build.

The job **fails on any backend or frontend build/test error**. The assembled
bundle and its SHA256 checksum are uploaded as a versioned workflow artifact
(`moddex-bundle-<os>`, label `ci-<run>-<os>`), retained for 14 days.

### Target matrix

| Runner | Covers |
|--------|--------|
| `ubuntu-22.04` | Debian 12 / Ubuntu 22.04 class (older glibc) |
| `ubuntu-24.04` | Ubuntu 24.04 class (newer glibc) |

The artifacts are a Java JAR plus static frontend assets and installer scripts,
so they are not glibc-linked; the matrix mainly guards against
toolchain/runner drift across the supported Debian/Ubuntu range.

**Arch Linux** has no GitHub-hosted runner and is treated as **experimental**:
the native bundle is expected to work on Arch (systemd, OpenJDK 17+), but it is
not validated in CI. Add a self-hosted Arch runner to the matrix to cover it.

## `release.yml` — tag-driven release

Triggers: pushing a `v*` tag, or manual dispatch with an explicit `tag` input.

All three repositories must carry the release tag (or you pass the ref via
`workflow_dispatch`). The release builds on a single pinned **`ubuntu-22.04`**
runner so the artifact links against the oldest still-supported glibc and runs
on the broadest range of Debian/Ubuntu targets.

Steps: checkout all three repos at the tag → backend tests → `build-bundle.sh`
→ verify the SHA256 checksum → publish a GitHub Release with:

- `moddex-<tag>-linux-amd64.tar.gz` (versioned bundle),
- `moddex-<tag>-linux-amd64.tar.gz.sha256`,
- `download.sh` + `download.sh.sha256` (the bootstrap installer fetcher).

### Cutting a release

1. Ensure `ci.yml` is green on the source branches.
2. Tag the same `v<version>` in **all three** repositories.
3. Pushing the tag in `aklozyp/Moddex` triggers `release.yml`. (Or run it
   manually via *Actions → release → Run workflow* with the tag input.)

## Out of scope for v0.2

**Windows packaging** is a **v0.3** target (epic
[#26](https://github.com/aklozyp/Moddex/issues/26)) and intentionally does not
gate v0.2. The current pipeline produces Linux artifacts only; a Windows job can
be added to the matrix when v0.3 work begins.
