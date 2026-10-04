# Overlook: Umsetzung der Reparaturen 1 bis 4

Stand: 5. Oktober 2026. Die vier beauftragten Reparaturbereiche sind umgesetzt, getrennt lokal committet und im neuen signierten App-Build installiert. Beide MCP-Konfigurationen zeigen auf den zugehörigen neuen Adapter. Der bereits laufende Codex-Chat übernimmt ihn erst beim normalen Neustart von Codex.

Der [Expertenbericht](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/docs/reviews/2026-10-05-overlook-expertenreview.md) und die [50 Diskussionsrunden](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/docs/reviews/2026-10-05-overlook-50-runden.md) dokumentieren den historischen Stand vor diesen Reparaturen. Dieser Bericht beschreibt die anschließende Umsetzung. Xcode 27.0, WebRTC 154.0.0 und MCP-SDK 2.2.0 wurden in diesem Reparaturauftrag beibehalten.

## 1. Janus-Antworten und Requestabschluss

Create-/Attach-Requests registrieren jetzt Antwortempfänger und Timeout vor dem Senden. Eine Antwort während eines wartenden Send-Aufrufs kann dadurch bereits dem richtigen Request zugeordnet werden. ACK beendet den Request weiterhin nicht; erst die abschließende Janus-Antwort beendet ihn.

Der kleine `JanusRequestCoordinator` führt Antwort, Sendfehler, Timeout, Cancellation und Disconnect auf genau einen Abschluss zusammen. UUIDs verhindern, dass alte Timer oder Fehler einen Ersatzrequest übernehmen. Cancellation wird synchron markiert und vor dem queued Dispatch geprüft. Ein notwendiger Transportabbruch schließt ausschließlich den erfassten Socket. Die acht Sekunden gelten weiterhin je Request; eine neue globale Videostart-Frist wurde nicht eingeführt.

Quellen: [Request-Coordinator](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/JanusRequestCoordinator.swift:23), [Manager-Integration](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebRTCManager.swift:697).

## 2. Audio-Initialisierung, Hotplug und Keepalive

AudioUnits bleiben während des Aufbaus lokal und werden erst nach vollständigem Erfolg veröffentlicht. Fehlgeschlagene Aufbauten entsorgen ihren Handle; nach einem begonnenen Initialisierungsversuch erfolgt zusätzlich Uninitialize. Retry erzeugt einen neuen Handle und initialisiert wirklich. Ein Fehler bei Ein- oder Ausgabe entsorgt nicht die andere Richtung. Die Echtzeit-Rendercallbacks wurden nicht umgebaut.

Hotplug-Debounce und Keepalive prüfen Cancellation, ursprüngliche Verbindungsgeneration und Socketidentität. Abgebrochene Hotplug-Aufgaben starten keinen verspäteten Reconnect. Ergebnisse eines alten Keepalive-Aufrufs beeinflussen keine neue Session. Tear-down beendet Debounce und offene Janus-Requests.

Quellen: [Output-Initialisierung](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebRTCAudioDevice.swift:124), [Input-Initialisierung](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebRTCAudioDevice.swift:194), [Task-Scope](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/JanusRequestCoordinator.swift:134).

## 3. Lokale Wiederherstellung und Bedienung

Die lokale Wiederherstellung liegt außerhalb der Remote-Videofläche, deren Hit-Testing in Headless gesperrt bleibt. Reconnect verwendet den vorhandenen SessionCoordinator und fällt bei einer neuen vollständigen Session weiterhin bewusst nach Manual zurück. Eine automatische Headless-Wiederaufnahme wurde nicht ergänzt.

Das Connections-Panel bietet während eines laufenden Versuchs Cancel über den bestehenden Cancellationpfad. Fehlerüberschriften nennen die betroffene Aktion. Preferences führt zum vorhandenen Settings-Panel; Menü und Toolbar verlangen denselben verbundenen Manual-Zustand. Ein früher Menürequest bleibt bis zum Mount der Hauptansicht erhalten. Bei fehlenden Voraussetzungen erscheint eine lokale Erklärung, ohne Settings zu öffnen.

Manuelle Adressen verlangen Ports aus Dezimalziffern im Bereich 1–65535; der stille Fallback auf 443 entfällt. Zugangsdaten in der Adresse, Pfad, Query und Fragment werden abgewiesen. Geklammerte IPv6-Adressen werden als tatsächliche Literale geprüft. Die TCP-Vorprüfung erhält deren numerische Network-Darstellung; gespeicherter Host und HTTP-/Janus-URLs behalten ihre Klammern. IPv4- und DNS-Pfade bleiben erhalten.

Quellen: [UI-Policies](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/LocalRecoveryPolicies.swift), [Hauptansicht](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift), [Connections-Dialog](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ConnectSheets.swift), [Preferences](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/MenuBarAgent.swift), [IPv6-Transport](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/KVMDevice.swift:18), [TCP-Vorprüfung](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/KVMDeviceManager.swift:1338).

## 4. MCP-Grenzen und nativer Testtreiber

MCP und Swift verwenden dieselbe maximale Action-Sequenz `9007199254740990`. Scroll-Delta 0 wird bereits im Adapter abgewiesen. Eine gemeinsame synthetische JSON-Fixture prüft 30 Grenzfälle auf beiden Seiten. Ungültige MCP-Eingaben werden vor dem Öffnen der Control-Verbindung abgelehnt. Replay-, Deduplication- und Cancellation-Verhalten wurde nicht neu entworfen.

Der Testtreiber verlangt vor den nativen Suites einen tatsächlich importierbaren WebRTC-Entwicklungsframeworkstand. Ein Runtime-Framework ohne Headers/Modules kann die nativen Fälle nicht mehr still reduzieren. Die vollständige native Kompatibilitätsprüfung ist eingebunden; Compiler und SDK stammen aus der konfigurierten Xcode-Umgebung. Der CI-Workflow nutzt dieselben Prüfungen; Remote-CI wurde hier nicht ausgeführt.

Snapshot-Tests für späte Encoderergebnisse verwenden Start-/Release-Barrieren und warten auf den tatsächlichen Abschluss einschließlich MainActor-Cleanup. Das Startsignal folgt dem erfolgreichen PNG-Aufbau. Ein Encoding-Fehler signalisiert ebenfalls vor dem Re-Throw. Feste Nachwartezeiten entscheiden dadurch nicht mehr, ob ein spätes Ergebnis tatsächlich geprüft wurde.

Quellen: [MCP-Schemas](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/mcp/overlook-control/src/control-contracts.ts:7), [gemeinsame Fixture](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/mcp/overlook-control/tests/fixtures/action-contract-boundaries.json), [Testtreiber](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/scripts/test-agent-control.sh), [native Kompatibilitätsprüfung](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/scripts/test-webrtc-compatibility.sh), [Snapshot-Settlement](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/RemoteSnapshot.swift:236).

## Prüfungen und Coverage-Grenzen

Der abschließende kombinierte Treiber nach allen Produktänderungen endete mit Exit 0. Die benötigten nativen WebRTC-Fälle wurden ausgeführt; MCP meldet ausdrücklich 0 skipped. Unterschiedliche Tests und Gruppen werden hier nicht zu einer künstlichen Gesamtzahl addiert.

| Prüfung | Ergebnis |
|---|---|
| Janus / Hotplug-/Keepalive-Scope | 16/16 und 8/8 |
| AudioUnit-Initialisierung und Cleanup | 22/22 |
| Lokale UI-Policies / Network-Endpunkte | 8 und 5 Gruppen; Endpunkte nur lokale Adressinterpretation, kein DNS-/TCP-Aufruf |
| Gemeinsame native Action-Grenzen | 30 Fälle innerhalb von 6 Verhaltensgruppen |
| Native WebRTC-Kompatibilität | 4/4, einschließlich Audio-Shim, Objective-C-Factory und Peer-Lifecycle |
| Snapshot / Frame / Stats | 17/17, 11/11, 7/7 |
| Lokaler Control-Server | 8 Integrationsgruppen; Loopback-TCP mit synthetischer Eingabe und Videoquelle |
| MCP-Build und vollständige Tests | 96/96, 0 fehlgeschlagen, 0 übersprungen |
| Bestehende Regressionen | Jiggler-Lifecycle, Credentials, SessionCoordinator, HID-Queue, Fenster- und WebSocket-Lifecycle bestanden |
| Scoped Dependency-Audit | 0 bekannte Schwachstellen im MCP-Paket |
| Unabhängige Reviews | Swift APPROVE; TypeScript, Security und Schlussreview PASS; keine offenen materiellen Befunde im Änderungsscope |

Belege: [finaler Gesamtlauf](/Users/doebber/.codex/artifacts/overlook-implementation-2026-10-05/final-regression.log), [Audit](/Users/doebber/.codex/artifacts/overlook-implementation-2026-10-05/npm-audit.json), [Swift](/Users/doebber/.codex/artifacts/overlook-implementation-2026-10-05/review/swift.md), [TypeScript](/Users/doebber/.codex/artifacts/overlook-implementation-2026-10-05/review/typescript.md), [Security](/Users/doebber/.codex/artifacts/overlook-implementation-2026-10-05/review/security.md), [Schlussreview](/Users/doebber/.codex/artifacts/overlook-implementation-2026-10-05/review/final.md). Frühere Reviewerberichte und `precommit-verification.json` enthalten Zwischenstände; die späteren Gesamt-, Build- und Auslieferungsbelege schließen deren Build-/IPv6-Pendenzen.

Gezielte Coverage: Janus-Helper 97,98 % Zeilen / 91,67 % Regionen; betroffene Audio-Initialisierung, HAL-Erstellung und Terminate 100 % gemappte Regionen und Zeilen; UI-Policies 93,46 % Zeilen / 90,14 % Regionen; MCP-Contracts 100 % Zeilen und Branches / 83,33 % Funktionen. Dies ist keine App-Gesamtcoverage. Die gesamte Audio-Datei erreicht beispielsweise 84,46 % Zeilen, aber 67,36 % Regionen; echte I/O- und Rendercallbacks gehören nicht zur Initialisierungs-Fehlereinjektion.

Coverage-Belege: [Janus](/Users/doebber/.codex/artifacts/overlook-implementation-2026-10-05/janus/coverage-report.txt), [Audio](/Users/doebber/.codex/artifacts/overlook-implementation-2026-10-05/audio/result.json), [UI](/Users/doebber/.codex/artifacts/overlook-implementation-2026-10-05/ui/review-final-coverage-report.txt), [MCP](/Users/doebber/.codex/artifacts/overlook-implementation-2026-10-05/mcp/full-contract-coverage.log).

## Installation und lesender Laufzeittest

Installiert ist `/Applications/Overlook.app`, Build-ID `309083c8e2ae-cd96e5cb97366f72-devsigned`, Produktrevision `309083c8e2aecd4f7c32836df8a5578af3500360`. Der aktuelle Produktquellfingerabdruck entspricht dem installierten Build. Beim Abschlusscheck lief genau eine App, PID `87281`, aus `/Applications/Overlook.app/Contents/MacOS/Overlook`. Der Xcode-Release-Build war erfolgreich. Strikte Signaturprüfung und vollständiger Bundle-Abgleich bestanden; designated requirement und Entitlements gegenüber der bisherigen App blieben unverändert.

Neuer Runtime-Pfad: `/Users/doebber/.local/share/overlook-control/releases/sdk-2.2.0-309083c`. Alle 24 `dist`-Dateien entsprechen Manifest und geprüftem Repo-Build. Der globale Eintrag `overlook-control` und der WAGO-Eintrag `overlook` zeigen darauf; in beiden wurde ausschließlich `args` geändert.

Ein isolierter SDK-2.2-Client startete diesen Adapter über stdio, initialisierte erfolgreich, listete neun Tools und rief ausschließlich `overlook_status` auf. Die Antwort bestätigte den neuen App-Build, Protokoll 2 und Manual. HID war Disconnected; Video-, Text- und Mouse-Readiness waren false. „Ready“ bezeichnet hier die erreichbare Control-API, keine verbundene oder eingabebereite KVM-Session. Die installierten Contract-Guards bestanden. Es wurde keine Remote-Eingabe gesendet.

Belege: [abschließender Quellen-/Laufzeitabgleich](/Users/doebber/.codex/artifacts/overlook-implementation-2026-10-05/delivery-verification.json), [Installation](/Users/doebber/.codex/artifacts/overlook-implementation-2026-10-05/install-receipt.json), [Build-Manifest](/Users/doebber/.codex/artifacts/overlook-implementation-2026-10-05/release/build-manifest.txt), [Build-Log](/Users/doebber/.codex/artifacts/overlook-implementation-2026-10-05/release/build.log), [MCP-Konfiguration](/Users/doebber/.codex/artifacts/overlook-implementation-2026-10-05/mcp-config-receipt.json), [Runtime-Manifest](/Users/doebber/.codex/artifacts/overlook-implementation-2026-10-05/mcp-runtime-manifest.json), [lesender MCP-Laufzeittest](/Users/doebber/.codex/artifacts/overlook-implementation-2026-10-05/mcp-live-smoke.json).

## Offene Abnahme und Rückfallstand

Die native visuelle Abnahme ist offen: beide `cua.getApp`-Versuche liefen nach 120 beziehungsweise 60 Sekunden in einen Timeout. Es wurden keine tatsächlichen Dialog-, Reconnect-Hit-Test- oder Preferences-Klickprüfungen abgeschlossen. Geräteaudio, Mikrofon, VoiceOver, echte Headless-Reconnect-Ausdauer und tatsächliches Jiggler-Wachhalten wurden ebenfalls nicht abgenommen. Grüne lokale Fixtures bestätigen keine Wirkung gegen das reale Idle-Limit. Bestehende Compilerwarnungen zur späteren Swift-6-Migration bleiben dokumentiert; der aktuelle Sprachmodus 5 besteht den Release-Build.

Die bisherige signierte App, Build-ID `bc9bec046c62-ca99916fd08f4b4e-devsigned`, ist als [Original beim Austausch](/Users/doebber/.codex/artifacts/overlook-implementation-2026-10-05/rollback/Overlook-at-swap.app) und [zusätzliche Kopie](/Users/doebber/.codex/artifacts/overlook-implementation-2026-10-05/rollback/Overlook-before-repairs.app) vollständig erhalten. Der vorherige Adapter bleibt unter `/Users/doebber/.local/share/overlook-control/releases/sdk-2.2.0-75a375a`. Ursprüngliche Konfigurationen liegen lokal geschützt im selben `rollback`-Verzeichnis; ihr Inhalt ist weder im Bericht noch im Git-Commit. Ein Rückfall wurde nicht ausgelöst.

Die neue App läuft bereits. Für den neuen Adapter im aktuellen Chat ist ein normaler Codex-Neustart erforderlich. Eine KVM-Verbindung wurde für die Auslieferungsprüfung nicht hergestellt.

## Lokale Sicherung

- `800ce68`: `fix: settle Janus requests before dispatch`
- `98dfbc6`: `fix: clean up incomplete audio initialization`
- `deb2c53`: `fix: make local recovery and settings actions consistent`
- `d3323ab`: `fix: align MCP and native action boundaries`
- `309083c`: `test: require native WebRTC coverage and encoder settlement`

Alle Produktänderungen sind lokal committet. Es erfolgte kein Push und keine PR-Veröffentlichung. Die separate Sicherung dieses Berichts verschiebt den Git-HEAD, ändert aber weder Produktrevision noch Produktquellfingerabdruck des installierten Builds.
