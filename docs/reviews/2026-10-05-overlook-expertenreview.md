# Overlook: weitere Verbesserungen nach dem M154-/MCP-2.2-Rollout

Stand: 5. Oktober 2026. Die weitere Prüfung empfiehlt kleine Reparaturen am Janus-/Audio-Lifecycle, verständlichere lokale Wiederherstellung und eine gezielte Geräteabnahme. Der bestehende native Aufbau und die Trennung von Manual, Headless und MCP bleiben passend. Ein Gesamtumbau ist aus den geprüften Quellen nicht begründet.

## Wichtigste neue Befunde

Die folgenden P2-Befunde sind durch aktuelle Codepfade belegt. Ihre Fehlerfolgen wurden heute nicht am KVM reproduziert. Vor einer Reparatur ist jeweils ein gezielter fehlgeschlagener Regressionstest erforderlich; grüne vorhandene Tests decken diese neuen Gegenbeispiele nicht automatisch ab.

| Rang | Befund, Folge und kleinste sinnvolle Arbeit | Beleg / Diskussion |
|---|---|---|
| 1 | Janus sendet Create/Attach, bevor der Antwort-Waiter registriert wird. Eine Antwort während des Send-Awaits kann am Waiter vorbeilaufen. Registrierung und genau einen Abschluss für Antwort, Sendfehler, Timeout, Cancel und Disconnect in einem kleinen Request-Helfer zusammenführen. | [Send vor Registrierung](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebRTCManager.swift:546), R22; Videostart-Frist gesondert R23 |
| 2 | Nach fehlgeschlagener AudioUnit-Initialisierung bleibt das Handle gesetzt. Ein zweiter Init kann deshalb Erfolg melden, obwohl der erste Aufbau unvollständig blieb. Unit erst nach vollständigem Erfolg veröffentlichen und die Fehlerpfade stufenabhängig aufräumen. | [Output-Init](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebRTCAudioDevice.swift:103), [Input-Init](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebRTCAudioDevice.swift:166), R24 |
| 3 | Ein abgebrochener Audio-Hotplug-Debounce läuft nach dem verworfenen Sleep-Fehler weiter. Ein alter Keepalive-Fehler besitzt außerdem keinen ursprünglichen Generation-/Socket-Abgleich. Beide Ergebnisse an ihren aktuellen Owner binden. | [Debounce](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebRTCManager.swift:320), [Keepalive](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebRTCManager.swift:642), R26/R27 |
| 4 | Der lokale Reconnect-Button liegt in der gesamten, für Headless gesperrten Videofläche. Wiederherstellung außerhalb der Remote-Eingabefläche anbieten. Ein vollständiger Reconnect fällt weiterhin bewusst nach Manual zurück. | [Hit-Testing-Sperre](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:249), [lokaler Button](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/VideoSurfaceView.swift:136), [Sessioninvalidierung](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/OverlookApp.swift:45), R03 |
| 5 | MCP- und Swift-Schemas weichen bei Scroll-Delta 0 und dem maximalen Sequenzwert voneinander ab. Zuerst gemeinsame Grenzwertfälle und identische Ablehnung herstellen. Ein umfassender neuer Discovery-Vertrag ist dafür nicht erforderlich. | [MCP-Schema](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/mcp/overlook-control/src/control-contracts.ts:15), [native Grenzen](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/RemoteActionState.swift:41), R33 |
| 6 | Importabhängige WebRTC-Tests können still entfallen; der heutige erste Testversuch hat dies konkret gezeigt. Importierbarkeit vorab verlangen. Den Test für späte Snapshot-Ergebnisse durch Encoder-Barrieren absichern, damit die Assertion tatsächlich nach dem Abschluss läuft. | [bedingte native Fälle](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/tests/FrameDeliveryTests.swift:73), [feste Prüfschlafzeit](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/tests/RemoteSnapshotTests.swift:344), R46/R48 |

Weitere kleine, quellbelegte Arbeiten: Verbindungsversuche im Connections-Panel abbrechbar machen (R02); Jiggler-/Modusfehler mit passenden Überschriften statt „Connection Failed“ zeigen (R08); ungültige Ports nicht still zu 443 machen (R09); den Preferences-Menüpunkt zum vorhandenen Settings-Panel führen (R17). Automatisch übernommene Settings brauchen verständliches Feedback für ausstehende und unbestätigte Ergebnisse (R06). „Verwerfen“ kann einen bereits gesendeten POST nicht zurücknehmen.

## Empfohlene Reihenfolge

| Paket | Arbeit und Abnahme | Eingriffsrisiko / Aufwand |
|---|---|---|
| A – Belege und begrenzte Lifecycle-Reparaturen | Janus-/Audio-/Debounce-/Keepalive-Gegenbeispiele zuerst mit steuerbaren Send-, Timer- und Audio-Grenzen reproduzieren; anschließend jeweils kleinste Reparatur. Schema-Grenzen angleichen und native Testvoraussetzungen explizit prüfen. | Kleine bis mittlere Änderungen, getrennte Commits; keine gemeinsame Medien-/Session-Neuarchitektur. |
| A – Gerätefunktion | Echte Click/Text/Escape-Wirkung über M154/MCP 2.2 in einem flüchtigen Testfeld; Jiggler-Wirkung gegenüber einem bekannten Idle-Limit einschließlich Headless-Pause und Manual-Rückkehr; zunächst drei reguläre Reconnect-Zyklen. | Abnahmebedarf P1, kein behaupteter P1-Produktdefekt. Eigenes begrenztes Wartungsfenster; heute nicht ausgeführt. |
| B – Bedienung | Lokalen Reconnect und Verbindungsabbruch, passende Fehler, Endpoint-/Passwortkontext und Preferences-Routing verbessern. Eine reine Anzeigeprojektion erklärt API, Bild und Eingabebereitschaft; sie wird kein neuer autoritativer Owner. | Überwiegend kleine Änderungen. Bestehende Capture-, Cleanup- und Manual-Rückfallregeln erhalten. |
| B – Native UI und Entwicklerweg | Tastatur/VoiceOver, Vollbild, geschlossene Panels, lange Texte und Themes mit synthetischen Zuständen prüfen. Nur beobachtete Probleme korrigieren. Kurzen lesenden MCP-Einstieg und ein App-/Adapter-/Alias-Rückfallrunbook ergänzen. | Statische Hinweise sind keine visuelle oder VoiceOver-Abnahme. Keine globalen Kürzel einführen, die Remote-Eingabe überlagern. |
| C – Bedarf zuerst belegen | Stats-Rückstau messen; Callback-Lebensdauervertrag klären; engere Framebudgets, neue Quittungsfelder und Zertifikatsbindung nur bei konkretem Bedarf entwerfen. | Keine Performanceversprechen, kein unbewiesener Use-after-free, keine automatisch verschärfte TLS-Policy. |

Audio-Playback ist getrennt von der erfolgreichen Linkprobe abzunehmen. Ein Mikrofontest wird bewusst gestartet, zeitlich begrenzt und ohne Aufzeichnung durchgeführt. Ein längerer Dauerlauf, Netzunterbrechung und M109-Vergleich benötigen einen passenden Testkontext. Eine Stunde und zehn Zyklen sind kein bereits vereinbarter Qualitätsmaßstab. Die Hardwarematrix beginnt mit der tatsächlich verfügbaren Kombination; weitere Firmwarestände, Intel oder ältere macOS-Versionen bleiben bis zur Prüfung ungeprüft.

Die Jiggler-Wirksamkeitsabnahme wird ausdrücklich empfohlen: Wolfgang hatte diese Funktion als wesentliches Ziel benannt. Ein Firmware-Readback bestätigt den Settingwert, aber kein tatsächliches Wachhalten. Der Test verändert keine Arbeits-Lock-Policy; Ausgangseinstellungen sind anschließend zu bestätigen.

## Was die Gegenprüfungen verändert haben

Der Headless-Reconnect-Vorschlag wurde korrigiert: Der Button kann lokal erreichbar werden, doch die bewusste Rückkehr nach Manual bei einer neuen vollständigen Session bleibt erhalten. Die drei Statusvorschläge R01/R11/R30 werden zu einer kleinen Anzeigeprojektion gebündelt; eine zusätzliche globale Zustandsmaschine entfällt. Fehlerüberschriften R08/R18 werden ebenfalls zusammengeführt.

Ein exaktes `next_action_seq`-Gebot wird nicht ohne Kompatibilitätsprüfung eingeführt. Identische Replays bleiben Lookup und unsichere Mutation wird nicht erneut gesendet. Cancel-Sättigung ist zunächst ein Fixture-Thema: das Schließen der bestehenden Verbindung bietet bereits einen eigenen Cancel-Pfad. Neue Discovery-/Quittungs-/Framebudget-Felder sind keine Voraussetzung für die beiden belegten Schema-Korrekturen. Ein Redesign, eine automatische Headless-Wiederaufnahme und ein automatischer Rollback bei schwankender Readiness werden nicht empfohlen.

## Fachrichtungen und die 50 Runden

Sechs spezialisierte Agenten prüften UX, native UI/Barrierefreiheit, Swift/Architektur/Performance, MCP/Sicherheit/Developer Experience, QA/Release/Betrieb und unabhängige Architektur-Skepsis. Verwendete Methoden: ECC-Fachrollen, `ecc:swift-protocol-di-testing` und `ecc:verification-loop`; aus Awesome/Aegis `first-principles-review` und `ui-ux-governance`; ergänzend der persönliche `gstack-devex-review`.

Die 50 Runden sind thematische, nummerierte Diskussionen, keine behaupteten 50 Vollversammlungen aller Agenten. Fünf Panels eröffneten jeweils zehn Vorschläge. Eine andere Fachrichtung prüfte jeden Vorschlag; ein unabhängiger Architektur-/Skepsis-Agent prüfte zusätzlich alle 50. Der Hauptagent entschied anschließend jede Runde. Rohvorschlag, Gegenpositionen und Urteil bleiben im [vollständigen Diskussionsprotokoll](2026-10-05-overlook-50-runden.md) und im [strukturierten Nachweis](2026-10-05-overlook-50-runden.json) erhalten. Die Themenzahl ist keine Anzahl bewiesener Bugs oder beauftragter Änderungen.

## Aktueller Nachweis und Grenzen

Die Produktquellen des geprüften M154-Arbeitsbaums am Ausgangs-HEAD `5f25347f5a568da4230f45e3f6320b03f16b31e4` stimmen mit dem installierten Quellfingerabdruck `ca99916fd08f4b4e820e25cf2baf80df41dd19248ac789778c7443233b518aa2` überein. Installierte Build-ID: `bc9bec046c62-ca99916fd08f4b4e-devsigned`. Das Executable ist unverändert, SHA-256 `7266bf8902f2697fae85e7c6b1b0a14de178a999965917bd2eca4ad83fb6f085`. Der Package-Pin bestätigt WebRTC 154.0.0. Die generische Framework-Plist-Version ist kein Ersatz für diesen Paketnachweis.

| Prüfung am 5. Oktober | Ergebnis |
|---|---|
| Native Swift-Regression, Xcode-Compiler/SDK und vollständiges M154-Entwicklungsframework | Exit 0; unter anderem Frame 11/11, Snapshot 17/17, Kontrollserver 8 Integrationsgruppen. |
| MCP-Build und Tests | Unveränderter Git-HEAD in separater Testkopie mit Lockfile-Installation: 65/65, Exit 0. |
| Dependency-Audit im tatsächlichen MCP-Paket | Null bekannte Schwachstellen. |
| Erster kombinierter Testtreiber | Exit 127: fehlendes lokales `tsc`; zuvor wurden mit dem installierten Framework ohne Import-Header drei native Fälle ausgelassen. Die korrigierte Swift-Prüfung und separate MCP-Prüfung sind eigene erfolgreiche Läufe; der Gesamttreiber wurde nicht nochmals ausgeführt. |
| Live-Gerät, native UI, VoiceOver und neue Fehlerfälle | Heute nicht abgenommen. Die App lief beim Check nicht; MCP meldete `local_file_unavailable`. Dies ist keine beobachtete Regression. Die erfolgreiche Gerätebeobachtung vom 2. Oktober bleibt historisch. |

Compilerwarnungen zur Swift-6-Concurrency und einem Snapshot-Testadapter bleiben dokumentiert. Der aktuelle Sprachmodus 5 besteht; eine Swift-6-Migration ist ein eigener, nicht automatisch beauftragter Schritt. Gesamtcoverage der App wurde heute nicht gemessen. Vorhandene Methoden-Coverage wird nicht in eine App-Gesamtquote umgedeutet. Heute entstand kein neuer Fehlerfalltest und kein neuer App-Build.

Belege: [Quellen-/Installationsabgleich](/Users/doebber/.codex/artifacts/overlook-expert-review-2026-10-05/source-and-live-scope.json), [Prüfübersicht](/Users/doebber/.codex/artifacts/overlook-expert-review-2026-10-05/verification-summary.json), [native Regression](/Users/doebber/.codex/artifacts/overlook-expert-review-2026-10-05/native-swift-regression.log), [MCP-Regression](/Users/doebber/.codex/artifacts/overlook-expert-review-2026-10-05/mcp-regression.log), [Audit](/Users/doebber/.codex/artifacts/overlook-expert-review-2026-10-05/npm-audit.json).

Dieser Auftrag erzeugt Vorschläge und Dokumentation. App, Produktquellen, MCP-Runtime, Konfiguration, Credentials und Geräteeinstellungen wurden nicht geändert. Keine Remote-Eingabe, kein Push und keine Veröffentlichung.
