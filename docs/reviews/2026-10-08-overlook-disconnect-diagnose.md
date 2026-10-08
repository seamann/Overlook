# Overlook: Stand und Eingabesperre nach Disconnect

Stand: 8. Oktober 2026. Die Bestandsaufnahme, erste Reparatur und Wiederverbindungsversuche stehen unten als Diagnoseprotokoll. Der letzte Abschnitt beschreibt die anschließende Korrektur des Gerätewechsels, nachdem Wolfgang die erneute Blockade meldete.

## Befund

Der Freigabe-Button führt im vollständig getrennten Zustand in eine Sackgasse. Die App behält eine Eingabesperre nach einem unbekannten Remote-Ergebnis. Zugleich entfernt der Disconnect den Eingabe-WebSocket. „Eingabe nach Prüfung freigeben“ braucht diesen WebSocket und scheitert ohne ihn mit `input_unavailable`. Die Oberfläche bietet den Button trotzdem an und meldet lediglich „Freigabe nicht bestätigt. Eingabe bleibt gesperrt.“

Der heutige MCP-Status bestätigt `manual`, `hid_status=Disconnected`, `input_blocked=true` und fehlende Video-, Text- und Mausbereitschaft. Beide MCP-Aliasse erreichen denselben installierten Build; die lokale Crash-Abfrage findet keinen Bericht. Das ist kein Beweis für einen noch laufenden Disconnect. Welcher frühere Send- oder Release-Aufruf die Sperre gesetzt hat, lässt sich aus dem Status allein nicht feststellen.

Beim ersten Wiederverbindungsversuch war außerdem eine nicht erreichbare gespeicherte Adresse ausgewählt. Diese zweite Ursache erklärt den heutigen fehlgeschlagenen Connect-Versuch.

## Projektübergreifender Stand bei Diagnosebeginn

| Ort | Rolle und aktueller Nachweis |
|---|---|
| `/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02` | Aktueller Entwicklungsstand, Branch `codex/overlook-webrtc154-2026-10-02`, HEAD vor diesem Bericht `06e8c595`; Arbeitsbaum zu Beginn sauber. |
| `/Applications/Overlook.app` | Installierter Produktcommit `46ffe684eb2387d09221d76ee22112f5ea949e1a`, Build `46ffe684eb23-6eb941f3220a973b-devsigned`; Info.plist und beide laufenden MCP-Aliasse bestätigen ihn. Nachfolgende Commits bis `06e8c595` ändern Dokumentation. |
| `/Users/doebber/.local/share/overlook-control/releases/sdk-2.2.0-309083c` | Aktuelle MCP-Runtime. Globaler Alias `overlook-control` und WAGO-Alias `overlook` zeigen beide auf `dist/index.js`. Kontrollprotokoll 2 über Loopback-Port 17891. |
| `/Users/doebber/.codex/worktrees/overlook-review-2026-10-02` | Sauberer älterer Review-Stand, HEAD `1f98015`; keine aktuelle Produktbasis. |
| `/Users/doebber/Documents/Wago/work/Overlook-agent` | Ältere Basis `52f2ee6` mit umfangreichen eigenen/uncommitteten Änderungen; nicht als aktueller Stand verwenden. |
| `/Users/doebber/Documents/Wago/work/overlook-session-refactor-2026-09-15` | Ältere Refactoring-Kopie mit umfangreichen Änderungen. |
| `/Users/doebber/Documents/Codex/2026-09-09/ich-habe-ja-ein-overlook-und` | Historische Gesamtsystemprüfung und Auslieferung von Snapshot-, Aktions-, Abbruch- und MCP-Funktionen. Chat „Overlook-Gesamtsystem verbessern“ und `outputs/Overlook-Polarion-Umsetzung.md` wurden für die Chronologie herangezogen. |

Die bisherige Auslieferung steht im Chat „Overlook-Architektur prüfen“ und in den [Reparaturen vom 5. Oktober](2026-10-05-overlook-reparaturen.md) sowie dem [Mikro-Jiggler-Bericht](2026-10-05-overlook-mikro-jiggler.md). Am 2. Oktober wurden WebRTC 154.0.0 und MCP-SDK 2.2.0 eingeführt. Am 5. Oktober folgten Janus-/Audio-/UI-/MCP-Reparaturen und anschließend der kleine Mausimpuls nach 60 Sekunden Ruhe. Die dortige native Regression und 96 MCP-Tests sind damalige Prüfergebnisse; der heutige neue Testlauf steht im Reparaturabschnitt.

Der letzte gespeicherte erfolgreiche Live-Beleg vom 5. Oktober meldet 1920×1080, Video-/Text-/Mausbereitschaft und `input_blocked=false`: `/Users/doebber/.codex/artifacts/overlook-jiggler-2026-10-05/mcp-after-reconnect.json`. Er ersetzt den heutigen Status nicht. Tatsächliche Jiggler-Amplitude, Sleep-Verhinderung, Audio und längere Headless-/Reconnect-Abnahme bleiben offen.

Eine zusätzliche begrenzte Suche in `MacBook`, `Linux Server`, `New project`, `ChatGPT/Openhands`, `ChatGPT/Flipper Zero`, `Meiko` und `Pixxo` fand keine eigene Overlook-Implementierung oder projektspezifische Integration in den untersuchten Text-/Konfigurationsdateien und Dateinamen. Dependencies, Git-Interna, Buildausgaben, Medien und E-Mails waren ausgeschlossen. Das ist eine Bestandsaufnahme dieser Projektwurzeln, keine vollständige Auswertung sämtlicher älterer Chats.

## Quellpfad des Bedienfehlers vor der Reparatur

Diese Quellbefunde beziehen sich auf die damalige Produktrevision `46ffe684eb2387d09221d76ee22112f5ea949e1a`. Sie lassen sich mit `git show 46ffe684:<Pfad>` wieder öffnen. Die Dateilinks führen zum inzwischen reparierten Arbeitsstand.

- [OverlookApp.swift](../../Overlook/OverlookApp.swift), `invalidateSession`: schaltet nach Manual, sperrt die Session, beendet Video und entfernt das verbundene Gerät.
- [InputManager.swift](../../Overlook/InputManager.swift), `disconnectInputForSession`: entfernt API-Client und WebSocket. Ein fehlgeschlagener Release-Aufruf setzt die Eingabesperre über `latchUnconfirmedInput()`.
- [InputManager.swift](../../Overlook/InputManager.swift), `recoverInputAfterManualReview`: wartet ausstehende Befehle ab, verlangt einen vorhandenen WebSocket und sendet einen begrenzten Release. Erst nach Erfolg wird die Sperre gelöscht.
- [ContentView.swift](../../Overlook/ContentView.swift), damaliger `inputRecoveryBanner`: prüft Manual-Autorisierung, aber keine vorhandene Recovery-Verbindung. Alle Fehler erhalten dieselbe Meldung.
- [SessionConnectionCoordinator.swift](../../Overlook/SessionConnectionCoordinator.swift), `beginTeardown`: wiederholt bei einem neuen Verbindungsversuch bei Bedarf die Bereinigung der alten Session, bevor der neue Client aktiviert wird.

Ein erfolgreicher Reconnect im selben App-Prozess stellt die Transporte wieder her und erhält die Eingabesperre. Tastatur, Maus und Mikro-Jiggler bleiben während der Sperre angehalten. Eine frühere Textübertragung wird dabei nicht automatisch wiederholt.

## Heutige Wiederverbindung

Die native Oberfläche zeigte zunächst `Manual KVM @ 192.168.8.142:443`. Ein Klick auf Connect endete mit „Connection Failed / Failed to connect to KVM device“. Je ein begrenzter TCP-Test an Port 443 ergab:

| Gespeicherte Adresse | Ergebnis |
|---|---|
| `192.168.8.142` | Timeout |
| `192.168.8.205` | Timeout |
| `192.178.1.60` | Timeout |
| `192.178.1.62` | TCP-Verbindung erfolgreich; allein noch kein KVM-/Anmeldenachweis |

Wolfgang bestätigte `192.178.1.62` als aktuelle KVM-Adresse und beauftragte die Verbindung. Das gespeicherte Ziel wurde ausgewählt und Connect betätigt. Overlook öffnete den nativen Passwortdialog; Wolfgang bestätigte die Eingabe und Connect. Ein Passwort wurde weder im Chat abgefragt noch in den Bericht übernommen.

Danach zeigte die native App ausdrücklich: „The previous KVM session could not confirm HID disconnect. Try connecting again to retry cleanup.“ Der durch diese Meldung vorgesehene einmalige weitere Connect-Versuch wurde ausgeführt und endete erneut mit derselben Meldung. Der heutige blockierende alte Session-Abschluss ist damit live reproduziert; die konkrete alte Endpoint-/Token-/Netzfehlerursache wird durch die zusammengefasste Meldung weiterhin nicht offengelegt.

Der neue Client wird im normalen Ablauf erst nach erfolgreicher alter HID-Bereinigung aktiviert. Deshalb gab es nach diesen Versuchen weiterhin kein Videobild und keine Möglichkeit zur Freigabe über den Banner-Button. Wolfgang wurde um eine direkte Prüfung des Zielrechners und die Bestätigung eines regulären Overlook-Neustarts gebeten. Er bestätigte diese Frage anschließend mit „ja“.

Bei erfolgreichem Reconnect im selben Prozess ist der vorgesehene Ablauf: KVM-Verbindung herstellen, frisches Remote-Bild prüfen, dann in Manual ausdrücklich „Eingabe nach Prüfung freigeben“. Nach der Freigabe müssen `input_blocked=false` und die tatsächliche Bereitschaft neu geprüft werden. Eine neue Verbindung allein bestätigt kein früheres unbekanntes Aktionsergebnis.

Für einen genehmigten App-Neustart gilt ein anderer Ablauf: Der Zielzustand muss vor dem Neustart direkt geprüft werden. `InputManager` startet mit `inputBlocked=false`; die vorherige Sperre und ihr Banner sind danach nicht erhalten. Nach der Wiederverbindung sind Bild, richtige Zieladresse und Bereitschaft frisch zu prüfen. Ein solcher Neustart belegt weiterhin keinen erfolgreichen Abschluss der alten HID-Bereinigung.

Nach Wolfgangs Bestätigung wurde Overlook über seinen nativen Quit-Button regulär beendet. Der Prozessabschluss wurde geprüft, ohne Force Quit. Anschließend wurde exakt `/Applications/Overlook.app` wieder geöffnet. Der Sperrbanner war weg. Das bestätigte Ziel `192.178.1.62` wurde erneut ausgewählt; der neue Connect öffnete wieder den nativen Passwortdialog. Die frische Anmeldung und abschließende Videoprüfung stehen an dieser Stelle noch aus.

## Reparaturauftrag und Umsetzung

Im getrennten Zustand sollte das Banner „Erneut verbinden“ anbieten und die Freigabe erst bei vorhandenem Recovery-Transport erlauben. Fehler wie `input_unavailable`, `sessionChanged` und `unauthorized` brauchen jeweils einen konkreten nächsten Schritt. Die Sperre und die menschliche Sichtprüfung bleiben erhalten. Zusätzlich braucht ein wiederholt fehlgeschlagener alter Session-Abschluss einen klaren lokalen Übernahmeablauf; der derzeitige bloße Hinweis auf erneutes Connect führt bei diesem reproduzierten Fall nicht weiter.

Wolfgang beauftragte anschließend ausdrücklich die Reparatur. Der aktuelle Code ergänzt:

- Eine reine UI-Policy bietet im getrennten Zustand „Erneut verbinden“. „Eingabe nach Prüfung freigeben“ erscheint erst bei aktuellem Video und tatsächlich verbundenem Eingabe-WebSocket im Modus Manual.
- Ein fehlgeschlagener alter HID-Abschluss setzt die Eingabesperre und veröffentlicht eine neue Review-ID mit dem alten Endpunkt. Der normale Cleanup-Retry bleibt erhalten.
- „Alte Sitzung prüfen …“ öffnet einen ausdrücklichen lokalen Prüfungsdialog. Die Bestätigung wartet alte Lifecycle-Arbeit ab und prüft Review-ID, Versuch, Clientidentität und unveränderte Manual-Autorisierung erneut. Sie entfernt ausschließlich die lokale alte Cleanup-Zuordnung. Sie sendet keine Remote-Aktion und hebt die Eingabesperre nicht auf.
- Nach Bestätigung öffnet sich das bestehende Connections-Panel. Erst die neue Verbindung, eine neue Sichtprüfung und ein erfolgreicher Release über den aktuellen WebSocket können die Eingabe freigeben. Kein alter Text wird wiederholt.
- Readiness-Rückmeldungen lesen den tatsächlichen WebSocket-Actor-Zustand und prüfen Socket, Observer, Transport und Abfragegeneration. Alte Rückmeldungen können keine neue Verbindung freigeben.
- Fehler unterscheiden fehlenden Transport, veraltete Prüfung, widerrufene Manual-Autorisierung, Abbruch und fehlgeschlagenen Release.

Die unabhängige Sicherheitsprüfung fand zusätzlich eine bereits bestehende Race bei parallel laufenden HTTP-Textübertragungen. Eine Sichtprüfung darf keine noch laufende Textübertragung überholen. Recovery wartet solche Übertragungen vollständig ab und verwirft anschließend immer die vorherige Sichtprüfung. Jeder neue Sperrvorgang erhält außerdem eine UUID; eine neu gesetzte Sperre macht die laufende Freigabe ungültig. Echte RED-Läufe reproduzierten beide Fehler vor der Korrektur; die Nachprüfung meldet keine offenen Sicherheitsbefunde.

Gezielte RED-Belege, Coverage und der vollständige Testlauf liegen unter `/Users/doebber/.codex/artifacts/overlook-recovery-2026-10-08`. Der abschließende Lauf `scripts/test-agent-control.sh all` mit dem gepinnten WebRTC-Framework endet mit Exit 0: sämtliche nativen Suites und 96/96 MCP-Tests bestanden. Darunter sind 24 Coordinator-Gruppen, 13 UI-Policy-Gruppen, 11 HTTP-Fälle und 12 echte Loopback-WSS-Gruppen.

Gemessene Zeilen-Coverage: gesamter Coordinator 235/240 (97,92 %), gesamte LocalRecoveryPolicies 146/153 (95,42 %), geänderte InputManager-Recoverymethoden 258/267 (96,63 %). Die LLVM-Regionen liegen bei 94,38 %, 93,27 % und 87,04 %. Swift liefert hier keine Branch-Zähler; eine App-Gesamtcoverage wurde nicht gemessen. Bestehende Swift-5-Warnungen sind im vollständigen Log erhalten.

Der erste Xcode-Release-Compile war erfolgreich. Die vorgeschriebene Swift-Reviewer-Rolle konnte den Diff wegen ihres zwingenden `swift build`/`swift test`-Ablaufs ohne `Package.swift` nicht prüfen; ein unabhängiger allgemeiner Reviewer prüfte anschließend die Swift-Implementierung und die letzte Sicherheitskorrektur ohne offene blockierende Befunde. Die JS-Testfixture wurde separat geprüft.

Die native Test-App verwendet die tatsächliche Produktansicht, Coordinator und InputManager mit inerten KVM-Abhängigkeiten. Ihr erster gerenderter Lauf zeigte eine Überdeckung des Connections-Panels durch den Banner. Der Banner bekommt deshalb reservierten Platz oberhalb des übrigen Inhalts.

Die abschließende native Prüfung bestand bei 720 und 480 Pixel Fensterbreite: Banner und Connections-Bedienelemente sind getrennt und lesbar; Abbrechen erhält Review und Eingabesicherung. Nach ausdrücklichem Bestätigen verschwindet der alte Review, Connections öffnet sich und die Eingabe bleibt gesperrt. Die simulierten HID-Aufrufe bleiben bei zwei; die Bestätigung sendet keinen weiteren Aufruf. Auch „Erneut verbinden“ öffnet das zuvor geschlossene Connections-Panel. Der geprüfte Fixture-Lauf `7FBE6FCA-1CD8-4CD2-8AB8-BE78DE3D1335` steht in `ui-e2e/native-v2/state.jsonl`.

Beim ersten Teststarter mit Shell-/Exec-Wrapper erschien eine Finder-Meldung „Programm nicht mehr geöffnet“ und die native Automatisierung verlor die App-Zuordnung. Die Zuordnung des Wrappers wird als Ursache vermutet; ein Crash-Bericht wurde nicht gefunden. Die zweite Fixture startet direkt ihre eigene Mach-O-Binary und setzt die Netzwerksperre vor dem Erzeugen aller App-Objekte. Ihr Selbsttest bestätigt tatsächliches `EPERM` sowie schreibbare lokale Nachweise. Der Test-only C-Wrapper wurde separat geprüft; er verändert keine Produkt-Sandbox. Die abgeschlossene Fixture wurde geschlossen.

## Installierte Reparatur

Produktcommit: `01d04d34a68b8714aa4f237c02a61cfbf6f8d6b5` (`fix: recover from unconfirmed KVM disconnects`). Der signierte Xcode-Release-Build lautet `01d04d34a68b-3ee61e319cdd5908-devsigned`, Team `PZWNQ5R725`, Kontrollprotokoll 2. Source-Fingerprint und Commit blieben während des Builds unverändert.

Vor Austausch wurden identische Bundle-ID, Team, Designated Requirement, Entitlements sowie tiefe/strikte Signaturprüfung bestätigt. Overlook wurde regulär über seinen Quit-Button beendet; vor Staging und unmittelbar vor Austausch wurde der Prozessabschluss geprüft. Staging und installierte Kopie wurden anhand vollständiger Dateihashes und Symlinks mit dem Kandidaten verglichen.

`/Applications/Overlook.app` enthält jetzt den Reparaturbuild. Die bisherige signierte App liegt unter `/Users/doebber/.codex/artifacts/overlook-recovery-2026-10-08/rollback/Overlook-before-recovery.app`. Belege: `release/build-manifest.txt`, `preinstall-verification.json`, `install-receipt.json` und `mcp-installed-before-auth.json` im Artefaktordner.

Nach Neustart bestätigt der laufende MCP-Endpunkt genau den neuen Build. Die App bleibt in Manual. Das bereits bestätigte Ziel `192.178.1.62:443` wurde ausgewählt und Connect gestartet. Wolfgang gab das Passwort im nativen Dialog ein und bestätigte anschließend die Anmeldung.

Der frische MCP-Status meldet `hid_status=Connected`, `input_blocked=false` sowie Video-, Text- und Mausbereitschaft jeweils `true`. Die native Oberfläche bestätigt die richtige Zieladresse, den Zustand Connected und laufendes Video mit 1920×1080 bei 59 fps. Beleg: `mcp-installed-after-connect.json`. Das ist die erfolgreiche neue Verbindung; es ist kein Nachweis für den alten unbekannten HID-Abschluss. Physische Tastatur-/Mauswirkung, längere Reconnect-Ausdauer und Audio wurden bei dieser Reparatur nicht neu abgenommen. Der Agent sendete keine Remote-Tastatur-, Maus- oder Textaktion.

`npm audit` im aktuellen MCP-Projekt meldete 0 bekannte Schwachstellen. Danach beauftragte Wolfgang ausdrücklich den GitHub-Push. Die vorhandenen 26 lokalen Commits wurden auf `seamann/codex/overlook-webrtc154-2026-10-02` veröffentlicht; HEAD `f92094f` wurde per Git-Remote und GitHub-API bestätigt. Eine PR und ein Merge wurden nicht vorgenommen. Die vorhandenen fremden Änderungen im WAGO-Arbeitsbaum bleiben unberührt.

## Nachbesserung: automatischer Gerätewechsel

Wolfgang meldete erneut die alte HID-Disconnect-Sperre, diesmal beim Wechsel zu einem anderen KVM. Ein frischer TCP-Test zeigte die inzwischen umgekehrte Erreichbarkeit: das ausgewählte neue `192.168.8.142:443` antwortete; das bisherige `192.178.1.62:443` antwortete nicht. Die fehlende Antwort des alten Geräts verhinderte weiterhin die Aktivierung des neuen Clients.

Die lokale GLKVM-Referenzimplementierung zeigt die falsche Bedeutung des bisherigen Abschlusses: `POST /api/hid/set_connected?connected=false` schaltet die globale USB-HID-Verbindung des Geräts. Der HTTP-Handler stellt lediglich ein MCU-Ereignis in die Queue und liefert `{"ok":true,"result":{}}`; er bestätigt weder den Abschluss einer Overlook-Sitzung noch die Ausführung der USB-Umschaltung. Das Antwortformat passt zu `GLKVMEmptyResult`. Der Fehler liegt im Einsatz dieses Aufrufs als zwingende Voraussetzung für den nächsten Gerätewechsel.

Der Coordinator schließt deshalb die lokale Sitzung automatisch: sofortige Session-Invalidierung, Abwarten bereits gesendeter HID-Enable-Aufrufe, vollständiger Mutation-/Print-/HID-Drain, Freigabe gedrückter Tasten und Maustasten sowie Schließen des alten Eingabe-WebSockets. Dieser Ablauf sendet kein globales HID(false). Das neue Gerät wird erst nach diesem lokalen Abschluss und einer aktuellen Versuchsgeneration installiert. HID(true) bleibt beim expliziten Verbinden erhalten, damit frühere App-Versionen abgeschaltete USB-HID-Verbindungen wieder einschalten können. Die bisherige lokale Alt-Sitzungsbestätigung und ihr blockierender Fehlerdialog entfallen.

Die Geräteauswahl ist auch bei bestehender Verbindung bedienbar. Ein anderes ausgewähltes Host-/Port-Paar bietet „Switch Device“ und nutzt denselben Coordinator; das aktive Ziel bietet weiterhin „Disconnect“. „Manual Connect…“ kann ebenfalls einen Wechsel starten. Laufende Versuche bleiben abbrechbar und sperren doppelte Auswahlaktionen.

Eine tatsächlich ungewisse Eingabe bleibt gesperrt, auch nach einem Gerätewechsel oder App-Neustart. Die Produktion speichert dafür `overlook.inputRecoveryBlocked` in ihren UserDefaults. Nur die erfolgreiche aktuelle Manual-Freigabe mit unverändertem Transport, Sperrgeneration und Autorisierung entfernt den Eintrag. Neue Verbindung, USB-Enable und Neustart löschen ihn nicht. Testinstanzen verwenden isolierte Defaults oder ausschließlich Speicherzustand.

RED reproduzierte die Blockade durch den nicht erreichbaren alten Endpunkt. Die gezielten GREEN-Läufe bestanden mit 25 Coordinator-Gruppen, 13 UI-Policy-Gruppen sowie 11 HTTP-Fällen und 4 Persistenzgruppen. Gemessene Zeilen-Coverage: Coordinator 98,06 %, LocalRecoveryPolicies 95,39 %. Die geänderten InputManager-Persistenz-/Recoveryfunktionen erreichten 100 % ausführbare LLVM-Regionen; dies ist keine App-Gesamtcoverage.

Die native Prüfung nutzte die tatsächliche ContentView in einer Test-App mit gesperrtem Netzwerk und inerten KVM-Abhängigkeiten. Über deren echte Connections-Oberfläche wurde New verbunden, zu Old gewechselt, zu New zurückgewechselt und anschließend getrennt. Alle vier Installationen blieben eingabegesperrt, HID-Enable wurde viermal simuliert, HID(false) keinmal. Der Lauf `9A604113-6760-45CD-9CB5-4BAFE0144C41` und die Größenprüfungen bei 720 und 480 Pixeln stehen unter `/Users/doebber/.codex/artifacts/overlook-switch-2026-10-08/ui-e2e/state.jsonl`. Banner und Geräteauswahl blieben getrennt und bedienbar. „Manual Connect…“ wurde in dieser Fixture nicht geöffnet; Video und reale Remote-Eingaben waren simuliert. Die Test-App wurde anschließend geschlossen.

Unabhängige Code-, Swift- und Sicherheitsprüfungen fanden keine offenen blockierenden Befunde. Die ursprünglich realen IP-Adressen im Regressionstest wurden durch `.invalid`-Testnamen ersetzt. `npm audit` meldete erneut 0 bekannte Schwachstellen.

Der vollständige neue Lauf `scripts/test-agent-control.sh all` bestand mit Exit 0, sämtlichen nativen Suites und 96/96 MCP-Tests. Ein früherer Lauf wurde während paralleler Quelländerungen vom Swift-Compiler abgebrochen; sein Log ist als `all-tests-intermediate.log` erhalten. Ein weiterer Lauf traf eine bestehende Zeit-Race im Snapshot-Test: dessen Encoder meldete „gestartet“ auch dann, wenn ein Fehler ihn bereits beendet hatte. Die Testhilfe hält nun Erfolg und Fehler bis zur expliziten Gate-Freigabe; Produktionscode wurde dafür nicht geändert. Der native Snapshot-Harness bestand anschließend 20 vollständige Läufe mit jeweils 17/17 Gruppen. Die früheren Fehler- und neuen Erfolgsausgaben bleiben im Artefaktordner erhalten.

Codecommit: `ea90adc` (`fix: switch KVM sessions without blocking on old devices`). Die getrennte Testhärtung steht in `8b035dc` (`test: keep snapshot encoder gates active after failures`).

Der signierte Xcode-Release-Build `8b035dc5fa46-92e417a9c37ce07e-devsigned` wurde unter `/Applications/Overlook.app` installiert. Source-Revision und Fingerprint blieben während des Builds unverändert; Team, Bundle-ID, Designated Requirement, Entitlements, Signaturen, Dateihashes und Symlinks stimmen zwischen Kandidat und installierter App überein. Overlook wurde regulär geschlossen. Das bisherige App-Bundle bleibt unter `/Users/doebber/.codex/artifacts/overlook-switch-2026-10-08/rollback/Overlook-before-switch.app` erhalten.

Vor dem Austausch bestätigte MCP erneut die aktive Eingabesperre. Weil der alte Build sie noch nicht persistierte, wurde dieser bestehende Sperrzustand vor dem regulären Quit in den neuen Defaults-Eintrag übernommen. Nach dem Start bestätigte der laufende MCP-Endpunkt den neuen Build, Manual und `input_blocked=true`. Die alte Cleanup-Bestätigung erscheint nicht mehr; der Banner bietet „Erneut verbinden“.

Das bereits von Wolfgang ausgewählte und nun erreichbare `192.168.8.142:443` wurde im neuen Build gewählt und Connect gestartet. Die App erreichte den normalen Passwortdialog. Die Anmeldung benötigt das Passwort dieses Geräts; der Agent fragte es nicht im Chat ab und speicherte es nicht in Nachweisen. Eine erfolgreiche neue Verbindung und tatsächliche Eingabewirkung waren zu diesem Prüfpunkt noch nicht nachgewiesen. Belege stehen unter `mcp-preinstall-state.json`, `mcp-installed-before-auth.json`, `release/build-manifest.txt`, `preinstall-verification.json` und `install-receipt.json` im neuen Artefaktordner.
