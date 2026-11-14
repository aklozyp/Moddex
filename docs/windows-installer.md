# Windows-Installer und WinSW-Testgrundlage

Stand: Forgejo-Issues #564 (Grundlage), #198 (Exitcode-Auswertung) und #200
(Staged Upgrade mit Rückfall). Dieses Dokument legt Quelle, Vertrag,
Unterstützungsstatus und Testgrundlage des Windows-Installers fest.

## Quelle und Übernahme

Der maßgebliche Windows-Installer-Quellstand existiert und wurde **übernommen,
nicht neu entwickelt**:

- **Quelle:** `https://github.com/aklozyp/Moddex`, Zweig `develop`, Commit
  `f0898ffa9bc1adcb2a62216143f2a9c0a1fa04fd` (Merge von PR #67; die
  Windows-Kette stammt aus den PRs #26, #40, #44, #50, #57, #59, #61 und #51).
- **Beleg:** Die Audit-Issues Forgejo #198 (M101, „Exitcodes der WinSW-Aufrufe
  auswerten“) und #200 (M103, „Windows-Upgrades mit Staging und Rückfall
  absichern“) referenzieren genau `scripts/windows/install.ps1` an diesem
  Commit (`Geprüfter Stand: f0898ffa9bc1adcb2a62216143f2a9c0a1fa04fd`).
- **Abgrenzung bei der Prüfung:** GitHub-`main` (`96bef43`, 25 Commits) und die
  Tags `v0.1.0`–`v0.1.2` enthalten **kein** Windows-Material (geprüft über die
  vollständige Historie beider Zweige — `main` 25, `develop` am Prüfpunkt
  `f0898ff` 101 Commits — mit `git log --all -- '*windows*' '*.ps1'` und
  Dateibaum-Sicht über alle Commits). Der `develop`-Zweig ist die einzige
  autoritative Grundlage.

Übernommene Dateien (byte-identisch bis auf die ergänzten Provenienz-Kommentare
und die dokumentierten Abweichungen — `#198`-Exitcode-Wrapper in beiden
Skripten, `#200`-Staging/Rollback in `install.ps1`; keine gelöschte Quellzeile):

| Datei | Zweck |
| --- | --- |
| `scripts/windows/install.ps1` | Installation und idempotentes Upgrade als Windows-Dienst (WinSW); seit #200 mit Staging und Rollback |
| `scripts/windows/uninstall.ps1` | Deinstallation; Daten unter `%ProgramData%\Moddex` bleiben ohne `-Purge` erhalten |
| `packaging/windows/moddex-backend.xml.template` | WinSW-Dienstdefinition mit `@@PLACEHOLDER@@`-Substitution |

Bewusst **nicht** übernommen (Grenzen von #564, keine erfundenen Bestandteile):

- `scripts/windows/build-bundle.ps1` (Quelle) — Windows-Zip-Bündelung gehört
  zur Release-Pipeline und ist ein Folgeauftrag; es gibt keinen
  Windows-Download-/Bundle-Modus (`download.sh`/`build-bundle.sh` bleiben
  linux-amd64).
- `scripts/windows/smoke-test.ps1` (Quelle) — installiert einen **echten**
  Windows-Dienst und ist nur für eine Wegwerf-Windows-VM bzw. einen
  Windows-CI-Runner vorgesehen. Solange keine solche Prüfung läuft, wird sie
  nicht ausgeliefert.
- `scripts/ci/lint-powershell.ps1` (Quelle) — das Parse-Check-Muster ist im
  Test-Harness unten enthalten (ohne PSScriptAnalyzer-Download).

## Unterstützungsstatus

- Linux/systemd bleibt die **geprüfte** Distribution; Bundles heißen weiterhin
  `moddex-<tag>-linux-amd64.tar.gz` (+ `.sha256`).
- Die Windows-Quellen sind eine **Grundlage**. Es wird keine geprüfte
  Windows-Unterstützung behauptet: Kein Release-Artefakt, kein Download-Pfad,
  keine Release-Pipeline und kein CI-Lauf auf Windows existieren.
- Issue-Referenzen in den übernommenen Kommentaren (`Moddex#59`,
  `Moddex-Backend#50`, `#57` …) gehören zum GitHub-Release-Repo bzw. dessen
  damaligen Backend-Repo, **nicht** zu Forgejo-Nummern dieses Projekts.

## Vertrag des Windows-Installers

- **Pfadlayout:** App `%ProgramFiles%\Moddex` (`app.jar`, UI, Dienst-Wrapper,
  `VERSION`), Daten `%ProgramData%\Moddex\data` (`MODDEX_ROOT`), Konfiguration
  `%ProgramData%\Moddex\config`, Logs `%ProgramData%\Moddex\logs`.
- **WinSW:** Die Wrapper-Binärdatei heißt `moddex-backend.exe` und liest die
  benachbarte `moddex-backend.xml` (WinSW-Namenskonvention). Native
  Dienstschritte sind `stop`, `uninstall`, `install`, `start` (dokumentiert
  außerdem `status` für Diagnosen). Die Pinning-Konstanten (WinSW v2.12.0,
  SHA256) stammen unverändert aus der Quelle; vor echter Nutzung die Prüfsumme
  unabhängig gegen die veröffentlichte WinSW-Prüfsumme verifizieren — eine im
  Installer gepinnte Prüfsumme ersetzt diese Verifikation nicht.
- **Exitcode-Auswertung (#198):** Seit dem Fix laufen alle nativen
  WinSW-Aufrufe beider Skripte durch die Wrapper-Funktion
  `Invoke-ServiceStep`. Sie ruft `& $ServiceExe <step> 2>$null | Out-Null`
  auf, prüft `$LASTEXITCODE` und bricht bei einem Nicht-Null-Code mit
  `Die` ab. Die Meldung nennt Schritt, Exitcode und die konkrete
  Wrapper-Log-Adresse (`%ProgramData%\Moddex\logs`, die `<logpath>` der
  Dienstvorlage — WinSW v2.12.0 schreibt jede CLI-Operation inklusive
  Fehlern in `<logpath>\moddex-backend.wrapper.log`) und eine sichere
  nächste Aktion (Ursache beheben, Installer bzw. Uninstaller erneut
  ausführen); sie enthält
  keine Pfade außerhalb des vom Installer ohnehin gedruckten Layouts und
  keine Secrets. **Kein Exitcode wird toleriert:** geprüft am Quellcode des
  gepinnten WinSW v2.12.0 (`Program.cs`) behandelt WinSW die
  „bereits erledigt"-Situationen selbst als Erfolg mit Exit 0 — `stop` auf
  einem bereits gestoppten Dienst (ERROR_SERVICE_NOT_ACTIVE intern → „has
  already stopped" → 0), `uninstall` ohne vorhandenen bzw. mit zum Löschen
  markiertem Dienst (→ 0), `start` auf einem bereits laufenden Dienst (→
  0). Ein Nicht-Null-Code ist damit immer ein echter Fehler (Win32-Fehlercode
  wie 5/Zugriff verweigert oder 1073/Dienst existiert bereits, oder `-1` für
  eine unbehandelte WinSW-Ausnahme) und rechtfertigt den Abbruch. Damit
  läuft keine Installation nach einem fehlgeschlagenen Schritt still weiter
  (Teilwechsel der Artefakte, halb registrierter Dienst bleiben aus).
- **Modus/Port:** `-Mode local|lan|public`, `-Port` (Standard 8080); `local`
  bindet `127.0.0.1`, sonst `0.0.0.0` — dieselbe Zuordnung wie der
  Linux-Installer. Ohne explizite Parameter erbt ein erneuter Lauf Modus und
  Port aus der bestehenden Service-XML; vom Betreiber ergänzte `<env>`-Einträge
  bleiben erhalten (Parität zum Linux-Vertrag, z. B. `MODDEX_CORS_*` oder
  manuelle `MODDEX_TLS_*`).
- **Upgrade mit Staging und Rückfall (#200):** `install.ps1` ist idempotent;
  ein erneuter Lauf ist das Upgrade. Der Upgrade-Lauf ist in vier Phasen
  gegliedert (Parität zu `update.sh`/`install.sh` unter Linux: Staging vor dem
  Stop, vorbereitete/verifizierte Artefakte vor der ersten Änderung):
  1. **Staging** — das komplette neue Anwendungsbild (`app.jar`, UI, `VERSION`,
     gerenderte Dienstdefinition inklusive bewahrter Betreiber-`<env>`-Einträge,
     WinSW-Executable) wird in `.upgrade-<id>\staging` unter
     `%ProgramFiles%\Moddex` vorbereitet und verifiziert (Vorlagen- und
     Platzhalterprüfung, WinSW-Prüfsumme beim Pin-Download), **bevor**
     irgendetwas Bestehende angerührt wird; der Dienst läuft weiter. Ein
     Fehler hier meldet „Nothing was changed" und den erneuten Lauf.
  2. **Stop** — erste Mutation ist der exit-geprüfte Dienst-Stop
     (`Invoke-ServiceStep`, #198). Vorher nicht: Die alte Logik überschrieb
     `app.jar` und löschte die UI, bevor die Dienstdefinition geprüft war.
  3. **Ersetzung** — die bestehenden verwalteten Dateien (`app.jar`, `ui`,
     `VERSION`, `moddex-backend.xml`, `moddex-backend.exe`, zusätzlich das
     veraltete `<AppDir>\frontend`) werden per Umbenennung in
     `.upgrade-<id>\aside` beiseitegestellt (nicht gelöscht) und die
     gestageten Kopien per Umbenennung eingesetzt. Alle verwalteten Dateien
     liegen in `%ProgramFiles%\Moddex`; das Arbeitsverzeichnis liegt deshalb
     ebenfalls dort, damit jede Umbenennung auf einem Volume bleibt und keine
     Teil-Kopien entstehen können (Staging-Ort bewusst gewählt und hier
     dokumentiert; `staging-<id>` unter `%ProgramData%` oder TEMP könnte auf
     einem anderen Volume liegen und würde Copy+Delete statt Rename).
  4. **Dienst** — `uninstall`/`install`/`start` durch den #198-Wrapper.

  Jeder Fehler in Phase 3 oder 4 löst `Invoke-UpgradeRollback` aus: die
  beiseitegestellten Dateien kehren in umgekehrter Reihenfolge zurück
  (teilweise eingesetzte neue Kopien werden entfernt), und der Dienst wird
  nach einer Fallmatrix wiederhergestellt. Grundlage: die SCM-Registrierung
  zeigt auf den Pfad, nicht auf eine Dateiversion — eine weiter existierende
  Registrierung läuft nach der Restauration wieder als vorherige Anwendung
  samt Betreiber-`<env>`-Einträgen; WinSW v2.12.0 normalisiert zwar
  stop/uninstall/start, aber `Install()` auf bereits registrierter ID
  schlägt mit ERROR_SERVICE_EXISTS (1073) fehl, und dieser Code wird **nicht**
  normalisiert — eine bestehende Registrierung wird deshalb im Rollback nie
  erneut `install`iert. Fallmatrix (Flag `$InstalledNew` = dieser Lauf hat
  die jetzt bestehende Registrierung angelegt):
  - Registrierung existierte vorher, kein uninstall gelaufen → nur `start`.
  - Registrierung existierte vorher, uninstall gelaufen, kein neues
    `install` geglückt → `install` (Neuregistrierung aus der restaurierten
    vorherigen Definition) + `start`.
  - Registrierung von diesem Lauf erzeugt (uninstall + `install` gelaufen,
    dann Fehler) → nur `start`, **kein** Duplicate-`install` (1073).
  - Fresh-Install (keine vorherige Registrierung), dieser Lauf hat eine
    angelegt → `uninstall` **vor** dem Datei-Abbau (das WinSW-uninstall
    läuft über die Wrapper-Executable, die die Restauration entfernen
    würde); danach bleiben keine Anwendungsdateien zurück.
  Die Meldungen nennen Ursache, wiederhergestellten Zustand und nächste
  Aktion (erneuter Lauf; bei Dienst-Restaurationsfehlern den konkreten
  Endzustand wie „registriert, aber gestoppt“ bzw. „nicht registriert“ und
  den manuellen Start/Register-Schritt); keine Secrets. Ein Rollback, der die
  Datei-Restauration nicht abschließt, und ein Rollback, der erst bei einem
  Dienst-Schritt scheitert, werden getrennt gemeldet: Letzteres heißt
  ausdrücklich „Dateien an Ort und Stelle restauriert“ statt fälschlich auf
  ein dann leeres `aside` zu verweisen. **Betreiberkonfiguration bleibt stets unangetastet:**
  `%ProgramData%\Moddex\config`, Instanzdaten (`data`) und operator-`<env>`-
  Einträge sind in keiner Phase Teil der Ersetzung.
  Das Arbeitsverzeichnis wird in `finally` geräumt; nur ein nicht
  abschließender Rollback behält das `aside` für manuelle Wiederherstellung
  und weist in der Meldung darauf hin. Grenzen: Ein harter Kill (Stromausfall)
  mittendrin kann das Arbeitsverzeichnis zurücklassen — geführte nächste
  Aktion ist der erneute Installer-Lauf; ein verbleibendes `aside` kann die
  vorherigen Dateien für die manuelle Wiederherstellung enthalten. Einen
  Host-Lock gegen parallele Läufe gibt es auf Windows nicht (Quellstand; Linux
  hat `flock` — #200 ändert das nicht).
- **Umgebungsvariablen der Dienstvorlage:** Das aktuelle Backend liest
  `MODDEX_ROOT`, `MODDEX_CONFIG_DIR`, `MODDEX_LOG_DIR`,
  `SERVER_ADDRESS`/`SERVER_PORT` und `MODDEX_TLS_*` (siehe `application.yml`
  und `TlsEnvironmentPostProcessor`). Die Quell-Ära-Einträge `MODDEX_UI_DIR`,
  `MODDEX_MODE` und `MODDEX_SECURITY_MODE` werden vom aktuellen Backend noch
  nicht gelesen (Stand wie unter Linux: UI-Dateien werden abgelegt, der
  Backend serves sie noch nicht); sie bleiben solange wirkungslos.
- **Bekannte Fehler/Grenzen:**
  - **#198 (M101) — behoben (Abweichung von der Quelle):** An Stand
    `f0898ffa` prüfte `install.ps1` nach den nativen
    `stop`/`uninstall`/`install`/`start`-Aufrufen (`… | Out-Null`)
    `$LASTEXITCODE` nicht. Das ist in diesem Repository durch die
    `Invoke-ServiceStep`-Wrapper in beiden Skripten behoben (siehe Vertrag
    oben); der verbatim-Übernahmestand endet damit — die Provenienznoten in
    den Skripten dokumentieren die Abweichung. Auf echtem Windows bleibt das
    Verhalten ungeprüft, bis eine Windows-Verifikation läuft.
  - **#200 (M103) — behoben (Abweichung von der Quelle):** An Stand
    `f0898ffa` entfernte/überschrieb das Upgrade die bestehenden UI-Dateien
    und `app.jar`, bevor die Dienstdefinition gerendert, geprüft und der
    Dienst neu registriert war; ein Fehler danach ließ die vorherige
    Installation zerstört zurück. Das ist in diesem Repository durch den
    Staging-/Rollback-Vertrag oben ersetzt (Staging vor dem Stop,
    Rename-Aside statt Löschen, `Invoke-UpgradeRollback` nach Fallmatrix:
    Neuregistrierung des vorherigen Dienstes nur, wenn die alte Registrierung
    entfernt wurde und keine neue existiert — sonst Start der bestehenden
    Registrierung ohne Duplicate-`install`, bei einem Fresh-Install-Rollback
    wird die Registrierung vor dem Datei-Abbau entfernt);
    die Provenienznoten in `install.ps1`
    dokumentieren die Abweichung. Auf echtem Windows bleibt das Verhalten
    ungeprüft, bis eine Windows-Verifikation läuft; die Vertragsprüfung
    läuft als Flow-Simulation (siehe unten).
  - **TLS:** Der Windows-Installer hat keine TLS-Parameter (Linux:
    `--tls-cert`/`--tls-key`/`--tls-keystore`). `MODDEX_TLS_*` kann der
    Betreiber manuell als `<env>` in der Service-XML ergänzen. Der verbatim
    übernommene Warntext in `install.ps1` (public mode) nennt dabei
    Variablennamen einer älteren Konvention
    (`MODDEX_TLS_TERMINATED`/`MODDEX_TLS_CERT`/`MODDEX_TLS_KEY`), die das
    aktuelle Backend nicht liest — heute gelten
    `MODDEX_TLS_ENABLED`/`MODDEX_TLS_CERT_FILE`/`MODDEX_TLS_KEY_FILE`/
    `MODDEX_TLS_KEYSTORE*` (TlsEnvironmentPostProcessor); `MODDEX_TLS_TERMINATED`
    existiert repo-weit nur in dieser Meldung. Der Code bleibt verbatim
    (Provenienz), die Abweichung ist hier benannt.
  - **Öffentlicher Modus:** Warnung und (interaktiv) Bestätigung vor reinem
    HTTP; keine Firewall-Automatik auf Windows. Vom Betreiber zu prüfen.

## Simulierte WinSW-Schritte (Vertragsprüfung für #198 und #200)

Die nativen WinSW-Schritte werden **nur simuliert**. Es werden keine echten
Windows-Dienste installiert, gestoppt oder entfernt und keine produktiven Daten
verändert; der Harness läuft auf Linux/macOS in einem isolierten
Fixture-Verzeichnis.

Aufruf (Repository-Root oder beliebiges Verzeichnis):

```bash
bash scripts/tests/test-windows-installer-foundation.sh
```

Der Test führt das PowerShell-Harness
`scripts/tests/winsw-simulate-steps.ps1` in fünf Stufen aus:

1. **Parse-Check** aller `*.ps1` unter `scripts/windows/` und `scripts/tests/`
   mit `[System.Management.Automation.Language.Parser]::ParseFile` (Muster aus
   der Quelle `scripts/ci/lint-powershell.ps1`); Syntaxfehler brechen ab, bevor
   etwas ausgeführt wird.
2. **Vorlagen-Konsistenz:** `moddex-backend.xml.template` muss wohlgeformtes
   XML sein und exakt die Platzhalter enthalten, die `install.ps1` substituiert
   (Drift zwischen Installer und Vorlage bricht den Test).
3. **#198/#200-Vertrag per AST:** In beiden Skripten darf kein direkter
   `& $ServiceExe …`-Aufruf mehr stehen; alle nativen Schritte müssen durch
   `Invoke-ServiceStep` laufen. Der Harness prüft pro Skript: die
   Wrapper-Funktion existiert, enthält genau einen nativen Aufruf über den
   `-Executable`-Parameter, referenziert `$LASTEXITCODE` und bricht über `Die`
   ab; jede Aufrufstelle übergibt `-Executable $ServiceExe`, ein
   Literal-`-Step` und `-LogDir`; der geordnete Hauptlauf bleibt
   `install.ps1: stop, uninstall, install, start` bzw.
   `uninstall.ps1: stop, uninstall`, und nur die #200-Rollback-Funktion
   `Invoke-UpgradeRollback` darf eigene Aufrufstellen tragen
   (`install`, `start` — Wiederherstellung des vorherigen Dienstes).
   Bei Änderungen an den Skripten schlägt diese Prüfung fehl, bis der
   Harness-Vertrag nachgeführt wurde — gewollte Drift-Sicherung (der
   #200-Staging-Umbau hat die Liste selbst nachgeführt).
4. **Runtime-Simulation des Abbruchvertrags:** Ein generiertes
   `moddex-backend.exe` (POSIX-sh-Stub im Fixture-Verzeichnis, Code pro
   Schritt aus einer Kontrolldatei) wird von den **unverändert per AST
   extrahierten Funktionskörpern** der echten Skripte (`Write-Log`, `Die`,
   `Invoke-ServiceStep`) aufgerufen, jeweils in einem isolierten Kind-pwsh.
   Damit sind Stub-Aufruf und `$LASTEXITCODE`-Behandlung echter Code, keine
   Nachbildung. Stub-Exitcode 0 muss durchlaufen (Kind-Exit 0), ein
   Nicht-Null-Code muss zu einem kontrollierten Abbruch führen: Kind-Exit
   nicht 0, Meldung nennt Schritt, Code, Wrapper-Log-Adresse und nächste
   Aktion. Ein stiller Weiterlauf bei Nicht-Null oder ein Abbruch ohne
   geführte Meldung wird als `CONTRACT VIOLATION` gemeldet; die Kette des
   betroffenen Skripts endet am fehlschlagenden Schritt (wie im echten Lauf),
   das andere Skript läuft unabhängig weiter.
5. **Flow-Simulation des #200-Upgrade-Vertrags:** Der Harness generiert aus
   dem **echten** `install.ps1` eine Variante im Fixture-Bundle: Param-Block,
   Hauptanweisungen und die Hilfsfunktionen (`Write-Log`, `Die`,
   `Invoke-ServiceStep`, `Invoke-UpgradeRollback`, `Get-ExistingEnv`,
   `Get-UnmanagedEnv`, `Resolve-Config`, `Resolve-JavaExe`) werden
   unverändert per AST extrahiert;
   nur plattformgebundene Einstiegspunkte sind Shims (`Assert-Admin`,
   `Resolve-WinSw`, `Get-Service`), und `Copy-Item`/`Move-Item`/`Remove-Item`
   laufen als protokollierende Shims, die an die echten Cmdlets
   weiterreichen und auf Bedarf einmalig fehlschlagen können
   (`MODDEX_SIM_FAILSPEC=<op>:<ordinal>`). Der Stub-Dienst läuft wie in
   Stufe 4; Stub-Aufrufe und Dateioperationen teilen sich ein Journal, sodass
   der Test die echte Reihenfolge belegt: Staging vor dem Dienst-Stop,
   Rename-Aside vor dem Rename-In, Rollback vor dem geführten Abbruch,
   Arbeitsverzeichnis-Räumung nach dem Start. Der Treibertest leitet
   `ProgramFiles`/`ProgramData`/`TEMP` auf die Fixture um und stellt einen
   Stub-`java.exe` bereit; die Backslash-Pfadliterale des Installers
   (`packaging\windows`) normalisiert `Join-Path` auf Linux zu
   `packaging/windows`, wo der Treibertest die Vorlage ablegt. Szenarien im
   Treibertest:
   (a) Erfolg — kompletter Ablauf, geerbter Modus/Port, bewahrter
   Betreiber-`<env>`-Eintrag, Konfiguration/Instanzdaten unangetastet;
   (b) Verschiebefehler bei der UI-Einspielung — Rollback stellt die
   vorherige Anwendung wieder her;
   (c) Dienststart-Fehler nach erfolgreichem `install` (`start=4:1` plus
   `install=1073:>1` als 1073-Falle) — der Rollback startet die
   von diesem Lauf erzeugte Registrierung **ohne** Duplicate-`install` wieder
   (Stub-Folge `stop/uninstall/install/start/start`; ein Regression-laufen
   des alten „immer install“-Rollbacks würde an der Falle mit 1073 scheitern
   und den vorherigen Dienst gestoppt lassen);
   (d) Abbruch vor jeder Dienstoperation (fehlerhafte Vorlage) — keine
   bestehende Datei angerührt, Dienst nicht einmal gestoppt;
   (e) Stop-Fehler (`stop=5`) — Abbruch vor der Ersetzungsphase, nichts
   angerührt;
   (f) Fresh-Install mit Dienststart-Fehler (`start=4:1`) — der Rollback
   entfernt die Registrierung dieses Laufs vor dem Datei-Abbau
   (`install/start/uninstall`, kein `stop`) und hinterlässt keinen
   Halbzustand;
   (g) `install`-Fehler nach dem `uninstall` (`install=3:1`) — der Rollback
   registriert den vorherigen Dienst aus der restaurierten Definition neu und
   startet ihn (`stop/uninstall/install/install/start`). Der Harness spiegelt
   den Exitcode des simulierten Laufs
   (`CONTROLLED EXIT` bei Abbruch, `PASS` bei Erfolg); der Treibertest
   unterscheidet über Greps zwischen kontrolliertem Abbruch (erwartet),
   Harness-Fehler und Vertragsverletzung.

Exitcode-Szenarien (der Stub nimmt pro Schritt einen Code aus einer
Kontrolldatei an):

```bash
fixture=$(mktemp -d)
printf 'install=3\n' > "$fixture/codes.conf"
pwsh -NoProfile -NonInteractive -File scripts/tests/winsw-simulate-steps.ps1 \
  -RepoRoot "$PWD" -FixtureDir "$fixture" -ExitCodes "$fixture/codes.conf"
# Erwartung: Exitcode 1 mit CONTROLLED-ABORT-Zeile, z. B.
#   [winsw-sim] CONTROLLED ABORT (expected observable for a nonzero WinSW exit code):
#   install.ps1 aborted at step 'install' with WinSW exit code 3; guided message verified.
# Die geführte Meldung (Schritt, Code, Wrapper-Log-Adresse, „rerun") wird
# zusätzlich als Kind-Ausgabe mitgedruckt. Ein Lauf ohne Fehlercode endet mit
# Exitcode 0 und PASS-Zeile.
```

Der Harness verifiziert den Abbruch als erwartetes Beobachtungsergebnis des
Fehlszenarios und endet trotzdem mit Exitcode 1 — er spiegelt den abgebrochenen
simulierten Lauf; der Treibertest unterscheidet über seine Grep-Assertions
zwischen kontrolliertem Abbruch (erwartet) und Vertragsverletzung (Fehler).
Die Kontrolldatei unterstützt daneben `step=code:N` (failt die ersten N
Aufrufe des Schritts und gelingt danach) und `step=code:>N` (gelingt für die
ersten N Aufrufe und failt ab Aufruf N+1) — `start=4:1` lässt den Start der
neuen Version fehlschlagen und den Rollback-Start gelingen; `install=1073:>1`
modelliert das nicht normalisierte WinSW-Verhalten (zweites `install` auf
bereits registrierter ID → ERROR_SERVICE_EXISTS) und pinnt, dass der Rollback
eine von diesem Lauf erzeugte Registrierung nicht erneut installiert.

## PowerShell-Voraussetzungen

- **Windows (echte Installation):** Windows PowerShell 5.1 oder PowerShell 7
  (`#Requires -Version 5.1` in beiden Skripten). Nicht durch dieses Repository
  geprüft.
- **Linux/macOS (Tests):** PowerShell 7 (`pwsh`); verifiziert mit 7.6.10 im
  debian:12-Container (arm64). Der Harness nutzt die Unix-Ausführung eines
  POSIX-Stub-Skripts und läuft nicht unter Windows.
- **Debian 12 (Forgejo-Runner-Container):** `pwsh` ist nicht in den
  Debian-Repositories. Geprüftes Rezept (als root, analog zur
  ShellCheck-Installation im `scripts`-Job von `checks.yml`):

  ```bash
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends curl gnupg apt-transport-https ca-certificates
  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor -o /usr/share/keyrings/microsoft.gpg
  echo "deb [signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/debian/12/prod bookworm main" \
    > /etc/apt/sources.list.d/microsoft.list
  apt-get update && apt-get install -y --no-install-recommends powershell
  pwsh --version
  ```

  Diese Installationslogik ist im `scripts`-Job von
  `.forgejo/workflows/checks.yml` eingerichtet — als harter Bestandteil ohne
  `|| true`-Abschwächung: Ein Installationsfehler macht den Job rot, statt
  die Prüfung still zu überspringen. Fehlt `pwsh` in einer Umgebung ohne
  diesen Workflow-Schritt, bricht `test-windows-installer-foundation.sh` mit
  dieser Anleitung **laut** ab — kein stiller Skip.

  Alternative ohne apt-Repository (Tarball): PowerShell-linux-arm64.tar.gz von
  der verifizierten PowerShell-Release-Seite laden und gegen die dort
  veröffentlichte `hashes.sha256`-Prüfsumme prüfen, bevor sie ausgeführt wird;
  eine selbst berechnete Prüfsumme genügt nicht.

- **PSScriptAnalyzer** ist nicht Teil des Harness (kein Netzdownload im CI).
  Lokal optional; das Muster samt Einstellungen liegt in der Quelle
  (`scripts/ci/lint-powershell.ps1`, `PSScriptAnalyzerSettings.psd1` an Stand
  `f0898ffa`).

## CI-Verortung

- Der Forgejo-`scripts`-Job führt alle `scripts/tests/test-*.sh` aus und
  nimmt den neuen Test dadurch automatisch auf.
- `bash -n`/ShellCheck prüfen die neue `.sh`; die neuen `.ps1` werden im
  Parse-Check des Harness geprüft.
- `checks.yml` installiert `pwsh` im `scripts`-Job als eigener Schritt vor den
  Regressionstests. Schlägt die Installation fehl, wird der Job rot; in
  Umgebungen ohne diesen Schritt schlägt der Test **sichtbar** mit
  Installationsanleitung fehl, alle übrigen Suiten bleiben davon unberührt.
