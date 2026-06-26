# Release smoke test & checklist (v0.2)

Before publishing a v0.2 release, the critical end-to-end flow must pass so that
installer or core-flow regressions are caught **before** users hit them.

The flow is: **install → first-run setup → login → create instance →
create backup → service healthy.**

Most of it is automated by [`scripts/release-smoke-test.sh`](../../scripts/release-smoke-test.sh);
the native install step is exercised by the
[Debian/Ubuntu install smoke test](../../README.md#debianubuntu-install-smoke-test)
in the README. The deeper data-safety matrix lives in
[`recovery-checklist.md`](recovery-checklist.md), and focused backup/restore/mod
endpoint checks in [`scripts/smoke-test.sh`](../../scripts/smoke-test.sh).

## Test environment

A clean Debian 12 / Ubuntu 22.04+ host, VM or container (or a CI runner — see
*CI* below). Requirements: `systemd`, OpenJDK 17+, network access (the
instance-create step downloads a Minecraft server JAR).

## Scenario

| # | Step | How | Expected |
|---|------|-----|----------|
| 1 | Install natively | `sudo ./scripts/install.sh --mode local --port 8080` | exit `0`; `moddex status` → `Active: active`; unit enabled |
| 2 | Service reachable | `moddex status` / `GET /api/v1/setup/status` | reachable; HTTP `200` |
| 3 | Auth enforced (pre-setup/anon) | `curl -i .../api/v1/instance` | `401 Unauthorized` |
| 4 | First-run setup | `POST /api/v1/setup/complete {password}` | `200`; `setupRequired` → `false` |
| 5 | Login | `POST /api/v1/auth/login {password}` | `200` + bearer token |
| 6 | Create instance | `POST /api/v1/instance {name,gameVersion,modLoader}` | `200`/`201`; server JAR downloaded; instance retrievable |
| 7 | Create backup | `POST /api/v1/instance/{id}/backups?type=full` | `200`/`201` |
| 8 | Service still healthy | `moddex status`; `systemctl status moddex-backend` | `Active: active`; no crash loop in logs |

Steps 2–8 are automated by `release-smoke-test.sh`. Step 1 (the real installer)
and step 8 (systemd health) are verified with the CLI / README install smoke
test on the target host.

## Running the automated smoke test

Against a running backend (defaults to `http://127.0.0.1:8080`):

```bash
# Fresh backend: the script completes setup with the given password.
MODDEX_ADMIN_PASSWORD='ChooseAStrongPassword' \
  scripts/release-smoke-test.sh

# Offline / quick (skip the network-dependent instance + backup steps):
MODDEX_ADMIN_PASSWORD='...' scripts/release-smoke-test.sh --skip-instance

# Override the test instance target:
GAME_VERSION=1.21.1 MOD_LOADER=VANILLA MODDEX_ADMIN_PASSWORD='...' \
  scripts/release-smoke-test.sh
```

On an already-set-up backend, `MODDEX_ADMIN_PASSWORD` must match the existing
admin password (login step). The script prints a `PASS`/`FAIL` line per step and
a final `Result: N passed, M failed`.

### Exit codes

| Code | Meaning |
|------|---------|
| `0` | all checked steps passed |
| `1` | one or more checked steps failed |
| `2` | usage / precondition error (e.g. `curl` missing) |
| `5` | backend unreachable |

### Expected logs

- Backend (`/var/log/moddex/backend.out.log`): `Admin logged in` on step 5;
  instance registration (`Instance id=… registered successfully`) on step 6.
- A clean run shows **no** `INSTANCE_CRASH` / restart-loop entries and the
  service stays `active` throughout.

## Release checklist

Tick every item before tagging a release:

- [ ] `ci.yml` is green on the source branches (backend + frontend build/tests).
- [ ] Fresh-host install (step 1) succeeds; `moddex status` healthy.
- [ ] `release-smoke-test.sh` exits `0` (all steps) against the fresh install.
- [ ] Anonymous access to a protected endpoint returns `401` (step 3).
- [ ] `recovery-checklist.md` 🚫 (blocker) rows pass — no silent data loss on
      restore / mod rollback / broken modpack / full disk.
- [ ] Re-running the installer preserves `/etc/moddex/moddex.env` and instance
      data (update-resistance).
- [ ] Release notes list known limitations (experimental features, Arch/Windows
      status).

A release is **blocked** if any checked smoke step fails or any 🚫 recovery row
regresses.

## CI

[`/.github/workflows/smoke.yml`](../../.github/workflows/smoke.yml) prepares this
as a manual (`workflow_dispatch`) job: it builds and boots the backend on
loopback with a throwaway data directory and runs `release-smoke-test.sh`. By
default it runs with `--skip-instance` (no network download); set the `full`
input to `true` to also exercise instance creation + backup. Run it as a
pre-release gate.
