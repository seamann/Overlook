# Overlook: isolierter WebRTC-154-Versuch

Stand: 2. Oktober 2026. Ergebnis: Die tatsächlich verwendeten nativen Swift-
und Objective-C-Pfade kompilieren, linken und bestehen ihre lokalen Tests mit
M154. Eine Freigabe für den laufenden KVM-Betrieb ist damit noch nicht erfolgt.
Der normale Reparaturstand und `/Applications/Overlook.app` verwenden M109.
Der M109-Reparaturbuild wurde inzwischen signiert und nach Freigabe installiert;
M154 ist weiterhin ausschließlich dieser getrennte Versuch.

## Reproduzierbarer Ausgangspunkt

Der eigene Worktree liegt unter
`/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02`, Branch
`codex/overlook-webrtc154-2026-10-02`. Grundlage ist der final integrierte
Reparaturstand des Hauptworktrees vom 2. Oktober. Alle 22 geänderten oder neuen
Reparaturdateien wurden vor der Übernahme gegen
`integrated-repair-source-manifest.json` geprüft. Insgesamt wurden 113
Source-, Test-, Projekt-, MCP- und Dokumentationsdateien synchronisiert und nach der
Kopie per SHA-256 geprüft. Eigene Probe und Dokumentation bleiben erhalten;
anschließend wurden die beiden M154-Pins erneut angewandt.

Der Vergleichsnachweis liegt in `integrated-source-proof.json`. Außer den zwei
Paketpins stimmen sämtliche übernommenen Main-Dateien bytegenau überein.
Der Versuch enthält damit auch den beschränkten Frame-Handoff, die Statistik-
Generationsprüfung, das einzelne Hauptfenster, die Konfigurations- und
Credential-Reparaturen sowie das MCP-Update auf 2.2.

Die Runtime-Quelldateien wurden für den Versuch nicht geändert. Die Änderung
am Projekt ist bewusst auf zwei Dateien begrenzt:

- `project.pbxproj`: `kind = exactVersion`, `version = 154.0.0` statt Bereich ab 109.0.1.
- `Package.resolved`: 154.0.0 mit live verifizierter Git-Revision
  `0c0ad84dac6c1941c16a414dfcfba94691866e4c`. Der alte `originHash` wurde
  entfernt, da er die alte Package-Anforderung beschreibt; der normale
  SwiftPM-/Xcode-Resolver kann ihn nach der Lizenzbestätigung neu erzeugen.

[WebRTC 154.0.0](https://github.com/stasel/WebRTC/releases/tag/154.0.0),
[Package.swift des Tags](https://github.com/stasel/WebRTC/blob/154.0.0/Package.swift)
und [WebRTC 109.0.1](https://github.com/stasel/WebRTC/releases/tag/109.0.1)
sind die primären Paketquellen. Beide offiziellen Archive wurden erneut gegen
ihre veröffentlichten SHA-256-Werte geprüft:

| Version | Archiv-SHA-256 |
| --- | --- |
| 109.0.1 | `28f5fa694cc9ccc36eb5b7ac19305e1fbf0ade03eabfd02cbc0386cda693c9f1` |
| 154.0.0 | `a2bcdda93578c82452ceb6e49d54a2746e1bcb4caf7c2fa601ffac8028b58c16` |

## Praktisch ausgeführte Prüfung

`scripts/test-webrtc-compatibility.sh` verwendet den vorhandenen Compiler der
Command Line Tools mit explizitem SDK 26.5 und Deployment-Target macOS 14.
Es ändert weder `xcode-select` noch die Xcode-Lizenz. Ein Beispiel:

```bash
bash scripts/test-webrtc-compatibility.sh \
  /Users/doebber/.codex/artifacts/overlook-review-2026-10-02/webrtc154-spike/frameworks/m154 \
  /Users/doebber/.codex/artifacts/overlook-review-2026-10-02/webrtc154-spike/integrated-m154
```

Die beiden macOS-Frameworks liegen als bytegeprüfte Kopien im Evidence-Ordner.
Bei einer Wiederholung auf einem anderen Rechner zuerst das offizielle
XCFramework herunterladen und prüfen.

| Prüfung | M109 | M154 |
| --- | --- | --- |
| Vollständiger WebRTCManager mit Peer-, SDP-, Statistik- und Renderer-Aufrufen: Swift-Typecheck | bestanden | bestanden |
| Production-Audiogerät mit AudioUnit-Code und Objective-C-Shim: Typecheck und Link | bestanden | bestanden |
| Unveränderte `WebRTCFactoryBuilder.m`: Objective-C-Compile und Link | bestanden | bestanden |
| Metal-View-Klasse und nativer `renderFrame:`-Selector vorhanden | bestanden | bestanden |
| Production-Audio-Protokoll, lesbare Properties und Idle-Terminierung | bestanden | bestanden |
| Tatsächliche Objective-C-Factory mit Production-Audiogerät erzeugen | bestanden | bestanden |
| Nativen Peer erzeugen, async Statistik lesen und Peer schließen | bestanden | bestanden |
| Bestehende Snapshot-Tests inklusive `RTCVideoFrame`/`RTCCVPixelBuffer` | 17/17 | 17/17 |
| Beschränkter Frame-Handoff inklusive tatsächlichem nativen Renderer | 11/11 | 11/11 |
| Statistik-Request-Identität und spätes Ergebnis nach Peer-/Session-Wechsel | 7/7 | 7/7 |

Die vier zusätzlichen Kompatibilitätstests und die 35 übernommenen Tests
bestehen mit beiden Versionen. Jeder lokale Testprozess hat eine 30-Sekunden-
Frist.
Sie öffnen kein Fenster, wenden kein SDP an und starten keine ICE-Verbindung,
Audiowiedergabe oder Mikrofonaufnahme. Die unveränderten Production-Dateien
werden im Testprogramm mitgelinkt; es werden keine API-Nachbauten verwendet.
Die SDP-Funktionen sind damit quell- und linkkompatibel, ihre Aushandlung mit
Janus bleibt Gegenstand der Hardware-Abnahme.

Beide Versionen zeigen dieselben vorhandenen Compilerwarnungen für
`Optional<CFString>` im CoreAudio-Helfer und einen Sendable-Testdefault im
Snapshot-Test. Es entstand kein versionsspezifischer Compilerfehler.

Logs, Testprogramme, Snapshot-Nachweis und Paketchecks liegen unter
`/Users/doebber/.codex/artifacts/overlook-review-2026-10-02/webrtc154-spike`.
`webrtc154-exact-pin.patch` enthält ausschließlich die zwei Paketänderungen.

## Noch erforderliche Abnahme

Der frühere reguläre M154-Buildversuch endete mit Exit 69 an der damals
fehlenden Apple-Lizenz. Lizenz und First-Launch sind inzwischen regulär
abgeschlossen; der vollständige signierte M109-Build besteht. Ein neuer
vollständiger signierter M154-Build wurde nach dem finalen Sync noch nicht
ausgeführt. Die bisherigen nativen M154-Proben ersetzen diesen Build und die
Abnahme an Janus beziehungsweise der echten KVM-Hardware nicht.

Der finale installierte M109-Quellstand mit Digest
`cec381b605626fa030589e7207cd0eb3730cb12aee88b1112fa848640dad3445`
ist übernommen, einschließlich der späteren Korrektur der kalten
Fensteranbindung. Unter den 113 gemeinsamen Dateien unterscheiden sich nur
die beiden Paketpins; drei eigene Probe-/Script-/Berichtsdateien bleiben
zusätzlich erhalten. Die zuvor mit beiden Frameworks ausgeführten 39 nativen
Fälle bleiben als lokale Kompatibilitätsnachweise dokumentiert. Für den
nachfolgenden Sync wird keine erneute M154-Build- oder Hardware-Abnahme
behauptet. In dieser Reihenfolge weiterprüfen:

1. Regulär mit Xcode bauen und den exakt aufgelösten 154.0.0-Stand im
   `Package.resolved` kontrollieren. Normale Unit-, Integrations- und MCP-Tests
   erneut ausführen.
2. Einen getrennten Test-Build gegen echte GLKVM-Hardware öffnen. Janus-Login,
   SDP-Offer/Answer, ICE und ersten Frame kontrollieren; die Produktions-App
   erst nach bestandener Abnahme ersetzen.
3. Video bei üblichen Auflösungen, Vollbild und längerer Nutzung prüfen.
   Native Snapshots, Crop, Rotation und Fehler bei unterbrochenem Stream
   über den tatsächlichen Agent-Control-Pfad bestätigen.
4. Audio-Ausgabe mit Standardgerät und gewähltem Gerät prüfen. Mikrofon erst
   bei bewusstem Einschalten testen; anschließend Ausschalten, Device-Wechsel
   und keine fortgesetzte Aufnahme kontrollieren.
5. Disconnect, Reconnect, kurze Netzwerkunterbrechung und Wechsel des KVM-
   Endpunkts testen. Statistik und Snapshot dürfen keine Daten der vorherigen
   Verbindung zeigen.
6. Verhalten und Ressourcenverbrauch mit dem gesicherten M109-Build
   vergleichen. Bei einer Abweichung den M109-Build weiterverwenden.

Der Versuch ist für diese nächste Abnahme vorbereitet. M154 bleibt bis dahin
ein eigener Kandidat; ein WebRTC-Upgrade der installierten App auf M154 wurde nicht
vorgenommen.
