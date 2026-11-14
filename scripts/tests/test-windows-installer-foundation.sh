#!/usr/bin/env bash
# Windows-Installer-Grundlage, WinSW-Exitcode-Vertrag (#198) und Staging-
# Upgrade-Vertrag mit Rollback (#200).
#
# Prueft ohne echtes Windows und ohne echte Dienstoperationen:
#   1. Parse-Check aller *.ps1 unter scripts/windows und scripts/tests.
#   2. Wohlgeformtheit und Platzhalter-Konsistenz der WinSW-Dienstvorlage.
#   3. WinSW-Vertrag per AST (#198/#200): alle nativen Aufrufe laufen durch die
#      Invoke-ServiceStep-Wrapper-Funktion ($LASTEXITCODE-Auswertung + Abbruch
#      via Die); der Hauptlauf je Skript behaelt seine Schrittkette
#      (install.ps1: stop/uninstall/install/start) und nur die #200-Rollback-
#      Funktion Invoke-UpgradeRollback traegt eigene Aufrufstellen
#      (uninstall/install/start: Fallmatrix - Registrierung eines Fresh-
#      Install-Laufs entfernen, vorherigen Dienst neu registrieren, wenn die
#      alte Registrierung entfernt wurde und keine neue existiert, starten;
#      eine von diesem Lauf erzeugte Registrierung wird OHNE Duplicate-
#      install wiederverwendet, da WinSW install auf bestehender ID mit 1073
#      fehlschlaegt und das nicht normalisiert).
#   4. Runtime-Simulation des #198-Vertrags: die unverandert extrahierten
#      Funktionskoerper (Write-Log, Die, Invoke-ServiceStep) laufen in einem
#      isolierten Kind-pwsh gegen einen generierten Stub. Stub-Exitcode 0 =
#      Schritt gelingt; Nicht-Null = kontrollierter Abbruch, dessen Meldung
#      Schritt, Exitcode und die konkrete Wrapper-Log-Adresse nennt.
#   5. Flow-Simulation des #200-Upgrade-Vertrags: der echte Hauptlauf von
#      install.ps1 (Anweisungen unverandert extrahiert; nur
#      plattformgebundene Einstiegspunkte sind Shims) laeuft gegen den Stub
#      auf einer Fixture, die das Windows-Pfadlayout als Linux-Baum nachstellt
#      (ProgramFiles/ProgramData/TEMP umgeleitet). Szenarien:
#        a) Erfolg: Staging vor dem Stop, Rename-Aside/Rename-In, Dienstkette,
#           Konfiguration unangetastet.
#        b) Kopier-/Verschiebefehler in der Ersetzungsphase (fail-once):
#           Rollback stellt die vorherige Anwendung wieder her.
#        c) Dienststart-Fehler NACH erfolgreichem install (start=4:1,
#           install=1073:>1 als 1073-Falle): Rollback startet die von diesem
#           Lauf erzeugte Registrierung OHNE Duplicate-install wieder
#           (Stub-Folge stop/uninstall/install/start/start).
#        d) Abbruch vor jeder Dienstoperation (fehlerhafte Vorlage): keine
#           bestehende Datei angeruehrt, Dienst nicht einmal gestoppt.
#        e) Stop-Fehler (stop=5): Abbruch vor der Ersetzungsphase, nichts
#           angeruehrt.
#        f) Fresh-Install mit Dienststart-Fehler (start=4:1): Rollback
#           entfernt die Registrierung dieses Laufs VOR dem Datei-Abbau
#           (Stub-Folge install/start/uninstall, kein stop).
#        g) install-Fehler nach dem uninstall (install=3:1): Rollback
#           registriert den vorherigen Dienst neu und startet ihn
#           (Stub-Folge stop/uninstall/install/install/start).
#
# Voraussetzung: pwsh (PowerShell 7) auf dem Host. Fehlt es, bricht der Test
# mit genauer Installationsanleitung ab - kein stiller Skip (etabliertes Muster
# der Skriptpruefungen). Die Runner-Installation gehoert in den scripts-Job von
# .forgejo/workflows/checks.yml; das gepruefte Rezept steht in
# docs/windows-installer.md.
#
# Der Harness schreibt ausschliesslich in dieses Testverzeichnis; es werden
# keine Dienste installiert/veraendert und keine produktiven Daten angefasst.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HARNESS="$PROJECT_ROOT/scripts/tests/winsw-simulate-steps.ps1"
FIXTURE_ROOT="$PROJECT_ROOT/.winsw-foundation-test.$$"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -f "$HARNESS" ]] || fail "Harness fehlt: $HARNESS"
[[ ! -e "$FIXTURE_ROOT" ]] || fail "Testverzeichnis existiert bereits: $FIXTURE_ROOT"

# --- pwsh anfordern: laute, dokumentierte Meldung (kein stiller Skip) --------
# Vor jeder Aenderung am Arbeitsverzeichnis, damit fehlendes pwsh immer zuerst
# mit der Anleitung gemeldet wird.
if ! command -v pwsh >/dev/null 2>&1; then
  cat >&2 <<'EOF'
FAIL: pwsh (PowerShell 7) ist nicht verfuegbar - der Test zum
Windows-Installer-Fundament (#564) und zum WinSW-Exitcode-Vertrag (#198) kann
nicht laufen. Fehlende Werkzeuge werden bewusst sichtbar gemeldet statt still
uebersprungen.

Debian 12 (amd64/arm64, wie der Forgejo-Runner-Container):
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends curl gnupg apt-transport-https ca-certificates
  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor -o /usr/share/keyrings/microsoft.gpg
  echo "deb [signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/debian/12/prod bookworm main" \
    > /etc/apt/sources.list.d/microsoft.list
  apt-get update && apt-get install -y --no-install-recommends powershell

Die Installation ist im scripts-Job von checks.yml eingerichtet (harter
Bestandteil, keine || true-Abschwaechung); diese Anleitung gilt fuer lokale
Container und Umgebungen ohne diesen Workflow-Schritt. Alternativverfahren
mit veroeffentlichter Pruefsumme: docs/windows-installer.md.
EOF
  exit 1
fi

pwsh_version="$(pwsh --version)" || fail "'pwsh --version' schlug fehl."
printf 'pwsh %s\n' "$pwsh_version"

cleanup() {
  if [[ "$FIXTURE_ROOT" == "$PROJECT_ROOT"/.winsw-foundation-test.* &&
    -d "$FIXTURE_ROOT" && ! -L "$FIXTURE_ROOT" ]]; then
    rm -rf -- "$FIXTURE_ROOT"
  fi
}
trap cleanup EXIT

mkdir -p "$FIXTURE_ROOT/happy" "$FIXTURE_ROOT/fail-install" "$FIXTURE_ROOT/fail-stop" \
  "$FIXTURE_ROOT/fail-uninstall"

run_harness() {
  local fixture="$1" codes="$2" status=0
  local args=(pwsh -NoProfile -NonInteractive -File "$HARNESS" -RepoRoot "$PROJECT_ROOT" -FixtureDir "$fixture")
  if [[ -n "$codes" ]]; then
    args+=(-ExitCodes "$codes")
  fi
  "${args[@]}" || status=$?
  return "$status"
}

# --- Szenario 1: Erfolgslauf (alle Stub-Exitcodes 0) --------------------------
status=0
run_harness "$FIXTURE_ROOT/happy" "" >"$FIXTURE_ROOT/happy.out" 2>&1 || status=$?
if [[ "$status" -ne 0 ]]; then
  cat "$FIXTURE_ROOT/happy.out" >&2
  fail "Simulierter Erfolgslauf schlug fehl (Exit $status)."
fi
grep -q '\[winsw-sim\] PASS:' "$FIXTURE_ROOT/happy.out" ||
  fail "Erfolgslauf lieferte keine PASS-Zeile."
grep -Fq 'install.ps1: stop, uninstall, install, start' "$FIXTURE_ROOT/happy.out" ||
  fail "Erfolgslauf belegte den install.ps1-Hauptlauf-Vertrag (stop/uninstall/install/start) nicht."
grep -Fq 'rollback Invoke-UpgradeRollback: uninstall, install, start' "$FIXTURE_ROOT/happy.out" ||
  fail "Erfolgslauf belegte den #200-Rollback-Vertrag (Invoke-UpgradeRollback: uninstall/install/start) nicht."
grep -Fq 'uninstall.ps1: stop, uninstall' "$FIXTURE_ROOT/happy.out" ||
  fail "Erfolgslauf belegte den uninstall.ps1-Aufrufvertrag (stop/uninstall) nicht."
grep -Fq 'Invoke-ServiceStep' "$FIXTURE_ROOT/happy.out" ||
  fail "Erfolgslauf belegte die #198-Wrapper-Funktion (Invoke-ServiceStep) nicht."

# Der Stub muss die Kette in der Reihenfolge der realen Aufrufstellen gelaufen
# sein (install.ps1-Hauptlauf: stop, uninstall, install, start; dann die
# #200-Rollback-Kette uninstall, install, start; uninstall.ps1: stop, uninstall).
printf 'stop\nuninstall\ninstall\nstart\nuninstall\ninstall\nstart\nstop\nuninstall\n' >"$FIXTURE_ROOT/expected-calls.log"
cmp -s "$FIXTURE_ROOT/expected-calls.log" "$FIXTURE_ROOT/happy/winsw-calls.log" ||
  fail "Stub-Aufrufprotokoll weicht von der simulierten Kette ab (siehe $FIXTURE_ROOT/happy/winsw-calls.log)."

# --- Szenario 2: install-Schritt meldet Exitcode 3 -> kontrollierter Abbruch --
printf 'install=3\n' >"$FIXTURE_ROOT/fail-install/codes.conf"
status=0
run_harness "$FIXTURE_ROOT/fail-install" "$FIXTURE_ROOT/fail-install/codes.conf" \
  >"$FIXTURE_ROOT/fail-install.out" 2>&1 || status=$?
if [[ "$status" -eq 0 ]]; then
  cat "$FIXTURE_ROOT/fail-install.out" >&2
  fail "Der simulierten 'install'-Schritt (Exitcode 3) fuehrte nicht zu einem Abbruch."
fi
grep -Fq "install.ps1 aborted at step 'install'" "$FIXTURE_ROOT/fail-install.out" ||
  fail "install.ps1 brach beim fehlgeschlagenen 'install'-Schritt nicht kontrolliert ab."
grep -Fq "step 'install'" "$FIXTURE_ROOT/fail-install.out" ||
  fail "Fehlermeldung nannte den Schritt nicht."
grep -Fq "exit code 3" "$FIXTURE_ROOT/fail-install.out" ||
  fail "Fehlermeldung nannte den Exitcode nicht."
grep -Fq "wrapper log" "$FIXTURE_ROOT/fail-install.out" ||
  fail "Fehlermeldung nannte die Wrapper-Log-Adresse nicht."
grep -Fq "rerun" "$FIXTURE_ROOT/fail-install.out" ||
  fail "Fehlermeldung nannte keine naechste Aktion (erneuter Lauf)."
if grep -q 'CONTRACT VIOLATION' "$FIXTURE_ROOT/fail-install.out"; then
  cat "$FIXTURE_ROOT/fail-install.out" >&2
  fail "Der Abbruch bei 'install'=3 war nicht kontrolliert (CONTRACT VIOLATION)."
fi
# AK1: keine still weiterlaufende Installation - nach dem fehlgeschlagenen
# install darf weder start noch ein weiterer Schritt laufen.
if grep -q '^start$' "$FIXTURE_ROOT/fail-install/winsw-calls.log"; then
  fail "Nach dem fehlgeschlagenen 'install'-Schritt lief die Simulation still weiter (start wurde aufgerufen)."
fi
printf 'stop\nuninstall\ninstall\nstop\nuninstall\n' >"$FIXTURE_ROOT/expected-fail-install.log"
cmp -s "$FIXTURE_ROOT/expected-fail-install.log" "$FIXTURE_ROOT/fail-install/winsw-calls.log" ||
  fail "Stub-Aufrufprotokoll des install-Fehlerszenarios weicht ab (Abbruchpunkt falsch)."

# --- Szenario 3: stop-Schritt (2>$null | Out-Null-Variante) meldet Exitcode 5 -
# Keine Toleranz: WinSW v2.12.0 normalisiert "already stopped" selbst auf 0,
# also ist jeder Nicht-Null-Code von stop ein echter Fehler in beiden Skripten.
printf 'stop=5\n' >"$FIXTURE_ROOT/fail-stop/codes.conf"
status=0
run_harness "$FIXTURE_ROOT/fail-stop" "$FIXTURE_ROOT/fail-stop/codes.conf" \
  >"$FIXTURE_ROOT/fail-stop.out" 2>&1 || status=$?
if [[ "$status" -eq 0 ]]; then
  cat "$FIXTURE_ROOT/fail-stop.out" >&2
  fail "Fehlgeschlagener simulierter 'stop'-Schritt fuehrte nicht zu einem Abbruch."
fi
grep -Fq "install.ps1 aborted at step 'stop'" "$FIXTURE_ROOT/fail-stop.out" ||
  fail "install.ps1 brach beim fehlgeschlagenen 'stop'-Schritt nicht kontrolliert ab."
grep -Fq "uninstall.ps1 aborted at step 'stop'" "$FIXTURE_ROOT/fail-stop.out" ||
  fail "uninstall.ps1 brach beim fehlgeschlagenen 'stop'-Schritt nicht kontrolliert ab."
grep -Fq "exit code 5" "$FIXTURE_ROOT/fail-stop.out" ||
  fail "Exitcode des 'stop'-Schritts (2>\$null | Out-Null-Variante) wurde verschluckt."
if grep -q 'CONTRACT VIOLATION' "$FIXTURE_ROOT/fail-stop.out"; then
  cat "$FIXTURE_ROOT/fail-stop.out" >&2
  fail "Der Abbruch bei 'stop'=5 war nicht kontrolliert (CONTRACT VIOLATION)."
fi
printf 'stop\nstop\n' >"$FIXTURE_ROOT/expected-fail-stop.log"
cmp -s "$FIXTURE_ROOT/expected-fail-stop.log" "$FIXTURE_ROOT/fail-stop/winsw-calls.log" ||
  fail "Stub-Aufrufprotokoll des stop-Fehlerszenarios weicht ab (Abbruchpunkt falsch)."

# --- Szenario 4: uninstall-Schritt meldet Exitcode 7 -> kontrollierter Abbruch
# Deckt den Fehlerpfad in uninstall.ps1 ab (eigenes Die, eigene Log-Adresse).
printf 'uninstall=7\n' >"$FIXTURE_ROOT/fail-uninstall/codes.conf"
status=0
run_harness "$FIXTURE_ROOT/fail-uninstall" "$FIXTURE_ROOT/fail-uninstall/codes.conf" \
  >"$FIXTURE_ROOT/fail-uninstall.out" 2>&1 || status=$?
if [[ "$status" -eq 0 ]]; then
  cat "$FIXTURE_ROOT/fail-uninstall.out" >&2
  fail "Fehlgeschlagener simulierter 'uninstall'-Schritt fuehrte nicht zu einem Abbruch."
fi
grep -Fq "install.ps1 aborted at step 'uninstall'" "$FIXTURE_ROOT/fail-uninstall.out" ||
  fail "install.ps1 brach beim fehlgeschlagenen 'uninstall'-Schritt nicht kontrolliert ab."
grep -Fq "uninstall.ps1 aborted at step 'uninstall'" "$FIXTURE_ROOT/fail-uninstall.out" ||
  fail "uninstall.ps1 brach beim fehlgeschlagenen 'uninstall'-Schritt nicht kontrolliert ab."
grep -Fq "exit code 7" "$FIXTURE_ROOT/fail-uninstall.out" ||
  fail "Fehlermeldung nannte den Exitcode 7 des 'uninstall'-Schritts nicht."
if grep -q 'CONTRACT VIOLATION' "$FIXTURE_ROOT/fail-uninstall.out"; then
  cat "$FIXTURE_ROOT/fail-uninstall.out" >&2
  fail "Der Abbruch bei 'uninstall'=7 war nicht kontrolliert (CONTRACT VIOLATION)."
fi
printf 'stop\nuninstall\nstop\nuninstall\n' >"$FIXTURE_ROOT/expected-fail-uninstall.log"
cmp -s "$FIXTURE_ROOT/expected-fail-uninstall.log" "$FIXTURE_ROOT/fail-uninstall/winsw-calls.log" ||
  fail "Stub-Aufrufprotokoll des uninstall-Fehlerszenarios weicht ab (Abbruchpunkt falsch)."

# --- #200-Flow-Simulation: gemeinsamer Fixture-Bau ----------------------------
# Die Fixture stellt das Windows-Pfadlayout als Linux-Verzeichnisbaum nach:
# ProgramFiles/ProgramData/TEMP werden per Umgebung auf die Fixture umgeleitet,
# ein Stub-java.exe liegt in $fx/run/bin (der Harness stellt dieses Verzeichnis
# vor PATH). Die Dienstvorlage liegt unter simbundle/packaging/windows -
# Join-Path normalisiert auf Linux die Backslash-Literale des Installers
# ('packaging\windows') zu diesem Verzeichnis.
build_flow_fixture() {
  local fx="$1" mode="${2:-upgrade}"
  mkdir -p "$fx/run/bin" "$fx/Temp" \
    "$fx/simbundle/backend" "$fx/simbundle/frontend/assets" \
    "$fx/simbundle/packaging/windows"
  if [[ "$mode" == "fresh" ]]; then
    # Erste Installation: im AppDir darf wirklich nichts vor dem Lauf
    # existieren (auch keine leeren Verzeichnisse); die Stub-Kopie des
    # Harness landet in einem Ablageverzeichnis.
    mkdir -p "$fx/run/winsw-stub-copy"
  else
    mkdir -p \
      "$fx/ProgramFiles/Moddex/ui/assets" "$fx/ProgramFiles/Moddex/frontend" \
      "$fx/ProgramData/Moddex/data/instance1/world" \
      "$fx/ProgramData/Moddex/config" "$fx/ProgramData/Moddex/logs"
  fi

  cat > "$fx/run/bin/java.exe" <<'EOF'
#!/bin/sh
printf 'openjdk version "17.0.9" 2023-10-17\n'
exit 0
EOF
  chmod +x "$fx/run/bin/java.exe"

  printf 'NEW-JAR-v2\n' >"$fx/simbundle/backend/Moddex-Backend.jar"
  printf '<html>NEW-UI-v2</html>\n' >"$fx/simbundle/frontend/index.html"
  printf '/* new */\n' >"$fx/simbundle/frontend/assets/app.css"
  printf '2.0.0-sim\n' >"$fx/simbundle/VERSION"
  cp "$PROJECT_ROOT/packaging/windows/moddex-backend.xml.template" \
    "$fx/simbundle/packaging/windows/moddex-backend.xml.template"

  # Vorherige (simulierte) Installation: alte Anwendung, gerenderte
  # Dienstdefinition mit vom Betreiber ergaenztem <env>-Eintrag, Legacy-UI.
  # Im fresh-Modus entfaellt sie (Szenario f: erste Installation ohne
  # Bestand), daher auch kein Baseline-Schnappschuss.
  if [[ "$mode" == "fresh" ]]; then
    return 0
  fi
  printf 'OLD-JAR-v1\n' >"$fx/ProgramFiles/Moddex/app.jar"
  printf '<html>OLD-UI-v1</html>\n' >"$fx/ProgramFiles/Moddex/ui/index.html"
  printf '/* old */\n' >"$fx/ProgramFiles/Moddex/ui/assets/app.css"
  printf '1.0.0\n' >"$fx/ProgramFiles/Moddex/VERSION"
  printf '<html>LEGACY</html>\n' >"$fx/ProgramFiles/Moddex/frontend/index.html"
  printf 'operator-world-sentinel\n' >"$fx/ProgramData/Moddex/data/instance1/world/level.dat"
  printf '# operator config sentinel\nMODDEX_CORS_ALLOWED_ORIGINS=https://ops.example\n' \
    >"$fx/ProgramData/Moddex/config/moddex.env"
  cat > "$fx/ProgramFiles/Moddex/moddex-backend.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<service>
  <id>moddex-backend</id>
  <name>Moddex Backend</name>
  <description>previous simulated install</description>
  <executable>$fx/run/bin/java.exe</executable>
  <arguments>-jar "$fx/ProgramFiles/Moddex/app.jar"</arguments>
  <env name="MODDEX_ROOT" value="$fx/ProgramData/Moddex/data" />
  <env name="MODDEX_CONFIG_DIR" value="$fx/ProgramData/Moddex/config" />
  <env name="MODDEX_LOG_DIR" value="$fx/ProgramData/Moddex/logs" />
  <env name="MODDEX_UI_DIR" value="$fx/ProgramFiles/Moddex/ui" />
  <env name="MODDEX_MODE" value="lan" />
  <env name="MODDEX_SECURITY_MODE" value="lan" />
  <env name="SERVER_ADDRESS" value="0.0.0.0" />
  <env name="SERVER_PORT" value="8081" />
  <env name="MODDEX_CORS_ALLOWED_ORIGINS" value="https://ops.example" />
  <log mode="roll-by-size">
    <logpath>$fx/ProgramData/Moddex/logs</logpath>
    <sizeThreshold>10240</sizeThreshold>
    <keepFiles>8</keepFiles>
  </log>
  <startmode>Automatic</startmode>
</service>
EOF

  snapshot_flow_baseline "$fx"
}

snapshot_flow_baseline() {
  local fx="$1"
  mkdir -p "$fx/baseline"
  cp -a "$fx/ProgramFiles/Moddex/ui" "$fx/baseline/ui"
  cp -a "$fx/ProgramFiles/Moddex/frontend" "$fx/baseline/frontend"
  cp -a "$fx/ProgramFiles/Moddex/app.jar" "$fx/baseline/app.jar"
  cp -a "$fx/ProgramFiles/Moddex/VERSION" "$fx/baseline/VERSION"
  cp -a "$fx/ProgramFiles/Moddex/moddex-backend.xml" "$fx/baseline/moddex-backend.xml"
  cp -a "$fx/ProgramData/Moddex/config" "$fx/baseline/config"
  cp -a "$fx/ProgramData/Moddex/data" "$fx/baseline/data"
}

# AK1: der komplette vorherige Anwendungszustand (JAR, UI, VERSION,
# Dienstdefinition mit Betreiber-<env>, Wrapper-Executable, Legacy-Verzeichnis)
# sowie die Betreiberkonfiguration (config/) und die Instanzdaten (data/)
# sind byte-identisch wiederhergestellt bzw. unangetastet.
assert_previous_intact() {
  local fx="$1"
  cmp -s "$fx/baseline/app.jar" "$fx/ProgramFiles/Moddex/app.jar" ||
    fail "Rollback: app.jar wurde nicht auf den vorherigen Stand restauriert."
  cmp -s "$fx/baseline/VERSION" "$fx/ProgramFiles/Moddex/VERSION" ||
    fail "Rollback: VERSION wurde nicht restauriert."
  cmp -s "$fx/baseline/moddex-backend.xml" "$fx/ProgramFiles/Moddex/moddex-backend.xml" ||
    fail "Rollback: Dienstdefinition wurde nicht restauriert (Betreiber-<env> fehlt?)."
  diff -r "$fx/baseline/ui" "$fx/ProgramFiles/Moddex/ui" >/dev/null ||
    fail "Rollback: UI-Dateien wurden nicht restauriert."
  diff -r "$fx/baseline/frontend" "$fx/ProgramFiles/Moddex/frontend" >/dev/null ||
    fail "Rollback: Legacy-UI-Verzeichnis wurde nicht restauriert."
  cmp -s "$fx/run/winsw-stub/moddex-backend.exe" "$fx/ProgramFiles/Moddex/moddex-backend.exe" ||
    fail "Rollback: Wrapper-Executable wurde nicht restauriert."
  diff -r "$fx/baseline/config" "$fx/ProgramData/Moddex/config" >/dev/null ||
    fail "Betreiberkonfiguration (config/) wurde veraendert."
  diff -r "$fx/baseline/data" "$fx/ProgramData/Moddex/data" >/dev/null ||
    fail "Instanzdaten (data/) wurden veraendert."
}

assert_no_upgrade_dir() {
  local fx="$1"
  if compgen -G "$fx/ProgramFiles/Moddex/.upgrade-*" >/dev/null; then
    fail "Das Upgrade-Arbeitsverzeichnis wurde nicht geräumt: $fx/ProgramFiles/Moddex/.upgrade-*"
  fi
}

# Zeilennummern-Ordnung im vereinheitlichten Journal (Dateioperationen +
# Stub-Dienstkette in echter Chronologie).
journal_line() {
  grep -n "$1" "$2" | head -n1 | cut -d: -f1
}

run_flow() {
  local fx="$1" codes="$2" failspec="$3" out="$4" service="${5:-1}" mode="${6:-upgrade}" status=0
  local stubdest="$fx/ProgramFiles/Moddex/moddex-backend.exe"
  if [[ "$mode" == "fresh" ]]; then
    # Fresh-Install: es darf nichts im AppDir vor dem Lauf existieren, daher
    # landet die Stub-Kopie des Harness in einem Ablageverzeichnis.
    stubdest="$fx/run/winsw-stub-copy/moddex-backend.exe"
  fi
  local args=(pwsh -NoProfile -NonInteractive -File "$HARNESS" -RepoRoot "$PROJECT_ROOT" \
    -FixtureDir "$fx/run" -FlowSimBundle "$fx/simbundle" -FlowStubDest "$stubdest")
  if [[ -n "$codes" ]]; then
    args+=(-ExitCodes "$codes")
  fi
  if [[ "$mode" == "fresh" ]]; then
    # Ohne bestehende Installation kann der Lauf keinen Modus erben - der
    # erste Installationslauf braucht -Mode explizit.
    args+=(-FlowInstallMode "lan")
  fi
  MODDEX_SIM_SERVICE_EXISTS="$service" MODDEX_SIM_FAILSPEC="$failspec" \
    PATH="$fx/run/bin:$PATH" \
    ProgramFiles="$fx/ProgramFiles" ProgramData="$fx/ProgramData" TEMP="$fx/Temp" \
    "${args[@]}" >"$out" 2>&1 || status=$?
  return "$status"
}

assert_flow_abort_reported() {
  local out="$1"
  grep -Fq '[winsw-flow] CONTROLLED EXIT' "$out" ||
    fail "Der fehlgeschlagene Flow-Lauf wurde nicht als kontrollierter Abbruch gemeldet (siehe $out)."
  if grep -q '\[winsw-sim\] FAIL:' "$out"; then
    cat "$out" >&2
    fail "Der Harness meldete einen internen Fehler statt eines kontrollierten Abbruchs."
  fi
  if grep -q 'CONTRACT VIOLATION' "$out"; then
    cat "$out" >&2
    fail "Der Flow-Lauf endete mit einer Vertragsverletzung."
  fi
}

# --- Flow-Szenario a: Erfolg -> kompletter Upgrade-Ablauf ----------------------
fx="$FIXTURE_ROOT/flow-success"
build_flow_fixture "$fx"
status=0
run_flow "$fx" "" "" "$fx/out.log" || status=$?
if [[ "$status" -ne 0 ]]; then
  cat "$fx/out.log" >&2
  fail "Flow-Szenario a (Erfolg) schlug fehl (Exit $status)."
fi
grep -q '\[winsw-sim\] PASS: the simulated #200 upgrade run completed' "$fx/out.log" ||
  fail "Flow-Szenario a lieferte keine PASS-Zeile."
grep -q "Moddex installed. Service 'moddex-backend' is running on 0.0.0.0:8081." "$fx/out.log" ||
  fail "Flow-Szenario a meldete keinen laufenden Dienst mit geerbtem Modus/Port (lan/8081)."
grep -q 'Preserving operator-added env entry: MODDEX_CORS_ALLOWED_ORIGINS' "$fx/out.log" ||
  fail "Flow-Szenario a bewahrte den Betreiber-<env>-Eintrag nicht."

# Neue Artefakte sind eingesetzt, Betreiberkonfiguration und Instanzdaten
# unangetastet (AK1, zweiter Halbsatz).
grep -q 'NEW-JAR-v2' "$fx/ProgramFiles/Moddex/app.jar" ||
  fail "Flow-Szenario a: app.jar wurde nicht ersetzt."
grep -q 'NEW-UI-v2' "$fx/ProgramFiles/Moddex/ui/index.html" ||
  fail "Flow-Szenario a: UI wurde nicht ersetzt."
cmp -s "$fx/simbundle/VERSION" "$fx/ProgramFiles/Moddex/VERSION" ||
  fail "Flow-Szenario a: VERSION stimmt nicht mit dem Bundle ueberein."
cmp -s "$fx/run/winsw-stub/moddex-backend.exe" "$fx/ProgramFiles/Moddex/moddex-backend.exe" ||
  fail "Flow-Szenario a: Wrapper-Executable wurde nicht aus dem Staging eingesetzt."
grep -q 'MODDEX_CORS_ALLOWED_ORIGINS' "$fx/ProgramFiles/Moddex/moddex-backend.xml" ||
  fail "Flow-Szenario a: gerenderte Dienstdefinition enthaelt den Betreiber-<env>-Eintrag nicht."
grep -q 'value="lan"' "$fx/ProgramFiles/Moddex/moddex-backend.xml" &&
  grep -q 'value="8081"' "$fx/ProgramFiles/Moddex/moddex-backend.xml" ||
  fail "Flow-Szenario a: Modus/Port wurden nicht aus der bestehenden Installation geerbt."
diff -r "$fx/baseline/config" "$fx/ProgramData/Moddex/config" >/dev/null ||
  fail "Flow-Szenario a: Betreiberkonfiguration wurde veraendert."
diff -r "$fx/baseline/data" "$fx/ProgramData/Moddex/data" >/dev/null ||
  fail "Flow-Szenario a: Instanzdaten wurden veraendert."
[[ ! -e "$fx/ProgramFiles/Moddex/frontend" ]] ||
  fail "Flow-Szenario a: veraltetes Legacy-UI-Verzeichnis wurde nicht entfernt."
assert_no_upgrade_dir "$fx"

# Reihenfolge im Journal: Staging-Kopien vor dem Dienst-Stop, Rename-Aside
# vor dem Rename-In, Dienstkette nach dem Einsatz, Raeumung nach dem Start.
j="$fx/run/flow-journal.log"
copy1="$(journal_line 'simop copy#1 ' "$j")"
stop1="$(journal_line '^stop$' "$j")"
move1="$(journal_line 'simop move#1 ' "$j")"
lastmove="$(grep -n 'simop move' "$j" | tail -n1 | cut -d: -f1)"
start1="$(journal_line '^start$' "$j")"
remove1="$(journal_line 'simop remove#1 ' "$j")"
[[ -n "$copy1" && -n "$stop1" && -n "$move1" && -n "$lastmove" && -n "$start1" && -n "$remove1" ]] ||
  fail "Flow-Szenario a: Journal unvollstaendig (siehe $j)."
[[ "$copy1" -lt "$stop1" ]] ||
  fail "Flow-Szenario a: Staging lief NACH dem Dienst-Stop (#200-Vertrag: Staging zuerst)."
[[ "$move1" -gt "$stop1" ]] ||
  fail "Flow-Szenario a: Ersetzungsphase begann vor dem Dienst-Stop."
[[ "$start1" -gt "$lastmove" ]] ||
  fail "Flow-Szenario a: Dienstschriftketten liefen vor der vollstaendigen Ersetzung."
[[ "$remove1" -gt "$start1" ]] ||
  fail "Flow-Szenario a: Arbeitsverzeichnis wurde vor dem Dienststart geräumt."
if grep -q 'simop-fail' "$j"; then
  fail "Flow-Szenario a: Journal enthaelt eine simulierten Fehler (sollte nicht)."
fi
grep -x -e 'stop' -e 'uninstall' -e 'install' -e 'start' "$j" >"$fx/stubseq.log"
printf 'stop\nuninstall\ninstall\nstart\n' | cmp -s - "$fx/stubseq.log" ||
  fail "Flow-Szenario a: Dienstkette im Journal weicht ab (stop/uninstall/install/start erwartet)."
printf 'Flow-Szenario a (Erfolg: Staging vor Stop, Ersetzung, Konfig unangetastet) geprueft.\n'

# --- Flow-Szenario b: Fehler in der Ersetzungsphase -> Rollback ----------------
# move:4 = der vierte Verschiebeaufruf = Einsatz der gestageten UI. Die
# Ersetzungsphase verschiebt je Verwaltungsdatei zuerst das Bestehende beiseite
# und dann die Staging-Kopie an Ort und Stelle (app.jar: #1/#2, ui: #3/#4) -
# genau die Stelle, an der die alte Logik die UI geloescht haette und der
# Kopierfehler die Installation zerstoert haette.
fx="$FIXTURE_ROOT/flow-copyfail"
build_flow_fixture "$fx"
status=0
run_flow "$fx" "" "move:4" "$fx/out.log" || status=$?
if [[ "$status" -eq 0 ]]; then
  cat "$fx/out.log" >&2
  fail "Flow-Szenario b (Ersetzungsfehler) endete erfolgreich - kein Rollback ausgeloest."
fi
assert_flow_abort_reported "$fx/out.log"
grep -q 'The upgrade failed while installing the new application files' "$fx/out.log" ||
  fail "Flow-Szenario b: Meldung nennt die fehlgeschlagene Phase nicht."
grep -q "Simulated move failure (fail-once spec 'move:4')" "$fx/out.log" ||
  fail "Flow-Szenario b: Meldung nennt die Ursache nicht."
grep -q 'Rolling back to the previous application files' "$fx/out.log" ||
  fail "Flow-Szenario b: Rollback wurde nicht ausgefuehrt."
grep -q 'were re-established' "$fx/out.log" ||
  fail "Flow-Szenario b: Meldung nennt den wiederhergestellten Zustand nicht."
grep -q 'rerun' "$fx/out.log" ||
  fail "Flow-Szenario b: Meldung nennt keine naechste Aktion (erneuter Lauf)."
# AK1: die komplette vorherige Anwendung ist restauriert, Konfig unangetastet.
assert_previous_intact "$fx"
assert_no_upgrade_dir "$fx"
j="$fx/run/flow-journal.log"
grep -q 'simop-fail move#4' "$j" ||
  fail "Flow-Szenario b: Journal belegt den Fehler bei der UI-Einspielung nicht."
if grep -qx 'uninstall' "$j"; then
  fail "Flow-Szenario b: Nach dem Ersetzungsfehler lief die Dienstkette still weiter (uninstall aufgerufen)."
fi
stop1="$(journal_line '^stop$' "$j")"
start1="$(journal_line '^start$' "$j")"
lastmove="$(grep -n 'simop move' "$j" | tail -n1 | cut -d: -f1)"
[[ -n "$stop1" && -n "$start1" && -n "$lastmove" ]] ||
  fail "Flow-Szenario b: Journal unvollstaendig (siehe $j)."
[[ "$stop1" -lt "$lastmove" && "$start1" -gt "$lastmove" ]] ||
  fail "Flow-Szenario b: Rollback-Reihenfolge falsch (Ersetzen nach Stop, vorheriger Dienst erst nach Restauration gestartet)."
grep -x -e 'stop' -e 'uninstall' -e 'install' -e 'start' "$j" >"$fx/stubseq.log"
printf 'stop\nstart\n' | cmp -s - "$fx/stubseq.log" ||
  fail "Flow-Szenario b: Nach dem Rollback wurde der vorherige Dienst nicht (nur) gestartet."
printf 'Flow-Szenario b (Kopierfehler in der Ersetzungsphase -> Rollback bewiesen) geprueft.\n'

# --- Flow-Szenario c: Dienststart-Fehler NACH erfolgreichem install ------------
# start=4:1 failt den ersten start (neue Version); der zweite start (Rollback)
# gelingt. install=1073:>1 modelliert das nicht normalisierte WinSW-Verhalten
# (install auf bereits registrierter ID -> ERROR_SERVICE_EXISTS) und ist die
# Falle fuer die Review-Korrektur: der Rollback darf die von diesem Lauf
# erzeugte Registrierung NICHT erneut installieren (das wuerde mit 1073
# brechen und den vorherigen Dienst gestoppt lassen), sondern startet sie
# nach der Datei-Restauration direkt (Stub-Folge stop/uninstall/install/
# start/start, genau ein install).
fx="$FIXTURE_ROOT/flow-startfail"
build_flow_fixture "$fx"
printf 'start=4:1\ninstall=1073:>1\n' >"$fx/codes.conf"
status=0
run_flow "$fx" "$fx/codes.conf" "" "$fx/out.log" || status=$?
if [[ "$status" -eq 0 ]]; then
  cat "$fx/out.log" >&2
  fail "Flow-Szenario c (Dienststart-Fehler) endete erfolgreich - kein Rollback ausgeloest."
fi
assert_flow_abort_reported "$fx/out.log"
grep -q 'The upgrade failed while bringing the service up' "$fx/out.log" ||
  fail "Flow-Szenario c: Meldung nennt die fehlgeschlagene Phase nicht."
grep -q "'start' step failed with exit code 4" "$fx/out.log" ||
  fail "Flow-Szenario c: Meldung nennt Schritt und Exitcode des Startfehlers nicht."
grep -q 'Starting the previous service' "$fx/out.log" ||
  fail "Flow-Szenario c: vorheriger Dienst wurde nicht gestartet."
if grep -q 'Re-registering the previous service' "$fx/out.log"; then
  fail "Flow-Szenario c: Rollback hat die Registrierung dieses Laufs erneut installiert (1073-Falle) statt sie zu starten."
fi
grep -q 'were re-established' "$fx/out.log" ||
  fail "Flow-Szenario c: Meldung nennt den wiederhergestellten Zustand nicht."
grep -q 'rerun' "$fx/out.log" ||
  fail "Flow-Szenario c: Meldung nennt keine naechste Aktion."
assert_previous_intact "$fx"
assert_no_upgrade_dir "$fx"
j="$fx/run/flow-journal.log"
grep -x -e 'stop' -e 'uninstall' -e 'install' -e 'start' "$j" >"$fx/stubseq.log"
printf 'stop\nuninstall\ninstall\nstart\nstart\n' | cmp -s - "$fx/stubseq.log" ||
  fail "Flow-Szenario c: Dienstkette weicht ab (Hauptlauf bis start-Fehler, dann Rollback-start ohne Duplicate-install erwartet)."
if [[ "$(grep -cx 'install' "$j")" -ne 1 ]]; then
  fail "Flow-Szenario c: genau ein install erwartet (keine Neuregistrierung einer bestehenden Registrierung)."
fi
startfirst="$(grep -nx 'start' "$j" | head -n1 | cut -d: -f1)"
startlast="$(grep -nx 'start' "$j" | tail -n1 | cut -d: -f1)"
lastmove="$(grep -n 'simop move' "$j" | tail -n1 | cut -d: -f1)"
[[ -n "$startfirst" && -n "$startlast" && -n "$lastmove" ]] ||
  fail "Flow-Szenario c: Journal unvollstaendig (siehe $j)."
[[ "$startfirst" -lt "$lastmove" && "$startlast" -gt "$lastmove" ]] ||
  fail "Flow-Szenario c: Rollback-Reihenfolge falsch (Restauration zwischen fehlgeschlagenem Start und Rollback-Start)."
printf 'Flow-Szenario c (Dienststart-Fehler -> Rollback startet die Registrierung dieses Laufs ohne Duplicate-install) geprueft.\n'

# --- Flow-Szenario d: Abbruch vor jeder Dienstoperation -----------------------
# Fehlerhafte Vorlage (@@BOGUS@@-Platzhalter) bricht im Staging ab, bevor der
# Dienst gestoppt oder eine bestehende Datei angeruehrt wird.
fx="$FIXTURE_ROOT/flow-stagingfail"
build_flow_fixture "$fx"
tmpl="$fx/simbundle/packaging/windows/moddex-backend.xml.template"
{ grep -v '^</service>' "$tmpl"; printf '  <env name="@@BOGUS@@" value="sim" />\n</service>\n'; } >"$tmpl.sim"
mv "$tmpl.sim" "$tmpl"
status=0
run_flow "$fx" "" "" "$fx/out.log" || status=$?
if [[ "$status" -eq 0 ]]; then
  cat "$fx/out.log" >&2
  fail "Flow-Szenario d (fehlerhafte Vorlage) endete erfolgreich."
fi
assert_flow_abort_reported "$fx/out.log"
grep -q 'Staging the new application files failed' "$fx/out.log" ||
  fail "Flow-Szenario d: Meldung nennt die Staging-Phase nicht."
grep -q 'Nothing was changed: the installed application files were not touched and the service was not stopped.' "$fx/out.log" ||
  fail "Flow-Szenario d: Meldung bestätigt nicht, dass nichts veraendert wurde."
grep -q '@@BOGUS@@' "$fx/out.log" ||
  fail "Flow-Szenario d: Meldung nennt die Ursache (Platzhalter) nicht."
grep -q 'rerun' "$fx/out.log" ||
  fail "Flow-Szenario d: Meldung nennt keine naechste Aktion."
assert_previous_intact "$fx"
assert_no_upgrade_dir "$fx"
j="$fx/run/flow-journal.log"
if grep -qE '^(stop|uninstall|install|start)$' "$j"; then
  fail "Flow-Szenario d: Der Dienst wurde trotz Staging-Abbruch angesprochen."
fi
if grep -q 'simop move' "$j"; then
  fail "Flow-Szenario d: Es wurden bestehende Dateien verschoben, obwohl das Staging fehlschlug."
fi
if grep -q 'simop-fail' "$j"; then
  fail "Flow-Szenario d: unerwarteter fail-once-Eintrag im Journal."
fi
printf 'Flow-Szenario d (Abbruch vor jeder Dienstoperation -> keine bestehende Datei angeruehrt) geprueft.\n'

# --- Flow-Szenario e: Stop-Fehler -> Abbruch vor der Ersetzungsphase ----------
fx="$FIXTURE_ROOT/flow-stopfail"
build_flow_fixture "$fx"
printf 'stop=5\n' >"$fx/codes.conf"
status=0
run_flow "$fx" "$fx/codes.conf" "" "$fx/out.log" || status=$?
if [[ "$status" -eq 0 ]]; then
  cat "$fx/out.log" >&2
  fail "Flow-Szenario e (Stop-Fehler) endete erfolgreich."
fi
assert_flow_abort_reported "$fx/out.log"
grep -q "'stop' step failed with exit code 5" "$fx/out.log" ||
  fail "Flow-Szenario e: Meldung nennt Schritt und Exitcode des Stopfehlers nicht."
grep -q 'wrapper log' "$fx/out.log" ||
  fail "Flow-Szenario e: Meldung nennt die Wrapper-Log-Adresse nicht."
grep -q 'rerun' "$fx/out.log" ||
  fail "Flow-Szenario e: Meldung nennt keine naechste Aktion."
assert_previous_intact "$fx"
assert_no_upgrade_dir "$fx"
j="$fx/run/flow-journal.log"
if grep -q 'simop move' "$j"; then
  fail "Flow-Szenario e: Nach dem fehlgeschlagenen Stop wurden bestehende Dateien verschoben."
fi
grep -x -e 'stop' -e 'uninstall' -e 'install' -e 'start' "$j" >"$fx/stubseq.log"
printf 'stop\n' | cmp -s - "$fx/stubseq.log" ||
  fail "Flow-Szenario e: Nach dem Stop-Fehler lief die Dienstkette still weiter."
printf 'Flow-Szenario e (Stop-Fehler -> Abbruch vor der Ersetzungsphase) geprueft.\n'

# --- Flow-Szenario f: Fresh-Install mit Dienststart-Fehler ---------------------
# Erste Installation (keine vorherige Anwendung, kein Dienst): install ok,
# start=4:1 failt. Der Rollback entfernt die Registrierung dieses Laufs VOR
# dem Datei-Abbau (WinSW uninstall laeuft ueber die Wrapper-Executable, die
# die Restauration entfernen wuerde) und hinterlaesst keinen Halbzustand.
fx="$FIXTURE_ROOT/flow-fresh"
build_flow_fixture "$fx" "fresh"
printf 'start=4:1\n' >"$fx/codes.conf"
status=0
run_flow "$fx" "$fx/codes.conf" "" "$fx/out.log" 0 fresh || status=$?
if [[ "$status" -eq 0 ]]; then
  cat "$fx/out.log" >&2
  fail "Flow-Szenario f (Fresh-Install-Startfehler) endete erfolgreich - kein Rollback ausgeloest."
fi
assert_flow_abort_reported "$fx/out.log"
grep -q 'The upgrade failed while bringing the service up' "$fx/out.log" ||
  fail "Flow-Szenario f: Meldung nennt die fehlgeschlagene Phase nicht."
grep -q "'start' step failed with exit code 4" "$fx/out.log" ||
  fail "Flow-Szenario f: Meldung nennt Schritt und Exitcode des Startfehlers nicht."
grep -q 'Removing the service registration created by this run' "$fx/out.log" ||
  fail "Flow-Szenario f: Registrierung dieses Laufs wurde nicht entfernt."
grep -q 'were re-established' "$fx/out.log" ||
  fail "Flow-Szenario f: Meldung nennt den wiederhergestellten Zustand nicht."
grep -q 'rerun' "$fx/out.log" ||
  fail "Flow-Szenario f: Meldung nennt keine naechste Aktion."
for leftover in app.jar ui VERSION moddex-backend.xml moddex-backend.exe frontend; do
  [[ ! -e "$fx/ProgramFiles/Moddex/$leftover" ]] ||
    fail "Flow-Szenario f: $leftover blieb als Halbzustand im AppDir zurueck."
done
assert_no_upgrade_dir "$fx"
j="$fx/run/flow-journal.log"
grep -x -e 'stop' -e 'uninstall' -e 'install' -e 'start' "$j" >"$fx/stubseq.log"
printf 'install\nstart\nuninstall\n' | cmp -s - "$fx/stubseq.log" ||
  fail "Flow-Szenario f: Dienstkette weicht ab (install/start des Fresh-Install-Laufs, dann Rollback-uninstall; kein stop erwartet)."
if grep -q 'simop-fail' "$j"; then
  fail "Flow-Szenario f: unerwarteter fail-once-Eintrag im Journal."
fi
printf 'Flow-Szenario f (Fresh-Install-Startfehler -> Registrierung vor dem Datei-Abbau entfernt, kein Halbzustand) geprueft.\n'

# --- Flow-Szenario g: install-Fehler nach dem uninstall -> Neuregistrierung ---
# install=3:1 failt das install der neuen Version (nach erfolgreichem
# uninstall der alten Registrierung). Der Rollback registriert den vorherigen
# Dienst aus der restaurierten Definition neu und startet ihn (Fallmatrix:
# RanUninstall ohne InstalledNew -> install+start).
fx="$FIXTURE_ROOT/flow-installfail"
build_flow_fixture "$fx"
printf 'install=3:1\n' >"$fx/codes.conf"
status=0
run_flow "$fx" "$fx/codes.conf" "" "$fx/out.log" || status=$?
if [[ "$status" -eq 0 ]]; then
  cat "$fx/out.log" >&2
  fail "Flow-Szenario g (install-Fehler) endete erfolgreich - kein Rollback ausgeloest."
fi
assert_flow_abort_reported "$fx/out.log"
grep -q 'The upgrade failed while bringing the service up' "$fx/out.log" ||
  fail "Flow-Szenario g: Meldung nennt die fehlgeschlagene Phase nicht."
grep -q "'install' step failed with exit code 3" "$fx/out.log" ||
  fail "Flow-Szenario g: Meldung nennt Schritt und Exitcode des install-Fehlers nicht."
grep -q 'Re-registering the previous service' "$fx/out.log" ||
  fail "Flow-Szenario g: vorheriger Dienst wurde nicht neu registriert."
grep -q 'Starting the previous service' "$fx/out.log" ||
  fail "Flow-Szenario g: vorheriger Dienst wurde nicht gestartet."
grep -q 'were re-established' "$fx/out.log" ||
  fail "Flow-Szenario g: Meldung nennt den wiederhergestellten Zustand nicht."
grep -q 'rerun' "$fx/out.log" ||
  fail "Flow-Szenario g: Meldung nennt keine naechste Aktion."
assert_previous_intact "$fx"
assert_no_upgrade_dir "$fx"
j="$fx/run/flow-journal.log"
grep -x -e 'stop' -e 'uninstall' -e 'install' -e 'start' "$j" >"$fx/stubseq.log"
printf 'stop\nuninstall\ninstall\ninstall\nstart\n' | cmp -s - "$fx/stubseq.log" ||
  fail "Flow-Szenario g: Dienstkette weicht ab (Hauptlauf bis install-Fehler, dann Rollback install/start erwartet)."
startlast="$(grep -nx 'start' "$j" | tail -n1 | cut -d: -f1)"
lastmove="$(grep -n 'simop move' "$j" | tail -n1 | cut -d: -f1)"
[[ -n "$startlast" && -n "$lastmove" && "$startlast" -gt "$lastmove" ]] ||
  fail "Flow-Szenario g: der restaurierte Dienst wurde erst nach der Datei-Restauration gestartet."
printf 'Flow-Szenario g (install-Fehler -> Rollback mit Neuregistrierung und Start des vorherigen Dienstes) geprueft.\n'

rm -f "$FIXTURE_ROOT/expected-calls.log" "$FIXTURE_ROOT/expected-fail-install.log" \
  "$FIXTURE_ROOT/expected-fail-stop.log" "$FIXTURE_ROOT/expected-fail-uninstall.log"
printf 'Windows-Installer-Grundlage geprueft: Parse-Check, Vorlagen-Konsistenz, WinSW-Vertrag (#198-Wrapper, #200-Rollback-Kette), simulierte Kette mit kontrolliertem Abbruch bei Nicht-Null-Exitcodes und Flow-Simulation des Staging-Upgrades mit Rollback und Konfigurationsschutz (keine echten Dienste).\n'
