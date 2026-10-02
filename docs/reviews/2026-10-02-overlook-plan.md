# Overlook: Review und begrenzte Reparatur, 2. Oktober 2026

Dieser Plan dokumentiert den ursprünglichen Jiggler-Auftrag. Nach Wolfgangs erweitertem Umsetzungsauftrag wurden auch die sinnvollen weiteren Reparaturen und Updates durchgeführt. Der aktuelle Ergebnisstand mit Prüfnachweisen und offenen Freigaben steht im [Umsetzungsbericht](/Users/doebber/.codex/worktrees/overlook-review-2026-10-02/docs/reviews/2026-10-02-overlook-implementation.md).

## Auftrag und Abnahme

Architektur und Code der stabil installierten Overlook-Version erneut prüfen, den unzuverlässigen Mouse Jiggler gezielt verbessern und Updates der Fork-Grundlage bewerten. Der bestehende Betrieb ist die Leitplanke. Die laufende App wird für dieses Review weder ersetzt noch neu gestartet.

Der Auftrag erlaubt lokale Analyse, Reparatur, Tests und Vorbereitung. Veröffentlichung, Push und Änderungen an externen Systemen bleiben gesondert freizugeben. Wolfgang hat die getrennte lokale Sicherung des nachgewiesenen stabilen Quellstands und der neuen Reparatur ausdrücklich freigegeben.

## Nachgewiesene Grundlage

- Installierte App: `/Applications/Overlook.app`.
- Installierte Build-ID: `52f2ee6e9506-44a20a59fcb10b78-devsigned`.
- Git-Basis: `52f2ee6e95066637cfc44fe485beaa88841d3d41`.
- Quellstand: `/Users/doebber/Documents/Wago/work/overlook-session-refactor-2026-09-15`.
- Vollständiger Build-Quellfingerabdruck am Beginn: `44a20a59fcb10b7894821d9834eb26d6294768241134d4d79acf65ddfc7ac59e`. Er stimmt mit der installierten Info.plist überein.
- Isolierte Reparatur: `/Users/doebber/.codex/worktrees/overlook-review-2026-10-02`, Branch `codex/overlook-review-2026-10-02`.
- Originalstand und vorhandene Änderungen werden erhalten; Prüflogs und Dateimanifest liegen unter `/Users/doebber/.codex/artifacts/overlook-review-2026-10-02`.

Der ältere Checkout `work/Overlook-agent` enthält bereits behobene Verbindungsprobleme und ist keine geeignete Grundlage für neue Befunde über den laufenden Betrieb.

## Architektur und Experten

Die native SwiftUI/AppKit-App komponiert Device-, Session-, Input-, WebRTC-, OCR-, Modus- und Control-API-Komponenten. Der TypeScript-MCP-Adapter spricht mit dem authentifizierten lokalen TCP-Server. Die bestehenden Session- und Capture-Verträge bleiben erhalten.

Parallele lokale Experten: Architektur, Swift-Codeprüfung, Upstream-/Dependency-Recherche, Jiggler-Planung und Security. Die Umsetzung folgt dem TDD-Experten; anschließend prüft ein unabhängiger Reviewer die endgültige Änderung. Es werden keine externen Agenten beauftragt und keine WAGO-Dokumente zur Recherche hochgeladen.

Verwendete Arbeitsmethoden: `a-team:architecture-audit`, `a-team:dispatching-parallel-agents` und Awesome/Aegis `writing-plans`. Befunde benötigen aktuelle Codeanker und konkrete Folgen.

## Minimale notwendige Codeänderung

Overlook erzeugt keine eigenen Jiggler-Mausbewegungen. Es schaltet die Firmwarefunktion `mouse_jiggle`. Headless deaktiviert diese Funktion für präzise Agenteneingaben; der vorher eingeschaltete Zustand wird beim Wechsel zurück zu Manual bislang nicht wiederhergestellt. Außerdem kann ein alter oder fehlgeschlagener Zustandsabruf die Anzeige unbrauchbar lassen. Eine reine Dokumentationsänderung behebt diese Abläufe nicht.

Der Umfang bleibt bei der Firmwarefunktion: vorher aktiven Zustand sessiongebunden merken, Headless-Deaktivierung bestätigen und nach Rückkehr zu Manual erst nach Abschluss laufender Remote-Aktionen wiederherstellen. Ein zuvor ausgeschalteter Jiggler bleibt ausgeschaltet. Neue manuelle Entscheidungen und neue Sessions gewinnen. Veraltete Refresh-Aufträge dürfen weder Zustand noch Task-Eigentümerschaft überschreiben. Vorübergehende Abruffehler erhalten wenige begrenzte Wiederholungen.

Eigene HID-Bewegungstimer, Änderungen am Remote-Desktop, ein neuer Einstellungsstandard, ein Architekturumbau und ein gleichzeitiges WebRTC-Upgrade gehören nicht in diese Reparatur.

Review-Korrektur: Die Rückkehr zu Manual behält ihre bisherige Reihenfolge bei: Remote-Eingaben abarbeiten, gültigen Modus prüfen und lokale Erfassung freigeben. Erst anschließend wird der Jiggler im selben kontrollierten Task wiederhergestellt. Die Firmwareantwort verzögert dadurch keine lokalen Manual-Eingaben. Cancellation und Sessionwechsel gelten auch für diesen nachgelagerten Schritt.

## TDD und Aufgaben

TDD Route: strict, aufgrund der Projektregeln und der Verhaltensänderung. Neue Verhaltenstests müssen zuerst am unveränderten Produktionscode scheitern. Die vorhandenen Swift-, HID-, Session- und MCP-Tests bilden die Regression.

1. Baseline nachweisen: installierte Metadaten, vollständiger Quellfingerabdruck, unveränderte Originaldateien und bestehende Tests.
2. Synthetische lokale GET/POST-Fixtures schreiben: aktiver Jiggler → Headless aus → Manual nach Drain wieder an; vorher aus; Deaktivierungsfehler; neue manuelle Entscheidung; erneutes Headless; Disconnect/Reconnect; alter Refresh; vorübergehender GET-Fehler. Keine Geräte, echten Tokens, Keychain oder Nutzerdefaults in Tests.
3. Minimale Reparatur im bestehenden Besitzer `KVMDeviceManager` und dem gemeinsamen Modus-/Drain-Ablauf implementieren. Integration in `ContentView`, `OverlookApp` und bestehendem Testskript. Neue Tests unter `tests/MouseJigglerLifecycleTests.swift`.
4. Neue Logik gezielt mit mindestens 80 % messbarer Abdeckung prüfen. Keine pauschale Gesamtabdeckung der App behaupten.
5. Unabhängiges Code- und Security-Review; relevante Tests, Typecheck und Dependency-Audit. Änderungen und Prüfgrenzen dokumentieren.
6. Lokale Basis und Reparatur entsprechend der ausdrücklichen Freigabe getrennt sichern. Keine historischen Änderungen in den Reparatur-Commit aufnehmen. Der Patch gegen den nachgewiesenen Stand bleibt als zusätzlicher Nachweis erhalten.

## Verifikation und verbleibende Grenze

`scripts/test-agent-control.sh all` prüft lokale Fixtures. MCP-Baseline: 62 Tests bestanden. `npm audit` meldet keine bekannten Schwachstellen. Die Swift-Suites werden mit dem vorhandenen Command-Line-Tools-Compiler und explizitem SDK/Deployment-Target ausgeführt.

Der reguläre Xcode-Aufruf ist aktuell durch den Lizenzzustand blockiert. Eine Lizenz wird hier nicht stellvertretend akzeptiert. Ein Typecheck oder Fixturetest ist keine Release-Build- oder Live-KVM-Abnahme. Vor Installation sind ein regulärer signierter Build und die Prüfung von Video, Eingabe, Headless/Manual-Wechsel, Reconnect sowie tatsächlichem Wachhalten erforderlich. Diese Abnahme wird erst mit einem konkreten geprüften Ergebnis vorbereitet.

## Update- und weitere Review-Arbeiten

Upstream-, MCP- und WebRTC-Ergebnisse werden mit Datum, Version und primären Quellen in einem Ergebnisbericht festgehalten. Updates werden nach ihrem Nutzen und ihrem Risiko eingeordnet. Ein Upstream-Merge oder WebRTC-Sprung wird nicht mit der Jiggler-Reparatur gekoppelt.

Die bisher bestätigten weiteren Architekturpunkte sind begrenzte Frame-Übergabe an den MainActor, ein klarer Vertrag für das einzelne Hauptfenster und generationsgebundene Statistikantworten. Sie bleiben gesonderte, priorisierte Arbeiten; die vorhandene Session-/Capture-Struktur muss dafür nicht ersetzt werden.
