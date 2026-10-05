# Overlook: kleiner Mausimpuls

Stand: 5. Oktober 2026. Produkt-Commit `46ffe684eb2387d09221d76ee22112f5ea949e1a`.

## Verhalten

Der neue Jiggler sendet nach 60 Sekunden ohne echte Eingabe einen kurzen horizontalen Hin- und Rückimpuls. Im absoluten Mausmodus beträgt der Abstand ungefähr einen Pixel der bekannten Videobreite. Im relativen Modus werden `+1` und `-1` HID-Zähler gesendet; die sichtbare Strecke hängt dort auch von der Mausbeschleunigung des Zielsystems ab. Die normale Mausempfindlichkeit und der Mausmodus werden nicht geändert.

`InputManager` besitzt den Timer und verwendet die bestehende HID-Warteschlange und WebSocket-Verbindung. Bei Benutzereingaben, gehaltenen Tasten oder Maustasten, laufendem Text-/Shortcut-/Gestenversand, Headless, Verbindungstransitionen oder Eingabesperre wird nicht gejiggelt. Vor beiden Teilbewegungen werden die Freigabe, Transportidentität und Aktivitätsgeneration erneut geprüft. Neue Benutzereingaben verhindern eine Rückbewegung zu einem veralteten Ursprung.

Im absoluten Modus stammt der Ursprung ausschließlich aus einer erfolgreich gesendeten Mausposition mit gültiger, aktueller Videobreite. Reines Ein- oder Ausschalten behält einen gültigen Ursprung derselben Verbindung. Sitzungs-, Transport-, Modus- und Breitenwechsel verwerfen ihn. Nach einer neuen Verbindung muss daher zunächst eine normale Mausbewegung im Videobild erfolgen. Direkte Mausbewegungen am Ziel außerhalb von Overlook sind über diese Schnittstelle nicht beobachtbar.

## Firmware und Einstellungen

Die Herstellerimplementierung bewegt beide Achsen mehrfach und bietet keinen Amplitudenparameter. Der Quellstand `3e8dd23c4bd638a4650433664cc3b0f3b4d29395` enthält absolut `100, -100, 100, -100, 0` und relativ `10, -10, 10, -10`. Die HID-API bietet Aktivierung und Intervall. Quellen: [Firmwarebewegung](https://github.com/gl-inet/glkvm/blob/3e8dd23c4bd638a4650433664cc3b0f3b4d29395/kvmd/plugins/hid/__init__.py#L346-L355), [HID-Einstellungen](https://github.com/gl-inet/glkvm/blob/3e8dd23c4bd638a4650433664cc3b0f3b4d29395/kvmd/apps/kvmd/api/hid.py#L108-L129).

Overlook gibt den lokalen Mikro-Jiggler erst frei, wenn sowohl `config.mouse_jiggle=false` als auch der tatsächliche HID-Daemonzustand `jiggler.active=false` bestätigt sind. Fehlende oder nicht boolesche Zustände führen zum Stopp. Kein Overlook-Schreibpfad aktiviert den großen Firmware-Jiggler erneut, auch nicht beim normalen Speichern anderer Einstellungen. Frische unbekannte Konfigurationsfelder bleiben erhalten.

Die gewünschte lokale Aktivierung wird je Host und Port gespeichert. Bestehende Firmware-Aktivierung wird in diese lokale Absicht übernommen und danach ausgeschaltet. Explizites Ausschalten bleibt auch bei einem Netzfehler und nach einem Neustart erhalten. Headless stoppt synchron und stellt nach dem vorhandenen Eingabe-Drain ausschließlich die lokale Absicht wieder her.

## Prüfung

Der vollständige Lauf `scripts/test-agent-control.sh all` ist erfolgreich, einschließlich aller nativen Regressionen und 96/96 MCP-Tests. Relevante Ergänzungen: 32 Manager-Lifecycle-Szenarien, 15 Credential-/Settings-Szenarien, 8 strikte HID-Readback-Fälle, 7 deterministische Planergruppen und 16 echte Loopback-TLS-HID-Gruppen. Der automatische Timer wurde ohne direkten Tick-Aufruf getestet, ebenso Toolbar-Aktivierung mit vorhandenem Ursprung, Hintergrund-Manual, gehaltene Eingaben und Benutzeraktivität/Headless zwischen den Teilschritten.

Die beiden neuen Module `MicroMouseJiggler` und `MicroJigglerPreference` erreichen jeweils 100 % gemessene LLVM-Zeilenabdeckung. Für die vollständige App wurde keine Gesamtquote ermittelt. Der Session-/Transportwechsel mitten im Bewegungspaar ist über Owner-/Generation-Tests und die Produktionsguards abgesichert; ein eigener TLS-Paarfall wurde nicht ergänzt.

Unabhängige Codeprüfung und Sicherheitsprüfung fanden nach den Reparaturen keine offenen materiellen Befunde. `npm audit` meldet 0 Schwachstellen. Die ursprünglichen Verhaltensfehler sind durch RED-Belege dokumentiert; der erste Planer-RED war eine fehlende neue API beim Kompilieren, kein Laufzeitbeleg. Die Toolbar-Regression wurde zusätzlich gegen die reproduzierte frühere Toggle-Logik zur Laufzeit nachgewiesen.

## Build und Auslieferung

Der signierte Release-Build `46ffe684eb23-6eb941f3220a973b-devsigned` wurde mit Xcode 27.0 über `xcodebuild` erstellt. WebRTC bleibt auf dem bestehenden Pin 154.0.0; MCP und Kontrollprotokoll 2 bleiben unverändert. Team, Bundle-Identität, Designated Requirement und Entitlements stimmen mit der bisher installierten App überein; `codesign --verify --deep --strict` ist erfolgreich.

Die neue App ist fertig und für den Austausch geprüft. Aktuell läuft noch die bisherige App `309083c8e2ae-cd96e5cb97366f72-devsigned`. Der Austausch wartet auf normales Beenden mit Cmd+Q, weil der native UI-Zugriff einen Timeout liefert. Es wurde kein Prozess erzwungen beendet und noch keine lokale Aktivierungspräferenz des verbundenen Geräts geändert. Beim Austausch wird die bisherige App unter `rollback/Overlook-before-micro-jiggler.app` aufbewahrt und die neue Kopie zusätzlich vollständig über Datei-Hashes und Symlinks geprüft.

Die vorbereiteten Belege liegen unter `/Users/doebber/.codex/artifacts/overlook-jiggler-2026-10-05`: `full-tests-final.log`, `npm-audit.json`, `coverage/tdd-acceptance.json`, `release/build-manifest.txt` und `preinstall-verification.json`. Tatsächliche Cursoramplitude und Sleep-Verhinderung am echten Ziel sind noch nicht abgenommen; die lokalen Tests und der signierte Build ersetzen diese Geräteprüfung nicht.
