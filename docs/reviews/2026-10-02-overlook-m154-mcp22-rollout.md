# Overlook: WebRTC-154- und MCP-2.2-Update

Stand: 2. Oktober 2026, nach Wolfgangs Codex-Neuladung. Wolfgang hat den Wechsel auf die neue App und den neuen MCP-Adapter ausdrücklich beauftragt. Der signierte WebRTC-154-Build ist unter `/Applications/Overlook.app` installiert und mit dem bisherigen KVM verbunden. MCP-SDK 2.2 ist separat installiert und als Codex-Ziel konfiguriert. Nach der Neuladung ist jetzt auch der tatsächlich benutzte `overlook-control`-Adapter dieses Chats mit SDK 2.2 gestartet; Status und frische Snapshots sind über dessen Chat-Werkzeuge geprüft.

## Installierter und geprüfter Stand

| Bestandteil | Tatsächlicher Stand |
|---|---|
| Native App | `/Applications/Overlook.app`, Build-ID `bc9bec046c62-ca99916fd08f4b4e-devsigned` |
| Buildquelle | Commit `bc9bec046c623209c3db7cb4ce69ae5b518f7ebb`, unveränderte Produktquellen des vorbereiteten M154-Kandidaten |
| Quellfingerabdruck | `ca99916fd08f4b4e820e25cf2baf80df41dd19248ac789778c7443233b518aa2` |
| Executable-SHA-256 | `7266bf8902f2697fae85e7c6b1b0a14de178a999965917bd2eca4ad83fb6f085` |
| WebRTC | Exakt 154.0.0, Revision `0c0ad84dac6c1941c16a414dfcfba94691866e4c` |
| Signatur | Apple Development, Team `PZWNQ5R725`; App und Framework bestehen die strikte Prüfung. Designated Requirement und Entitlements entsprechen dem bisherigen M109-Build. |
| MCP-Installation | `/Users/doebber/.local/share/overlook-control/releases/sdk-2.2.0-75a375a` |
| Adapter / SDK | Adapter `overlook-control-mcp` 1.0.0; Server/Core-SDK 2.2.0, Zod 4.6.5 |
| Globale Codex-Konfiguration | Nur `mcp_servers.overlook-control.args` wurde auf den neuen `dist/index.js`-Pfad umgestellt. Alle anderen geparsten Konfigurationswerte bleiben identisch. Der zusätzliche Projektalias ist unten dokumentiert. |
| Aktueller Codex-Chat | Neue `overlook-control`-Prozesse mit SDK 2.2.0 aus dem konfigurierten Releasepfad, tatsächliche Chat-Werkzeuge bestehen Status und Snapshot-Abfragen. |

Die 24 kompilierten Adapterdateien stammen aus dem bereits getesteten Reparaturstand. Vor der Installation wurde der TypeScript-Build erneut ausgeführt. Die produktiven Abhängigkeiten wurden mit dem gesicherten Lockfile über `npm ci --omit=dev` installiert; `npm audit --omit=dev` meldet null bekannte Schwachstellen. Der vorhandene 65-Test-Nachweis bleibt gültig; für den lokalen Installationswechsel wurden keine Produktquellen geändert.

## Tatsächlicher Ablauf und Live-Prüfung

Die laufende M109-App wurde zunächst bytegleich gesichert. Anschließend wurde sie regulär über ihren Quit-Button beendet. Der Kandidat wurde unter einem temporären Namen in `/Applications` kopiert und geprüft, dann am bisherigen App-Pfad eingesetzt. Die installierten Bundle-Dateien und Symlinks stimmen mit dem signierten Kandidaten überein. Die neue App wurde über ihren vollständigen Pfad gestartet; der beobachtete Prozess lief als PID 43540 aus `/Applications/Overlook.app/Contents/MacOS/Overlook`.

Die gespeicherte Geräteliste war vorhanden. Nach Auswahl desselben KVM verlangte die App erneut dessen Passwort. Wolfgang hat es direkt im sicheren Overlook-Dialog eingegeben; im Chat und in den Nachweisen wurde kein Passwort erfasst. Danach zeigte die native Verbindungsübersicht `Connected`, 1920×1080 und ungefähr 60 fps. Der Steuerungsmodus blieb `manual`; Audio und Firmware-Jiggler waren ausgeschaltet.

Ein frisch gestarteter stdio-Adapter aus der neuen SDK-2.2-Installation lieferte anschließend den tatsächlichen M154-Build im Status und zwei gültige PNG-Snapshots mit 1920×1080. Ihr Alter betrug etwa 195 und 155 ms. Beide gehören derselben Session an; zwischen den Abfragen kam ein neues Frame. Video-, Text- und Mausbereitschaft sind true, der Input ist nicht blockiert und `next_action_seq` bleibt 1. Es wurden keine Remote-HID-Eingaben ausgelöst. Das bestätigt den SDK-2.2 → native Control API → M154-Video-Pfad, aber keine ausgeführte Tastatur-/Mausaktion, Audio-I/O oder tatsächliche Jiggler-Wachhaltewirkung.

Beim ersten Installations-Smoke blieb die HID-Anzeige `Connecting`, obwohl die Mausbereitschaft aus dem tatsächlich verbundenen WebSocket berechnet wurde. Das war der bereits identifizierte Statuslabel-Fehler im Erstverbindungsweg; dieser Rollout ändert seinen Produktcode nicht. Die Nachprüfung nach Codex-Neuladung meldet inzwischen `Connected`.

## Bestätigte Codex-Neuverbindung

Die verfügbare `codex mcp`-CLI bietet keinen Reload-/Reconnect-Befehl. Eine gezielte Computer-Use-Interaktion mit der Codex-App wurde vom Werkzeug mit `Computer Use is not allowed to use the app 'com.openai.codex' for safety reasons` abgelehnt. Es wurde keine alternative UI-Steuerung oder private API als Umgehung verwendet; die alten Adapterprozesse anderer Chats wurden nicht beendet.

Wolfgang hat Codex inzwischen neu geladen. Neu gestartete Adapterprozesse verwenden den konfigurierten Releasepfad; der ESM-Import von `@modelcontextprotocol/server/stdio` löst auf `node_modules/@modelcontextprotocol/server/dist/stdio.mjs` mit SDK 2.2.0 auf. Die tatsächlichen `mcp__overlook_control__overlook_status`- und `overlook_observe`-Aufrufe dieses Chats bestehen. Die Initialize-Antwort mit `serverInfo.version: 1.0.0` bleibt die Adapterversion und wird nicht mit der SDK-Version verwechselt.

Die Nachprüfung erhält den laufenden M154-Prozess und bestätigt HID `Connected`, Video-/Text-/Mausbereitschaft true und `input_blocked:false`. Zwei 1920×1080-Frames derselben Session sind neu und etwa 116 beziehungsweise 206 ms alt; die Abfragen liegen ungefähr 27 Sekunden auseinander. Die Aktionssequenz bleibt 1. Es wurden keine Remote-Eingaben gesendet.

Zusätzlich bestand im WAGO-Projekt ein eigener Alias `mcp_servers.overlook`, der beim ersten Update noch auf den alten SDK-2.0-Pfad zeigte. Dieser eine `args`-Wert in `/Users/doebber/Documents/Wago/.codex/config.toml` wurde nun ebenfalls auf den SDK-2.2-Releasepfad umgestellt. Die übrige Projektkonfiguration bleibt semantisch identisch; der vorherige Inhalt ist mit Modus 0600 gesichert. Die Datei war bereits eine unversionierte Benutzerkonfiguration und wurde nicht als fremder Gesamtstand ins Git übernommen. Bereits gecachte Prozesse dieses zusätzlichen Alias bleiben bis zu ihrer nächsten Neuverbindung auf 2.0. Der aktuell benutzte globale `overlook-control`-Adapter dieses Chats läuft bereits mit 2.2.

## Sicherung und Nachweise

Die Rückfall-App liegt bytegleich unter [Overlook-M109-before-upgrade.app](/Users/doebber/.codex/artifacts/overlook-review-2026-10-02/rollout-m154-mcp22/Overlook-M109-before-upgrade.app). Der frühere App-Pfad wurde beim Austausch zusätzlich nach `/Applications/.Overlook-m109-rollback-20261002.app` erhalten. Die private vollständige Codex-Konfiguration ist separat mit Dateimodus 0600 gesichert und wird nicht ins Git übernommen.

- [Konfigurations- und Sicherungsbeleg](/Users/doebber/.codex/artifacts/overlook-review-2026-10-02/rollout-m154-mcp22/pre-switch-and-config-receipt.json)
- [Installationsbeleg](/Users/doebber/.codex/artifacts/overlook-review-2026-10-02/rollout-m154-mcp22/install-receipt.json)
- [MCP-2.2-/M154-Live-Nachweis](/Users/doebber/.codex/artifacts/overlook-review-2026-10-02/rollout-m154-mcp22/mcp22-m154-live-verification.json)
- [Nachprüfung nach Codex-Neuladung](/Users/doebber/.codex/artifacts/overlook-review-2026-10-02/rollout-m154-mcp22/after-codex-reload-live-verification.json)
- [Korrigierter zusätzlicher Projektalias](/Users/doebber/.codex/artifacts/overlook-review-2026-10-02/rollout-m154-mcp22/project-alias-config-receipt.json)
- [Einzeiliger eigener Projektkonfigurationspatch](2026-10-02-overlook-project-mcp-update.patch), rückwärts gegen die angewandte Änderung geprüft; der fremde Gesamtstand bleibt unversioniert.
- [Vorheriger M109-Checkpoint](2026-10-02-overlook-implementation.md) und [vorbereiteter M154-Spike](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/docs/reviews/2026-10-02-overlook-webrtc154-spike.md)

Der Update-Smoke ist bestanden. Eine länger laufende Geräteabnahme mit echten Eingaben, Reconnect, Audio und Firmware-Jiggler steht noch aus. Keine neuen Geräte-Settings, Zugriffsrechte oder entfernten Inhalte wurden verändert; kein Push und keine Veröffentlichung erfolgten.
