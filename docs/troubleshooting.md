# Moddex Troubleshooting & Known Issues

> Häufige Probleme beim Installieren und Betreiben von Moddex auf **Linux** und
> **Windows**, jeweils mit Ursache und Lösung. Findest du dein Problem hier
> nicht, öffne ein Issue über die [Fehler-Vorlage](https://github.com/aklozyp/Moddex/issues/new?template=bug_report.yml)
> (siehe auch [SUPPORT.md](../SUPPORT.md)).

## Wichtige Pfade auf einen Blick

| Zweck | Linux | Windows |
|-------|-------|---------|
| Anwendung (`app.jar`, Frontend) | `/opt/moddex` | `%ProgramFiles%\Moddex` |
| Instanz-Daten (`MODDEX_ROOT`) | `/var/lib/moddex` | `%ProgramData%\Moddex\data` |
| Konfiguration | `/etc/moddex/moddex.env` | `%ProgramFiles%\Moddex\moddex-backend.xml` |
| Logs | `/var/log/moddex/backend.out.log` | `%ProgramData%\Moddex\logs` |
| Dienst | `moddex-backend.service` (systemd) | `moddex-backend` (WinSW) |

**Logs ansehen**

```bash
# Linux
moddex logs            # letzte 200 Zeilen
moddex logs --follow   # live mitlaufen
journalctl -u moddex-backend.service -e   # systemd-Sicht
```

```powershell
# Windows (elevated)
Get-Content "$env:ProgramData\Moddex\logs\moddex-backend.out.log" -Tail 200 -Wait
& "$env:ProgramFiles\Moddex\moddex-backend.exe" status
```

---

## 1. Java fehlt oder ist zu alt

**Symptom:** Installer bricht mit „Java 17+ required" ab, oder der Dienst startet
nicht und das Log zeigt `UnsupportedClassVersionError`.

**Ursache:** Moddex benötigt eine **Java-Laufzeit (JRE/JDK) ab Version 17**.

**Lösung:**

```bash
# Linux: Version prüfen
java -version
# Installieren (Beispiel Debian/Ubuntu)
sudo apt install openjdk-17-jre-headless
```

```powershell
# Windows: Version prüfen
java -version
```

Unter Windows muss `java` im `PATH` liegen **oder** `JAVA_HOME` gesetzt sein,
damit `install.ps1` die Laufzeit findet. Nach einer Java-Installation eine neue
PowerShell-Sitzung öffnen (PATH-Aktualisierung) und den Installer erneut starten.

---

## 2. Port ist belegt

**Symptom:** Dienst startet nicht; Log zeigt `Address already in use` /
`Port 8080 ... bind`.

**Ursache:** Ein anderer Prozess belegt den Backend-Port (Standard `8080`).

**Lösung:** Belegenden Prozess finden oder einen anderen Port wählen.

```bash
# Linux: wer hält den Port?
sudo ss -ltnp 'sport = :8080'
# Neuen Port setzen (Installer erneut ausführen)
sudo /opt/moddex/.../install.sh --port 8090
```

```powershell
# Windows: wer hält den Port?
Get-NetTCPConnection -LocalPort 8080 | Select-Object -ExpandProperty OwningProcess |
  ForEach-Object { Get-Process -Id $_ }
# Neuen Port setzen
.\scripts\windows\install.ps1 -Port 8090
```

Ein erneuter Installer-Lauf mit `--port`/`-Port` aktualisiert den
maschinen-lokalen Port, ohne Daten zu berühren.

---

## 3. Dienst startet nicht / beendet sich sofort

**Symptom:** `moddex status` bzw. `Get-Service moddex-backend` zeigt nicht
„running", oder der Dienst startet und stoppt wiederholt.

**Vorgehen:**

1. **Log lesen** (siehe oben) — die eigentliche Ursache steht fast immer dort
   (Java fehlt, Port belegt, kaputte Config, fehlende Schreibrechte).
2. **Java prüfen** (Abschnitt 1).
3. **Pfad-/Rechteprobleme (Linux):** Daten gehören dem Dienstbenutzer `moddex`.

   ```bash
   sudo systemctl status moddex-backend.service
   sudo ls -ld /var/lib/moddex /var/log/moddex
   ```
4. **Windows:** WinSW protokolliert Startfehler nach
   `%ProgramData%\Moddex\logs\moddex-backend.wrapper.log`.

---

## 4. Web-UI lädt, aber API-Aufrufe schlagen mit CORS fehl

**Symptom:** Im Browser erscheinen CORS-Fehler; API-Antworten werden blockiert,
besonders im `lan`-/`public`-Modus.

**Ursache:** Das Backend ist **fail-closed**. Im `local`-Modus sind nur
Loopback-Ursprünge erlaubt; in `lan`/`public` ist Cross-Origin-Zugriff aus dem
Browser deaktiviert, bis eine explizite Allow-List gesetzt ist.

**Lösung:** Erlaubte Ursprünge konfigurieren und sicherstellen, dass der
Security-Mode zum Betriebsmodus passt.

- Setze `MODDEX_CORS_ALLOWED_ORIGINS` (bzw. `moddex.security.cors.allowed-origins`)
  auf die konkrete Origin (z. B. `https://moddex.example.org`).
- Stelle sicher, dass `MODDEX_SECURITY_MODE` **gleich** `MODDEX_MODE` ist.
  - Linux: in `/etc/moddex/moddex.env`.
  - Windows: in `%ProgramFiles%\Moddex\moddex-backend.xml` (`<env>`-Einträge).
    Beachte: Auf Windows werden manuell ergänzte `<env>`-Einträge (z. B.
    `MODDEX_CORS_ALLOWED_ORIGINS`) bei einem Upgrade **nicht** automatisch
    übernommen — siehe [Upgrade-Hinweis](upgrade.md#upgrade--windows).
- Bevorzugt: Web-UI und API über **dieselbe** Origin hinter einem Reverse Proxy
  ausliefern (nginx-Beispiel im [README](../README.md)) — dann entfällt CORS.

Siehe `docs/security-configuration.md` im Backend-Repo für Details.

---

## 5. CurseForge: „API-Key fehlt/ungültig" oder Provider nicht verfügbar

**Symptom:** Beim Suchen/Importieren von CurseForge-Mods erscheint eine
Fehlermeldung zu API-Key, Autorisierung oder Verfügbarkeit.

**Ursachen & Lösung:**

| Meldung (`errorKind`) | Bedeutung | Lösung |
|-----------------------|-----------|--------|
| `API_KEY_MISSING` | Kein CurseForge-Key hinterlegt | In den **Einstellungen → Allgemein** einen gültigen CurseForge-API-Key eintragen und speichern. |
| `UNAUTHORIZED` | Key abgelehnt | Key prüfen/neu erzeugen; auf führende/folgende Leerzeichen achten. |
| `RATE_LIMITED` | Zu viele Anfragen | Kurz warten und erneut versuchen. |
| `PROVIDER_UNAVAILABLE` | CurseForge nicht erreichbar | Netzwerk/Ausgehende Verbindung prüfen, später erneut versuchen. |

Der Key wird serverseitig gespeichert und nie an die Web-UI zurückgegeben; das
Feld zeigt nur, ob ein Key **konfiguriert** ist.

---

## 6. Checksummen-Mismatch beim Download/Update

**Symptom:** Installation oder Update bricht mit „Checksum mismatch" ab.

**Ursache:** Der heruntergeladene Artefakt (Release-Zip/Tarball oder die
gebündelte WinSW-Binary) entspricht nicht dem erwarteten SHA256 — meist ein
abgebrochener Download oder eine gecachte/manipulierte Datei.

**Lösung:** Download verwerfen und die `.sha256`-Datei vom **selben** Release
erneut laden, dann verifizieren:

```bash
# Linux
sha256sum -c moddex-<tag>-linux-amd64.tar.gz.sha256
```

```powershell
# Windows
$expected = (Get-Content moddex.zip.sha256).Split(' ')[0]
if ((Get-FileHash moddex.zip).Hash.ToLower() -ne $expected) { throw 'Checksum mismatch' }
```

Stimmt die Prüfsumme weiterhin nicht, liegt ein beschädigter oder
nicht-vertrauenswürdiger Download vor — **nicht** installieren und neu beziehen.

---

## 7. Erstes Login / Setup nicht möglich

**Symptom:** Nach der Installation kein Login möglich, oder geschützte Endpunkte
antworten mit `401 Unauthorized`.

**Ursache:** Das ist im Auslieferungszustand **korrekt** — Moddex ist
authentifizierungspflichtig. Das Erst-Setup (Admin-Passwort) muss zuerst über
die Web-UI abgeschlossen werden.

**Lösung:** Web-UI öffnen, Erst-Setup durchlaufen, danach anmelden. Per CLI
benötigen instanz-bezogene Befehle ein Token bzw. das Admin-Passwort (siehe
README, Abschnitt *Command-line interface*).

---

## 8. Erreichbarkeit aus dem LAN

**Symptom:** Lokal (`localhost`) erreichbar, aber nicht von anderen Geräten im
Netz.

**Prüfen:**

1. **Bind-Adresse:** Im `lan`/`public`-Modus bindet das Backend an alle
   Interfaces. Im `local`-Modus nur an Loopback — von außen nicht erreichbar.
   Modus ggf. per Installer-Neulauf (`--mode lan`/`-Mode lan`) anpassen.
2. **Firewall:** Port freigeben.
   - Linux: `sudo ufw allow 8080/tcp` (bzw. `firewalld`, siehe README).
   - Windows: Eingehende Regel für den Port erstellen
     (`New-NetFirewallRule -DisplayName 'Moddex' -Direction Inbound -LocalPort 8080 -Protocol TCP -Action Allow`).

---

## Bekannte Einschränkungen

- **Kein Point-in-Time-Recovery / Restore ist destruktiv** — siehe
  [Recovery-Checkliste](qa/recovery-checklist.md).
- **Keine Malware-Prüfung externer Downloads** — geprüft werden Host-Allowlist
  und Prüfsummen, kein Schadsoftware-Scan.
- **Freier Speicherplatz im Dashboard** wird derzeit als „nicht verfügbar"
  angezeigt; die backend-seitige Speicherprüfung greift dennoch vor schreibenden
  Aktionen.

---

## Verwandte Dokumentation

- [README](../README.md) — Installation, Betriebsmodi, CLI.
- [Upgrade- und Rollback-Anleitung](upgrade.md).
- [Recovery-Checkliste](qa/recovery-checklist.md).
