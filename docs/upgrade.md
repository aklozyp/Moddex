# Moddex Upgrade & Rollback

> Wie du eine bestehende Moddex-Installation sicher auf eine neue Version
> aktualisierst und im Notfall auf die vorherige Version zurückrollst — für
> **Linux** und **Windows**. Beide Installer sind **idempotent**: ein erneuter
> Lauf tauscht `app.jar` und das Frontend aus, **ohne** Instanz-Daten oder die
> maschinen-lokale Konfiguration (Modus/Port) zu verändern.

## Grundprinzip

- **Anwendung** (`app.jar`, Frontend) wird beim Upgrade ersetzt.
- **Instanz-Daten** (`MODDEX_ROOT`) und **Konfiguration** (Modus/Port/CORS)
  bleiben erhalten, solange du nicht ausdrücklich `--mode`/`-Mode` bzw.
  `--port`/`-Port` neu setzt.
- Die installierte Version steht in `VERSION` (Linux: `/opt/moddex/VERSION`,
  Windows: `%ProgramFiles%\Moddex\VERSION`).

> ⚠️ **Vor jedem Upgrade ein Backup ziehen.** Ein Versions-Upgrade kann ein
> Datenschema migrieren; ein Rollback auf die ältere Version ist nur garantiert
> sauber, wenn du den Datenstand **vor** dem Upgrade gesichert hast.

---

## Schritt 0: Backup vor dem Upgrade

```bash
# Linux – Dienst stoppen für ein konsistentes Backup (empfohlen)
sudo systemctl stop moddex-backend.service
sudo tar czf moddex-data-$(date +%F).tar.gz -C /var/lib/moddex .
sudo cp /etc/moddex/moddex.env moddex.env.bak
sudo systemctl start moddex-backend.service
```

```powershell
# Windows (elevated)
Stop-Service moddex-backend
$stamp = Get-Date -Format yyyy-MM-dd
Compress-Archive "$env:ProgramData\Moddex\data\*" "moddex-data-$stamp.zip"
Copy-Item "$env:ProgramFiles\Moddex\moddex-backend.xml" "moddex-backend.xml.bak"
Start-Service moddex-backend
```

Alternativ kannst du pro Instanz die eingebaute Backup-Funktion nutzen
(`moddex backup <instance-id>` bzw. die Web-UI).

---

## Upgrade — Linux

### Variante A: Automatisch (empfohlen)

Der Helfer vergleicht `/opt/moddex/VERSION` mit dem neuesten Release-Tag und
aktualisiert nur bei Bedarf:

```bash
curl -fsSLO https://github.com/aklozyp/Moddex/releases/latest/download/update.sh
bash update.sh
```

`update.sh` lädt den passenden Tarball, **verifiziert die SHA256-Prüfsumme** und
ruft `install.sh` ohne `--mode`/`--port` auf — Modus, Port, Konfiguration und
Daten bleiben unangetastet.

### Variante B: Manuell mit einem bestimmten Release

```bash
TAG=v0.3.0
curl -fsSLO "https://github.com/aklozyp/Moddex/releases/download/$TAG/moddex-$TAG-linux-amd64.tar.gz"
curl -fsSLO "https://github.com/aklozyp/Moddex/releases/download/$TAG/moddex-$TAG-linux-amd64.tar.gz.sha256"
sha256sum -c "moddex-$TAG-linux-amd64.tar.gz.sha256"
tar xzf "moddex-$TAG-linux-amd64.tar.gz"
sudo ./moddex-$TAG-*/scripts/install.sh
```

---

## Upgrade — Windows

Aus einer **elevated** PowerShell-Sitzung, mit dem `windows-x64.zip` der
Zielversion:

```powershell
$Tag = 'v0.3.0'
Invoke-WebRequest "https://github.com/aklozyp/Moddex/releases/download/$Tag/moddex-$Tag-windows-x64.zip" -OutFile moddex.zip
Invoke-WebRequest "https://github.com/aklozyp/Moddex/releases/download/$Tag/moddex-$Tag-windows-x64.zip.sha256" -OutFile moddex.zip.sha256
$expected = (Get-Content moddex.zip.sha256).Split(' ')[0]
if ((Get-FileHash moddex.zip).Hash.ToLower() -ne $expected) { throw 'Checksum mismatch' }
Expand-Archive moddex.zip -DestinationPath moddex-$Tag -Force
.\moddex-$Tag\scripts\windows\install.ps1
```

Ohne `-Mode`/`-Port` übernimmt der Installer die bestehenden `<env>`-Werte aus
`moddex-backend.xml`; nur `app.jar`/Frontend und die checksum-gepinnte WinSW-
Binary werden ersetzt.

---

## Nach dem Upgrade verifizieren

```bash
# Linux
moddex version          # zeigt neue Version + Pfade
moddex status           # Dienst läuft, Endpunkt erreichbar
```

```powershell
# Windows
Get-Service moddex-backend
& "$env:ProgramFiles\Moddex\moddex-backend.exe" status
Get-Content "$env:ProgramFiles\Moddex\VERSION"
```

Prüfe, dass die Web-UI lädt und der Login funktioniert. Schlägt der Start fehl,
siehe [Troubleshooting](troubleshooting.md) (Abschnitt „Dienst startet nicht").

---

## Rollback auf die vorherige Version

Es gibt **keinen** automatischen Rollback-Befehl — ein Rollback ist eine erneute
Installation der **älteren** Version, gefolgt von einem Restore des vor dem
Upgrade gesicherten Datenstands, falls ein Schema migriert wurde.

1. **Dienst stoppen.**
   - Linux: `sudo systemctl stop moddex-backend.service`
   - Windows: `Stop-Service moddex-backend`
2. **Ältere Version installieren** — wie oben unter „Upgrade", aber mit dem
   **vorherigen** `TAG` (z. B. `v0.2.0`). Der Installer ersetzt die Anwendung
   durch die ältere Build-Variante.
3. **Daten bei Bedarf zurücksetzen.** Hat das Upgrade Daten migriert, spiele das
   in Schritt 0 erstellte Backup zurück:
   ```bash
   # Linux
   sudo systemctl stop moddex-backend.service
   sudo rm -rf /var/lib/moddex/* && sudo tar xzf moddex-data-<datum>.tar.gz -C /var/lib/moddex
   sudo cp moddex.env.bak /etc/moddex/moddex.env
   sudo chown -R moddex:moddex /var/lib/moddex
   sudo systemctl start moddex-backend.service
   ```
   ```powershell
   # Windows (elevated)
   Stop-Service moddex-backend
   Remove-Item "$env:ProgramData\Moddex\data\*" -Recurse -Force
   Expand-Archive "moddex-data-<datum>.zip" "$env:ProgramData\Moddex\data" -Force
   Copy-Item "moddex-backend.xml.bak" "$env:ProgramFiles\Moddex\moddex-backend.xml" -Force
   Start-Service moddex-backend
   ```
4. **Verifizieren** (siehe oben).

> **Grenzen des Rollbacks:** Ohne ein vor dem Upgrade gezogenes Backup ist ein
> sauberer Rollback nicht garantiert — eine neuere Version kann Daten in ein
> Format überführt haben, das die ältere Version nicht mehr liest. Behalte das
> Pre-Upgrade-Backup, bis die neue Version im Betrieb bestätigt ist.

---

## Verwandte Dokumentation

- [README](../README.md) — Installation, Betriebsmodi, CLI, Backup/Restore.
- [Troubleshooting & Known Issues](troubleshooting.md).
- [Recovery-Checkliste](qa/recovery-checklist.md).
