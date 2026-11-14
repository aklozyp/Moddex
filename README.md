# Moddex

> **Note:** This project is under active development. Features may be missing and defects can occur.

> **Platform support:** Linux with systemd is the verified installation target
> (bundles are `linux-amd64`). Windows installer sources exist in
> `scripts/windows/` (WinSW service) as a code foundation ported from the
> release repository (commit `f0898ffa`, Forgejo issue #564), but Windows
> support has **not** been verified on a Windows host — no Windows bundles or
> release artifacts are published. See [docs/windows-installer.md](docs/windows-installer.md).

## Installation

### Prerequisites

Make sure curl is installed. If it’s already available, you can skip this step:

```bash
sudo apt update && sudo apt install curl -y 
```

### Automatic

Fetches the helper script, verifies its checksum, and runs it in one go. The script downloads the
packaged Moddex bundle (`moddex-<tag>-linux-amd64.tar.gz`), verifies the checksum and invokes the
installer contained in the archive. No checkout or adjacent `install.sh` is needed: the installer
and systemd unit are taken from the same downloaded release bundle.

Verification requires the release-published `<bundle>.sha256` asset: one standard
`sha256sum` record naming the exact downloaded bundle. Missing or invalid release
metadata, a missing/unavailable checksum, an invalid record or a digest mismatch
aborts before extraction or installer execution. The downloader never substitutes
a locally generated checksum for independent verification. Retry with a complete
published release; if a mismatch persists, contact the release maintainer rather
than running the archive.

```bash
curl -fsSLO https://github.com/aklozyp/Moddex/releases/latest/download/download.sh && \
curl -fsSLO https://github.com/aklozyp/Moddex/releases/latest/download/download.sh.sha256 && \
sha256sum -c download.sh.sha256 && \
bash download.sh
```

The installer prompts for the deployment mode during execution.

`latest` is resolved to the concrete release tag before installation. The downloader
checks that the bundle's `VERSION` matches that tag and passes it to the bundled
installer, which records it in `/opt/moddex/VERSION`. Run `moddex version` to print
the installed tag. Missing/invalid release tags or missing/mismatched bundle versions
abort before installation. To select a specific release, use `bash download.sh --version v0.1.2`.
Manual/local installs use the bundle or checkout's `VERSION` unless the installer
is given an explicit `--version <tag>`; inherited `VERSION` variables do not override it.

Run `bash scripts/tests/test-download-bundle-installer.sh` for offline regression
checks using real bundle builds, checksum verification and an isolated installer/CLI
fixture. The checks verify that failed verification never starts extraction or
installation, including duplicate records and unrelated checksum filenames/assets.
Network and privileged commands are mocked; host installation paths are not used.

### Manual

1. Pick the release tag you want to install (for example `TAG=v0.1.0`).
2. Download the bundle and checksum list from the Moddex release:
   ```bash
   curl -fsSLO https://github.com/aklozyp/Moddex/releases/download/$TAG/moddex-$TAG-linux-amd64.tar.gz
   curl -fsSLO https://github.com/aklozyp/Moddex/releases/download/$TAG/moddex-$TAG-linux-amd64.tar.gz.sha256
   ```
3. Verify the archive:
   ```bash
   grep "moddex-$TAG-linux-amd64.tar.gz" moddex-$TAG-linux-amd64.tar.gz.sha256 | sha256sum --check
   ```
4. Extract the archive and switch into the bundle directory:
   ```bash
   mkdir moddex-$TAG
   tar -C moddex-$TAG -xzf moddex-$TAG-linux-amd64.tar.gz
   cd moddex-$TAG
   ```
5. Run the installer with elevated privileges:
   ```bash
   sudo ./scripts/install.sh
   ```

## Installer Options

The installer accepts optional arguments and environment variables if you need to skip prompts or override defaults:

- `--mode local|lan|public` - Deployment mode (default: `local`).
- `--backend-jar <path>` - Custom backend JAR (default: `../backend/Moddex-Backend.jar`).
- `--frontend-dir <path>` - Custom frontend build directory (default: `../frontend`).
- `--port <number>` - Override the backend listen port with a decimal integer from `1` to `65535` (default: `8080`).

Port precedence is `--port`, then `PORT`, then `MODDEX_PORT`, then `8080` when
neither environment variable is set. Empty overrides and invalid ports are rejected
before privilege escalation, package installation or any installation changes.
Leading zeros are accepted as decimal padding and removed from the persisted port.
Run `bash scripts/tests/test-install-port.sh` for offline regression checks of
rejected inputs, precedence and successful mocked installs, without host changes.

## Uninstall

Use the bundled script to uninstall Moddex **without deleting your data**:

```bash
sudo ./moddex-<tag>-bundle/scripts/uninstall.sh
```

The default removes the systemd unit, `/opt/moddex/app.jar` and `/opt/moddex/VERSION`.
Worlds, backups and other data in `/var/lib/moddex`, configuration in `/etc/moddex`,
all other files in `/opt/moddex`, and the `moddex` system account are retained.
Keeping the account preserves the ownership of retained files for a later reinstall.

To permanently delete the installation directories and their contents instead, explicitly opt in:

```bash
sudo ./moddex-<tag>-bundle/scripts/uninstall.sh --purge-data
```

`--purge-data` lists `/opt/moddex`, `/var/lib/moddex`, `/etc/moddex` and the systemd
unit path before asking for confirmation (`y`; the default is **No**). It deletes
these paths, including worlds, backups and configuration, and removes the `moddex`
system account. Back up anything you need first. Custom data paths outside these
directories are not deleted. Use `--help` to display the options without making changes.

Both modes stop/disable the service and verify that it is inactive with no main PID
**before removing any files or the account**. A failed stop or an unreadable,
incomplete or still-running service state aborts removal, even with `--purge-data`.
An explicitly missing, inactive unit with no main PID is safe for a repeated uninstall.
Errors report the stop failure, safe systemd state/result values and matching PIDs
and process names when available, without command arguments, configuration or logs.
Resolve sudo/systemd errors and stop the reported processes cleanly before rerunning;
the script does not force-kill processes or automatically retry deletion. A new purge
attempt still requires confirmation. Safe state/process checks are:

```bash
sudo systemctl show moddex-backend --property=LoadState,ActiveState,MainPID,Result
sudo ps -u moddex -o pid=,comm=
```

The mocked regression checks (`bash scripts/tests/test-uninstall-data-policy.sh`)
cover retention, confirmed purge, already-absent units, failed stops, unverifiable or
still-running states, and unavailable process diagnostics without using host services
or installation paths.

## Update

To update to the latest release (or install if missing), use the helper from an extracted Moddex bundle:

```bash
bash "/path/to/moddex-bundle/scripts/update.sh"
```

The script compares `/opt/moddex/VERSION` (if present) to the latest GitHub release tag and upgrades automatically. If Moddex is not installed yet, it offers to run the installer.
The update is downloaded, checksum-verified, and staged before the running service is stopped, so a failed download or verification never extends downtime; the previous version keeps running and `scripts/update.sh` can be rerun safely.
Keep `update.sh` and `download.sh` together in the complete Moddex bundle's `scripts` directory.
The updater always uses that bundled downloader, regardless of your working directory; copying
`update.sh` alone is not sufficient. For example, you can invoke
`bash "/path with spaces/moddex-bundle/scripts/update.sh"` from your home directory or any other directory.

Run the offline updater regression with `bash scripts/tests/test-update-script-path.sh`.
It uses isolated fixtures and mocked commands; it does not download releases, modify an installation,
or stop real services.
Checks also run from `/tmp` and your real home directory, keeping all fixtures and logs inside the
checkout and leaving those directories untouched. Inaccessible required directories fail the check.

## Building from source

Use the bundled helper to build the backend, the frontend, and assemble the deployable archive:

```bash
VERSION=$(git describe --tags --always) scripts/build-bundle.sh
ls build
# => moddex-<version>-linux-amd64.tar.gz and checksum file
```

The script requires Java 17+, Node.js 20+, Maven (via the wrapper), npm, and `tar`. It produces a
standalone bundle identical to the release assets, ready to be installed via `scripts/install.sh`.

## Development and releases

Development and CI run on Forgejo. GitHub contains filtered release snapshots;
private development history and internal tooling stay on Forgejo. Version tags
trigger the GitHub build, installation gate and release publication.
