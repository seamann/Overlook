# Overlook: Stand und Eingabesperre nach Disconnect

Stand: 8. Oktober 2026. Lesende Bestandsaufnahme, Quellprüfung und native Wiederverbindung im bestehenden Overlook. Produktcode, installierte App und MCP-Konfiguration wurden nicht geändert.

## Befund

Der Freigabe-Button führt im vollständig getrennten Zustand in eine Sackgasse. Die App behält eine Eingabesperre nach einem unbekannten Remote-Ergebnis. Zugleich entfernt der Disconnect den Eingabe-WebSocket. „Eingabe nach Prüfung freigeben“ braucht diesen WebSocket und scheitert ohne ihn mit `input_unavailable`. Die Oberfläche bietet den Button trotzdem an und meldet lediglich „Freigabe nicht bestätigt. Eingabe bleibt gesperrt.“

Der heutige MCP-Status bestätigt `manual`, `hid_status=Disconnected`, `input_blocked=true` und fehlende Video-, Text- und Mausbereitschaft. Beide MCP-Aliasse erreichen denselben installierten Build; die lokale Crash-Abfrage findet keinen Bericht. Das ist kein Beweis für einen noch laufenden Disconnect. Welcher frühere Send- oder Release-Aufruf die Sperre gesetzt hat, lässt sich aus dem Status allein nicht feststellen.

Beim ersten Wiederverbindungsversuch war außerdem eine nicht erreichbare gespeicherte Adresse ausgewählt. Diese zweite Ursache erklärt den heutigen fehlgeschlagenen Connect-Versuch.

## Projektübergreifender Stand

| Ort | Rolle und aktueller Nachweis |
|---|---|
| `/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02` | Aktueller Entwicklungsstand, Branch `codex/overlook-webrtc154-2026-10-02`, HEAD vor diesem Bericht `06e8c595`; Arbeitsbaum zu Beginn sauber. |
| `/Applications/Overlook.app` | Installierter Produktcommit `46ffe684eb2387d09221d76ee22112f5ea949e1a`, Build `46ffe684eb23-6eb941f3220a973b-devsigned`; Info.plist und beide laufenden MCP-Aliasse bestätigen ihn. Nachfolgende Commits bis `06e8c595` ändern Dokumentation. |
| `/Users/doebber/.local/share/overlook-control/releases/sdk-2.2.0-309083c` | Aktuelle MCP-Runtime. Globaler Alias `overlook-control` und WAGO-Alias `overlook` zeigen beide auf `dist/index.js`. Kontrollprotokoll 2 über Loopback-Port 17891. |
| `/Users/doebber/.codex/worktrees/overlook-review-2026-10-02` | Sauberer älterer Review-Stand, HEAD `1f98015`; keine aktuelle Produktbasis. |
| `/Users/doebber/Documents/Wago/work/Overlook-agent` | Ältere Basis `52f2ee6` mit umfangreichen eigenen/uncommitteten Änderungen; nicht als aktueller Stand verwenden. |
| `/Users/doebber/Documents/Wago/work/overlook-session-refactor-2026-09-15` | Ältere Refactoring-Kopie mit umfangreichen Änderungen. |
| `/Users/doebber/Documents/Codex/2026-09-09/ich-habe-ja-ein-overlook-und` | Historische Gesamtsystemprüfung und Auslieferung von Snapshot-, Aktions-, Abbruch- und MCP-Funktionen. Chat „Overlook-Gesamtsystem verbessern“ und `outputs/Overlook-Polarion-Umsetzung.md` wurden für die Chronologie herangezogen. |

Die jüngste Auslieferung steht im Chat „Overlook-Architektur prüfen“ und in den [Reparaturen vom 5. Oktober](2026-10-05-overlook-reparaturen.md) sowie dem [Mikro-Jiggler-Bericht](2026-10-05-overlook-mikro-jiggler.md). Am 2. Oktober wurden WebRTC 154.0.0 und MCP-SDK 2.2.0 eingeführt. Am 5. Oktober folgten Janus-/Audio-/UI-/MCP-Reparaturen und anschließend der kleine Mausimpuls nach 60 Sekunden Ruhe. Die native Regression und 96 MCP-Tests sind dort als damalige Prüfergebnisse dokumentiert; heute wurden sie nicht erneut ausgeführt.

Der letzte gespeicherte erfolgreiche Live-Beleg vom 5. Oktober meldet 1920×1080, Video-/Text-/Mausbereitschaft und `input_blocked=false`: `/Users/doebber/.codex/artifacts/overlook-jiggler-2026-10-05/mcp-after-reconnect.json`. Er ersetzt den heutigen Status nicht. Tatsächliche Jiggler-Amplitude, Sleep-Verhinderung, Audio und längere Headless-/Reconnect-Abnahme bleiben offen.

Eine zusätzliche begrenzte Suche in `MacBook`, `Linux Server`, `New project`, `ChatGPT/Openhands`, `ChatGPT/Flipper Zero`, `Meiko` und `Pixxo` fand keine eigene Overlook-Implementierung oder projektspezifische Integration in den untersuchten Text-/Konfigurationsdateien und Dateinamen. Dependencies, Git-Interna, Buildausgaben, Medien und E-Mails waren ausgeschlossen. Das ist eine Bestandsaufnahme dieser Projektwurzeln, keine vollständige Auswertung sämtlicher älterer Chats.

## Quellpfad des heutigen Bedienfehlers

- [OverlookApp.swift:46](../../Overlook/OverlookApp.swift#L46): Session-Invalidierung schaltet nach Manual, sperrt die Session, beendet Video und entfernt das verbundene Gerät.
- [InputManager.swift:456](../../Overlook/InputManager.swift#L456): Disconnect entfernt API-Client und WebSocket. Ein fehlgeschlagener Release-Aufruf setzt die Eingabesperre über `latchUnconfirmedInput()`.
- [InputManager.swift:1041](../../Overlook/InputManager.swift#L1041): Manuelle Freigabe wartet ausstehende Befehle ab, verlangt einen vorhandenen WebSocket und sendet einen begrenzten Release. Erst nach Erfolg wird die Sperre gelöscht.
- [ContentView.swift:200](../../Overlook/ContentView.swift#L200): Der Button prüft Manual-Autorisierung, aber keine vorhandene Recovery-Verbindung. Alle Fehler erhalten dieselbe Meldung.
- [SessionConnectionCoordinator.swift:122](../../Overlook/SessionConnectionCoordinator.swift#L122): Ein neuer Verbindungsversuch wiederholt bei Bedarf die Bereinigung der alten Session, bevor der neue Client aktiviert wird.

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

Der neue Client wird im normalen Ablauf erst nach erfolgreicher alter HID-Bereinigung aktiviert. Deshalb gibt es weiterhin kein Videobild und keine Möglichkeit zur Freigabe über den Banner-Button. Wolfgang wurde um eine direkte Prüfung des Zielrechners und die Bestätigung eines regulären Overlook-Neustarts gebeten. Ein Neustart würde den lokalen, nur im Prozess gehaltenen Sperrzustand verlieren und wird nicht als Beweis der Remote-Bereinigung behandelt.

Bei erfolgreichem Reconnect im selben Prozess ist der vorgesehene Ablauf: KVM-Verbindung herstellen, frisches Remote-Bild prüfen, dann in Manual ausdrücklich „Eingabe nach Prüfung freigeben“. Nach der Freigabe müssen `input_blocked=false` und die tatsächliche Bereitschaft neu geprüft werden. Eine neue Verbindung allein bestätigt kein früheres unbekanntes Aktionsergebnis.

Für einen genehmigten App-Neustart gilt ein anderer Ablauf: Der Zielzustand muss vor dem Neustart direkt geprüft werden. `InputManager` startet mit `inputBlocked=false`; die vorherige Sperre und ihr Banner sind danach nicht erhalten. Nach der Wiederverbindung sind Bild, richtige Zieladresse und Bereitschaft frisch zu prüfen. Ein solcher Neustart belegt weiterhin keinen erfolgreichen Abschluss der alten HID-Bereinigung.

## Kleinste sinnvolle Produktreparatur

Im getrennten Zustand sollte das Banner „Erneut verbinden“ anbieten und die Freigabe erst bei vorhandenem Recovery-Transport erlauben. Fehler wie `input_unavailable`, `sessionChanged` und `unauthorized` brauchen jeweils einen konkreten nächsten Schritt. Die Sperre und die menschliche Sichtprüfung bleiben erhalten. Zusätzlich braucht ein wiederholt fehlgeschlagener alter Session-Abschluss einen klaren lokalen Übernahmeablauf; der derzeitige bloße Hinweis auf erneutes Connect führt bei diesem reproduzierten Fall nicht weiter.

Vor Umsetzung fehlen gezielte Regressionen für den getrennten Bannerzustand und den vollständigen Ablauf Reconnect → manuelle Freigabe. Bestehende Tests prüfen bereits, dass unsichere Übertragungen und fehlgeschlagene Releases die Sperre erhalten und eine gescheiterte Session-Bereinigung vor der neuen Aktivierung erneut versucht wird. Heute wurde kein Reparaturcode geschrieben.

`npm audit --audit-level=low` im aktuellen MCP-Projekt meldet am 8. Oktober 0 bekannte Schwachstellen. Der neue Bericht wird ausschließlich lokal gesichert; kein Push und keine PR.
