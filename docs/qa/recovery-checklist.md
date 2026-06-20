# Moddex QA: Recovery- und Datenverlust-Szenarien

> Versionierte, release-nahe QA-Checkliste für privaten Linux-Betrieb. Ziel ist
> sicherzustellen, dass Restore, Mod-Änderungen und Dateioperationen Instanzen
> **nicht unbeabsichtigt zerstören**. Für privaten Betrieb zählt Zuverlässigkeit
> mehr als Feature-Breite.

**Vor jedem Release ausführen.** Trage Datum, Version und Tester ein:

| Feld | Wert |
|------|------|
| Moddex-Version / Tag | `__________` |
| Betriebsmodus | local / lan / public |
| Tester | `__________` |
| Datum | `__________` |

## Legende

- **Ergebnis:** ✅ bestanden · ⚠️ mit Einschränkung · ❌ fehlgeschlagen
- 🚫 **BLOCKER (Public Beta):** Ein ❌ bei diesem Schritt **blockiert** die Public Beta.
- Automatisiert abgedeckte Schritte sind mit `[smoke]` markiert (siehe
  [`scripts/smoke-test.sh`](../../scripts/smoke-test.sh)).

---

## 1. Backup → Restore → Start

| # | Szenario | Erwartung | 🚫 | Ergebnis |
|---|----------|-----------|----|----------|
| 1.1 | Backup einer laufenden Instanz erstellen `[smoke]` | Backup erscheint in der Liste, Größe > 0 | | |
| 1.2 | Backup bei zu wenig Speicherplatz erstellen | Abbruch **vor** dem Schreiben mit `507`/klarer Fehlermeldung, **keine** halbe Datei | 🚫 | |
| 1.3 | Restore eines Backups in dieselbe Instanz | Instanz-Daten entsprechen dem Backup-Stand | 🚫 | |
| 1.4 | Instanz nach Restore starten | Server startet sauber, Welt ladbar | 🚫 | |
| 1.5 | Restore mit defektem/unvollständigem Backup-Archiv | Abbruch ohne Überschreiben der vorhandenen Daten; klare Fehlermeldung | 🚫 | |
| 1.6 | Backup löschen (über Review-Dialog) | Datei entfernt; Bestätigung erforderlich; kein Löschen ohne Bestätigung | | |

## 2. Fehlgeschlagene Mod-Installation & Rollback

| # | Szenario | Erwartung | 🚫 | Ergebnis |
|---|----------|-----------|----|----------|
| 2.1 | Mod installieren (Erfolgsfall) `[smoke]` | Mod erscheint in der Liste, Datei vorhanden | | |
| 2.2 | Mod-Installation mit abgebrochenem Download | Atomarer Rollback: kein Teil-Artefakt, Mod-Liste unverändert | 🚫 | |
| 2.3 | Mod-Installation mit Prüfsummen-Mismatch | Ablehnung; keine Datei geschrieben | 🚫 | |
| 2.4 | Mod entfernen und Zustand prüfen | Datei entfernt, Mod-Liste konsistent | | |
| 2.5 | Parallele Mod-Änderung an derselben Instanz | Zweite Operation wird mit `409` abgewiesen (Lock) | | |

## 3. Kaputte / inkompatible Modpacks

| # | Szenario | Erwartung | 🚫 | Ergebnis |
|---|----------|-----------|----|----------|
| 3.1 | Import eines Modpacks von nicht erlaubtem Host | Ablehnung durch Trust-Policy mit lesbarer Meldung | 🚫 | |
| 3.2 | Import mit Pfad-Traversal-Eintrag (`../`) | Ablehnung; kein Schreibzugriff außerhalb der Instanz | 🚫 | |
| 3.3 | Import mit überschrittenem Größen-/Dateilimit | Ablehnung vor dem Entpacken | | |
| 3.4 | Import eines inkompatiblen Loaders/MC-Version | Warnung im Review-Dialog; Nutzer kann bewusst abbrechen | | |
| 3.5 | Abbruch eines Imports zur Laufzeit | Keine teil-importierten Mods; Ausgangszustand erhalten | 🚫 | |

## 4. Umgebungsfehler

| # | Szenario | Erwartung | 🚫 | Ergebnis |
|---|----------|-----------|----|----------|
| 4.1 | Volle Platte während Backup/Import | Abbruch vor Schreibbeginn; bestehende Daten unversehrt | 🚫 | |
| 4.2 | Abgebrochener externer Download | Temp-Datei entfernt; kein halbes Artefakt | | |
| 4.3 | Fehlende Dateirechte auf Datenpfad | Klare Fehlermeldung; kein stiller Datenverlust | | |
| 4.4 | Unvollständiges/korruptes Archiv | Ablehnung mit Hinweis; kein Überschreiben | 🚫 | |
| 4.5 | Backend-Neustart während laufender Operation | Konsistenter Zustand nach Neustart (kein halb-applizierter Stand) | 🚫 | |

## 5. Frische Linux-Installation (Smoke)

| # | Szenario | Erwartung | 🚫 | Ergebnis |
|---|----------|-----------|----|----------|
| 5.1 | `install.sh --mode lan` auf frischem System | Dienst läuft als `moddex`, Port wie konfiguriert | | |
| 5.2 | Erst-Setup abschließen (Admin-Passwort) | Setup erfolgreich; danach Login möglich | 🚫 | |
| 5.3 | Unauth. Zugriff auf geschützten Endpunkt | Antwort `401 Unauthorized` (siehe README-Verifikation) | 🚫 | |
| 5.4 | Instanz anlegen, starten, Backup, Restore | End-to-End ohne Datenverlust `[smoke]` | 🚫 | |
| 5.5 | `uninstall.sh` ausführen | Dienst und Daten wie dokumentiert entfernt | | |

---

## Bekannte Recovery-Grenzen

- **Kein Point-in-Time-Recovery:** Restore stellt den Stand des gewählten
  Backups her; Änderungen seit dem Backup gehen verloren.
- **Restore ist destruktiv:** Es überschreibt den aktuellen Instanzzustand.
  Vor dem Restore wird ein aktuelles Backup empfohlen (Review-Dialog weist darauf hin).
- **Keine Inhalts-/Malware-Prüfung:** Externe Downloads werden gegen erwartete
  Prüfsummen (SHA-512/SHA-1) und eine Host-Allowlist geprüft, aber **nicht** auf
  Schadsoftware gescannt.
- **Disk-Status im Dashboard:** Freier Speicherplatz wird im Frontend aktuell als
  „nicht verfügbar" angezeigt (kein Backend-API); die Backend-seitige
  Speicherplatz-Prüfung greift dennoch vor schreibenden Aktionen.
- **Backup-Konsistenz:** Für ein garantiert konsistentes Backup sollte der
  Serverprozess gestoppt sein (siehe README, Abschnitt Backup).

## Blocker-Regel für Public Beta

Jeder mit 🚫 markierte Schritt, der mit ❌ endet, ist ein **Release-Blocker**
für die Public Beta. Trage gefundene Blocker hier ein und verlinke das Issue:

| Schritt | Beschreibung | Issue |
|---------|--------------|-------|
| | | |
