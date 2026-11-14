# Backend-Shutdown mit Spielservern

Ein normaler Backend-Shutdown (Spring-Kontext schließen oder `SIGTERM`, etwa durch
`systemctl stop moddex-backend`) **stoppt alle verwalteten Minecraft-Server geordnet**.
Die Server bleiben nicht absichtlich als unverwaltete Prozesse zurück; Reattach wird
nicht unterstützt. `javaPath` muss Java direkt starten, nicht einen abkoppelnden
Launcher/Daemon.

## Ablauf und Grenzen

- Sobald der Spring-Kontext schließt, werden neue Starts abgewiesen. Bereits
  begonnene Starts werden mitverfolgt; entsteht dabei noch ein Prozess, erhält auch
  dieser `stop`. Die Shutdown-Konsolenausgabe läuft in Daemon-Workern, nicht im
  fertig werdenden Startaufruf. Beim Schließen aktive oder noch startende Instanzen
  sowie begonnene Shutdown-Stop-Versuche werden auch dann auf Erfolg geprüft, wenn
  der Prozess bereits vor dem Destroy-Hook beendet ist.
- Jeder aktive Server erhält denselben Konsolenbefehl `stop` wie beim normalen
  Stoppen in Moddex. Minecraft führt damit seine eigene Welt-Speicherung und
  Beendigung durch; ein zusätzliches `save-off` oder ein Host-Signal ersetzt das
  nicht. Die normale Stop-API bleibt asynchron.
- Stop-Anforderungen laufen parallel. Ein gemeinsames Zeitbudget von **60 Sekunden**
  umfasst laufende Starts, Konsolenausgabe und Prozessende, nicht 60 Sekunden pro
  Server. Auch beim Stop beobachtete Kindprozesse müssen beendet sein. Exitcodes
  ungleich null werden als Fehler gemeldet, weil die Welt-Speicherung dann geprüft
  werden muss.
- Das Budget kann mit `MODDEX_PROCESS_SHUTDOWN_TIMEOUT_MS` bzw.
  `moddex.process.shutdown-timeout-ms` angepasst werden (positive Millisekunden).
  Bei Änderung muss auch die Wartezeit des Dienstmanagers angepasst werden.
- Bei Timeout, Schreibfehler oder Unterbrechung wird der Shutdown ausdrücklich als
  **unvollständig** mit Instanz-ID und sicherem nächsten Schritt protokolliert.
  Rohe Exception-Texte und Konsolenbefehle werden dabei nicht in Fehlermeldungen
  übernommen. Es gibt **keinen automatischen Force-Kill** und keinen automatischen
  Reattach. Eine nach dem Zeitbudget fertig werdende Startoperation versucht
  weiterhin `stop`; ihr Ende wurde beim fehlgeschlagenen Shutdown nicht bestätigt.

Die gebündelte systemd-Unit verwendet `KillMode=mixed`: Das erste `SIGTERM` geht
nur an den Backend-Hauptprozess, nicht gleichzeitig an die Minecraft-JVMs.
`TimeoutStopSec=120s` lässt zusätzlich zum Backend-Budget Zeit für Springs
Web-Shutdown (standardmäßig bis zu 30 Sekunden) und Dienstverwaltung.
`SendSIGKILL=no` verhindert, dass systemd bei einer langsamen Welt-Speicherung
nachträglich die gesamte Prozessgruppe zwangsweise beendet. systemd verweigert
bei `KillMode=mixed`/`SendSIGKILL=no` einen Neustart mit verbleibenden Prozessen
der alten Service-Control-Group. Eigene Supervisoren müssen dieselbe Reihenfolge
und ausreichend Zeit gewährleisten.

Ein `SIGKILL`, Stromverlust oder JVM-Absturz kann keinen geordneten Shutdown
garantieren. Auch ein sauberer Exit ist keine unabhängige Prüfung der Weltdaten.

## Bei unvollständigem Shutdown

Spring kann trotz eines Fehlers im Destroy-Hook den Backend-Prozess beenden.
Ein beendetes Backend allein beweist daher **nicht**, dass alle Spielserver
beendet oder die Welten gespeichert sind:

1. Instanz-Logs und verbleibende Prozesse prüfen (bei systemd zusätzlich
   `systemctl status moddex-backend` und das Journal).
2. Noch laufende Server über deren unterstützte Administrationsschnittstelle
   speichern und stoppen. Nicht blind zwangsweise beenden oder einen zweiten
   Server auf demselben Weltverzeichnis starten.
3. Vor einem Moddex-Neustart das Ende sämtlicher alter Spielserver bestätigen;
   bei Exitcode ungleich null die Speicher-/Fehlermeldungen der Instanz prüfen.

## Automatisierte Prüfung

`ProcessManagerServiceTest` verwendet ausschließlich Prozess-Testdoubles und lokale
Testdateien unter `backend/target`; weder Minecraft noch systemd werden gestartet.
Die Tests decken Kontext-Shutdown, aktive/inaktive Prozesse, konkurrierende Starts,
paralleles Stoppen, gemeinsame Zeitgrenze, blockierte/defekte Konsolen, unterbrochenes
Warten, Fehlercodes und verbleibende Kindprozesse ab.

```bash
cd backend
bash ./mvnw -Dtest=ProcessManagerServiceTest,ConsoleControllerTest test
```
