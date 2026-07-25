# Moddex

> **Note:** This project is under active development (v0.2, Public-Beta-Foundation). Features may be missing and defects can occur.

Moddex is a self-hosted **Minecraft server panel and modpack/instance manager**.
It installs natively on Linux as a systemd service, gives you a web UI plus a
terminal CLI to create and run server instances, manage mods from
[Modrinth](https://modrinth.com), edit `server.properties` and player access,
take backups, and watch a live console and metrics dashboard.

**Who it is for:** private administrators running one or more Minecraft servers
on their own Debian/Ubuntu host or home server, who want a manageable panel
without renting a hosted control panel — and without Docker. Moddex runs as a
single-user, self-hosted application; it is built to be safe on a trusted LAN
and hardenable for restricted public exposure behind a reverse proxy.

**Not a hosting product:** there is no multi-tenant SaaS, no built-in TLS
terminator and no managed cloud. You own the host and the data.

## Feature matrix

Status of the major capabilities per milestone. v0.2 is the current
Public-Beta-Foundation; v0.3/v0.4 are planned (see the
[issue tracker](https://github.com/aklozyp/Moddex/issues) for the live roadmap).

| Area | Capability | v0.2 | v0.3 | v0.4 |
|------|------------|:----:|:----:|:----:|
| Platform | Native Debian/Ubuntu install (systemd, CLI) | ✅ | ✅ | ✅ |
| Platform | Arch Linux | 🧪 | 🧪 | ✅ |
| Platform | Windows installer | — | ✅ | ✅ |
| Instances | Create/start/stop, crash detection & auto-restart | ✅ | ✅ | ✅ |
| Instances | Live console (WebSocket) & metrics dashboard | ✅ | ✅ | ✅ |
| Mods | Modrinth install/update, modpack import/export (`.mrpack`) | ✅ | ✅ | ✅ |
| Mods | CurseForge integration (user API key) | — | ✅ | ✅ |
| Backups | `.moddex` archive, restore, retention, scheduler | ✅ | ✅ | ✅ |
| Server config | `server.properties` schema, whitelist/ops/bans, MOTD | ✅ | ✅ | ✅ |
| Files | Hardened file manager (upload/download/rename) | ✅ | ✅ | ✅ |
| Notifications | Discord webhooks (crash/backup/update) | ✅ | ✅ | ✅ |
| Security | Single-user auth, CORS/audit, quota, sandbox | ✅ | ✅ | ✅ |
| i18n | DE/EN (+ RTL groundwork) | ✅ | — | — |
| i18n | Full 7-language coverage | — | ✅ | ✅ |
| Release | Release-ready checklist for external admins | — | — | ✅ |

Legend: ✅ available · 🧪 experimental/unvalidated · — not yet / out of scope.

## Supported platforms

| Platform | Status | Notes |
|----------|--------|-------|
| Debian 12 / Ubuntu 22.04+ | **Supported** | Primary target; native installer + systemd. |
| Arch Linux | **Experimental** | Expected to work (systemd, OpenJDK 17+) but not validated in CI. |
| Windows 10/11, Server 2019+ | **Supported (v0.3)** | PowerShell installer + Windows service (WinSW). See [Windows](#windows). |
| Docker | Dev utility only | The `Docker/` files in the meta repo are for local development. Docker is **not** the supported production deployment path — install natively per below. |

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

### Windows

Windows is installed from the dedicated `moddex-<tag>-windows-x64.zip` artifact and runs the
backend as a Windows service via [WinSW](https://github.com/winsw/winsw). Java 17+ must be on the
`PATH` (or reachable via `JAVA_HOME`).

Path layout:

| Purpose | Location |
|---------|----------|
| Application (`app.jar`, frontend, service wrapper) | `%ProgramFiles%\Moddex` |
| Instance data (`MODDEX_ROOT`) | `%ProgramData%\Moddex\data` |
| Config | `%ProgramData%\Moddex\config` |
| Logs | `%ProgramData%\Moddex\logs` |

Install from an **elevated** PowerShell session:

```powershell
$Tag = 'v0.1.0'
Invoke-WebRequest "https://github.com/aklozyp/Moddex/releases/download/$Tag/moddex-$Tag-windows-x64.zip" -OutFile moddex.zip
Invoke-WebRequest "https://github.com/aklozyp/Moddex/releases/download/$Tag/moddex-$Tag-windows-x64.zip.sha256" -OutFile moddex.zip.sha256
# Verify the checksum
$expected = (Get-Content moddex.zip.sha256).Split(' ')[0]
if ((Get-FileHash moddex.zip).Hash.ToLower() -ne $expected) { throw 'Checksum mismatch' }
Expand-Archive moddex.zip -DestinationPath moddex-$Tag
# Install and register the service (defaults: local mode, port 8080)
& ".\moddex-$Tag\scripts\windows\install.ps1" -Mode local
```

The installer is idempotent: re-running it upgrades `app.jar` and the frontend without touching
instance data, and preserves the machine-local mode/port unless you pass `-Mode`/`-Port` again. The
bundled WinSW binary is checksum-pinned; the installer rejects a mismatched download.

Manage the service with standard tooling:

```powershell
Get-Service moddex-backend            # status
Restart-Service moddex-backend        # restart
& "$env:ProgramFiles\Moddex\moddex-backend.exe" status   # WinSW status/logs
.\scripts\windows\uninstall.ps1        # remove (add -Purge to also delete data)
```

## Installer Options

The installer accepts optional arguments and environment variables if you need to skip prompts or override defaults:

- `--mode local|lan|public` - Deployment mode (default: `local`).
- `--backend-jar <path>` - Custom backend JAR (default: `../backend/Moddex-Backend.jar`).
- `--frontend-dir <path>` - Custom frontend build directory (default: `../frontend`).
  Point this at the directory that *contains* `index.html`, not at Angular's
  `dist/` root.
- `--without-frontend` - Install the backend only, without a web UI. Without
  this flag, a bundle that carries no usable UI is rejected instead of being
  installed silently. On an existing installation this also removes the
  previously installed UI, so nothing keeps serving a stale frontend.
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

For manual upgrades, version verification and **rollback to a previous release** (Linux and Windows), see the **[upgrade & rollback guide](docs/upgrade.md)**.

## Command-line interface (`moddex`)

The installer places an administrative CLI at `/usr/local/bin/moddex` so basic operations can be performed from the terminal without the web UI.

```bash
moddex help            # full command reference
moddex status          # service state, endpoint and reachability
moddex start|stop|restart
moddex version         # version, build date and installation paths
moddex logs [--follow] # tail the backend log
```

Instance-scoped commands talk to the backend REST API and therefore require authentication:

```bash
moddex list-instances
moddex backup <instance-id> [--type standard|full]
moddex restore <instance-id> <backup-name> [--yes]   # destructive, asks for confirmation
```

**Authentication.** Provide a JWT via `--token` / the `MODDEX_API_TOKEN` environment variable, or an admin password via `MODDEX_ADMIN_PASSWORD` (the CLI then logs in for you). Without either, the CLI prompts for the password interactively. The connection target is derived from `/etc/moddex/moddex.env` (`SERVER_ADDRESS`/`SERVER_PORT`); a wildcard bind is contacted on `127.0.0.1`.

**Exit codes** are stable so the CLI can be used in scripts:

| Code | Meaning |
|------|---------|
| `0` | success |
| `1` | generic runtime error |
| `2` | usage error (unknown command, missing/invalid arguments) |
| `3` | service control failure or service not running |
| `4` | authentication required or failed |
| `5` | backend unreachable |
| `6` | missing dependency (e.g. `curl`) |

`list-instances` prints aligned columns when [`jq`](https://jqlang.github.io/jq/) is installed and falls back to raw JSON otherwise.

## Private Linux Operation

This section is aimed at private administrators who want to run Moddex securely on a home server or in a local network (LAN). It describes secure defaults, explicit anti-patterns, and the system layout the installer creates.

### Betriebsmodi im Überblick

| Modus | Bind-Adresse | Empfohlener Einsatz |
|-------|-------------|---------------------|
| `local` | `127.0.0.1` | Entwicklung / lokaler Test auf demselben Rechner |
| `lan` | `0.0.0.0` | **Empfohlen** für privaten Betrieb im Heimnetz (Router nicht exponiert) |
| `public` | `0.0.0.0` | Nur hinter Reverse Proxy mit TLS – niemals direkt ins Internet |

**Anti-Pattern:** Den Modus `public` ohne vorgeschalteten Reverse Proxy und TLS verwenden. Moddex liefert keinen TLS-Terminator; die eingebaute Authentifizierung allein ersetzt keine TLS-Verschlüsselung für öffentlich erreichbare Instanzen.

### Linux-Benutzer, Dienst-Rechte und Datenpfade

Der Installer legt automatisch einen unprivilegierten Systembenutzer an:

```
moddex  – kein Login-Shell, kein Home-Verzeichnis, nur für den Dienst
```

Verzeichnisstruktur nach der Installation:

| Pfad | Berechtigungen | Inhalt |
|------|---------------|--------|
| `/opt/moddex/` | `0755 moddex:moddex` | Anwendungsdateien (`app.jar`, `VERSION`) |
| `/opt/moddex/ui/` | `0755 root:root` | Gebaute Web-UI, vom Backend ausgeliefert; fuer den Dienst nur lesbar |
| `/var/lib/moddex/` | `0755 moddex:moddex` | Laufzeitdaten (Datenbank, Instanz- und Backup-Daten) |
| `/var/log/moddex/` | `0755 moddex:moddex` | Backend-Logs (`backend.out.log`, `backend.err.log`) |
| `/etc/moddex/` | `0750 root:moddex` | Maschinen-lokale Konfiguration |
| `/etc/moddex/moddex.env` | `0640 root:moddex` | Betriebsmodus, Bind-Adresse, Port (vom Installer geschrieben) |
| `/etc/systemd/system/moddex-backend.service` | `0644 root:root` | Systemd-Unit |
| `/usr/local/bin/moddex` | `0755 root:root` | Administrative CLI (siehe unten) |

Der Dienst läuft niemals als `root`. Die Dateien unter `/opt/moddex` und `/var/lib/moddex` gehören `moddex:moddex` und sind für andere Benutzer nur lesbar. Die systemd-Unit ist zusätzlich gehärtet (`ProtectSystem=strict`, `NoNewPrivileges`, schreibbar nur unter `/var/lib/moddex` und `/var/log/moddex`).

**Update-Resistenz:** Ein erneuter Installer-Lauf **ohne** `--mode`/`--port` aktualisiert nur die Anwendungsartefakte (`app.jar`, Frontend, CLI, systemd-Unit); `/etc/moddex/moddex.env` und sämtliche Instanz-/Backup-Daten unter `/var/lib/moddex` bleiben unangetastet. Um Modus oder Port nachträglich zu ändern, starte den Installer **mit** explizitem `--mode`/`--port` (dann wird nur die betroffene Einstellung in `moddex.env` überschrieben) oder bearbeite die Datei direkt; anschließend `moddex restart` ausführen.

### Authentifizierung

> **Grundregel (Defense in Depth):** Behandle den Moddex-Port immer als schützenswert und verlasse dich **nicht allein** auf die App-Authentifizierung. Begrenze den Zugriff zuerst über Netzwerkmittel (Bind-Adresse, Firewall, Router, Reverse Proxy) und setze die eingebaute Auth als zusätzliche Schicht obendrauf.

Moddex bringt eine **eingebaute Authentifizierung** mit (bereitgestellt von der Backend-Komponente, nicht vom Installer): Beim ersten Start legst du über den Setup-Assistenten ein Admin-Passwort fest (BCrypt-Hash, persistiert in den Server-Einstellungen). Die Weboberfläche meldet sich anschließend per Login an und sendet ein **JWT-Bearer-Token** an die API. Serverseitig sind die API-Endpunkte geschützt; nur die Setup- und Login-Endpunkte (`/api/v1/setup/**`, `/api/v1/auth/**`) sowie `/error` sind ohne Token erreichbar.

> **Wichtig:** Schließe das Erst-Setup sofort ab und vergib ein starkes Admin-Passwort. Solange das Setup nicht abgeschlossen ist, ist die Oberfläche ungeschützt. Prüfe nach der Installation aktiv, dass ein nicht authentifizierter Aufruf eines geschützten Endpunkts (z. B. `curl -i http://127.0.0.1:8080/api/v1/instance`) mit `401 Unauthorized` beantwortet wird, bevor du den Dienst über `localhost` hinaus erreichbar machst.

Sichere Defaults für den Privatbetrieb:

- **`local`-Modus:** Zugriff nur vom selben Rechner – kein Firewall-Risiko.
- **`lan`-Modus:** Nur im eigenen Heimnetz exponieren. Sicherstellen, dass der Router den Port **nicht** an das Internet weiterleitet (Port-Forwarding deaktiviert).
- **`public`-Modus:** Zusätzlich zur eingebauten Auth einen Reverse Proxy mit TLS (und optional einer weiteren Schutzschicht wie HTTP Basic Auth) vorschalten. Verlasse dich nie allein auf die App-Auth, wenn der Dienst öffentlich erreichbar ist.

Passwörter und Tokens werden **nicht** vom Installer verwaltet; sie entstehen aus der laufenden Anwendung heraus. Hinterlege keine Zugangsdaten in der `moddex-backend.service`-Datei.

> **CORS:** Das Backend ist fail-closed konfiguriert. Im `local`-Modus sind nur Loopback-Ursprünge erlaubt; in `lan`/`public` ist Cross-Origin-Zugriff aus dem Browser deaktiviert, bis `MODDEX_CORS_ALLOWED_ORIGINS` (bzw. `moddex.security.cors.allowed-origins`) eine explizite Allow-List setzt. Siehe `docs/security-configuration.md` im Backend-Repo.

### Firewall (UFW / firewalld)

Der Installer öffnet im `lan`- und `public`-Modus automatisch den konfigurierten Port:

```bash
# UFW (Debian/Ubuntu)
ufw allow 8080/tcp

# firewalld (RHEL/Fedora)
firewall-cmd --permanent --add-port=8080/tcp && firewall-cmd --reload
```

Empfohlene UFW-Grundkonfiguration vor der Installation:

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
sudo ufw enable
```

Nach der Installation öffnet der Installer nur den Moddex-Port zusätzlich. So bleibt die Angriffsfläche minimal.

### Reverse Proxy mit TLS (nginx-Beispiel)

Für den `public`-Modus oder wenn TLS im LAN gewünscht ist, eine nginx-Konfiguration als Vorlage:

```nginx
server {
    listen 443 ssl;
    server_name moddex.example.internal;

    ssl_certificate     /etc/ssl/certs/moddex.crt;
    ssl_certificate_key /etc/ssl/private/moddex.key;

    # Optionale HTTP-Basic-Auth als zusätzliche Schutzschicht
    auth_basic           "Moddex";
    auth_basic_user_file /etc/nginx/.htpasswd;

    location / {
        proxy_pass         http://127.0.0.1:8080;
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        # Overwrite (do NOT append) so a client cannot inject a spoofed leftmost
        # entry, and clear the RFC Forwarded header the backend also honours.
        proxy_set_header   X-Forwarded-For $remote_addr;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_set_header   Forwarded "";
    }

    # Ein separater Webserver fuer das Frontend ist nicht noetig: das Backend
    # liefert die UI auf demselben Port wie die API aus (Moddex#59). Der Proxy
    # oben reicht sowohl die Oberflaeche als auch die API durch.
}

server {
    listen 80;
    server_name moddex.example.internal;
    return 301 https://$host$request_uri;
}
```

Für Caddy ist `reverse_proxy localhost:8080` mit automatischem TLS über Let's Encrypt ausreichend.

Damit das Backend die echte Client-IP (für Login-Rate-Limit und Audit-Log) aus
dem Proxy übernimmt, muss `MODDEX_FORWARD_HEADERS_STRATEGY=framework` gesetzt
sein — **nur** hinter einem Proxy, der wie oben *alle* Forwarded-Header
überschreibt/leert. Ohne Proxy (Direkt-Exposition) bleibt der sichere Default
`none`, sonst könnten Clients ihre IP fälschen. Siehe
`Moddex-Backend/docs/security-configuration.md`.

### Backup

Moddex hat **integrierte Instanz-Backups** (Web-UI und CLI). Pro Instanz wird ein
portables `.moddex`-Archiv erzeugt:

- **Typen:** `STANDARD` (Welten inkl. `level-name`, `config/`, `server.properties`)
  und `FULL` (gesamte Instanz).
- **Format:** ZIP mit `moddex-manifest.json` und den Daten unter `data/`; beim
  Restore werden Manifest/ZIP validiert (korrupt/fremd → Abbruch), Zip-Slip-Pfade
  abgewiesen und vor dem Extrahieren ein Snapshot-Rollback vorbereitet.
- **Retention** global oder pro Instanz; optionaler **Scheduler** (Uhrzeit/Wochentage).

```bash
# Per CLI (siehe Abschnitt "Command-line interface"):
moddex backup  <instance-id> --type full
moddex restore <instance-id> <backup-name>     # destruktiv, fragt nach Bestätigung
```

> **Restore ist destruktiv** und überschreibt den aktuellen Instanzstand. Erstelle
> vorher ein Backup; siehe auch „Experimentelle Funktionen".

Für ein **vollständiges Host-Backup** (alle Instanzen, Einstellungen, Konfiguration)
zusätzlich `/var/lib/moddex` und `/etc/moddex` sichern – für Konsistenz den Dienst
kurz stoppen:

```bash
sudo systemctl stop moddex-backend
sudo tar -czf moddex-backup-$(date +%Y%m%d).tar.gz /var/lib/moddex /etc/moddex
sudo systemctl start moddex-backend
```

Die Anwendungsdatei `/opt/moddex/app.jar` muss nicht gesichert werden – sie wird bei Updates ersetzt.

### Mod-Verwaltung (Modrinth)

Mods und Modpacks werden über [Modrinth](https://modrinth.com) verwaltet:

- **Mods** suchen, installieren und entfernen; Dependencies werden aufgelöst,
  client-only Mods werden nicht auf den Server gespielt.
- **Updates:** pro Mod wird die neueste **kompatible** Version ermittelt (gefiltert
  nach Loader + MC-Version); einzeln oder als Batch aktualisierbar. Vor riskanten
  Änderungen wird automatisch ein Pre-Update-Backup erstellt.
- **Modpacks:** Import/Export im `.mrpack`-Format. Importe werden gegen eine
  Trust-Policy (erlaubte Hosts/Endungen, Größenlimits, Prüfsummen) validiert.
- **Versionierung:** Modpack-Änderungen werden versioniert (mit Cooldown-Fenster),
  inklusive Verknüpfung zum jeweiligen Pre-Update-Backup.

> **CurseForge** ist ein **v0.3-Ziel**
> ([#25](https://github.com/aklozyp/Moddex/issues/25)): geplant mit nutzereigenem
> API-Key, ohne die v0.2-Modrinth-UX zu beeinträchtigen. In v0.2 nicht verfügbar.

### Experimentelle Funktionen

Die folgenden Funktionen sind noch in der Entwicklung. Sie können unerwartet fehlschlagen oder Daten inkonsistent hinterlassen:

| Funktion | Status | Hinweis |
|----------|--------|---------|
| **Restore / Wiederherstellung** | Experimentell | Kann bestehende Daten überschreiben; vorher Backup erstellen |
| **Modpack Import** | Experimentell | Importe werden gegen eine Trust-Policy (erlaubte Hosts/Endungen, Größenlimits, Prüfsummen) validiert; importiere dennoch nur Modpacks vertrauenswürdiger Autoren |
| **File Manager** | Experimentell | Schreibzugriff auf das Dateisystem des Servers; an die Instanz-Wurzel gebunden, Berechtigungen trotzdem prüfen |
| **Externe Downloads** | Experimentell | Downloads laufen nur über erlaubte HTTPS-Hosts und werden gegen erwartete SHA-512/SHA-1-Prüfsummen verifiziert; eine Malware-Prüfung des Inhalts findet nicht statt |

Für produktive oder sicherheitskritische Umgebungen diese Funktionen deaktiviert lassen, bis sie als stabil markiert sind.

### Schnellcheckliste für den LAN-Betrieb

- [ ] Installer mit `--mode lan` ausgeführt
- [ ] UFW aktiv und nur notwendige Ports geöffnet
- [ ] Router leitet Port **nicht** ins Internet weiter
- [ ] Backend läuft als Benutzer `moddex` (prüfen: `moddex status` oder `systemctl status moddex-backend`)
- [ ] Logs unter `/var/log/moddex/` erreichbar und lesbar (`moddex logs`)
- [ ] Regelmäßiges Backup von `/var/lib/moddex` eingerichtet
- [ ] Experimentelle Funktionen nur bewusst aktivieren

---

## Building from source

Use the bundled helper to build the backend, the frontend, and assemble the deployable archive:

```bash
VERSION=$(git describe --tags --always) Moddex-build/scripts/build-bundle.sh
ls Moddex-build/build
# => moddex-<version>-linux-amd64.tar.gz and checksum file
```

The script requires Java 17+, Node.js 20+, Maven (via the wrapper), npm, and `tar`. It produces a
standalone bundle identical to the release assets, ready to be installed via `scripts/install.sh`.

The same bundle is built in CI and on tags by GitHub Actions. See
[`docs/ci.md`](docs/ci.md) for the build matrix, the required cross-repo
checkout secret, the release process and the Arch/Windows status.

## Releases & changelog

Notable changes are recorded in the **[CHANGELOG](CHANGELOG.md)**; each GitHub
Release additionally carries auto-generated notes listing every merged pull
request. Maintainers cutting a release should follow the
**[release process](docs/releasing.md)** and the
[release checklist](docs/qa/release-checklist.md).

## Quality assurance

Before each release, run the recovery QA pass to make sure restore, mod changes
and file operations cannot silently destroy instances:

- **Security review:** [`docs/qa/security-review.md`](docs/qa/security-review.md)
  — the pre-release review across backend, frontend and CI (auth, CORS,
  file/download, secret handling, XSS, workflow permissions). See also
  [`SECURITY.md`](SECURITY.md) for vulnerability reporting.
- **Manual matrix:** [`docs/qa/recovery-checklist.md`](docs/qa/recovery-checklist.md)
  — versioned checklist covering backup → restore → start, mod-install rollback,
  broken modpacks, full-disk/aborted-download scenarios and a fresh-install smoke
  test. Steps marked 🚫 are Public-Beta blockers.
- **Automated smoke test:** [`scripts/smoke-test.sh`](scripts/smoke-test.sh) —
  exercises the backup/restore and mod endpoints against a running backend:

  ```bash
  BASE_URL=http://127.0.0.1:8080 TOKEN=<jwt> INSTANCE_ID=<uuid> \
    scripts/smoke-test.sh            # add --with-restore for the destructive restore step
  ```
- **Release smoke test:** [`scripts/release-smoke-test.sh`](scripts/release-smoke-test.sh)
  and the [release checklist](docs/qa/release-checklist.md) — the v0.2 release
  gate covering install → setup → login → create instance → backup → service
  health, with stable exit codes. A manual `smoke.yml` GitHub Actions job boots a
  throwaway backend and runs it:

  ```bash
  MODDEX_ADMIN_PASSWORD='<strong-password>' scripts/release-smoke-test.sh
  # add --skip-instance for an offline run (no server-JAR download)
  ```

### Debian/Ubuntu install smoke test

After a fresh install on Debian 12 / Ubuntu 22.04+ (or a clean VM/container), verify the
native deployment end to end:

```bash
# 1. Install (non-interactive). Pass the artifacts produced by build-bundle.sh.
sudo ./scripts/install.sh --mode lan --port 8080

# 2. Service is up and managed by systemd.
moddex status                         # Active: active, Reachable: yes
systemctl is-enabled moddex-backend   # enabled (starts on boot)

# 3. Version and paths are reported.
moddex version

# 4. Auth is enforced before any token is issued.
curl -i http://127.0.0.1:8080/api/v1/instance   # expect HTTP/1.1 401

# 5. Complete the first-run setup in the web UI, then exercise the API:
MODDEX_ADMIN_PASSWORD='<your-admin-password>' moddex list-instances

# 6. Update resistance: re-running the installer must not touch local config/data.
sudo ./scripts/install.sh             # reuses mode/port from /etc/moddex/moddex.env
sudo cat /etc/moddex/moddex.env       # unchanged
```

Acceptance: after the installer the service is running under systemd and the web UI is
reachable; a second installer run upgrades the artifacts without overwriting
`/etc/moddex/moddex.env` or any instance data under `/var/lib/moddex`.

## Troubleshooting & support

Common operational problems (missing/old Java, occupied port, service won't
start, CORS/security mode, CurseForge API key, checksum mismatch) are documented
for both Linux and Windows in the **[troubleshooting guide](docs/troubleshooting.md)**.

If that does not resolve it, open an issue via the bug-report form (see
**[SUPPORT.md](SUPPORT.md)**) and include version, platform and operating mode.
Report security issues privately via GitHub's "Report a vulnerability".

## Contributing

Issues and pull requests are welcome. Backend (Kotlin/Spring Boot) and frontend
(Angular) changes target the `tests` branch of their respective repositories;
packaging/docs changes here target `develop`.

### Translations

Moddex ships German and English (`de`/`en`) with groundwork for right-to-left
layouts; full 7-language coverage is a v0.3 goal
([#27](https://github.com/aklozyp/Moddex/issues/27)). UI strings live in the
frontend under `src/assets/i18n/<lang>.json`, and a single registry entry adds a
language to the switcher (English is always the fallback for missing keys).

See the **[translation contribution guide](docs/translations.md)** for the full
workflow: file locations, key/placeholder rules, RTL notes, how to verify
completeness, and the PR checklist.
