Moddex -- One-Command Install & Release Bundle
=============================================

This repository packages the **Moddex** application (Angular frontend + Spring Boot backend) into a single, ready-to-install release bundle.\
It builds both codebases, adds installer scripts, systemd units, and a Caddy reverse proxy configuration, and publishes a tarball you can install on a server with **one command**.

-   Frontend is served statically by **Caddy**.

-   API is a local **Spring Boot JAR** bound to `127.0.0.1:8080`.

-   **TLS always on**: local/lan use Caddy's internal CA; public uses Let's Encrypt.

-   **HTTP Basic Auth** at the proxy (username `admin`, password set at install time).

* * * * *

Repository layout (this repo)
-----------------------------

`Moddex/                      # packaging repo
├─ scripts/
│  ├─ install.sh             # idempotent installer (server)
│  └─ uninstall.sh           # removal script
├─ packaging/
│  ├─ systemd/
│  │  ├─ moddex-backend.service
│  │  └─ moddex-caddy.service
│  └─ caddy/
│     └─ Caddyfile.tmpl
├─ config/
│  └─ defaults/              # optional JSON defaults (client/server settings)
└─ .github/workflows/
   └─ release.yml            # builds & publishes the bundle on tags`

> The **application sources** live in:
>
> -   Backend: `https://github.com/aklozyp/Moddex-Backend`
>
>
> -   Frontend: `https://github.com/aklozyp/Moddex-Frontend`

* * * * *

Quickstart (server install)
---------------------------

### Option A: Online one-liner (recommended)

`curl -fsSL\
  https://github.com/aklozyp/Moddex/releases/download/v0.1.0/moddex-v0.1.0-linux-amd64.tar.gz\
| sudo bash -s -- --mode lan --password 'ChangeMe!123' --email admin@example.com --domain moddex.example.com`

### Option B: Download first, then install

`wget https://github.com/aklozyp/Moddex/releases/download/v0.1.0/moddex-v0.1.0-linux-amd64.tar.gz
mkdir -p /tmp/moddex && tar -xzf moddex-v0.1.0-linux-amd64.tar.gz -C /tmp/moddex
cd /tmp/moddex
sudo ./scripts/install.sh --mode local --password 'ChangeMe!123'`

### After install -- where to connect

-   **local**: `https://127.0.0.1:8443`

-   **lan**: `https://<server-ip>:8443`

-   **public**: `https://<your-domain>`

Login: `admin` + the password you provided to the installer.

* * * * *

Installation modes
------------------

-   `--mode local` -- localhost only, Caddy uses its internal CA (browsers show a warning).

-   `--mode lan` -- same as local but reachable in your LAN (internal CA).

-   `--mode public` -- requires `--domain` and `--email` (issues Let's Encrypt certificates + HSTS).

* * * * *

Server prerequisites
--------------------

-   Ubuntu/Debian with `sudo` and outbound internet for package install.

-   The installer creates user `moddex` and uses:

    -   `/opt/moddex` (app),

    -   `/etc/moddex` (config),

    -   `/var/lib/moddex/ui` (frontend),

    -   `/var/lib/moddex/logs` (logs).

* * * * *

What the installer does
-----------------------

-   Installs **Caddy**, **htpasswd (apache2-utils)**, **rsync** (Debian/Ubuntu).

-   Creates directories and system user.

-   Deploys:

    -   `backend/Moddex-Backend.jar` → `/opt/moddex/app.jar`

    -   `frontend/dist` → `/var/lib/moddex/ui/`

    -   Caddyfile → `/etc/moddex/Caddyfile`

    -   Basic Auth → `/etc/moddex/htpasswd`

    -   optional defaults → `/etc/moddex/*.json`

-   Enables and restarts systemd services:

    -   `moddex-backend.service`

    -   `moddex-caddy.service`

* * * * *

Operating the service
---------------------

Status & logs:

`sudo systemctl status moddex-backend moddex-caddy
sudo journalctl -u moddex-backend -f`

Restart:

`sudo systemctl restart moddex-backend
sudo systemctl reload moddex-caddy`

Change admin password:

`sudo htpasswd /etc/moddex/htpasswd admin
sudo systemctl reload moddex-caddy`

Uninstall (on the server):

`sudo ./scripts/uninstall.sh`

* * * * *

Building & releasing (CI)
-------------------------

This repo publishes a single **install tarball** whenever you push a Git tag like `vX.Y.Z`.

### Versioning discipline

For a release, **all three repos** must carry the **same tag** (e.g., `v0.1.0`):

`# In aklozyp/Moddex-Backend
git tag v0.1.0 && git push origin v0.1.0

# In aklozyp/Moddex-Frontend
git tag v0.1.0 && git push origin v0.1.0

# In aklozyp/Moddex  (this repo - triggers the release build)
git tag v0.1.0 && git push origin v0.1.0`

### How the workflow works

`.github/workflows/release.yml` (in **this** repo) will:

1.  Check out **this** repo at the tag that triggered the workflow.

2.  Check out **Backend** `aklozyp/Moddex-Backend` at the same tag and build the JAR (Temurin 21).

3.  Check out **Frontend** `aklozyp/Moddex-Frontend` at the same tag and build `dist/` (Node 20).

4.  Assemble the bundle with:

    -   `scripts/` (installer/uninstaller)

    -   `packaging/systemd/*.service`

    -   `packaging/caddy/Caddyfile.tmpl`

    -   `config/defaults/*` (optional)

    -   built frontend `dist/`

    -   built backend JAR

5.  Create a GitHub Release with:

    -   `moddex-vX.Y.Z-linux-amd64.tar.gz`

    -   `moddex-vX.Y.Z-SHA256SUMS`

### Private repos?

If `Moddex-Backend` and/or `Moddex-Frontend` are private, add a fine-grained token with **read** access as secret `GH_TOKEN` in **this** repo, and set:

`with:
  token: ${{ secrets.GH_TOKEN }}`

on both `actions/checkout@v4` steps that fetch the backend/frontend.

* * * * *

Upgrade
-------

Re-run the installer with the **new version**. It's **idempotent** (replaces JAR, updates UI, reloads services):

`curl -fsSL https://github.com/aklozyp/Moddex/releases/download/v0.2.0/moddex-v0.2.0-linux-amd64.tar.gz\
| sudo bash -s -- --mode lan --password 'NewPassword!234'`

* * * * *

Rollback
--------

Install a **previously working** version (same command with an older tag), then restart services if needed:

`curl -fsSL https://github.com/aklozyp/Moddex/releases/download/v0.1.0/moddex-v0.1.0-linux-amd64.tar.gz\
| sudo bash -s -- --mode lan --password 'TempRevert!123'`

* * * * *

Troubleshooting
---------------

-   **Browser warning (local/lan):** Expected --- Caddy's internal CA isn't trusted by default. For proper certs, use `--mode public` with a real `--domain` and `--email`.

-   **Port 8443 closed:** Open your firewall:

    `sudo ufw allow 8443/tcp`

-   **Backend won't start:** Check logs and Java:

    `sudo journalctl -u moddex-backend -n 200 --no-pager`

    CI builds with Temurin Java 21.

-   **Angular dist path differs:** Adjust the `rsync` path in the workflow to your actual build output (default: `FRONTEND_REPO/dist/`).

-   **Caddy config changes:** Edit `/etc/moddex/Caddyfile`, then:

    `sudo systemctl reload moddex-caddy`

-   **Private repositories not checked out by CI:** Add secret `GH_TOKEN` and pass it to `actions/checkout` for backend/frontend.

* * * * *

Security notes
--------------

-   TLS is enforced (no plain HTTP).

-   Basic Auth uses bcrypt hashes (`htpasswd`).

-   In `--mode public`, HSTS is enabled.

-   Logs at `/var/lib/moddex/logs/`.

* * * * *

Development (local)
-------------------

-   Backend dev:

    `./mvnw -f Moddex-Backend spring-boot:run  # http://localhost:8080`

-   Frontend dev:

    `npm start     # or ng serve → http://localhost:4200`

-   Production headers are handled by Caddy; for pure local dev, adjust as needed.

* * * * *

License
-------