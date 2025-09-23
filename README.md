# Moddex

> **Note:** This project is under active development. Features may be missing and defects can occur.

## Installation

### Automatic

Fetches the helper script, verifies its checksum, and runs it in one go:

```bash
curl -fsSLO https://github.com/aklozyp/Moddex/releases/latest/download/download.sh && \
curl -fsSLO https://github.com/aklozyp/Moddex/releases/latest/download/download.sh.sha256 && \
sha256sum -c download.sh.sha256 && \
bash download.sh --run
```

The installer prompts for mode, domain, email, and password during execution.

### Manual

1. Pick the release tag you want to install (for example `TAG=v0.1.0`).
2. Download the bundle and checksum list from the Moddex release:
   ```bash
   curl -fsSLO https://github.com/aklozyp/Moddex/releases/download/$TAG/moddex-$TAG-linux-amd64.tar.gz
   curl -fsSLO https://github.com/aklozyp/Moddex/releases/download/$TAG/moddex-$TAG-SHA256SUMS
   ```
3. Verify the archive:
   ```bash
   grep "moddex-$TAG-linux-amd64.tar.gz" moddex-$TAG-SHA256SUMS | sha256sum --check
   ```
4. Extract the archive and switch into the bundle directory:
   ```bash
   tar -xzf moddex-$TAG-linux-amd64.tar.gz
   cd moddex-$TAG-bundle
   ```
5. Run the installer with elevated privileges:
   ```bash
   sudo ./scripts/install.sh
   ```

## Installer Options

The installer accepts optional arguments and environment variables if you need to skip prompts or override defaults:

- `--mode local|lan|public` - Deployment mode (default: `local`).
- `--domain <name>` - Public hostname, required when `--mode public`.
- `--email <address>` - ACME contact address for public mode certificates.
- `--password <value>` - Admin password for HTTP basic authentication. You can also export `MODDEX_ADMIN_PASSWORD`.
- `--backend-jar <path>` - Custom backend JAR (default: `../backend/Moddex-Backend.jar`).
- `--frontend-dir <path>` - Custom frontend build directory (default: `../frontend`).

## Uninstall

Use the bundled script to remove Moddex:

```bash
sudo ./moddex-<tag>-bundle/scripts/uninstall.sh
```
