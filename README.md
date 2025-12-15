# Moddex

> **Note:** This project is under active development. Features may be missing and defects can occur.

## Installation

### Prerequisites

Make sure curl is installed. If it’s already available, you can skip this step:

```bash
sudo apt update && sudo apt install curl -y 
```

### Automatic

Fetches the helper script, verifies its checksum, and runs it in one go. The script downloads the
packaged Moddex bundle (`moddex-<tag>-linux-amd64.tar.gz`), verifies the checksum and invokes the
installer contained in the archive.

```bash
curl -fsSLO https://github.com/aklozyp/Moddex/releases/latest/download/download.sh && \
curl -fsSLO https://github.com/aklozyp/Moddex/releases/latest/download/download.sh.sha256 && \
sha256sum -c download.sh.sha256 && \
bash download.sh --run
```

The installer prompts for the deployment mode during execution.

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
- `--port <number>` - Override the backend listen port (default: `8080`).

## Uninstall

Use the bundled script to remove Moddex:

```bash
sudo ./moddex-<tag>-bundle/scripts/uninstall.sh
```


## Update

To update to the latest release (or install if missing), use the helper:

```bash
curl -fsSLO https://github.com/aklozyp/Moddex/releases/latest/download/update.sh && \
bash update.sh
```

The script compares `/opt/moddex/VERSION` (if present) to the latest GitHub release tag and upgrades automatically. If Moddex is not installed yet, it offers to run the installer.

## Building from source

Use the bundled helper to build the backend, the frontend, and assemble the deployable archive:

```bash
VERSION=$(git describe --tags --always) Moddex-build/scripts/build-bundle.sh
ls Moddex-build/build
# => moddex-<version>-linux-amd64.tar.gz and checksum file
```

The script requires Java 17+, Node.js 20+, Maven (via the wrapper), npm, and `tar`. It produces a
standalone bundle identical to the release assets, ready to be installed via `scripts/install.sh`.
