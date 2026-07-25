# CI & Release pipeline

Moddex ships as three repositories that are assembled into a single installable
Linux bundle:

| Repo | Visibility | Role |
|------|-----------|------|
| `aklozyp/Moddex` (this repo) | public | packaging, installer, CLI, workflows |
| `aklozyp/Moddex-Backend` | private | Kotlin/Spring Boot backend (`app.jar`) |
| `aklozyp/Moddex-Frontend` | private | Angular frontend (static assets) |

Two GitHub Actions workflows cover build validation and releases.

## Branch model

All three repositories use the same two long-lived branches:

| Branch | Role |
|--------|------|
| `develop` | Integration branch. Every ticket branch merges here. |
| `main` | Stable release line. Only updated when a release is cut. |

Work happens on per-ticket branches (`ai/<repo>/issue-<n>`) that target
`develop`. The app repos previously used a third branch, `tests`, as their
integration branch while `develop` sat unused and months out of date — which
made "check out `develop`" the wrong instruction and cost a full working session
before the divergence was noticed. `develop` has since been fast-forwarded onto
that history in both app repos, and `tests` is retained only for genuinely
experimental work that is not ready for integration.

## The pipeline script

Build, test and verification logic lives in
[`scripts/ci/pipeline.sh`](../scripts/ci/pipeline.sh), not in workflow YAML. The
workflows provide a checkout and a toolchain and then call it. The point is that
a green local run and a green CI run mean the same thing, and a CI failure can
be reproduced on a workstation without pushing a commit:

```bash
scripts/ci/pipeline.sh                    # everything
scripts/ci/pipeline.sh backend frontend   # selected stages
scripts/ci/pipeline.sh --list             # available stages
```

| Stage | What it does |
|-------|--------------|
| `tools` | Verifies the toolchain the selected stages need. |
| `lint` | `shellcheck` plus `bash -n` over the shell scripts, PSScriptAnalyzer over the PowerShell scripts, and a check that every script kept its executable bit. |
| `backend` | Backend unit tests (always `clean`) and the production JAR. |
| `frontend` | `npm ci`, headless unit tests, production build. |
| `bundle` | Assembles the installable bundle, reusing the artefacts the previous stages already built. |
| `verify` | Checks the assembled artefact: structure, file modes, no stray sources, checksum. |

### Missing tools fail the run

A stage whose tool is absent fails rather than being skipped, because a skipped
check that reports success is indistinguishable from a passing one.
`--allow-missing-tools` downgrades that to a warning for workstation use; **CI
never passes it**.

On a Debian/Ubuntu workstation:

```bash
sudo apt-get install -y shellcheck chromium
```

PowerShell is only needed for the Windows-installer analysis and is available as
a [self-contained tarball](https://github.com/PowerShell/PowerShell/releases).

### Why `clean` is not optional

The backend stage always runs `mvnw clean test`. Without it, Maven leaves
compiled test classes in `target/` and surefire runs classes whose sources are no
longer in the tree — which produces failures for tests that do not exist and,
worse, green runs for tests that were deleted.

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

Triggers: push and pull requests to `develop` and `main`, plus manual dispatch.

### Cross-repo refs

The backend/frontend checkouts are resolved per branch
([#53](https://github.com/aklozyp/Moddex/issues/53)): builds validating `main`
of this repo check out `main` of the app repos (reproducible release-line
builds); every other branch tracks the app repos' integration branch `develop`.
Manual dispatch accepts explicit `backend_ref`/`frontend_ref` overrides. The
resolved refs and their commit SHAs are recorded in the job summary of every
run.

The app repos additionally run their own slim test workflows on every push/PR
(`Moddex-Backend`: `mvnw -Pci test`; `Moddex-Frontend`: headless unit tests,
theme-contrast audit and AOT production build), so changes there are validated
without waiting for this repo's bundle build.

The job itself is thin: check out the three repos, install the toolchain, run
`scripts/ci/pipeline.sh`, upload the artefact. Everything the pipeline does is
described under [The pipeline script](#the-pipeline-script) above and is
reproducible locally.

The job **fails on any lint, build, test or verification error**. The assembled
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

The release smoke test (`smoke.yml`, called as a reusable workflow) runs first
as a **mandatory gate** ([#53](https://github.com/aklozyp/Moddex/issues/53)):
no release artifact is built unless the backend boots and passes
`scripts/release-smoke-test.sh` at the release ref.

Steps: smoke gate → checkout all three repos at the tag → backend tests →
`build-bundle.sh` → verify the SHA256 checksum → publish a GitHub Release with:

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
