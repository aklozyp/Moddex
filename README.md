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

## Private Linux Operation

This section is aimed at private administrators who want to run Moddex securely on a home server or in a local network (LAN). It describes secure defaults, explicit anti-patterns, and the system layout the installer creates.

### Betriebsmodi im Überblick

| Modus | Bind-Adresse | Empfohlener Einsatz |
|-------|-------------|---------------------|
| `local` | `127.0.0.1` | Entwicklung / lokaler Test auf demselben Rechner |
| `lan` | `0.0.0.0` | **Empfohlen** für privaten Betrieb im Heimnetz (Router nicht exponiert) |
| `public` | `0.0.0.0` | Nur hinter Reverse Proxy mit TLS – niemals direkt ins Internet |

**Anti-Pattern:** Den Modus `public` ohne vorgeschalteten Reverse Proxy und TLS verwenden. Moddex liefert keinen TLS-Terminator und hat aktuell keine eingebaute Authentifizierung.

### Linux-Benutzer, Dienst-Rechte und Datenpfade

Der Installer legt automatisch einen unprivilegierten Systembenutzer an:

```
moddex  – kein Login-Shell, kein Home-Verzeichnis, nur für den Dienst
```

Verzeichnisstruktur nach der Installation:

| Pfad | Berechtigungen | Inhalt |
|------|---------------|--------|
| `/opt/moddex/` | `0755 moddex:moddex` | Anwendungsdateien (`app.jar`, `VERSION`) |
| `/var/lib/moddex/` | `0755 moddex:moddex` | Laufzeitdaten (Datenbank, Konfiguration) |
| `/var/lib/moddex/ui/` | `0755 moddex:moddex` | Statische Frontend-Assets |
| `/var/lib/moddex/logs/` | `0755 moddex:moddex` | Backend-Logs (`backend.out.log`, `backend.err.log`) |
| `/etc/systemd/system/moddex-backend.service` | `0644 root:root` | Systemd-Unit |

Der Dienst läuft niemals als `root`. Die Dateien unter `/opt/moddex` und `/var/lib/moddex` gehören `moddex:moddex` und sind für andere Benutzer nur lesbar.

### Authentifizierung

> **Wichtig:** Moddex hat aktuell **keine eingebaute Authentifizierung**. Jede Person, die den Port erreichen kann, hat vollen Zugriff auf die Benutzeroberfläche.

Sichere Defaults für den Privatbetrieb:

- **`local`-Modus:** Zugriff nur vom selben Rechner – kein Firewall-Risiko.
- **`lan`-Modus:** Nur im eigenen Heimnetz exponieren. Sicherstellen, dass der Router den Port **nicht** an das Internet weiterleitet (Port-Forwarding deaktiviert).
- **`public`-Modus:** Immer einen Reverse Proxy mit Authentifizierung (z. B. HTTP Basic Auth über nginx oder Caddy) vorschalten.

Passwörter und Tokens werden nicht vom Installer verwaltet; sie entstehen aus der laufenden Anwendung heraus. Keine Zugangsdaten in der `moddex-backend.service`-Datei ablegen.

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
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
    }

    # Statische Frontend-Assets direkt ausliefern (optional, performanter)
    # location /assets/ {
    #     root /var/lib/moddex/ui;
    # }
}

server {
    listen 80;
    server_name moddex.example.internal;
    return 301 https://$host$request_uri;
}
```

Für Caddy ist `reverse_proxy localhost:8080` mit automatischem TLS über Let's Encrypt ausreichend.

### Backup

Alle persistenten Daten liegen unter `/var/lib/moddex`. Für ein konsistentes Backup den Dienst kurz stoppen:

```bash
sudo systemctl stop moddex-backend
sudo tar -czf moddex-backup-$(date +%Y%m%d).tar.gz /var/lib/moddex
sudo systemctl start moddex-backend
```

Die Anwendungsdatei `/opt/moddex/app.jar` muss nicht gesichert werden – sie wird bei Updates ersetzt.

### Experimentelle Funktionen

Die folgenden Funktionen sind noch in der Entwicklung. Sie können unerwartet fehlschlagen oder Daten inkonsistent hinterlassen:

| Funktion | Status | Hinweis |
|----------|--------|---------|
| **Restore / Wiederherstellung** | Experimentell | Kann bestehende Daten überschreiben; vorher Backup erstellen |
| **Modpack Import** | Experimentell | Externe Quellen werden nicht kryptografisch verifiziert |
| **File Manager** | Experimentell | Schreibzugriff auf das Dateisystem des Servers; Berechtigungen prüfen |
| **Externe Downloads** | Experimentell | URLs werden zum Zeitpunkt des Abrufs nicht auf Schadsoftware geprüft |

Für produktive oder sicherheitskritische Umgebungen diese Funktionen deaktiviert lassen, bis sie als stabil markiert sind.

### Schnellcheckliste für den LAN-Betrieb

- [ ] Installer mit `--mode lan` ausgeführt
- [ ] UFW aktiv und nur notwendige Ports geöffnet
- [ ] Router leitet Port **nicht** ins Internet weiter
- [ ] Backend läuft als Benutzer `moddex` (prüfen: `systemctl status moddex-backend`)
- [ ] Logs unter `/var/lib/moddex/logs/` erreichbar und lesbar
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
