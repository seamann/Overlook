# Overlook: 50 fachliche Diskussionsrunden

Stand: 5. Oktober 2026. Quellenbasis: 5f25347f5a568da4230f45e3f6320b03f16b31e4. Keine Produktimplementierung.

Jede Runde enthält den eröffnenden Vorschlag, eine echte Kreuzprüfung, die unabhängige Architektur-Gegenposition und die Entscheidung des Hauptagenten. Rohpositionen sind keine verabschiedeten Änderungen; insbesondere ihre ursprünglichen Prioritäten und Akzeptanzvorschläge bleiben im JSON nachvollziehbar. Zusammengeführte Themen erzeugen keine zusätzlichen Arbeitspakete.

Die Runden wurden in fünf parallelen Themenblöcken und anschließenden Gegenprüfungen bearbeitet, nicht als 50 Vollversammlungen aller Agenten.

Entscheidungen: 17 präzisieren, 16 empfehlen, 6 erst prüfen, 7 zusammenführen, 4 zurückstellen. P1 bezeichnet hier zentrale offene Geräteabnahme, keinen heute nachgewiesenen P1-Ausfall. A: Belege/Lifecycle/Geräteabnahme; B: Bedienung/kleiner Entwicklerweg; C: Bedarf zuerst belegen. Aufwand S/M/L ist eine relative Expertenschätzung, keine Termin- oder Budgetzusage.

[Priorisierung](2026-10-05-overlook-expertenreview.md) · [Vollständiger strukturierter Nachweis](2026-10-05-overlook-50-runden.json)

<a id="r01"></a>

## R01 – Verbindung und tatsächliche Bedienbereitschaft verständlich trennen

Eröffnung: `UX Researcher`. Evidenz: aktuell quellbelegt; Konsequenz hier nicht zwingend ausgeführt. Endbewertung: **präzisieren**, P2, Paket B; ursprüngliche Aufwandsschätzung M.

**Ausgangspunkt:** Eine vorhandene API-Session kann Connected anzeigen, obwohl Bild oder HID noch fehlen. Das ist ein bewusst unterstützter Teilzustand. Die Oberfläche erklärt dessen Bedeutung für die nächste Nutzeraktion nur über technische Einzelwerte.

**Vorschlag:** Eine gemeinsame, auf die Aufgabe bezogene Anzeige für Session, aktuelles Bild und Eingabebereitschaft verwenden. Beispiele: Verbindung steht, Bild fehlt; Eingabe angehalten; Manual wartet auf Freigabe. Technische WebRTC-Werte weiterhin als aufklappbare Diagnose anbieten.

**Kreuzprüfung (UI Designer):** Transportbereitschaft ist nicht lokale Eingabebereitschaft: Fokus, offene Panels und Headless sperren lokale Eingabe absichtlich. Eine gemeinsame Ampel könnte diese normalen Zustände als Ausfall darstellen.

**Architektur-Gegenposition:** Connected bezeichnet absichtlich die API-Verbindung; daraus folgt kein Verbindungsbug. P2-Anzeigeverbesserung aus vorhandenen Ownern, ohne neue autoritative Zustandsmaschine. R11/R30 zusammenführen.

**Entscheidung:** Vorhandene Session-, Video- und Eingabezustände als reine Anzeige bündeln. Teilverfügbarkeit und absichtliche lokale Sperren bleiben gültig; keine neue globale Zustandsmaschine.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Transportzustand und Eingabebesitz getrennt benennen. Geöffnetes Panel und Headless sind keine Fehler. VoiceOver erhält eine verständliche Zusammenfassung ohne fortlaufende Statistikansagen.

Quellanker der Eröffnung:

- [ContentView.swift:51](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:51) – Connected wird allein aus connectedDevice abgeleitet.
- [ContentView.swift:1289](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:1289) – Die Verbindungsübersicht zeigt daraus Connected oder Disconnected.
- [SessionConnectionCoordinatorTests.swift:174](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/tests/SessionConnectionCoordinatorTests.swift:174) – Der Test erhält die API-Verbindung ausdrücklich trotz fehlgeschlagenem Videostart.
- [InputManager.swift:351](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/InputManager.swift:351) – Text- und Mausbereitschaft existieren als getrennte transportbezogene Werte.

<a id="r02"></a>

## R02 – Verbindungsaufbau im Connections-Panel abbrechbar machen

Eröffnung: `UX Researcher`. Evidenz: aktuell quellbelegt; Konsequenz hier nicht zwingend ausgeführt. Endbewertung: **empfehlen**, P2, Paket B; ursprüngliche Aufwandsschätzung S.

**Ausgangspunkt:** Im Connections-Panel gibt es während eines Verbindungsversuchs einen Spinner, aber keine Abbruchaktion. Der vorhandene Abbruch ist über das separate Menüleistenmenü erreichbar. Das Schließen des Panels beendet den Versuch nicht.

**Vorschlag:** Am laufenden Versuch eine lokale Aktion Verbindung abbrechen anbieten und dieselbe Coordinator-Funktion verwenden. Nach Abbruch Auswahl und unkritische Hostdaten für einen korrigierten Versuch behalten.

**Kreuzprüfung (UI Designer):** Abbrechen ist sinnvoll am Spinner, darf aber nicht mit Panel schließen gleichgesetzt werden. Hintergrundverbindung und vorhandener Menüleistenabbruch sind gültige bestehende Wege.

**Architektur-Gegenposition:** Der Abbruch funktioniert bereits über Menüleiste und Coordinator; keine erneute Konkurrenzreparatur nötig. Kleine P2-Erreichbarkeitslücke am wartenden Panel ist belegt.

**Entscheidung:** Abbruch am Verbindungsversuch anbieten und den vorhandenen Coordinator verwenden. Panel schließen bleibt eine eigenständige Handlung.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Expliziten Versuch-Abbruch per Tastatur und VoiceOver erreichbar halten; nach Abbruch Fokus zur Gerätewahl. Keine späte Passwortfrage, keine HID-Eingabe und kein gespeichertes Passwort.

Quellanker der Eröffnung:

- [ContentView.swift:1254](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:1254) – Connect wird während des Aufbaus zu Connecting und deaktiviert.
- [SessionConnectionCoordinator.swift:99](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/SessionConnectionCoordinator.swift:99) – Ein kontrollierter Disconnect mit synchroner Invalidierung ist vorhanden.
- [SessionConnectionCoordinatorTests.swift:63](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/tests/SessionConnectionCoordinatorTests.swift:63) – Abbruch während Vorbereitung ist bereits als Verhaltensfall abgesichert.
- [MenuBarAgent.swift:259](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/MenuBarAgent.swift:259) – Der Menüleisten-Disconnect ist während Connecting bereits verfügbar.

<a id="r03"></a>

## R03 – Lokalen Reconnect auch während Headless erreichbar halten

Eröffnung: `UX Researcher`. Evidenz: aktuell quellbelegt; Konsequenz hier nicht zwingend ausgeführt. Endbewertung: **präzisieren**, P2, Paket B; ursprüngliche Aufwandsschätzung S.

**Ausgangspunkt:** Die Headless-Sperre umfasst im Code neben Remote-Mausaktionen auch den eingebetteten lokalen Reconnect-Button. Ein Pointer-Klick auf diese Wiederherstellung ist daher im Headless-Pfad gesperrt. Das ist aus dem View-Aufbau abgeleitet, noch nicht nativ ausgeführt.

**Vorschlag:** Lokale Wiederherstellungsaktionen außerhalb der gesperrten Remote-Eingabefläche platzieren. Reconnect soll ausdrücklich eine neue Verbindung herstellen und keine HID-Aktion wiederholen; eine zusätzliche Manual-Umschaltung soll dafür nicht erforderlich sein.

**Kreuzprüfung (UI Designer):** Die Formulierung ohne Moduswechsel widerspricht dem bestehenden vollständigen Reconnect: Session-Invalidierung setzt bewusst Manual. Headless automatisch wiederherzustellen würde eine Sicherheitsregel ändern und Agentenarbeit überlagern.

**Architektur-Gegenposition:** Vollständiger Reconnect setzt absichtlich Manual; Headless-Erhalt würde neue Eingabeautorität erteilen. Lokale Erreichbarkeit korrigieren, bestehenden Modusvertrag erhalten. Ein separater Medien-Reconnect ist eine andere Entscheidung.

**Entscheidung:** Lokale Reconnect-Aktion außerhalb der Remote-Hit-Testing-Sperre platzieren. Ein vollständiger neuer Verbindungsaufbau fällt weiterhin bewusst nach Manual zurück; Headless nicht automatisch wiederherstellen.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Lokalen Reconnect außerhalb der gesperrten Fläche anbieten, Unterbrechung und Rückkehr zu Manual erklären. Alte Aktionsberechtigungen bleiben ungültig. Einen reinen Video-Reconnect separat spezifizieren.

Quellanker der Eröffnung:

- [ContentView.swift:249](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:249) – Die gesamte VideoSurfaceView erhält in Headless kein Hit-Testing.
- [ContentView.swift:261](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:261) – Dieselbe Sperre gilt außerhalb des Vollbilds.
- [VideoSurfaceView.swift:136](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/VideoSurfaceView.swift:136) – Der lokale Reconnect-Button ist innerhalb dieser VideoSurfaceView angeordnet.

Ergänzung/Korrektur der Gegenprüfung: [OverlookApp.swift:45](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/OverlookApp.swift:45) – invalidateSession setzt bei vollständigem Neuaufbau ausdrücklich Manual.

<a id="r04"></a>

## R04 – Freigabe nach unbekanntem Eingabeergebnis als vollständige Wiederherstellung prüfen

Eröffnung: `UX Researcher`. Evidenz: belegte Prüf-/Abnahmelücke; kein damit bewiesener Produktdefekt. Endbewertung: **erst prüfen**, P2, Paket A; ursprüngliche Aufwandsschätzung M.

**Ausgangspunkt:** Die konservative Eingabesperre und explizite Manual-Prüfung sind vorhanden. Die gelesenen Tests beweisen keine verständliche vollständige Wiederherstellung über den Banner. Der Banner unterscheidet fehlenden Transport, Sessionwechsel und fehlgeschlagenes Release nicht.

**Vorschlag:** Den bestehenden Ablauf mit synthetischen Zuständen vom unbekannten Ergebnis bis zur bestätigten Freigabe testen. Kontext nur als Aktionstyp und Zeitpunkt anzeigen; Fehlermeldung mit passendem nächsten Schritt verbinden. Keine automatische Wiederholung der ursprünglichen Eingabe ergänzen.

**Kreuzprüfung (UI Designer):** Mehr Fehlertypen helfen, können aber eine automatische Remote-Prüfung suggerieren. Die vorhandene Freigabe bestätigt technische Eingabefreigabe nach eigener Prüfung, keine erfolgreiche fachliche Ausführung.

**Architektur-Gegenposition:** Release und Eingabesicherheitslogik sind implementiert; der offene Beleg betrifft Bannerverständlichkeit und Darstellung. P2 auf bestehende Fehlerarten und nächsten lokalen Schritt begrenzen; keine zusätzliche Aktionshistorie voraussetzen.

**Entscheidung:** Bestehenden Recovery-Ablauf mit synthetisch unbekanntem Ergebnis und Releasefehler abnehmen. Technische Freigabe und fachlichen Zielerfolg ausdrücklich auseinanderhalten.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Eigene Prüfung, Release und fortbestehende Sperre sprachlich unterscheiden. VoiceOver meldet Ergebnis und nächsten Schritt einmal. Fokus bleibt auf Wiederherstellung; kein Originaltext und keine automatische Wiederholung.

Quellanker der Eröffnung:

- [ContentView.swift:153](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:153) – Der Banner verlangt bereits eigene Remote-Prüfung und erklärt, dass Text nicht zurückgenommen wird.
- [ContentView.swift:169](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:169) – Jeder Freigabefehler erhält dieselbe allgemeine Meldung.
- [InputManager.swift:884](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/InputManager.swift:884) – Freigabe benötigt einen Release-Transport und kann inputUnavailable liefern.
- [InputManagerGLKVMTests.swift:112](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/tests/InputManagerGLKVMTests.swift:112) – Der gelesene Recovery-Test prüft fehlenden Release-Transport, nicht den gerenderten erfolgreichen Bannerablauf.

<a id="r05"></a>

## R05 – Modusübergabe und automatisch pausierten Jiggler sichtbar erklären

Eröffnung: `UX Researcher`. Evidenz: aktuell quellbelegt; Konsequenz hier nicht zwingend ausgeführt. Endbewertung: **präzisieren**, P2, Paket B; ursprüngliche Aufwandsschätzung M.

**Ausgangspunkt:** Die reparierte Übergabe wartet auf laufende Eingaben und stellt einen zuvor aktiven Jiggler wieder her. Die Oberfläche zeigt überwiegend den Modusnamen, eine deaktivierte Auswahl und einen Jiggler-Spinner. Off erklärt nicht, ob der Nutzer ausgeschaltet hat oder Headless bewusst pausiert.

**Vorschlag:** Übergangsfeedback wie Headless wird vorbereitet oder Manual wartet auf laufende Eingabe ergänzen. Beim Jiggler Pausiert für Headless und Wiederherstellung läuft unterscheiden; den bestätigten Firmwarezustand weiterhin separat halten.

**Kreuzprüfung (UI Designer):** Pausiert für Headless ist nur für einen zuvor aktiven Jiggler zutreffend. Ein ohnehin ausgeschalteter oder nicht unterstützter Jiggler darf dadurch keine Wiederherstellungszusage erhalten.

**Architektur-Gegenposition:** Jiggler-Pause und Wiederherstellung sind bereits abgesichert; zusätzliche Übergangstexte beweisen keine Wachhaltewirkung. P2 nur Pausengrund und anhaltendes Warten erklären. Tatsächliche Wirkung separat unter R45 priorisieren.

**Entscheidung:** Nur belegte Übergänge und gespeicherten Resume-Intent anzeigen. Ein schon ausgeschalteter oder nicht unterstützter Jiggler ist nicht für Headless pausiert.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Off, automatisch pausiert, nicht unterstützt und Wiederherstellung ausstehend unterscheiden. Accessibility-Wert und sichtbarer Status widersprechen sich nicht. Manual-Freigabe bleibt unabhängig vom verzögerten Firmware-POST.

Quellanker der Eröffnung:

- [ContentView.swift:120](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:120) – Die Jiggler-Hilfe kennt Updating, Unavailable und On/Off, aber keinen Headless-Pausengrund.
- [ContentView.swift:759](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:759) – Vor Headless wird der Firmware-Jiggler bewusst pausiert.
- [ControlMode.swift:83](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ControlMode.swift:83) – Manual-Eingabe wird erst nach dem Drain wieder freigegeben.
- [MouseJigglerLifecycleTests.swift:87](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/tests/MouseJigglerLifecycleTests.swift:87) – Manual-Freigabe und spätere Jiggler-Wiederherstellung sind bewusst entkoppelt.

<a id="r06"></a>

## R06 – Automatische Settings-Übernahme mit bestätigtem Ergebnis und Fehlerentwurf verbinden

Eröffnung: `UX Researcher`. Evidenz: aktuell quellbelegt; Konsequenz hier nicht zwingend ausgeführt. Endbewertung: **präzisieren**, P2, Paket B; ursprüngliche Aufwandsschätzung M.

**Ausgangspunkt:** Ein geänderter Toggle erscheint sofort, während der Remote-Apply verzögert startet. Schließen kann den ausstehenden Auftrag abbrechen. Nach einem Fehler können die sichtbaren Entwurfswerte daher von der übernommenen Gerätekonfiguration abweichen; ein Spinner allein erklärt diesen Unterschied nicht.

**Vorschlag:** Den Auto-Apply-Vertrag im Panel nennen und pro Änderungsgruppe Ausstehend, Übernommen oder Unbestätigt anzeigen. Bei Fehlern Entwurf und bestätigten Zustand unterscheidbar halten. Vor dem Schließen ausstehende Änderungen erkennbar behandeln und eine bewusste Korrektur oder Verwerfung ermöglichen.

**Kreuzprüfung (UI Designer):** Verwerfen kann einen bereits gesendeten POST nicht rückgängig machen. Ein Schließen-Dialog mit Save/Discard würde falsche Kontrolle versprechen und den schnellen Auto-Apply-Ablauf belasten.

**Architektur-Gegenposition:** Die Reparatur der Bearbeitungsmenge ist vorhanden; fehlendes Übernahmefeedback rechtfertigt keinen neuen Konfigurations-Owner. P2 auf ausstehenden beziehungsweise unbestätigten Entwurf begrenzen; explizites Save-System wäre zusätzlicher Scope.

**Entscheidung:** Ausstehende, beantwortete und unbestätigte Settings-Schreibvorgänge sichtbar machen. Verwerfen betrifft höchstens ungesendete Entwürfe; ein gesendeter POST wird dadurch nicht zurückgenommen.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Noch nicht gesendet, gesendet/unbestätigt und bestätigter Zustand unterscheiden. Schließen darf keine Rücknahme zusagen. Erneutes Öffnen liest den Gerätezustand; Fehlerstatus bleibt auch mit VoiceOver verständlich.

Quellanker der Eröffnung:

- [WebUISettingsPanel.swift:1216](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebUISettingsPanel.swift:1216) – Der lokale Entwurf wird vor dem Remote-Apply aktualisiert.
- [WebUISettingsPanel.swift:1228](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebUISettingsPanel.swift:1228) – Konfigurationsänderungen werden nach 150 ms automatisch angewendet.
- [WebUISettingsPanel.swift:721](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebUISettingsPanel.swift:721) – Panel schließen bricht Apply-Aufträge ab und verwirft den lokalen Entwurf.
- [WebUISettingsPanel.swift:1252](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebUISettingsPanel.swift:1252) – Ein bestätigtes Apply ersetzt den Entwurf und leert die Änderungsmenge.

<a id="r07"></a>

## R07 – Reset KVM als begrenzte Eingabe- und Video-Wiederherstellung beschreiben

Eröffnung: `UX Researcher`. Evidenz: aktuell quellbelegt; Konsequenz hier nicht zwingend ausgeführt. Endbewertung: **empfehlen**, P2, Paket B; ursprüngliche Aufwandsschätzung S.

**Ausgangspunkt:** Reset KVM bezeichnet eine sequenzielle Wiederherstellung von HID und Streamer, keinen im Code sichtbaren vollständigen Geräte-Neustart. Es gibt keine eigene Busy-Sperre und keine Rückmeldung, welcher Teil bereits abgeschlossen ist.

**Vorschlag:** Die Aktion als Eingabe und Video zurücksetzen benennen und ihre Unterbrechungswirkung kurz erklären. Während der Ausführung erneute Betätigung sperren. Teilerfolg sichtbar melden; bei Bedarf später einzelne HID- und Video-Aktionen anbieten.

**Kreuzprüfung (UI Designer):** Die präzisere Benennung ist sinnvoll. Erfolgreiche Reset-Antworten beweisen jedoch noch kein aktuelles Bild oder funktionierende Eingabe; Teilfeedback darf diese Wiederherstellung nicht vorwegnehmen.

**Architektur-Gegenposition:** Sessionwechsel wird bereits zwischen HID- und Streamerreset geprüft; das ist kein offener Ownershipbug. Benennung und fehlende Busy-Sperre sind konkrete kleine P2-Lücken.

**Entscheidung:** Reset präzise benennen, Doppelauslösung sperren und HID-/Streamer-Teilerfolg melden. Reset-Antwort ist noch keine Gerätefunktionsabnahme.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Busy bleibt sichtbar und gesprochen, Doppelauslösung gesperrt. Teilmeldungen nennen bestätigte Reset-Anfragen, erst zusätzliche Zustandsevidenz behauptet Bedienbereitschaft. Kein obligatorischer Bestätigungsdialog für jeden Rettungsversuch.

Quellanker der Eröffnung:

- [WebUISettingsPanel.swift:665](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebUISettingsPanel.swift:665) – Die Aktion heißt Reset KVM und ist nur bei fehlendem Client deaktiviert.
- [WebUISettingsPanel.swift:1291](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebUISettingsPanel.swift:1291) – Die Umsetzung setzt zuerst HID und danach den Streamer zurück.
- [WebUISettingsPanel.swift:1297](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebUISettingsPanel.swift:1297) – Fehler beider Teilaktionen werden gemeinsam als Failed to reset gemeldet.

<a id="r08"></a>

## R08 – Fehler dem betroffenen Vorgang zuordnen

Eröffnung: `UX Researcher`. Evidenz: aktuell quellbelegt; Konsequenz hier nicht zwingend ausgeführt. Endbewertung: **empfehlen**, P2, Paket B; ursprüngliche Aufwandsschätzung S.

**Ausgangspunkt:** Eine weiterhin bestehende Verbindung kann einen Connection-Failed-Dialog auslösen, weil der Jiggler oder die Modusvorbereitung scheitert. Die allgemeine Überschrift lenkt den Nutzer auf den falschen Wiederherstellungsweg.

**Vorschlag:** Eine kleine strukturierte Meldung mit Vorgang, Ergebnis und passender nächster Aktion verwenden. Verbindung, Headless-Vorbereitung, Jiggler und Credential-Speicherung erhalten eigene Titel; Detailtext bleibt kopierbar. Wiederholen nur anbieten, wenn das Ergebnis sicher und wiederholbar ist.

**Kreuzprüfung (UI Designer):** Passende Titel beseitigen die falsche Verbindungsaussage. Zusätzliche Retry-Buttons könnten dennoch Aktionen wiederholen, deren Ergebnis unbekannt ist; OK bleibt für solche Fälle legitim.

**Architektur-Gegenposition:** Der falsche Alerttitel ist belegt; eine allgemeine Fehlerframework-Reform oder Retry-Oberfläche ist dafür unnötig. Kleine P2-Zuordnung nach Vorgang; R18 als Accessibility-Abnahme integrieren.

**Entscheidung:** Kleine aktionsgebundene Fehlermeldung einführen. Keine generische Retry-Schaltfläche für unbekannte Eingabewirkung.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Vorgang und Folgen vorlesen; nächster Schritt ist konkret und ohne Farbe verständlich. Retry nur bei bekanntem wiederholbarem Ergebnis. Nach Schließen kehrt Fokus zur betroffenen lokalen Funktion zurück.

Quellanker der Eröffnung:

- [ContentView.swift:447](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:447) – Jiggler-Fehler werden in connectionErrorMessage übernommen.
- [ContentView.swift:548](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:548) – Bis auf Credential-Warnungen heißt derselbe Alert Connection Failed.
- [ContentView.swift:735](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:735) – Auch die lokale Headless-Voraussetzung verwendet connectionErrorMessage.
- [ContentView.swift:554](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:554) – Der Alert bietet nur OK.

<a id="r09"></a>

## R09 – Manuelle Verbindung vor dem Absenden verständlich validieren

Eröffnung: `UX Researcher`. Evidenz: aktuell quellbelegt; Konsequenz hier nicht zwingend ausgeführt. Endbewertung: **präzisieren**, P2, Paket B; ursprüngliche Aufwandsschätzung M.

**Ausgangspunkt:** Ein Host reicht zum Absenden; ungültiger Porttext wird still als 443 behandelt. Die Passwortnachfrage im Hauptfenster verliert außerdem den sichtbaren Zielkontext, während der Menüleistenpfad einen Gerätenamen nennt.

**Vorschlag:** Host und Port mit einer gemeinsamen Endpoint-Auswertung vor dem Schließen prüfen. Feldfehler direkt am Formular zeigen und unkritische Eingaben bewahren. Die Passwortnachfrage nennt Gerät und tatsächlich verwendeten Host:Port; Passwort wie bisher sofort aus dem View-Zustand entfernen.

**Kreuzprüfung (UI Designer):** Validierung darf gültige DNS-Namen, eingefügte Adressen und vereinbarte IPv6-Formen nicht durch eine enge Regex ausschließen. Passwortlöschung darf korrigierbare Feldfehler nicht unnötig zur erneuten Eingabe zwingen.

**Architektur-Gegenposition:** Stiller Portersatz ist belegt; beliebige neue Endpointformen dürfen daraus nicht als unterstützt gelten. P2-Validierung an bestehender Transportgrenze und Zielkontext; R16 integrieren.

**Entscheidung:** Endpoint gemeinsam auswerten und Portfehler vor dem Absenden zeigen; Zielkontext im Passwortdialog ergänzen. Gültige DNS-/IPv6-Eingaben und bestehende Passwortlöschung erhalten.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Akzeptierte Endpoint-Formen festlegen; Validierung vor Credential-Snapshot und Sheet-Schließen. Fehler am Feld anzeigen und einmal ansagen, Fokus auf fehlerhaftes Feld. Host/Port erhalten, Passwort nach tatsächlicher Absendung löschen.

Quellanker der Eröffnung:

- [ReliabilityPolicies.swift:662](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ReliabilityPolicies.swift:662) – Die Formularfreigabe verlangt lediglich einen nichtleeren Host.
- [ContentView.swift:679](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:679) – Ein nicht numerischer Port fällt still auf 443 zurück.
- [ConnectSheets.swift:73](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ConnectSheets.swift:73) – Der Hauptfenster-Passwortdialog nennt keinen Gerätenamen oder Endpoint.
- [ReliabilityPolicyTests.swift:736](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/tests/ReliabilityPolicyTests.swift:736) – Die gelesenen Formulartests prüfen Host vorhanden/leer, nicht korrigierbare Endpointfehler.

<a id="r10"></a>

## R10 – Tastatur- und VoiceOver-Bedienung der lokalen Oberfläche gezielt validieren

Eröffnung: `UX Researcher`. Evidenz: ungeprüfte Hypothese; Produktänderung erst nach Bedarf oder Reproduktion. Endbewertung: **erst prüfen**, P2, Paket B; ursprüngliche Aufwandsschätzung M.

**Ausgangspunkt:** Die lokale Eingabesicherheit ist gut abgedeckt. Für VoiceOver-Namen, Fokus auf geöffneten Panels, unsichtbare Panelinhalte und Vollbildbedienung liegt aus diesem Review kein Ausführungsnachweis vor. Der View-Aufbau begründet konkrete Prüffälle, beweist aber noch keine Barriere.

**Vorschlag:** Eine kleine native Prüfung mit synthetischen Verbindungszuständen planen: Connect, Abbruch, Moduswechsel, Fehlerdialog, Settings öffnen/schließen und Recovery. Fokus beim Öffnen und Schließen definieren, unsichtbare Panels aus der Accessibility-Navigation nehmen und symbolische Aktionen eindeutig benennen, soweit die Prüfung Bedarf zeigt.

**Kreuzprüfung (UI Designer):** Alle lokalen Aufgaben ist als pauschale Abnahme zu breit. Native Semantik kann bereits funktionieren; Remote-Pixelinhalte werden dadurch nicht VoiceOver-zugänglich. Fehlende explizite Labels allein beweisen keinen Defekt.

**Architektur-Gegenposition:** Fehlende native Prüfung beweist keine Accessibility-Verletzung; Capture-Tests sichern einen anderen Vertrag. Begrenzte Abnahmematrix zuerst; Produktänderungen nur aus konkretem Ergebnis. R12–R14/R19/R20 darin bündeln.

**Entscheidung:** Lokale native Tastatur-/VoiceOver-Matrix mit synthetischen Zuständen. Keine Behauptung über Remote-Pixelzugänglichkeit oder bereits nachgewiesene Barrieren.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Benannte lokale Aufgaben in Fenster/Vollbild mit synthetischen Zuständen prüfen. Namen, Fokusfolge, unsichtbare Panels und Textfit separat dokumentieren; Änderungen nur bei Befund. Remote-Inhalt und allgemeine WCAG-Konformität bleiben außerhalb dieser Abnahme.

Quellanker der Eröffnung:

- [ContentView.swift:336](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:336) – Das Settings-Panel bleibt auch geschlossen im View-Baum, nur Offset und Hit-Testing ändern sich.
- [ContentView.swift:221](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:221) – Vollbildaktionen werden über zeitverzögerten Pointer-Hover sichtbar.
- [WebUISettingsPanel.swift:221](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebUISettingsPanel.swift:221) – Der Settings-Schließen-Button ist ein reines Symbol ohne explizites Accessibility-Label.
- [InputManagerCaptureTests.swift:13](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/tests/InputManagerCaptureTests.swift:13) – Vorhandene Tests prüfen lokale Editor-/Eingabegrenzen, keine VoiceOver-Namen oder SwiftUI-Fokusfolge.

<a id="r11"></a>

## R11 – Geräteverbindung, Videofrische und Eingabebereitschaft getrennt anzeigen

Eröffnung: `UI Designer`. Evidenz: aktuell quellbelegt; Konsequenz hier nicht zwingend ausgeführt. Endbewertung: **zusammenführen**, P2, Paket B; ursprüngliche Aufwandsschätzung M.

**Ausgangspunkt:** Die Oberfläche besitzt bereits wichtige Verlust- und Sperrmeldungen. Der allgemeine Begriff Connected im Gerätepanel kann daneben weiterhin die Geräteverbindung beschreiben und sagt damit wenig darüber, ob ein aktuelles Bild oder nutzbare Eingabe vorhanden ist.

**Vorschlag:** Eine kleine gemeinsame Statusdarstellung verwenden: Gerät verbunden, Video aktuell/unterbrochen und Eingabe bereit/angehalten. Nur Abweichungen hervorheben; Diagnosewerte darunter belassen. Das bestehende Wiederverbinden und die manuelle Prüfung der Eingabesperre erhalten.

**Kreuzprüfung (UX Researcher):** Die getrennten Verlust- und Sperrmeldungen existieren bereits. Drei permanente Statusanzeigen kosten Bildfläche; eine P1-Einstufung ist durch den statischen Befund allein nicht begründet. Bereitschaft darf außerdem keine erfolgreiche Remote-Wirkung versprechen.

**Architektur-Gegenposition:** Dieselbe Statusprojektion wird in R01 vorgeschlagen; bestehende Verlust-/Sperrbanner verhindern die behauptete reine Gesundanzeige teilweise bereits. Als eigener P1-Arbeitsblock unbegründet. In R01 als P2 zusammenführen.

**Entscheidung:** Mit R01 bündeln. Drei permanente Ampeln sind nicht notwendig; nur aufgabenrelevante Abweichungen hervorheben. P1 ist aus dem statischen Befund nicht begründet.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Zuerst vorhandene Statusstellen präzisieren. API-only, Stall und Eingabesperre müssen denselben Gesamtzustand erklären; aktuelle Frames und Transportbereitschaft getrennt prüfen. Kein neuer Bildschirmaufbau erforderlich.

In [R01](#r01) gebündelt.

Quellanker der Eröffnung:

- [ContentView.swift:51](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:51) – isConnected basiert ausschließlich auf connectedDevice.
- [ContentView.swift:1289](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:1289) – Das Gerätepanel zeigt daraus Connected oder Disconnected.
- [VideoSurfaceView.swift:119](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/VideoSurfaceView.swift:119) – Streamstillstand und Connection Lost besitzen eine separate Darstellung.
- [ContentView.swift:275](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:275) – Eine Eingabesperre wird unabhängig von der Verbindung eingeblendet.

<a id="r12"></a>

## R12 – Vollbildsteuerung lokal per Tastatur erreichbar machen

Eröffnung: `UI Designer`. Evidenz: aktuell quellbelegt; Konsequenz hier nicht zwingend ausgeführt. Endbewertung: **präzisieren**, P2, Paket B; ursprüngliche Aufwandsschätzung M.

**Ausgangspunkt:** Der direkte Vollbildweg zu Verbindungen, Einstellungen und Fensteranpassung ist zeigerabhängig. Eine lokale Tastaturaktion zum Einblenden dieser Leiste oder zur Moduswahl ist in den geprüften Quellen nicht vorhanden. Bestehende Menüleistenwege decken einzelne Aktionen ab.

**Vorschlag:** Lokale Menübefehle für die vorhandenen Aktionen bereitstellen und eine Tastaturaktion für die Vollbildsteuerungen ergänzen. Bei lokalem Fokus die Leiste sichtbar halten. Befehle durch dieselben Modus-, Verbindungs- und Eingaberegeln führen; Hover unverändert erhalten.

**Kreuzprüfung (UX Researcher):** Ein neues globales Kürzel kann mit Remote-Shortcuts kollidieren. Die vorhandenen globalen Befehle sind ausschließlich Manual zugeordnet; diese Einschränkung darf eine neue Vollbildaktion nicht unbemerkt übernehmen oder umgehen.

**Architektur-Gegenposition:** Fehlender direkter Vollbildbefehl ist statisch belegt; ein vollständiger Tastaturblockadefall wurde nicht nativ gezeigt. P1 auf P2 herabstufen. Erst R10-Prüfung, dann kleinster lokaler Menü-/Fokusweg.

**Entscheidung:** Bestehende lokale Menüaktionen und Vollbildsteuerung per Tastatur erreichbar machen. Konflikte mit Remote-Kürzeln und Capture-Regeln zuerst prüfen; keine unbemerkten globalen Shortcuts.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Native lokale Menübefehle bevorzugen. Mit Remote-Fokus und lokalem Editor prüfen: lokale Aktivierung sendet kein HID, normale Remote-Kürzel funktionieren weiter. Moduswechsel nutzt dieselbe Übergabelogik; Hover bleibt verfügbar.

Quellanker der Eröffnung:

- [ContentView.swift:219](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:219) – Vollbildsteuerungen werden nach Hover im oberen Streifen eingeblendet.
- [ContentView.swift:281](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:281) – Die Steuerungsleiste wird nur bei showFullscreenControls aufgebaut.
- [ContentView.swift:561](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:561) – Die normale Toolbar einschließlich Moduswahl entfällt im Vollbild.
- [MenuBarAgent.swift:601](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/MenuBarAgent.swift:601) – Vorhandene globale Kürzel betreffen Quick Connect, OCR und Scan.

<a id="r13"></a>

## R13 – Geschlossene Seitenpanels aus Fokus und VoiceOver-Navigation nehmen

Eröffnung: `UI Designer`. Evidenz: ungeprüfte Hypothese; Produktänderung erst nach Bedarf oder Reproduktion. Endbewertung: **zusammenführen**, P2, Paket B; ursprüngliche Aufwandsschätzung M.

**Ausgangspunkt:** Beide Panels bleiben bei geschlossenem Zustand Teil der View-Hierarchie. Eine explizite Accessibility-Ausblendung oder Fokusübergabe ist dort nicht angegeben. Ob VoiceOver oder Tastaturnavigation die verschobenen Inhalte weiterhin erreicht, ist statisch nicht entschieden.

**Vorschlag:** Zuerst geschlossenes/offenes Panel mit VoiceOver und vollständiger Tastaturnavigation prüfen. Bei bestätigtem Problem Accessibility-Sichtbarkeit an den Präsentationszustand binden; Eintrittsfokus, Escape zum Schließen und Rückkehr zum auslösenden Button festlegen.

**Kreuzprüfung (UX Researcher):** Offset und Hit-Testing beweisen keine VoiceOver-Barriere. Ein pauschaler Fokusfang könnte erlaubte Menübedienung blockieren oder beim Schließen unerwartet sofort Remote-Tastatureingaben freigeben.

**Architektur-Gegenposition:** Offset und allowsHitTesting entscheiden VoiceOver-Sichtbarkeit nicht vollständig; fehlendes accessibilityHidden ist allein kein Fehlerbeweis. Hypothese innerhalb R10 prüfen; kein separater Fokusmechanismus vor Befund.

**Entscheidung:** Als konkreten Fokus-/Accessibility-Prüffall unter R10 führen; nach bestätigtem Problem Sichtbarkeit und Fokus korrigieren.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Prüfung vor Änderung beibehalten. Geschlossenes Panel darf keine Navigation anbieten; Rückkehr zuerst zum auslösenden lokalen Button. Anschließende Remote-Fokussierung muss ausdrücklich erfolgen. Escape und VoiceOver-Navigation erzeugen keine HID-Aktion.

In [R10](#r10) gebündelt.

Quellanker der Eröffnung:

- [ContentView.swift:336](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:336) – Das Settings-Panel bleibt aufgebaut und wird per Offset verschoben.
- [ContentView.swift:397](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:397) – Auch Connections bleibt aufgebaut; allowsHitTesting schaltet nur Zeigerzugriffe.
- [LocalInputCaptureTests.swift:137](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/tests/LocalInputCaptureTests.swift:137) – Vorhandene Fokustests prüfen Eingabebesitz, nicht die SwiftUI-Panelnavigation.

<a id="r14"></a>

## R14 – Icon-Buttons nach Wirkung und Zustand benennen

Eröffnung: `UI Designer`. Evidenz: belegte Prüf-/Abnahmelücke; kein damit bewiesener Produktdefekt. Endbewertung: **erst prüfen**, P2, Paket B; ursprüngliche Aufwandsschätzung S.

**Ausgangspunkt:** Explizite Accessibility-Namen sind uneinheitlich vorhanden. Aus dem Code lässt sich nicht ableiten, welche automatisch erzeugten Namen VoiceOver für alle SF Symbols tatsächlich spricht; OCR besitzt außerdem einen wechselnden Help-Text statt eines ausdrücklich gesprochenen Zustands.

**Vorschlag:** Das vorhandene Jiggler-Muster auf Connections, Fensteranpassung, OCR, Clipboard und Settings-Schließen übertragen. Aktionsnamen statt Symbolnamen verwenden; OCR ein/aus als Zustand vermitteln. Die kompakte Icon-Toolbar erhalten.

**Kreuzprüfung (UX Researcher):** Explizite Labels können bereits sinnvolle native Ansagen verdoppeln. Hilfe beschreibt häufig die nächste Aktion, während ein Zustandswert den aktuellen Zustand nennen muss; diese Bedeutungen nicht vermischen.

**Architektur-Gegenposition:** Help-Text und native Symbolnamen können bereits gesprochen werden; explizite Labels sind kein pauschaler Pflichtfix. Nur unverständliche oder zustandslose Ansagen aus R10 korrigieren; bestehendes Jiggler-Muster nutzen.

**Entscheidung:** Tatsächlich gesprochene native Namen prüfen; fehlende oder missverständliche Namen gezielt ergänzen. Hilfe, aktuelle Werte und nächste Aktion getrennt benennen.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Tatsächliche Ansagen zunächst aufnehmen. Nur unklare Namen ergänzen; OCR-Name bleibt stabil, Zustand nennt ein/aus. Dekorative Symbole nicht zusätzlich sprechen. Kompakte Toolbar und Tooltip-Inhalte erhalten.

Quellanker der Eröffnung:

- [ContentView.swift:584](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:584) – Mehrere Toolbar-Buttons bestehen aus SF Symbols mit Help-Text.
- [ContentView.swift:145](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:145) – Mouse Jiggler besitzt bereits explizites Label und Zustandswert.
- [WebUISettingsPanel.swift:221](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebUISettingsPanel.swift:221) – Der Settings-Schließen-Button besitzt nur das xmark-Symbol.
- [ContentView.swift:1228](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:1228) – Connections-Schließen besitzt bereits ein sprechendes Accessibility-Label.

<a id="r15"></a>

## R15 – Manual und Headless unmittelbar erklären

Eröffnung: `UI Designer`. Evidenz: ungeprüfte Hypothese; Produktänderung erst nach Bedarf oder Reproduktion. Endbewertung: **präzisieren**, P3, Paket C; ursprüngliche Aufwandsschätzung S.

**Ausgangspunkt:** Für erfahrene Nutzer sind die beiden Namen etabliert. Gelegentliche Nutzer können Headless jedoch mit einem bildlosen Betrieb verwechseln; die Auswirkungen auf lokale Eingabe und KI-Steuerung sind im Picker nicht unmittelbar erklärt. Die Sprache der neuen Hinweise ist gemischt.

**Vorschlag:** Bestehende Modusnamen und technische Werte erhalten, aber kurze Beschreibungen ergänzen: Manual für eigene Remote-Eingabe, Headless für KI-Steuerung bei gesperrter lokaler Remote-Eingabe. Neue Sicherheitstexte sprachlich einheitlich halten; eine vollständige Lokalisierung zunächst parken.

**Kreuzprüfung (UX Researcher):** Headless bedeutet erlaubte Agentensteuerung und gesperrte lokale Remote-Eingabe, aber nicht zwangsläufig eine aktive KI. Zusätzliche Beschreibung darf keine falsche Besitzer- oder Aktivitätsanzeige erzeugen.

**Architektur-Gegenposition:** Die behauptete Verwechslung von Headless ist eine Nutzerhypothese; Wolfgangs etablierte Begriffe sollen erhalten bleiben. P3-Verständlichkeitsprüfung, kein erforderlicher Umbau vor Funktionsabnahme.

**Entscheidung:** Kurze Erklärungen an bestehende Namen ergänzen. Headless erlaubt Agentensteuerung, meldet aber keine laufende KI. Vollständige Lokalisierung vertagen.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Headless als bereit für Agentensteuerung erklären. Manual-Auswahl während Drain nicht mit sofortiger Eingabebereitschaft gleichsetzen. Etablierte Titel und Manual beim Neustart erhalten; vollständige Lokalisierung getrennt vertagen.

Quellanker der Eröffnung:

- [ControlMode.swift:12](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ControlMode.swift:12) – Die sichtbaren Modustitel lauten Manual und Headless.
- [ContentView.swift:582](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:582) – Der Help-Text erklärt nur allgemein, wer den Remote-Rechner steuert.
- [ContentView.swift:153](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:153) – Neue Sicherheitsmeldungen erscheinen auf Deutsch neben englischen UI-Begriffen.
- [ControlModeTests.swift:39](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/tests/ControlModeTests.swift:39) – Manual beim Neustart ist bewusst abgesichert.

<a id="r16"></a>

## R16 – Passwortdialog mit Zielkontext und klarer Fokusfolge versehen

Eröffnung: `UI Designer`. Evidenz: aktuell quellbelegt; Konsequenz hier nicht zwingend ausgeführt. Endbewertung: **zusammenführen**, P2, Paket B; ursprüngliche Aufwandsschätzung S.

**Ausgangspunkt:** Der erneute Passwortdialog benennt das Zielgerät nicht, obwohl der Aufrufer den Pending-Device- oder Endpoint-Kontext besitzt. Erstfokus und Escape-Abbruch sind in diesen Sheets nicht ausdrücklich definiert; die bestehenden Schutzmaßnahmen beim Absenden sind vorhanden.

**Vorschlag:** Gerätename und Host:Port oberhalb des sicheren Passwortfelds zeigen. Beim manuellen Dialog Host, beim Passwortdialog Passwort fokussieren; Cancel als native Abbruchaktion definieren. Feldbedeutung und optionales Passwort konsistent erklären.

**Kreuzprüfung (UX Researcher):** Zielkontext ist sinnvoll; native Erstfokus- und Escape-Regeln könnten bereits funktionieren. Eine neue Fokusimplementierung darf gespeicherte Hostwerte, einmalige Absendung und Passwortlöschung nicht beeinträchtigen.

**Architektur-Gegenposition:** Zielkontext überschneidet R09; native Standardfokusfolge ist ohne Ausführung nicht als defekt belegt. Zielanzeige in R09 integrieren; Fokus unter R10 prüfen. One-shot-Absendung und Löschung bereits vorhanden.

**Entscheidung:** Zielkontext mit R09 bündeln; nativen Erstfokus/Escape unter R10 prüfen. Keine zusätzliche Passwortpersistenz.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Zielzeile stammt vom aktuellen Versuch. Spätes Authentifizierungsergebnis darf keinen fremden Dialog aktualisieren. Return bleibt einmalig, Escape entfernt Geheimnisse, Tab-Reihenfolge bleibt lokal. Fokus nur bei nachgewiesenem Bedarf ändern.

In [R09](#r09) gebündelt.

Quellanker der Eröffnung:

- [ConnectSheets.swift:73](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ConnectSheets.swift:73) – Password Required zeigt keine Geräte- oder Endpoint-Information.
- [ContentView.swift:522](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:522) – Die PasswordPromptSheet erhält nur Passwort und Aktionen, keinen Zielkontext.
- [ConnectSheets.swift:22](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ConnectSheets.swift:22) – Der manuelle Dialog enthält Host, Port und Passwort ohne explizite Fokusführung.
- [ConnectSheets.swift:99](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ConnectSheets.swift:99) – Einmalige Absendung und Passwortlöschung sind bereits implementiert.

<a id="r17"></a>

## R17 – Preferences zum tatsächlichen Panel führen und kurze Hilfe anbieten

Eröffnung: `UI Designer`. Evidenz: aktuell quellbelegt; Konsequenz hier nicht zwingend ausgeführt. Endbewertung: **empfehlen**, P2, Paket B; ursprüngliche Aufwandsschätzung M.

**Ausgangspunkt:** Der angebotene Preferences-Befehl führt im aktuellen Code nur zum Hauptfenster. Die vorhandenen Bedienhinweise sind im README; ein eigener lokaler Hilfepfad für Moduswahl, Eingabefokus, OCR und Wiederherstellung ist in den geprüften App-Quellen nicht erkennbar.

**Vorschlag:** Preferences zur vorhandenen Settings-Präsentation routen. Ist sie wegen Modus oder Verbindung nicht nutzbar, den Grund verständlich zeigen. Eine kleine lokale Hilfe aus den gültigen Bedienregeln anbieten; bestehende Tooltips und README weiterverwenden.

**Kreuzprüfung (UX Researcher):** Der Preferences-Menüpunkt besitzt einen konkreten Routingmangel. Eine neue Hilfefläche ist dagegen zusätzlicher Umfang ohne belegten Nachschlagebedarf. Beides gemeinsam würde die kleine Reparatur unnötig verbreitern.

**Architektur-Gegenposition:** Preferences öffnet tatsächlich nur das Fenster; eine zusätzliche lokale Hilfe ist ein zweites, unbelegtes Ausbauziel. P2 auf bestehenden Settings-Präsentationsweg begrenzen; separates Hilfesystem parken.

**Entscheidung:** Den konkreten Preferences-Routingmangel separat beheben. Eine neue Hilfefläche benötigt erst belegten Bedarf.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Zuerst Preferences zum bestehenden Panel routen oder seine Voraussetzung nennen. Identisches Verhalten aus Menü und Toolbar prüfen, einschließlich Headless und getrennter Session. Hilfe separat nach Bedarf bewerten und gültige README-Inhalte wiederverwenden.

Quellanker der Eröffnung:

- [MenuBarAgent.swift:143](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/MenuBarAgent.swift:143) – Preferences wird als eigener Menüpunkt mit Tastenkürzel angeboten.
- [MenuBarAgent.swift:495](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/MenuBarAgent.swift:495) – showPreferences öffnet lediglich das Hauptfenster.
- [OverlookApp.swift:13](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/OverlookApp.swift:13) – Die Scene enthält keine eigene Commands- oder Help-Erweiterung.
- [README.md:109](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/README.md:109) – Bedienhinweise existieren bislang im Repository-Quick-Start.

<a id="r18"></a>

## R18 – Fehlerüberschriften und Rückmeldungen an die betroffene Aktion binden

Eröffnung: `UI Designer`. Evidenz: aktuell quellbelegt; Konsequenz hier nicht zwingend ausgeführt. Endbewertung: **zusammenführen**, P2, Paket B; ursprüngliche Aufwandsschätzung M.

**Ausgangspunkt:** Die Überschrift Connection Failed kann auch einen abgewiesenen Moduswechsel oder Jiggler-Fehler begleiten. Clipboard-Ergebnisse erscheinen dynamisch; eine gezielte Accessibility-Ankündigung ist dort nicht vorgesehen. Ob VoiceOver sie automatisch bemerkt, bleibt ungeprüft.

**Vorschlag:** Überschrift nach Aktion wählen, beispielsweise Moduswechsel nicht möglich oder Jiggler nicht geändert. Handlungshinweis nahe der Meldung ergänzen. Relevante Übertragungs- und Sperrergebnisse gezielt ankündigen; laufende Statistikwerte nicht vorlesen.

**Kreuzprüfung (UX Researcher):** Aktionsbezogene Titel helfen. Erfolgsansagen dürfen jedoch keinen erfolgreichen Remote-Edit behaupten oder Clipboard-Inhalt vorlesen. Wiederholte identische Rückmeldungen können außerdem störende Sprachfolgen erzeugen.

**Architektur-Gegenposition:** Alertzuordnung ist R08; fehlende ausdrückliche Ansage beweist keinen VoiceOver-Verlust. Kein separater Änderungsblock. Titel in R08, tatsächliche Ankündigung in R10 abnehmen.

**Entscheidung:** Aktionsüberschriften mit R08 bündeln, relevante Ansagen mit R10 prüfen. Keine Clipboard-Inhalte oder laufenden Statistikwerte vorlesen.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Nur Vorgang, Ergebnis und gegebenenfalls Zeichenzahl ankündigen. Versandbestätigung von sichtbarer Remote-Wirkung unterscheiden. Aufeinanderfolgende Transfers und Sperrmeldungen separat prüfen; unbekannte Übertragung niemals automatisch wiederholen.

In [R08](#r08) gebündelt.

Quellanker der Eröffnung:

- [ContentView.swift:547](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:547) – Der gemeinsame Alert unterscheidet nur Credentials Not Saved und Connection Failed.
- [ContentView.swift:742](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:742) – Auch eine fehlende Jiggler-Voraussetzung für Headless benutzt connectionErrorMessage.
- [ContentView.swift:264](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:264) – Clipboard-Rückmeldung wird als dynamischer Text im Bildbereich eingeblendet.
- [ContentView.swift:847](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:847) – Erfolgreiche Übertragung verschwindet nach zwei Sekunden.

<a id="r19"></a>

## R19 – Gerätepanel bei kleinen Fenstern und langen Texten prüfen

Eröffnung: `UI Designer`. Evidenz: ungeprüfte Hypothese; Produktänderung erst nach Bedarf oder Reproduktion. Endbewertung: **zusammenführen**, P2, Paket B; ursprüngliche Aufwandsschätzung M.

**Ausgangspunkt:** Feste Breite und eine wachsende, nicht scrollbare Statistikliste können bei kleinen Fenstern, aktivem Audio oder langen Gerätenamen zu Gedränge führen. Konkrete Überläufe wurden im statischen Review nicht beobachtet.

**Vorschlag:** Connect/Disconnect und Gerätewahl oben erhalten. Diagnosewerte bei Bedarf in einen einklappbaren, scrollbaren Abschnitt legen; lange Namen und Werte gezielt umbrechen oder mit vollständigem Accessibility-Wert versehen. Nur nach bestätigtem Platzproblem umbauen.

**Kreuzprüfung (UX Researcher):** Ein tatsächlicher Überlauf ist nicht beobachtet. Diagnose automatisch einzuklappen kann erfahrene Nutzer ausbremsen und einen gerade untersuchten Fehler verstecken. Die Primäraktionen stehen bereits vor den Statistikwerten.

**Architektur-Gegenposition:** Feste Breite und viele Zeilen sind ein konkreter Prüfauslöser, jedoch kein beobachteter Überlauf. P3-Matrix in R10; Layoutänderung erst bei verdeckter Aktion oder abgeschnittenem Inhalt.

**Entscheidung:** Kleine Fenster, lange Namen und aktive Audiostatistik als R10-Prüffälle. Layout erst bei beobachtetem Überlauf verändern.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Erst kleines Fenster, langen Namen und alle Audiozeilen rendern. Umbau nur bei reproduziertem Platzproblem; Gerätewahl und Connect/Disconnect bleiben sichtbar. Diagnose vollständig erreichbar halten und eine bewusste Expansion erhalten.

In [R10](#r10) gebündelt.

Quellanker der Eröffnung:

- [ContentView.swift:390](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:390) – Das Gerätepanel hat eine feste Breite von 360 Punkten.
- [ContentView.swift:1218](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:1218) – Das Panel ist ein VStack ohne eigenen ScrollView.
- [ContentView.swift:1301](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:1301) – Mehrere Diagnosezeilen werden dauerhaft gezeigt.
- [ContentView.swift:1360](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:1360) – Audio ergänzt bis zu fünf weitere Diagnosezeilen.
- [ContentView.swift:804](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:804) – Gespeicherte Fenster können bis auf 320 Punkte Höhe begrenzt werden.

<a id="r20"></a>

## R20 – Native Themes erhalten und Darstellungsoptionen gezielt abnehmen

Eröffnung: `UI Designer`. Evidenz: belegte Prüf-/Abnahmelücke; kein damit bewiesener Produktdefekt. Endbewertung: **zusammenführen**, P3, Paket B; ursprüngliche Aufwandsschätzung S.

**Ausgangspunkt:** Die native Grundlage und textliche Statusinformation sind bereits vorhanden. Die geprüften Quellen und Tests belegen keine vollständige Abnahme mit erhöhtem Kontrast, reduzierter Transparenz, reduzierter Bewegung und den drei App-Appearances; daraus folgt keine nachgewiesene Kontrastverletzung.

**Vorschlag:** Ein generelles Farb-/Designsystem-Redesign parken. Eine kleine macOS-Prüfmatrix für Toolbar, Panels, Fehler und Status anlegen; nur reproduzierte Probleme beheben. Prüfen, ob Bewegungseinstellungen die Panel- und Fensteranimationen ausreichend reduzieren.

**Kreuzprüfung (UX Researcher):** Native Farben und Materialien können Darstellungsoptionen bereits korrekt berücksichtigen. Der frühere Moduswechsel verzichtet bewusst auf Fensteranimation; eine allgemeine Animationsvereinheitlichung könnte diese Stabilitätsregel verletzen.

**Architektur-Gegenposition:** Native Themes und Textstatus existieren; fehlende Appearance-Matrix rechtfertigt kein Designsystem-Redesign. Kleine P3-Abnahme unter R10, ohne vorgezogene Produktänderung.

**Entscheidung:** Native Themes und Darstellungsoptionen in R10 prüfen; kein pauschales Farb- oder Animationsredesign.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Die begrenzte Prüfmatrix übernehmen, kosmetischen Umbau weiter vertagen. Konkrete problematische Zustände und Systemeinstellungen dokumentieren. Nichtanimierten Moduswechsel erhalten; Panelbewegung gesondert mit reduzierter Bewegung prüfen. Keine allgemeine Konformitätsbehauptung.

In [R10](#r10) gebündelt.

Quellanker der Eröffnung:

- [ContentView.swift:58](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:58) – System, Light und Dark werden bereits unterstützt.
- [WebUISettingsPanel.swift:85](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebUISettingsPanel.swift:85) – Das Settings-Panel nutzt eine semantische AppKit-Hintergrundfarbe.
- [ContentView.swift:1291](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:1291) – Statusfarben sind explizit grün/rot, aber zusätzlich textlich benannt.
- [ContentView.swift:398](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:398) – Seitliche Panels verwenden feste Animationen.
- [2026-10-02-overlook-m154-mcp22-rollout.md:54](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/docs/reviews/2026-10-02-overlook-m154-mcp22-rollout.md:54) – Der Rollout-Smoke dokumentiert keine vollständige UI- oder Accessibility-Abnahme.

<a id="r21"></a>

## R21 – WebRTC-Neustarts über einen überprüfbaren Owner führen

Eröffnung: `swift-reviewer`. Evidenz: belegte Prüf-/Abnahmelücke; kein damit bewiesener Produktdefekt. Endbewertung: **erst prüfen**, P2, Paket A; ursprüngliche Aufwandsschätzung M.

**Ausgangspunkt:** Der SessionCoordinator schützt API/HID bereits mit Generationen und serialisiertem Cleanup. Medien-Neustarts laufen daneben über automatischen Retry, Audio-Hotplug und Settings. Die vorhandenen Coordinator-Tests belegen deren gemeinsames Verhalten nicht; ein tatsächlicher Sessionverlust ist damit nicht nachgewiesen.

**Vorschlag:** Eine kleine Medien-Neustartmethode im WebRTCManager mit Grund, erwarteter Session und gespeichertem Task diskutieren. Alle drei Auslöser nutzen deren Arbitration. Der SessionCoordinator bleibt Owner für API/HID. Ein Videoretry darf keinen vollständigen Sessionwechsel mit unbeabsichtigtem Wechsel des Kontrollmodus auslösen.

**Kreuzprüfung (Test Automation Engineer):** Die Konkurrenz verschiedener Neustartauslöser ist im Code sichtbar, der Verlust einer Session aber nicht reproduziert. Coordinator-Fixtures simulieren Video. Eine neue Arbitration darf deshalb erst aus einem gezielt fehlenden Verhalten folgen.

**Architektur-Gegenposition:** WebRTCManager ist bereits Medien-Owner; zusätzliche Arbitration braucht zuerst ein konkurrierendes Gegenbeispiel. P2 zunächst injizierte drei Neustartauslöser prüfen, dann vorhandenen Owner begrenzt vereinheitlichen. Kein neuer Sessionkoordinator.

**Entscheidung:** Konkurrierende Medienauslöser gezielt orchestrieren. Nur ein reproduziertes Ownership-Problem rechtfertigt zusätzliche Arbitration innerhalb des bestehenden Medienowners.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Mit steuerbarem Mediensender gleichzeitig Settings-Neustart, Hotplug und Retry auslösen; anschließend Disconnect und Gerätewechsel einschieben. Aufgezeichnete Starts/Commits müssen dem aktuellen Owner gehören. Den bestehenden API-/HID-Vertrag als separate Regression erhalten; kein kompletter Session-Actor-Umbau.

Quellanker der Eröffnung:

- [SessionConnectionCoordinator.swift:12](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/SessionConnectionCoordinator.swift:12) – Besitzt Authentifizierung, Session-Commit und HID-Übergänge.
- [WebRTCManager.swift:340](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebRTCManager.swift:340) – Audio-Hotplug startet einen eigenen, nicht gespeicherten Reconnect-Task.
- [WebUISettingsPanel.swift:1198](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebUISettingsPanel.swift:1198) – Settings starten den Videotransport direkt neu.
- [SessionConnectionCoordinatorTests.swift:345](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/tests/SessionConnectionCoordinatorTests.swift:345) – Der Videostart wird durch eine Closure simuliert; native Reconnect-Konkurrenz wird hier nicht geprüft.

<a id="r22"></a>

## R22 – Janus-Waiter vor dem ersten Send-Await anlegen

Eröffnung: `swift-reviewer`. Evidenz: aktuell quellbelegt; Konsequenz hier nicht zwingend ausgeführt. Endbewertung: **empfehlen**, P2, Paket A; ursprüngliche Aufwandsschätzung M.

**Ausgangspunkt:** Send und Antwortregistrierung sind getrennt. Während await send kann der Listener eine schnelle Create-/Attach-Antwort verarbeiten. Ohne registrierten Waiter fällt sie aus dem Transaktionspfad; anschließend wartet der Aufrufer bis zum Acht-Sekunden-Timeout. Dieser Ablauf ergibt sich aus dem Code, wurde hier aber nicht ausgeführt.

**Vorschlag:** Einen kleinen Janus-Request-Helfer einführen, der Waiter und Deadline zuerst registriert und dann sendet. Sendfehler, Antwort, Timeout, Cancellation und Disconnect dürfen die Continuation genau einmal abschließen. Dafür nur die externe Signaling-Grenze injizieren.

**Kreuzprüfung (Test Automation Engineer):** Send-Await vor Waiterregistrierung erlaubt die beschriebene Reihenfolge. Die heutigen nativen Kompatibilitätsproben verwenden jedoch kein SDP/Signaling und beweisen keinen beobachteten Janus-Ausfall.

**Architektur-Gegenposition:** Frühe Antwort ist codeplausibel, jedoch nicht reproduziert; ACK und finale Janus-Antwort dürfen dabei nicht verwechselt werden. Kleine P2-Korrektur am Signaling-Vertrag statt allgemeinem Transportrewrite.

**Entscheidung:** Janus-Transaktion vor Send-Await registrieren. Erst Barriere-Test mit sehr früher Antwort; dann minimaler Request-Helfer mit genau einem Abschluss für Antwort/Sendfehler/Timeout/Cancel/Disconnect.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Den Listener eine gültige Create-/Attach-Antwort verarbeiten lassen, während send noch an einer Barriere wartet. Vor dem Fix muss dieser gesteuerte Fall scheitern. Antwort, Sendfehler, Cancellation, Timeout und Disconnect in verschiedenen Reihenfolgen prüfen: genau ein Abschluss, keine verbleibenden Waiter/Timer und kein alter Sessioncommit.

Quellanker der Eröffnung:

- [WebRTCManager.swift:546](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebRTCManager.swift:546) – Create wird vor Registrierung des Antwort-Waiters gesendet.
- [WebRTCManager.swift:552](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebRTCManager.swift:552) – Erst nach dem Send-Await wird auf die Transaktion gewartet; Attach folgt demselben Muster.
- [WebRTCManager.swift:701](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebRTCManager.swift:701) – Die Continuation wird erst beim Aufruf dieser Methode gespeichert.
- [WebRTCManager.swift:780](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebRTCManager.swift:780) – Eine früh eintreffende Transaktionsantwort findet noch keinen Waiter und wird nicht zwischengespeichert.

<a id="r23"></a>

## R23 – Videoaufbau mit einer eigenen Deadline beenden

Eröffnung: `swift-reviewer`. Evidenz: aktuell quellbelegt; Konsequenz hier nicht zwingend ausgeführt. Endbewertung: **präzisieren**, P2, Paket A; ursprüngliche Aufwandsschätzung M.

**Ausgangspunkt:** Der Janus-Antworttimeout begrenzt weder einen zuvor wartenden Send noch die Phase ohne Offer oder ohne abschließenden ICE-Zustand. Die Initial-Frame-Deadline greift erst nach verbundenem ICE. Der Code enthält daher keinen vollständigen Zeitvertrag für den Videostart; eine konkrete Hängedauer wurde hier nicht gemessen.

**Vorschlag:** Eine generationengebundene Deadline für den Medienaufbau definieren und mit injizierbarer Uhr testen. Bei Ablauf nur den betroffenen Medientransport abbrechen und einen klaren Zustand veröffentlichen. Die bereits funktionierende API/HID-Session bleibt erhalten; die bestehende HID-Settlement-Reparatur wird nicht neu aufgerollt.

**Kreuzprüfung (Test Automation Engineer):** Der fehlende vollständige Videostart-Zeitvertrag ist nachvollziehbar; eine konkrete Hängedauer fehlt. Die neue Deadline muss von Janus-Transaktionsfristen und vorhandener Initial-Frame-Prüfung unterscheidbar bleiben.

**Architektur-Gegenposition:** Fehlender Gesamtzeitvertrag ist belegt; bloßes Task.cancel garantiert kein begrenztes Settlement eines suspendierten Send. P2-Zeitbudget mit begrenztem Socket-Teardown festlegen. Kein API/HID-Abbruch und kein unendlicher Zusatzretry.

**Entscheidung:** Videostart-Budget mit definierten Anfangs-/Endereignissen festlegen. Der Ablauf betrifft Medien; bereits funktionierende API/HID nicht verlieren. Keine neue willkürliche globale Frist. Auch Socket-Teardown und Ressourcen-Settlement müssen begrenzt enden; Task.cancel allein genügt nicht.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Budget und Start-/Endereignis ausdrücklich festlegen. Steuerbare Uhr und blockierter Sender reproduzieren fehlenden Sendabschluss, Offer und ICE-Erfolg ohne Prüfschlaf. Fristablauf cancelt den realen betroffenen Transport auch bei nicht kooperierendem Await. Ein späterer A-Abschluss darf B nicht verändern; API/HID bleiben entsprechend vorhandener Regression erreichbar.

Quellanker der Eröffnung:

- [WebRTCManager.swift:720](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebRTCManager.swift:720) – Der Signaling-Send wird direkt ohne eigene begrenzte Settlement-Logik erwartet.
- [WebRTCManager.swift:701](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebRTCManager.swift:701) – Der Acht-Sekunden-Timeout beginnt erst beim nachfolgenden Antwort-Waiter.
- [WebRTCManager.swift:924](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebRTCManager.swift:924) – Stream-Health beendet die Prüfung solange ICE noch nicht verbunden ist.
- [WebRTCManager.swift:418](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebRTCManager.swift:418) – connect endet nach Signaling-Aufbau, bevor erstes Bild oder erfolgreicher ICE-Aufbau garantiert sind.

<a id="r24"></a>

## R24 – Fehlgeschlagene AudioUnit-Initialisierung vollständig zurückrollen

Eröffnung: `swift-reviewer`. Evidenz: aktuell quellbelegt; Konsequenz hier nicht zwingend ausgeführt. Endbewertung: **empfehlen**, P2, Paket A; ursprüngliche Aufwandsschätzung S.

**Ausgangspunkt:** Scheitern StreamFormat, Callback-Registrierung oder AudioUnitInitialize, bleibt inputUnit beziehungsweise outputUnit gesetzt. Ein zweiter initialize-Aufruf interpretiert das Handle als vollständig initialisiert und setzt das Erfolgsflag, obwohl der vorherige Aufbau gescheitert ist.

**Vorschlag:** Die Unit zunächst lokal aufbauen, Fehlerpfade gezielt uninitialisieren/disposen und erst nach vollständigem Erfolg in den Gerätezustand übernehmen. Wenige injizierte AudioUnit-Aufrufe genügen für Fehlernachweise; kein umfassendes Audio-Protokollsystem nötig.

**Kreuzprüfung (Test Automation Engineer):** Der Fehlerpfad ist direkt belegt: Handle wird vor fehlbaren Schritten gespeichert, Wiederholung interpretiert vorhandenes Handle als Erfolg. Aktuelle Audio-Proben üben diese Schritte nicht aus.

**Architektur-Gegenposition:** Gespeichertes Teilhandle wird beim zweiten Initialize tatsächlich als Erfolg behandelt; das ist ein konkreter Fehlerpfad. P2-Fehlerrollback lokal beheben; keine Audio-Actor-Architektur nötig.

**Entscheidung:** AudioUnit erst nach vollständigem Init veröffentlichen; Fehler stufenabhängig aufräumen. Input-/Output-Fehler injizieren und einen echten zweiten Aufbau nachweisen.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Je Input/Output Formatsetzung, Callbackregistrierung und Initialisierung gezielt scheitern lassen. Handle/Flag dürfen keinen Erfolg anzeigen; Cleanup muss dem erreichten Initialisierungsstadium entsprechen und höchstens einmal disposen. Auch Inputpuffer prüfen. Derselbe Geräteowner muss beim zweiten Versuch alle Schritte erneut erfolgreich durchlaufen. Native Audio-I/O ist für diese Fehlerfalltests unnötig.

Quellanker der Eröffnung:

- [WebRTCAudioDevice.swift:103](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebRTCAudioDevice.swift:103) – Ein bereits gespeichertes Output-Handle führt sofort zu gemeldetem Initialisierungserfolg.
- [WebRTCAudioDevice.swift:109](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebRTCAudioDevice.swift:109) – Das Handle wird vor mehreren fehlbaren Initialisierungsschritten gespeichert.
- [WebRTCAudioDevice.swift:166](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebRTCAudioDevice.swift:166) – Recording besitzt denselben Wiederholungsfehler.
- [WebRTCAudioDevice.swift:183](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebRTCAudioDevice.swift:183) – Fehlerpfade räumen das zuvor gespeicherte Input-Handle nicht auf.

<a id="r25"></a>

## R25 – Audio-Callback- und Cleanup-Vertrag zuerst beweisen

Eröffnung: `swift-reviewer`. Evidenz: ungeprüfte Hypothese; Produktänderung erst nach Bedarf oder Reproduktion. Endbewertung: **zurückstellen**, P3, Paket C; ursprüngliche Aufwandsschätzung M.

**Ausgangspunkt:** Callback-Lebensdauer und Quieszenz hängen von nativen WebRTC-/CoreAudio-Verträgen ab. Im Swift-Code ist kein eigener Nachweis sichtbar, dass bei fehlgeschlagenem Stop kein Callback mehr auf Puffer oder unretained self zugreifen kann. Ein Race oder Use-after-free ist hier nicht bewiesen.

**Vorschlag:** Einen Audio-Actor-Rewrite parken. Zuerst native Ownership-/Stop-Verträge des eingebundenen Frameworks prüfen und Cleanup mit kontrolliert laufendem Callback sowie Stopfehler testen. Nur bei Vertragslücke Lebenszyklus und Callback-State gezielt absichern; auf dem Echtzeitpfad keine blockierenden Actor-Hops oder Locks ergänzen.

**Kreuzprüfung (Test Automation Engineer):** Stopfehler werden ignoriert, Callback-State wird anschließend freigegeben. Ob native Stop-/Dispose-Verträge trotzdem Quieszenz garantieren, ist hier ungeprüft. Eine synthetische Callback-Fortsetzung allein beweist keinen realen Use-after-free.

**Architektur-Gegenposition:** Ignorierter Stopfehler und unretained Callback belegen allein keinen Use-after-free; native Quieszenzverträge fehlen. P2-Vertragsprüfung vor Änderung. Keine Race-P1 oder blockierenden Actor-/Lock-Hops aus Hypothese ableiten.

**Entscheidung:** Native Stop-/Dispose- und Callback-Lebensdauer zuerst mit Primärvertrag klären. Kein bewiesener Use-after-free und kein pauschaler Audio-Actor-/Lock-Umbau.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Zuerst den tatsächlichen CoreAudio-/WebRTC-Lebenszeitvertrag als Primärbeleg ermitteln. Dann eine lokale Callback-Overlap-/Stopfehlerprobe mit präzisem Ownership-Nachweis ergänzen. Nur eine bestätigte Vertragslücke rechtfertigt Implementierungsänderungen. Ein Actor oder blockierende Locks im Echtzeitcallback sind keine akzeptierte pauschale Lösung.

Quellanker der Eröffnung:

- [WebRTCAudioDevice.swift:72](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebRTCAudioDevice.swift:72) – Terminate ignoriert die Rückgabewerte von stopPlayout und stopRecording.
- [WebRTCAudioDevice.swift:90](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebRTCAudioDevice.swift:90) – Input-Puffer und Delegate werden anschließend freigegeben beziehungsweise entfernt.
- [WebRTCAudioDevice.swift:356](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebRTCAudioDevice.swift:356) – Der Echtzeit-Callback verwendet einen nicht retained Gerätereferenzkontext.
- [WebRTCAudioDevice.swift:369](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebRTCAudioDevice.swift:369) – Recording liest Unit, Delegate und Puffer aus dem veränderlichen Gerätezustand.
- [WebRTCCompatibilityTests.swift:6](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/tests/WebRTCCompatibilityTests.swift:6) – Der Kompatibilitätstest startet ausdrücklich keine AudioUnit.

<a id="r26"></a>

## R26 – Audio-Hotplug-Debounce darf nach Cancellation nicht feuern

Eröffnung: `swift-reviewer`. Evidenz: aktuell quellbelegt; Konsequenz hier nicht zwingend ausgeführt. Endbewertung: **empfehlen**, P2, Paket A; ursprüngliche Aufwandsschätzung S.

**Ausgangspunkt:** Cancellation beendet Task.sleep sofort, wird aber ignoriert. Der alte Debounce-Task prüft anschließend trotzdem den Reconnect-Bedarf. Bei weiter fehlendem Audiogerät kann damit gerade der verworfene Task den Neustart vor Ablauf der neuen 800-ms-Frist auslösen.

**Vorschlag:** Sleep mit do/catch und sofortiger Rückkehr bei Cancellation behandeln. Zusätzlich die erwartete Mediengeneration beim Debounce erfassen, damit eine alte Gerätebenachrichtigung nicht den gerade neu aufgebauten Transport beeinflusst.

**Kreuzprüfung (Test Automation Engineer):** try? verwirft den Cancellationfehler und führt anschließend den Reconnect-Check aus. Das ist ein gezielt prüfbarer Debouncefehler; bestehende Retry-Schutzregeln machen ihn nicht korrekt.

**Architektur-Gegenposition:** try? setzt den verworfenen Debounce nach Cancellation fort; aktueller Gerätecheck verhindert lediglich manche Folgen. Konkreter kleiner P2-Cancellationfehler; bestehende 800-ms-Policy erhalten.

**Entscheidung:** Abgebrochenen Hotplug-Debounce sofort beenden und Generation prüfen. Gezielt testen, dass nur die letzte vollständige Frist einen aktuellen Neustart auslösen kann.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Die erste Benachrichtigung startet den Debounce, die zweite cancelt ihn vor Ablauf. Mit steuerbarem Scheduler darf der alte Task keinen Check oder Reconnect auslösen; nur nach Ablauf der letzten vollständigen Frist erfolgt genau ein Auftrag. Gerätewechsel/Disconnect während der Frist verhindern jeden alten Auftrag. Keine echten Audiogeräte oder festen Prüfschlafzeiten nötig.

Quellanker der Eröffnung:

- [WebRTCManager.swift:320](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebRTCManager.swift:320) – Eine neue Geräteänderung cancelt den vorherigen Debounce-Task.
- [WebRTCManager.swift:322](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebRTCManager.swift:322) – Der Sleep-Cancellation-Fehler wird mit try? verworfen.
- [WebRTCManager.swift:324](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebRTCManager.swift:324) – Auch der gecancelte Task ruft danach den Reconnect-Check auf.

<a id="r27"></a>

## R27 – Verspäteter Keepalive-Fehler gehört zur alten Session

Eröffnung: `swift-reviewer`. Evidenz: aktuell quellbelegt; Konsequenz hier nicht zwingend ausgeführt. Endbewertung: **empfehlen**, P2, Paket A; ursprüngliche Aufwandsschätzung S.

**Ausgangspunkt:** Timer-Invalidierung beendet einen bereits gestarteten Keepalive-Task nicht. Scheitert dessen alter Send nach einem Transportwechsel, ruft der Catch requestReconnect für das inzwischen aktuelle Gerät auf. Im Gegensatz zum Signaling-Listener fehlt hier die Generationsprüfung.

**Vorschlag:** Vor dem Send Mediengeneration und Socket-/Sessionidentität erfassen. Im Catch Cancellation beziehungsweise einen inzwischen anderen Owner verwerfen; nur ein Fehler des weiterhin aktuellen Transports darf Reconnect auslösen. Bei Bedarf den Keepalive-Task speichern und in den Medien-Owner einbinden.

**Kreuzprüfung (Test Automation Engineer):** Der Janus-Keepalive-Catch besitzt keine ursprüngliche Generation. Der bereits reparierte alte HID-Ping betrifft einen anderen Transport und ersetzt diesen Test nicht. Ein Betriebsausfall wurde hier nicht beobachtet.

**Architektur-Gegenposition:** Timer-Invalidierung beendet bereits gesendete Keepalive-Arbeit nicht; alter Catch besitzt keine Generationsprüfung. Gezielte P2-Ownerkorrektur, kein allgemeines Retry-Replay-System.

**Entscheidung:** Keepalive-Ergebnis an ursprünglichen Socket/Generation binden. Später Fehler von A darf B weder neu verbinden noch mit einer alten Fehlermeldung überschreiben.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** A-Keepalive-Send an einer Barriere halten, B vollständig einsetzen, dann A mit Fehler beenden. B darf weder Retry noch alte Fehleranzeige erhalten. Dieselbe Fehlerfreigabe bei weiterhin aktuellem A muss Retry auslösen. Timerinvalidate und Cancellation zusätzlich prüfen; Reihenfolge über Ereignisse steuern, keine reale 25-Sekunden-Wartezeit.

Quellanker der Eröffnung:

- [WebRTCManager.swift:642](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebRTCManager.swift:642) – Der Timer erzeugt einen unabhängigen MainActor-Task.
- [WebRTCManager.swift:648](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebRTCManager.swift:648) – Der Send kann über einen Sessionwechsel hinweg suspendieren.
- [WebRTCManager.swift:650](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebRTCManager.swift:650) – Der Catch fordert ohne Prüfung des ursprünglichen Owners Reconnect an.
- [WebRTCManager.swift:448](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebRTCManager.swift:448) – Reconnect nimmt das zu diesem späteren Zeitpunkt aktuelle Gerät und dessen Generation.

<a id="r28"></a>

## R28 – Diagnose-Polling begrenzen, bevor Performance behauptet wird

Eröffnung: `swift-reviewer`. Evidenz: ungeprüfte Hypothese; Produktänderung erst nach Bedarf oder Reproduktion. Endbewertung: **erst prüfen**, P3, Paket C; ursprüngliche Aufwandsschätzung M.

**Ausgangspunkt:** Der jüngste Stats-Fix verwirft veraltete Reports korrekt. Er begrenzt die Zahl wartender Timer-Tasks nicht. Bei Statistikdauern über einer Sekunde könnten Aufgaben wachsen oder alle Antworten durch neuere IDs verdrängt werden. Im geprüften Material liegt dazu keine Laufzeitmessung vor; CPU-/Speicherverbesserungen wären derzeit eine Behauptung.

**Vorschlag:** Zunächst Dauer, Zahl laufender Aufträge und verworfene Reports erfassen beziehungsweise mit verzögerter Statistikgrenze prüfen. Bei bestätigtem Rückstau einen gespeicherten Mess-Task und höchstens einen Auftrag gleichzeitig verwenden. Den funktionierenden Frame-Delivery-Pfad beibehalten; MainActor-Verlagerungen erst nach Profiling diskutieren.

**Kreuzprüfung (Test Automation Engineer):** Vorhandene Tests sichern Reportidentität, nicht Taskanzahl. Rückstau und Statistikstarvation sind plausible Folgen langsamer Antworten, aber heute nicht gemessen. Daraus folgt noch kein Leistungsgewinn einer Architekturänderung.

**Architektur-Gegenposition:** Alte Statistikreports werden bereits verworfen; tatsächlicher Ressourcenrückstau oder Leistungsgewinn ist ungemessen. P3 zunächst verzögerte Statistik-Fixture oder Profiling. Kein MainActor-/Frame-Delivery-Umbau auf Verdacht.

**Entscheidung:** Überlappende Stats-Aufgaben und verworfene Ergebnisse unter steuerbarer Verzögerung messen. Keine CPU-/Speicherverbesserung ohne Nachweis behaupten.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Zuerst das tatsächliche Timer-/Messowner-Verhalten mit steuerbaren Ticks und blockierter Statistikgrenze erfassen: gestartete/laufende/beendete Aufträge und publizierte Werte. Einen späten sowie nie abschließenden Report gezielt erzwingen. Erst bei reproduziertem Wachstum oder Starvation begrenzen; den bestehenden Schutz gegen alte Reports beibehalten. Hardwareprofiling ergänzt anschließend die Performanceaussage.

Quellanker der Eröffnung:

- [WebRTCManager.swift:909](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebRTCManager.swift:909) – Jeder Sekundentick startet einen ungespeicherten Mess-Task.
- [WebRTCManager.swift:995](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebRTCManager.swift:995) – Ein neuer Statistikauftrag ersetzt die akzeptierte Request-ID.
- [WebRTCManager.swift:1014](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebRTCManager.swift:1014) – Native Statistikantworten werden asynchron erwartet.
- [StatsGenerationTests.swift:105](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/tests/StatsGenerationTests.swift:105) – Der vorhandene Test beweist Schutz vor alten Reports, jedoch keine Begrenzung laufender Arbeit.

<a id="r29"></a>

## R29 – Latenzmessung mit Channel, Antwort und Alter korrelieren

Eröffnung: `swift-reviewer`. Evidenz: aktuell quellbelegt; Konsequenz hier nicht zwingend ausgeführt. Endbewertung: **präzisieren**, P2, Paket B; ursprüngliche Aufwandsschätzung M.

**Ausgangspunkt:** Ein verzögerter Pong kann gegen den Start eines späteren Pings gerechnet werden; ein alter Channel kann ebenfalls eine aktuelle Messung beenden. Null unterscheidet fehlende Messung nicht von echter geringer Latenz. Das ist zudem eine DataChannel-Rundreise und kein Nachweis der Bild-/Eingabelatenz.

**Vorschlag:** Eine optionale, monotone und channelgebundene Messung mit Alter führen. Höchstens ein Ping bleibt offen, sofern der Server keine belegte Antwortkorrelation unterstützt. Bestehenden Wire-Vertrag zuerst prüfen; keinen neuen Pong-Vertrag voraussetzen. Anzeige eindeutig als Rundreise beschriften oder die bereits verfügbare ICE-RTT nutzen.

**Kreuzprüfung (Test Automation Engineer):** Startzeitüberschreiben, Wanduhr und fehlender Channelabgleich sind konkret sichtbar. Der tatsächliche Pongvertrag des KVM ist ungeprüft; ein neu erfundener synthetischer Echopeer würde diesen Vertrag nicht bestätigen.

**Architektur-Gegenposition:** Gemeinsame Wanduhr-Startzeit macht verspätete Pongs falsch zuordenbar; der Server-Echovertrag ist unbekannt. P2 zunächst Anzeige ehrlich als DataChannel-Rundreise/unbekannt führen oder vorhandene ICE-RTT verwenden. Kein neuer Wire-Vertrag.

**Entscheidung:** Messquelle und Alter korrekt anzeigen; fehlende Messung ist unbekannt. Belegten Pongvertrag oder vorhandene ICE-RTT nutzen, keinen neuen Echovertrag voraussetzen.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Zuerst entscheiden: belegten bestehenden Pongvertrag testen oder vorhandene ICE-RTT anzeigen. Für Pongsteuerung alte/neue Channels, fehlende Antwort, verspäteten Pong und Uhrsprung ohne echte Netzzeit simulieren. Unbekannt/abgelaufen bleibt ausdrücklich unbekannt. Neue Sequenzfelder erst nach bestätigtem Wirevertrag; keine Anzeige als Video- oder Eingabe-Endlatenz.

Quellanker der Eröffnung:

- [WebRTCManager.swift:72](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebRTCManager.swift:72) – Unbekannte Latenz startet als numerische Null.
- [WebRTCManager.swift:1299](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebRTCManager.swift:1299) – Jeder Ping überschreibt eine gemeinsame Startzeit und nutzt die Wanduhr.
- [WebRTCManager.swift:1600](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebRTCManager.swift:1600) – Empfangene Pongs werden ohne Abgleich des aktuellen DataChannels weitergereicht.
- [WebRTCManager.swift:1614](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebRTCManager.swift:1614) – Jeder Pong wird gegen die zuletzt gespeicherte Startzeit ausgewertet.
- [ContentView.swift:1295](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:1295) – Die Anzeige zeigt auch ohne bestätigten Messwert eine Millisekundenzahl.

<a id="r30"></a>

## R30 – API- und Medienzustand als kleine Anzeigeprojektion vereinheitlichen

Eröffnung: `swift-reviewer`. Evidenz: aktuell quellbelegt; Konsequenz hier nicht zwingend ausgeführt. Endbewertung: **zusammenführen**, P2, Paket B; ursprüngliche Aufwandsschätzung S.

**Ausgangspunkt:** Connected bedeutet in der Oberfläche API-Session vorhanden, während WebRTC eigene Connecting-/Stalled-/Connected-Zustände führt. Der bestehende API-Vertrag ist sinnvoll und getestet. Die verschiedenen booleschen Projektionen machen aber nicht überall deutlich, ob nur die API oder auch ein frisches Bild verfügbar ist.

**Vorschlag:** Eine kleine unveränderliche Statusprojektion aus vorhandenen Ownern diskutieren und für Titel/Verbindungsanzeige verwenden: API erreichbar, HID bereit, Video wird aufgebaut, Bild verfügbar oder Bild unterbrochen. Keine neue Session-State-Machine und keinen zusätzlichen autoritativen Owner erzeugen.

**Kreuzprüfung (Test Automation Engineer):** API-Connected bei Videofehler ist absichtliches, geprüftes Verhalten. Die Verbesserung betrifft seine verständliche Darstellung, nicht eine fehlerhafte Verbindungsfreigabe. Eine zweite autoritative Zustandsmaschine wäre unnötig.

**Architektur-Gegenposition:** Dieselbe unveränderliche Statusprojektion ist bereits R01; API-Verfügbarkeit bei Videofehler ist ausdrücklich gewünschtes Verhalten. Als eigener Umbau redundant. Keine weitere autoritative Zustandsmaschine aus drei Anzeigevorschlägen bilden.

**Entscheidung:** Reine unveränderliche Statusprojektion mit R01 bündeln. Keine zweite autoritative Session-State-Machine.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Kleine reine Anzeigeabbildung mit Tabellenfällen prüfen: API ohne Video, ICE ohne erstes Frame, altes/gestalltes Bild und Video trotz Audiofehler. Ein gezielter sichtbarer Darstellungscheck genügt zusätzlich. Bestehende API-/HID-Verfügbarkeit und Kontrollberechtigung dürfen sich nicht ändern. Falls Beschriftung allein reicht, darauf begrenzen.

In [R01](#r01) gebündelt.

Quellanker der Eröffnung:

- [ContentView.swift:51](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:51) – Connected wird aus dem vorhandenen API-Gerät abgeleitet.
- [ContentView.swift:102](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ContentView.swift:102) – Auch der Headless-Fenstertitel verwendet diesen API-Zustand.
- [SessionConnectionCoordinator.swift:164](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/SessionConnectionCoordinator.swift:164) – WebRTC-Fehler werden gemeldet, die API-Session bleibt absichtlich verbunden.
- [SessionConnectionCoordinatorTests.swift:174](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/tests/SessionConnectionCoordinatorTests.swift:174) – Der bestehende Test verankert genau diese gewünschte API-Verfügbarkeit bei Videofehler.

<a id="r31"></a>

## R31 – Aktionssequenzen gegen große Sprünge absichern

Eröffnung: `security-reviewer`. Evidenz: aktuell quellbelegt; Konsequenz hier nicht zwingend ausgeführt. Endbewertung: **präzisieren**, P2, Paket A; ursprüngliche Aufwandsschätzung M.

**Ausgangspunkt:** Ein authentifizierter Client kann mit einer großen gültigen Sequenz den gemeinsamen highwater erhöhen, auch wenn die spätere Ausführung nicht beginnt. Am maximalen Wert zeigt next_action_seq wieder denselben Wert; eine neue Aktion kollidiert dann mit dem vorhandenen Datensatz. Das ist aus dem Code ableitbar, kein nachgewiesener Angriff.

**Vorschlag:** Neue Sequenzen auf den angekündigten nächsten Wert oder einen kleinen erklärten Sprungbereich begrenzen. Den erschöpften Zustand ausdrücklich melden. Identische Wiederholungen behalten ihre reine Lookup-Semantik. Die Regeln für mehrere Clients zusammen dokumentieren.

**Kreuzprüfung (swift-reviewer):** Das Grenzwertproblem ist belegt, aber exaktes next_action_seq wäre eine Vertragsänderung für monotone Legacy-Clients. Zuerst Erschöpfung korrekt melden. Geteilte Sequenzen sind Clientkoordination innerhalb derselben Benutzervertrauensgrenze, kein belegter Angriff. Der Testpfad lautet tests/, nicht Tests/.

**Architektur-Gegenposition:** Großer Sequenzsprung kann tatsächlich erschöpfen; das erfordert authentifizierten lokalen Zugriff und beweist keinen Angriff. P2-Vertragsfehler statt Sicherheits-P1. Nur angekündigten Next-Wert beziehungsweise begründete Mehrclientregel entscheiden.

**Entscheidung:** Sequenzerschöpfung und Client-Konflikt explizit testen/melden. Identische Replays bleiben Lookup. Sprunglimit erst nach Kompatibilitätsentscheidung, kein abruptes exakt-next_seq-Gebot.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Bekannte identische Replays müssen vor jeder neuen Sprungregel weiterhin nur Lookup sein. Maximalwert, Erschöpfung und Zwei-Client-Konflikt prüfen; abgelehnte neue Sequenzen ändern highwater nicht. Sprunglimit nur mit versioniertem Vertrag oder bestätigter Kompatibilität einführen.

Quellanker der Eröffnung:

- [RemoteActionState.swift:164](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/RemoteActionState.swift:164) – nextActionSequence wird am maximalen Wert gekappt.
- [RemoteActionState.swift:206](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/RemoteActionState.swift:206) – reserve akzeptiert jede größere zulässige Sequenz und erhöht highwater vor der Ausführung.
- [RemoteActionStateTests.swift:36](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Tests/RemoteActionStateTests.swift:36) – Sequenztests behandeln kleine fortlaufende Werte, Konflikt und Eviction.

Ergänzung/Korrektur der Gegenprüfung: [RemoteActionStateTests.swift:36](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/tests/RemoteActionStateTests.swift:36) – Quellverzeichnis heißt tests, nicht Tests.

<a id="r32"></a>

## R32 – Cancel bei ausgelasteter Verbindungskapazität erreichbar halten

Eröffnung: `security-reviewer`. Evidenz: ungeprüfte Hypothese; Produktänderung erst nach Bedarf oder Reproduktion. Endbewertung: **erst prüfen**, P3, Paket C; ursprüngliche Aufwandsschätzung M.

**Ausgangspunkt:** Status, Aktionen und Cancel teilen sich 16 Verbindungsslots. Sind diese durch noch offene Aktionen belegt, wird auch die zusätzliche Abbruchverbindung verworfen. Die Hypothese ist eine erschwerte Stopp-Erreichbarkeit unter Last; eine laufende Störung wurde nicht reproduziert.

**Vorschlag:** Unklassifizierte Leser, authentifizierte Arbeitsanfragen und eine kleine authentifizierte Status-/Cancel-Kapazität getrennt begrenzen. Die Gesamtkapazität bleibt beschränkt. Überlastung mit festem Fehlercode statt nur kommentarlosem Verbindungsabbruch erklären.

**Kreuzprüfung (swift-reviewer):** Die Überlastungshypothese ist plausibel. Status/Cancel sind aber erst nach Lesen und Authentifizierung erkennbar. Eine Reservierung nach dem heutigen globalen acquire beseitigt die vorherige Ablehnung nicht. Verfügbarkeit gegen denselben privilegierten Benutzer ist kein erreichbarer Vertrag.

**Architektur-Gegenposition:** Neue Cancel-Verbindung ist nicht einziger Abbruchweg: Peer-Close cancelt den bestehenden nativen Auftrag. Hypothese zuerst unter synthetischer Sättigung prüfen; getrennte Verbindungsklassen erst bei verbleibender Stopp-/Statuslücke.

**Entscheidung:** Sättigung und separate Cancel-Erreichbarkeit im Fixture prüfen, vorhandenen Peer-Close-Cancel mitbewerten. Keine zweite Admission-Struktur ohne nachgewiesene Lücke.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Fixture belegt alle 16 aktuellen Arbeitsslots; Cancel muss dennoch authentifiziert erreichbar werden. Bereits die Admission-Phase und unklassifizierte Leser begrenzen. Gesamtkapazität bleibt endlich; Cancel-Antwort bedeutet weder abgeschlossenes Cleanup noch Rücknahme übertragener Eingaben.

Quellanker der Eröffnung:

- [LocalControlServer.swift:64](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/LocalControlServer.swift:64) – Alle neuen Verbindungen passieren denselben Limiter vor der Kommandoerkennung.
- [ReliabilityPolicies.swift:109](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/ReliabilityPolicies.swift:109) – Gemeinsame Grenze von 16 Verbindungen; Kommandozeitraum bis 30 Sekunden.
- [overlook-client.ts:118](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/mcp/overlook-control/src/overlook-client.ts:118) – Abbruch nach möglichem Dispatch verwendet eine zusätzliche Cancel-Verbindung.

Ergänzung/Korrektur der Gegenprüfung: [LocalControlServer.swift:203](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/LocalControlServer.swift:203) – Peer-Close beendet den ursprünglichen Request unabhängig von zusätzlicher Cancel-Verbindung.

<a id="r33"></a>

## R33 – Vertragsgrenzen gemeinsam maschinenlesbar veröffentlichen

Eröffnung: `security-reviewer`. Evidenz: aktuell quellbelegt; Konsequenz hier nicht zwingend ausgeführt. Endbewertung: **präzisieren**, P2, Paket A; ursprüngliche Aufwandsschätzung M.

**Ausgangspunkt:** Clients entdecken protocol_version=2 und Funktionen, müssen aber Frame-TTL, Retention und Grenzwerte aus Code oder README kennen. Das TypeScript-Schema erlaubt Scroll-Delta 0, Swift lehnt es ab; das TypeScript-Sequenzmaximum liegt um eins über dem nativen Maximum.

**Vorschlag:** Status um einen festen Vertragsdeskriptor mit Version/Revision, Befehlen, Aktionsarten und Grenzen erweitern. Native und Adapter-Schemas durch gemeinsame Fixtures auf Gleichheit prüfen. Unbekannte Protokolle vor Eingaben mit einem eigenen verständlichen Code ablehnen.

**Kreuzprüfung (swift-reviewer):** Schemaabweichungen zuerst mit gemeinsamen Fixtures beheben. Ein umfassender Deskriptor schafft sonst eine dritte Vertragskopie. Neue native Statusfelder erreichen MCP aktuell nicht automatisch: sanitizeStatusPayload verwendet eine feste Allowlist. Unbekanntes Protocol 2 darf keinen Legacy-Fallback auslösen.

**Architektur-Gegenposition:** Null-Scroll und Sequenzmaximum sind echte Schemaabweichungen; sie erfordern keinen neuen Vertragsdeskriptor. P2 zuerst diese zwei Grenzen mit gemeinsamen Fixtures angleichen. Zusätzliche Discovery-Versionierung nach realem Verbraucherbedarf.

**Entscheidung:** Zuerst belegte Null-Scroll- und Sequenzmaximum-Abweichungen per gemeinsamen Grenzwertfällen angleichen. Optionaler Discovery-Deskriptor folgt nur bei Bedarf und ohne dritte Vertragskopie.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Grenzwerte und Null-Scroll zunächst auf beiden Seiten angleichen. Ein kleiner optionaler Deskriptor muss native Statusantwort, Sanitizer und Discovery überleben. Fehlende neue Metadaten dürfen bestehende lesende beziehungsweise ausdrücklich verwendete Legacy-Funktionen nicht pauschal sperren.

Quellanker der Eröffnung:

- [LocalControlServer.swift:260](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/LocalControlServer.swift:260) – Status nennt Version, Build und flache Capabilities, aber keine Vertragsgrenzen.
- [RemoteActionState.swift:158](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/RemoteActionState.swift:158) – Frame-TTL und Quittungsretention sind interne Defaults.
- [control-contracts.ts:15](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/mcp/overlook-control/src/control-contracts.ts:15) – Adapter-Sequenzmaximum und Scroll-Schema weichen vom nativen Maximum beziehungsweise Null-Delta-Verbot ab.

<a id="r34"></a>

## R34 – Legacy-Eingaben im Tool-Katalog eindeutig kennzeichnen

Eröffnung: `security-reviewer`. Evidenz: aktuell quellbelegt; Konsequenz hier nicht zwingend ausgeführt. Endbewertung: **empfehlen**, P2, Paket B; ursprüngliche Aufwandsschätzung S.

**Ausgangspunkt:** Die Legacy-Tools verlangen Headless, bieten aber keine Frame-Bindung und keine nachträglich abfragbare Aktionssequenz. Ihre Discovery-Beschreibungen wirken ähnlich wie die neue API. Erst README/Skill warnen ausdrücklich vor dem Ausweichen nach einer abgelehnten bewachten Aktion.

**Vorschlag:** Legacy-Tools als Kompatibilitätsschnittstelle beschreiben, inklusive fehlender Frame-/Quittungsbindung. Mutations-, Destruktivitäts- und Nicht-Idempotenz-Hinweise konsistent setzen; Status und Crashdiagnose als lesend markieren. Für neue Arbeit im Katalog unmittelbar auf observe/act verweisen.

**Kreuzprüfung (swift-reviewer):** Kataloghinweise sind die kleinste sinnvolle Verbesserung. Native Gates bleiben die Autorität; Legacy-Tools behalten ihren legitimen Kompatibilitätszweck. Destruktivitäts-Hinweise beschreiben mögliche Zielwirkungen, keine automatisch untersagte Nutzung.

**Architektur-Gegenposition:** Legacy ist weiterhin legitim kompatibel; Kennzeichnung rechtfertigt keine ungefragte Abschaltung oder Frame-Metadaten-Erfindung. Kleine P2-Discovery-Korrektur verdeutlicht bestehenden V2-Vertrag.

**Entscheidung:** Legacy-Tools im Katalog klar markieren und V2 empfehlen; legitime Kompatibilität erhalten. Nach abgelehntem act kein automatischer Legacy-Fallback.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Alle neun Tools auf konsistente Annotations prüfen. Argumente und ausdrücklich verwendeter Legacy-Pfad bleiben kompatibel. Nach abgelehntem act darf weder automatisch auf Legacy gewechselt noch nach unbekannter Wirkung wiederholt werden. Status/Diagnose bleiben lesend.

Quellanker der Eröffnung:

- [server.ts:59](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/mcp/overlook-control/src/server.ts:59) – Legacy-Text, Shortcut und Click stehen neben den framegebundenen Tools ohne entsprechende Annotations.
- [overlook-client.ts:55](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/mcp/overlook-control/src/overlook-client.ts:55) – Legacy-Eingaben besitzen Statuspreflight, aber keine Frame-/Aktionsreferenz.
- [SKILL.md:61](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/mcp/overlook-control/skills/overlook-kvm-control/SKILL.md:61) – Der Skill erklärt die Fallback-Grenze, die Tool-Discovery selbst jedoch nicht vollständig.

<a id="r35"></a>

## R35 – Ein engeres Frame-Altersbudget pro Aktion erlauben

Eröffnung: `security-reviewer`. Evidenz: ungeprüfte Hypothese; Produktänderung erst nach Bedarf oder Reproduktion. Endbewertung: **zurückstellen**, P3, Paket C; ursprüngliche Aufwandsschätzung M.

**Ausgangspunkt:** Ein unverbrauchter Frame bleibt innerhalb von 30 Sekunden gültig, während sich eine entfernte Seite ohne lokale Mutation verändern kann. Frische Aufnahme, Sessionbindung und Verbrauch funktionieren bereits; eine konkrete Fehlbedienung wurde nicht beobachtet.

**Vorschlag:** Optional ein kleineres max_frame_age_ms an act zulassen, das die serverseitige Obergrenze ausschließlich verschärft. Verbleibendes Altersbudget in Beobachtungsmetadaten nennen. Für Text nach Auswahl weiterhin eine neue sichtbare Prüfung verlangen.

**Kreuzprüfung (swift-reviewer):** Ein engeres Altersbudget ist ergänzend sinnvoll, beweist aber weder Fokus noch unveränderten Remote-Inhalt. Der neue Requestparameter muss auch zur Replay-Identität gehören; sonst gilt derselbe Action-Record trotz nachträglich geänderter Gültigkeitsbedingung als identisch.

**Architektur-Gegenposition:** 30 Sekunden sind ein begrenzter Vertrag, keine garantierte Zielseitenstabilität. Ein optionales Budget behebt keinen Fokusverlust. P3-Vertragserweiterung erst bei belegtem Bedarf. Frische observe-Nutzung und vorhandene Dispatchprüfung zuerst nutzen.

**Entscheidung:** Engeres Framebudget erst bei konkreter zeitkritischer Aufgabe. Es muss in Digest und Dispatchprüfung passen; es beweist weder Fokus noch unveränderten Bildinhalt.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Budget in den Digest aufnehmen und beim Gateeintritt sowie consumeFrame unmittelbar vor Dispatch prüfen. Gleiche Sequenz mit geändertem Budget erzeugt Konflikt; identischer Replay bleibt Lookup. Default bleibt kompatibel, Clientbudget kann 30 Sekunden nur verkürzen; monotone Zeit verwenden.

Quellanker der Eröffnung:

- [RemoteActionState.swift:158](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/RemoteActionState.swift:158) – Beobachtete Frames dürfen standardmäßig bis 30 Sekunden alt sein.
- [LocalControlServer.swift:417](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/LocalControlServer.swift:417) – Die Ausführung prüft Alter und Generation vor dem Dispatch.
- [README.md:62](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/mcp/overlook-control/README.md:62) – Die Dokumentation benennt ausdrücklich die Grenzen hinsichtlich Fokus und asynchroner Zieländerungen.

<a id="r36"></a>

## R36 – Übertragungsumfang und Dispatchbeginn in Quittungen ausdrücken

Eröffnung: `security-reviewer`. Evidenz: aktuell quellbelegt; Konsequenz hier nicht zwingend ausgeführt. Endbewertung: **zurückstellen**, P3, Paket C; ursprüngliche Aufwandsschätzung M.

**Ausgangspunkt:** queued, running, not_started und outcome_unknown sind korrekt getrennt. Intern ist zusätzlich gespeichert, ob Dispatch begann. Der MCP-Ausgang kann dennoch ok:true bei not_started tragen; die Grenze zwischen Transportergebnis und bestätigter Zieländerung steht in der Dokumentation.

**Vorschlag:** Quittungen um feste Felder für den Aussageumfang ergänzen, etwa completion_scope=transport und dispatch_started. Folgeschritte für jeden Zustand maschinenlesbar nennen. Eine bestätigte Zieländerung darf der Transportserver niemals selbst behaupten.

**Kreuzprüfung (swift-reviewer):** dispatch_started ist brauchbar, wenn es die erreichte Dispatchgrenze ausdrückt, nicht tatsächlich übertragene Bytes. Maschinenlesbare Folgeschritte dürfen unbekannte Wirkung keinesfalls in eine Replay-Freigabe umwandeln. ok bleibt Erfolg der Vertragsantwort, nicht Zielerfolg.

**Architektur-Gegenposition:** ok:true bestätigt gültige Quittung, nicht Ausführung; not_started ist bereits korrekt dokumentiert und kein Fehler. P3 optionale Klarstellung nach nachgewiesenem Consumer-Missverständnis. Kein weiterer Ergebnis- oder Verifikations-Owner.

**Entscheidung:** Bestehende Outcome-Semantik klar erhalten. Neue Quittungsfelder nur mit konkretem Clientbedarf; niemals Zielpersistenz oder Replay-Freigabe aus Transportmetadaten ableiten.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Vor-/Nach-Dispatchfehler, retired Session und verlorene Antwort prüfen. Alle Quittungswege sowie Adapter-Output-Schema erhalten die neuen optionalen Felder. Bei outcome_unknown nur Status/Beobachtung empfehlen; keine neue Sequenz oder automatische Wiederholung. Persistenz und Teilwirkung bleiben ausdrücklich unbestätigt.

Quellanker der Eröffnung:

- [RemoteActionState.swift:137](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/RemoteActionState.swift:137) – Das Ledger unterscheidet intern didDispatch vom Aktionszustand.
- [LocalControlServer.swift:456](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/LocalControlServer.swift:456) – Die Antwort enthält Zustand und optional Fehler, aber keine Dispatch- oder Verifikationsstufe.
- [README.md:74](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/mcp/overlook-control/README.md:74) – Die Bedeutung von ok und transmitted muss bisher aus Prosa erschlossen werden.

<a id="r37"></a>

## R37 – Crashdiagnosen mit Herkunft und begrenzten Freitextfeldern versehen

Eröffnung: `security-reviewer`. Evidenz: aktuell quellbelegt; Konsequenz hier nicht zwingend ausgeführt. Endbewertung: **präzisieren**, P3, Paket C; ursprüngliche Aufwandsschätzung S.

**Ausgangspunkt:** Die Diagnose ist bereits größenbeschränkt und reduziert private Daten. Ein passender Dateiname reicht jedoch zur Zuordnung; Report-Strings bleiben in Teilen frei. Ein fremder oder manipulierter Report wurde nicht gelesen oder nachgewiesen.

**Vorschlag:** Vorhandene App-/Bundle-Identität prüfen und fehlende Herkunft ausdrücklich als unbekannt kennzeichnen. Zeit, Signal und Ausnahme strukturell begrenzen; Steuer-/Richtungszeichen in Symbolen sichtbar entschärfen. Die Ausgabe als untrusted Reportdaten kennzeichnen, ohne daraus Bedienanweisungen abzuleiten.

**Kreuzprüfung (swift-reviewer):** Herkunftsprüfung verbessert Diagnosequalität. Fehlende Metadaten älterer Apple-Reports dürfen die nützliche Zusammenfassung nicht pauschal verhindern. Die installierte Bundle-ID ist com.overlook.app; ein generisch angenommener Upstream-Identifier wäre hier falsch. Manipulation ist nicht beobachtet.

**Architektur-Gegenposition:** Dateipräfix ist keine Identitätsprüfung; manipulierte Reports oder Ausführung ihrer Texte sind jedoch nicht nachgewiesen. P3 auf Herkunft unbekannt und begrenzte Textzeichen beschränken. Fehlende Bundle-ID älterer Formate nicht als Angriff behandeln.

**Entscheidung:** Diagnoseherkunft begrenzt verbessern; historische Identitäten und unbekannte Metadaten unterstützen. Kein behaupteter Manipulationsvorfall, kein Rohreport.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Aktuelle Identität, explizit unterstützte historische Identitäten, fehlende Metadaten und falsche App unterscheiden. Fehlende Herkunft als unbekannt markieren. Steuerzeichen entschärfen, freigegebene Symbole erhalten. Keinerlei Rohbericht, Bedienanweisung oder zusätzliche private Felder ausgeben.

Quellanker der Eröffnung:

- [diagnostics.ts:52](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/mcp/overlook-control/src/diagnostics.ts:52) – Die Report-Auswahl beruht auf Dateipräfix und mtime, nicht geprüfter App-Identität.
- [diagnostics.ts:149](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/mcp/overlook-control/src/diagnostics.ts:149) – Freitext wird verkürzt und bezüglich Pfaden/IPs redigiert, aber strukturell kaum geprüft.
- [diagnostics.test.mjs:9](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/mcp/overlook-control/tests/diagnostics.test.mjs:9) – Fixtures prüfen jüngsten Report und Redaktion, nicht falsche App-Identität oder Steuerzeichen.

<a id="r38"></a>

## R38 – Token-Datei über einen begrenzten geprüften Handle lesen

Eröffnung: `security-reviewer`. Evidenz: aktuell quellbelegt; Konsequenz hier nicht zwingend ausgeführt. Endbewertung: **präzisieren**, P3, Paket C; ursprüngliche Aufwandsschätzung S.

**Ausgangspunkt:** Die normalen Rechte sind geschützt. Der Adapter folgt beim stat/readFile Pfadwechseln und liest die ganze Datei. Der absolute Request-Timeout beendet das Ergebnis, nicht zwingend bereits laufende Datei-I/O. Kein Austausch einer echten Datei wurde untersucht.

**Vorschlag:** Einen Handle öffnen, darüber regulären Dateityp, Rechte, Eigentümer und eine kleine Maximalgröße prüfen; begrenzt lesen und zuverlässig schließen. Symlinks nach erklärter Policy ablehnen. Nur feste Fehlercodes ausgeben, niemals Tokeninhalt.

**Kreuzprüfung (swift-reviewer):** Ein geprüfter Handle ist eine begrenzte Robustheitsverbesserung, keine Same-User-Isolation. Eine FIFO darf bereits open nicht unbegrenzt blockieren. Atomarer Tokenwechsel des Produzenten muss als normale Rotation behandelt werden, ohne Eingaben blind erneut zu senden.

**Architektur-Gegenposition:** Der Produzent schreibt bereits atomar und restriktiv; ein gleichprivilegierter Angreifer ist keine neue belegte Bedrohung. Begrenzte P3-Ressourcen-/Dateiprüfung am gleichen Handle sinnvoll; keine Credentialmigration.

**Entscheidung:** Begrenztes Dateilesen am selben geprüften Handle als kleine Robustheitsarbeit. FIFO darf schon beim Öffnen nicht blockieren; normale atomare Tokenrotation erhalten.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Nichtblockierende beziehungsweise begrenzte Öffnung, Typ/Rechte/Eigentümer/Größe am selben Handle und zuverlässiges Schließen prüfen. Fixture für FIFO, Symlink, große Datei und atomare Rotation. Alte Tokens dürfen höchstens Authentifizierungsfehler verursachen; abgelehnte Datei verursacht keinen TCP-Dispatch und keine Secret-Ausgabe.

Quellanker der Eröffnung:

- [control-transport.ts:85](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/mcp/overlook-control/src/control-transport.ts:85) – Getrenntes stat und readFile prüfen Berechtigungen, aber weder regulären Dateityp noch Größe am selben Handle.
- [LocalControlServer.swift:89](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/LocalControlServer.swift:89) – Der Produzent schützt das Verzeichnis und schreibt die Token-Datei atomar mit restriktiven Rechten.
- [error-boundaries.test.mjs:22](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/mcp/overlook-control/tests/error-boundaries.test.mjs:22) – Breite Dateirechte sind bereits als synthetischer Fehlerfall abgedeckt.

<a id="r39"></a>

## R39 – Die TLS-Vertrauensentscheidung pro Gerät sichtbar und bindbar machen

Eröffnung: `security-reviewer`. Evidenz: aktuell quellbelegt; Konsequenz hier nicht zwingend ausgeführt. Endbewertung: **zurückstellen**, P3, Paket C; ursprüngliche Aufwandsschätzung M.

**Ausgangspunkt:** Der Gerätepfad akzeptiert standardmäßig die TLS-Vertrauensausnahme. Das löst die Verbindung zu selbst signierenden KVMs, bindet aber keine explizit bestätigte Zertifikatsidentität. Ein Netzangriff oder Zertifikatswechsel wurde nicht geprüft.

**Vorschlag:** Die Vertrauensart pro Gerät ausdrücklich anzeigen und optional ein von Wolfgang nativ bestätigtes Zertifikat beziehungsweise einen Fingerprint binden. Änderungen erfordern erneute lokale Entscheidung. Der MCP-Status darf nur die Vertrauensart und einen passenden Sperrgrund melden.

**Kreuzprüfung (swift-reviewer):** HTTP-Pinning allein hinterlässt die separat implementierte Janus-TLS-Ausnahme. Gerätevertrauen braucht einen gemeinsamen Vertrag für API, HID-WebSocket und Signaling. Optional vorbereiten; keine automatische Verschärfung der funktionierenden selbstsignierten Geräteverbindung und keine durch Agenten angenommene Identität.

**Architektur-Gegenposition:** Selbstsignierte Geräte sind unterstützte Realität; Pinning nur im HTTP-Client lässt unabhängiges Signaling unverifiziert. P2 erst Vertrauensart offenlegen und Endpoint-Vertrag planen. Keine ungefragte Profil-/Credentialänderung.

**Entscheidung:** Gerätevertrauen gemeinsam für API/HID/Janus entwerfen, bevor Pinning gewählt wird. Bestehende selbstsignierte Profile nicht automatisch verschärfen; native Benutzerentscheidung erforderlich.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Fixtures prüfen Zertifikatswechsel auf allen Transportpfaden und mehreren Geräteendpunkten. Eine bestätigte Bindung gilt konsistent, explizite Ausnahmen bleiben erkennbar. Native Benutzerbestätigung und klarer Rotationsweg; bestehende Profile bleiben nutzbar bis zur bewussten Entscheidung. Keine echten Credentials nötig.

Quellanker der Eröffnung:

- [GLKVMClient.swift:339](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/GLKVMClient.swift:339) – allowInsecureTLS akzeptiert erhaltenes ServerTrust ohne eigene Zertifikatsbindung.
- [GLKVMClient.swift:359](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/GLKVMClient.swift:359) – Die Ausnahme ist im Standardkonstruktor aktiviert.
- [GLKVMClient.swift:392](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/GLKVMClient.swift:392) – Auch der Gerätekonstruktor verwendet diesen Standard.

Ergänzung/Korrektur der Gegenprüfung: [WebRTCManager.swift:59](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebRTCManager.swift:59) – Signaling besitzt eine eigene TLS-Vertrauensausnahme; HTTP-Pinning allein wäre unvollständig.

<a id="r40"></a>

## R40 – Den ersten lesenden Startweg und stdio-Grenzen vollständig erklären

Eröffnung: `security-reviewer`. Evidenz: belegte Prüf-/Abnahmelücke; kein damit bewiesener Produktdefekt. Endbewertung: **empfehlen**, P2, Paket B; ursprüngliche Aufwandsschätzung S.

**Ausgangspunkt:** Beim statischen Einstieg anhand der Dokumentation endet der Weg bei node dist/index.js. Der stille stdio-Prozess ist erwartbar, beweist aber keine App-Verbindung. Vollständige Clientregistrierung, lesende Erstabnahme und der Unterschied zwischen EOF und Prozessverlust sind nicht als zusammenhängender Weg dokumentiert. Laufzeit oder Zeit bis zum Erstwert wurden hier nicht gemessen.

**Vorschlag:** Einen kurzen Einstieg mit Node-Voraussetzung, absolutem Client-Entry-Point, normal gestarteter App und tools/list → status → observe ergänzen. stdout ist ausschließlich MCP; kein Terminal-Banner. Bestehende Fehlercodes in konkrete lokale nächste Schritte übersetzen. EOF ist geprüft; harter Prozessverlust bleibt ohne zusätzliche Evidenz unbestätigt.

**Kreuzprüfung (swift-reviewer):** Ein kurzer lesender Runbook-Pfad reicht. Ein gestarteter stiller stdio-Prozess belegt keine App-Verbindung. EOF-Test und harter Prozessverlust haben unterschiedliche Cleanup-Garantien; daraus darf keine zusätzliche generische Installationsarchitektur entstehen.

**Architektur-Gegenposition:** Stiller stdio-Start ist normal; EOF ist bereits getestet. Harte Prozessbeendigung ist eine eigene Nachweisgrenze. Kurzen P2-README-Erstpfad ergänzen; kein neues Installations-/Reparaturframework und kein verpflichtender Prozesskiller.

**Entscheidung:** Kurzen rein lesenden Einstieg und Fehlersuche dokumentieren: korrektes Paket, Appstart, Clientregistrierung, tools/list, status, observe. stdout bleibt Protokoll; keine Tokenkopie.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Node-Voraussetzung, absoluter Entry-Point, separat gestartete App und tools/list → status → observe nachvollziehbar dokumentieren. Status umfasst API/HID/Video getrennt. stdout bleibt MCP; keine Tokenkopie oder Remote-Eingabe. Harten Prozessverlust separat synthetisch testen oder die Abnahmegrenze ausdrücklich nennen.

Quellanker der Eröffnung:

- [README.md:18](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/mcp/overlook-control/README.md:18) – Build/Start sind beschrieben; ein vollständiger App-/Client-/Status-Erstpfad fehlt.
- [package.json:6](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/mcp/overlook-control/package.json:6) – Die Node-Voraussetzung steht nur im Paketmetadatum.
- [index.ts:5](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/mcp/overlook-control/src/index.ts:5) – stdio startet unabhängig von der App; Fehler gehen sanitisiert nach stderr.
- [stdio-lifecycle.integration.test.mjs:54](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/mcp/overlook-control/tests/stdio-lifecycle.integration.test.mjs:54) – EOF-Abbruch ist abgedeckt; harter Prozessverlust ist davon zu unterscheiden.

<a id="r41"></a>

## R41 – Den M154-Eingabepfad sichtbar abnehmen

Eröffnung: `Test Automation Engineer`. Evidenz: belegte Prüf-/Abnahmelücke; kein damit bewiesener Produktdefekt. Endbewertung: **empfehlen**, P1, Paket A; ursprüngliche Aufwandsschätzung S.

**Ausgangspunkt:** Der Rollout vom 2. Oktober bestätigt frische M154-Frames und Readiness. Damit ist die Ausgabe eines echten Click-/Text-/Shortcut-Auftrags auf dem Ziel noch nicht belegt. Die vorhandenen Vertrags- und Capture-Tests bleiben wertvoll, schließen diese Integrationsgrenze aber nicht.

**Vorschlag:** Eine kurze gesonderte Hardware-Abnahme im verifizierten Headless-Modus vorsehen: eigenes flüchtiges Testfeld öffnen, Click, eindeutigen synthetischen Text und Escape über den aktiven MCP-Adapter senden. Vorher und nachher frische Frames und Sessionidentität sichern; keine Fachanwendung oder gespeicherten Dokumente als Testdaten verwenden.

**Kreuzprüfung (security-reviewer):** Die Abnahmegrenze ist korrekt. Das Testfeld muss eindeutig isoliert und der konkrete Eingabetest gesondert freigegeben sein.

**Architektur-Gegenposition:** Historischer Readiness-/PNG-Smoke enthält ausdrücklich keine reale Eingabe; heutige App ist nicht gestartet. P1-Abnahmevorbereitung schließt zentrale Integrationsgrenze; diese Reviewrunde führt sie nicht aus.

**Entscheidung:** Hardware-Abnahme als offene Evidenzlücke priorisieren, nicht als bewiesenen Defekt. Flüchtiges isoliertes Testfeld, drei synthetische Aktionen und sichtbare lokale Kontrolle gesondert durchführen.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Drei synthetische Kernaktionen genügen. Zustand und Session vorher/nachher prüfen; keine Remote-Screenshots, Credentials oder Fachinhalte protokollieren. Sichtbaren Effekt vor Ort bestätigen, Transportquittung separat notieren. Heute keine Geräteaktion ausführen.

Quellanker der Eröffnung:

- [2026-10-02-overlook-m154-mcp22-rollout.md:28](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/docs/reviews/2026-10-02-overlook-m154-mcp22-rollout.md:28) – Der bestandene reale Adapterpfad enthält ausdrücklich keine HID-Eingaben.
- [LocalControlServerStubs.swift:1](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/tests/LocalControlServerStubs.swift:1) – Kontrollserver-Fixtures ersetzen InputManager und WebRTCManager.
- [README.md:337](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/README.md:337) – Capture-Fixtures belegen keine sichtbare Texteingabe am KVM.

<a id="r42"></a>

## R42 – Unterstützung durch eine kleine Gerätematrix begrenzen

Eröffnung: `Test Automation Engineer`. Evidenz: belegte Prüf-/Abnahmelücke; kein damit bewiesener Produktdefekt. Endbewertung: **empfehlen**, P2, Paket A; ursprüngliche Aufwandsschätzung M.

**Ausgangspunkt:** Der dokumentierte Live-Smoke ist ein einzelner Gerätepfad. Ein Deployment-Target macOS 14 und arm64-Compilerproben sind keine Laufzeitabnahme weiterer macOS-Versionen, Intel-Macs oder Firmwarestände.

**Vorschlag:** Eine kompakte Matrix im bestehenden Reviewbereich führen: tatsächliches KVM-Modell/Firmware, Mac-Architektur/macOS, App-/SDK-Version, Auflösung, Netzwerkpfad und geprüfte Funktionen. Mit der vorhandenen Kombination beginnen. Weitere Geräte oder Intel/macOS 14 bis zur verfügbaren Hardware als ungeprüft markieren statt einen großen Testkreuzverbund aufzubauen.

**Kreuzprüfung (security-reviewer):** Eine Matrix hilft, rechtfertigt aber keinen neuen Hardwarepark oder zusätzlichen Gerätezugriff für diese Einzelinstallation.

**Architektur-Gegenposition:** Deployment-Target und arm64-Probe sind keine Intel-/macOS-14-/Firmwareabnahme; ein Kreuzprodukt wäre unverhältnismäßig. P2 auf verfügbare Basiskombination samt Versionsmetadaten begrenzen; weitere Kombinationen ausdrücklich ungeprüft.

**Entscheidung:** Eine vorhandene Hardwarekombination sauber dokumentieren; weitere Plattformen ungeprüft lassen. Kein neuer Testgerätepark und keine privaten Adressen/Seriennummern.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Mit einer vorhandenen Kombination beginnen: Modell/Firmware, Architektur/macOS, App-/SDK-Version und geprüfte Funktionen. Nur pseudonymisierte Gerätebezeichnung, keine Hostadresse oder Seriennummer. Weitere Kombinationen ausdrücklich ungeprüft lassen; bei Bedarf erweitern.

Quellanker der Eröffnung:

- [README.md:69](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/README.md:69) – Der Anspruch umfasst Comet und kompatible Janus-Geräte.
- [README.md:82](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/README.md:82) – Die dokumentierte Untergrenze ist macOS 14.
- [test-webrtc-compatibility.sh:39](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/scripts/test-webrtc-compatibility.sh:39) – Die Kompatibilitätsprobe kompiliert explizit für arm64.
- [2026-10-02-overlook-m154-mcp22-rollout.md:26](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/docs/reviews/2026-10-02-overlook-m154-mcp22-rollout.md:26) – Der Live-Smoke betrifft dasselbe KVM und 1920×1080.

<a id="r43"></a>

## R43 – Reconnect und Dauerbetrieb am tatsächlichen KVM qualifizieren

Eröffnung: `Test Automation Engineer`. Evidenz: belegte Prüf-/Abnahmelücke; kein damit bewiesener Produktdefekt. Endbewertung: **präzisieren**, P1, Paket A; ursprüngliche Aufwandsschätzung M.

**Ausgangspunkt:** Session- und Statistikgenerationen besitzen Regressionstests. Der Bericht belegt jedoch keinen langen M154-Betrieb, wiederholte reale ICE-/Janus-Neuverbindungen oder Gerätewechsel. Das ist eine offene Abnahme, kein nachgewiesener Reconnectfehler.

**Vorschlag:** Einen begrenzten Abnahmelauf mit mindestens einer Stunde Video, zehn kontrollierten Disconnect/Reconnect-Zyklen und einer kurzen gezielten Netzunterbrechung planen. Framealter, Session-/Quellenidentität, Wiederanlaufzeit, RSS und CPU erfassen; mit dem gesicherten M109 unter gleichen Bedingungen vergleichen. Endpunktwechsel nur bei vorhandenem zweitem Testgerät.

**Kreuzprüfung (security-reviewer):** Eine Stunde und zehn Zyklen sind ohne Nutzungsanforderung willkürlich. Netzunterbrechung und M109-Wechsel unterbrechen reale Arbeit.

**Architektur-Gegenposition:** Eine Stunde, zehn Zyklen und zwingender M109-Vergleich sind unbegründete Zahlen beziehungsweise zusätzliche Installationsarbeit. P1-Abnahme planen; Dauer und Ressourcenbudget an Wolfgangs Nutzung binden. Vorhandenen Rückfallstand erhalten, keinen Vergleichswechsel erzwingen.

**Entscheidung:** Zunächst begrenztes Wartungsfenster und drei reguläre Reconnect-Zyklen. Dauer/Last aus realem Einsatz ableiten; Netzunterbrechung und M109-Vergleich separat vorbereiten.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Zunächst begrenztes Wartungsfenster und drei reguläre Reconnect-Zyklen; Dauerlauf bei Auffälligkeit erweitern. Netzunterbrechung und App-Wechsel separat freigeben. Nur Zeiten, Ressourcen und pseudonymisierte Sessionwechsel erfassen. M109-Vergleich ohne Konfigurationsverlust vorbereiten.

Quellanker der Eröffnung:

- [2026-10-02-overlook-m154-mcp22-rollout.md:54](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/docs/reviews/2026-10-02-overlook-m154-mcp22-rollout.md:54) – Die länger laufende Geräteabnahme einschließlich Reconnect ist offen.
- [2026-10-02-overlook-webrtc154-spike.md:143](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/docs/reviews/2026-10-02-overlook-webrtc154-spike.md:143) – Netzunterbrechung und Endpunktwechsel sind explizite nächste Prüfschritte.
- [SessionConnectionCoordinatorTests.swift:345](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/tests/SessionConnectionCoordinatorTests.swift:345) – Der Videoaufbau im Coordinator-Test ist eine steuerbare Fixture-Closure.

<a id="r44"></a>

## R44 – Audio-I/O und Abschalten getrennt von Linkkompatibilität prüfen

Eröffnung: `Test Automation Engineer`. Evidenz: belegte Prüf-/Abnahmelücke; kein damit bewiesener Produktdefekt. Endbewertung: **präzisieren**, P2, Paket A; ursprüngliche Aufwandsschätzung M.

**Ausgangspunkt:** Audio-Shim und Factory sind real gelinkt, aktives Playout/Recording und Geräteaustausch sind damit nicht ausgeführt. Der Rollout mit ausgeschaltetem Audio ersetzt diese Prüfung nicht.

**Vorschlag:** Playback mit einem bekannten Testsignal über Standard- und gewähltes Ausgabegerät abnehmen. Mikrofon nur in einem ausdrücklich gestarteten, begrenzten Test einschalten; danach Ausschalten, Reconnect, Gerätewechsel und Terminate prüfen. Für AudioUnit-Fehlerpfade eine schmale injizierbare Systemgrenze nutzen, statt ganze WebRTC-Typen nachzubauen.

**Kreuzprüfung (security-reviewer):** Audio-I/O ist tatsächlich ungeprüft. Eine neue injizierbare Systemgrenze sollte erst aus konkretem Testbedarf entstehen.

**Architektur-Gegenposition:** Native Link-/Idle-Proben beweisen kein Audio-I/O; Audio war historisch ausgeschaltet. P2-Abnahmevorbereitung, nach R24-Fehlernachweis. Keine große Audio-Abstraktion.

**Entscheidung:** Playback mit Testsignal; Mikrofon nur ausdrücklich und zeitlich begrenzt, ohne Aufzeichnung. R24-Fehlerfälle ergänzen funktionalen I/O-Test, ersetzen ihn nicht.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Playback zunächst mit synthetischem Testsignal separat abnehmen. Mikrofonaufnahme ausschließlich ausdrücklich starten, zeitlich begrenzen und ohne Aufzeichnungsdatei prüfen; danach native Aufnahmeindikatoren und Stop/Terminate kontrollieren. Zusätzliche Abstraktion erst für einen benannten Fehlerpfad.

Quellanker der Eröffnung:

- [WebRTCCompatibilityTests.swift:6](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/tests/WebRTCCompatibilityTests.swift:6) – Die Probe startet ausdrücklich kein AudioUnit-I/O.
- [WebRTCCompatibilityTests.swift:38](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/tests/WebRTCCompatibilityTests.swift:38) – Der Audiofall prüft Protokoll, Properties und den Idle-Lifecycle.
- [WebRTCAudioDevice.swift:219](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/Overlook/WebRTCAudioDevice.swift:219) – Die tatsächliche Aufnahme besitzt einen separaten Stop-Pfad.
- [README.md:251](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/README.md:251) – Audio-/Mikrofonänderungen erfordern Reconnect.

<a id="r45"></a>

## R45 – Jiggler-Readback und tatsächliches Wachhalten getrennt bewerten

Eröffnung: `Test Automation Engineer`. Evidenz: belegte Prüf-/Abnahmelücke; kein damit bewiesener Produktdefekt. Endbewertung: **empfehlen**, P1, Paket A; ursprüngliche Aufwandsschätzung M.

**Ausgangspunkt:** Die vorhandenen Tests sichern Readback, Ownership, Wiederherstellung und Fehlerbehandlung. Die tatsächliche Wirkung auf den Idle-/Lock-Zustand des Zielrechners ist weiterhin unbelegt; ein zusätzlicher lokaler Mausbewegungsloop wäre keine Abnahme dieser Firmwarefunktion.

**Vorschlag:** Die Wirksamkeitsprüfung zunächst parken, sofern Wolfgang sie nicht benötigt. Bei Bedarf einen separaten Testdesktop mit bekanntem Idle-Limit verwenden: Firmware-Jiggler an/aus, Zustand jenseits dieses Limits beobachten und anschließend Headless-Pause sowie Rückkehr in Manual prüfen. Ursprüngliche Einstellung am Ende bestätigen.

**Kreuzprüfung (security-reviewer):** Pauschales Parken widerspricht der ausdrücklichen Jiggler-Priorität. Readback und tatsächliche Wirkung bleiben trotzdem getrennte Nachweise.

**Architektur-Gegenposition:** Parken wegen fehlendem Bedarf widerspricht Wolfgangs ausdrücklichem Ziel: Mouse Jiggler funktioniert nicht gut. P1-Abnahmevorbereitung für bestehendes Ziel; Readback-/Lifecycle-Fixes sind vorhanden und werden nicht erneut als offen behandelt.

**Entscheidung:** Wachhaltewirkung ist ein bestehendes Nutzerziel. Firmware an/aus, Idle-Grenze, Headless-Pause und Manual-Rückkehr am freigegebenen Testsystem abnehmen; ursprüngliche Settings bestätigen.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Begrenzte Wirksamkeitsabnahme auf freigegebenem Testsystem mit bekanntem Idle-Limit vorbereiten. Keine Arbeits-Lock-Policy abschalten. An/aus, Wirkung, Headless-Pause und Manual-Rückkehr vor Ort prüfen; Ausgangseinstellung wieder bestätigen. Keine Screenshots protokollieren. Heute keine Geräteänderung durchführen.

Quellanker der Eröffnung:

- [MouseJigglerLifecycleTests.swift:38](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/tests/MouseJigglerLifecycleTests.swift:38) – Die 22 Lifecycle-Szenarien laufen nur über URLProtocol ohne KVM.
- [2026-10-02-overlook-implementation.md:89](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/docs/reviews/2026-10-02-overlook-implementation.md:89) – Ein Config-Readback wird ausdrücklich nicht als Wachhaltebeweis gewertet.
- [2026-10-02-overlook-m154-mcp22-rollout.md:26](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/docs/reviews/2026-10-02-overlook-m154-mcp22-rollout.md:26) – Der Firmware-Jiggler war beim Update-Smoke ausgeschaltet.

<a id="r46"></a>

## R46 – Native WebRTC-Testfälle ausdrücklich voraussetzen und in CI schützen

Eröffnung: `Test Automation Engineer`. Evidenz: aktuell quellbelegt; Konsequenz hier nicht zwingend ausgeführt. Endbewertung: **empfehlen**, P2, Paket A; ursprüngliche Aufwandsschätzung S.

**Ausgangspunkt:** Der heutige zentrale Lauf gegen das installierte Framework meldet nur FrameDelivery 9/9 und Snapshot 16/16. Das App-Framework besitzt keine Header/Module; drei native Fälle werden dadurch über canImport ausgelassen. Linker-Erfolg verhindert diese Umfangsreduktion nicht. Die vier eigenen Kompatibilitätsproben laufen außerdem nicht im Workflow.

**Vorschlag:** Vor Framework-Suites Importierbarkeit ausdrücklich prüfen und bei fehlendem Modul mit verständlichem Fehler auf den aufgelösten Entwicklungsframework-Pfad verweisen. Im Debug-CI-Job zusätzlich die vier nativen Audio-/Factory-/Peer-Proben starten. Compiler/SDK aus Xcode ableiten; den M109/M154-Vergleich auf Dependencyänderungen begrenzen.

**Kreuzprüfung (security-reviewer):** Der aktuelle Teilumfang ist eine Harness-Voraussetzung, kein M154-Produktfehler. Der native Wiederholungslauf muss die zeitgebundene Beobachtung aktualisieren.

**Architektur-Gegenposition:** Heutiger vollständiger Frameworklauf erreicht inzwischen 11/11 und 17/17; ursprünglicher Teilumfang ist nicht letzter Stand. P2-Harnesslücke bleibt: canImport kann native Fälle still entfernen; separate vier Proben fehlen weiterhin im CI.

**Entscheidung:** Native Importierbarkeit vorab erzwingen und native Probe in CI aufnehmen. Der heutige korrekte Wiederholungslauf belegt 11/11 und 17/17; die erste stille Untermenge bleibt als Harness-Lücke dokumentiert.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Importierbarkeit und verlangten nativen Umfang vorab erzwingen; Helfersuites separat behalten. Vier netz-/audiofreie Proben integrieren. Den erneuten vollständigen Lauf mit tatsächlicher Toolchain dokumentieren; feste Fallzahlen als Umfangsassertion erklären, nicht als universelle Qualitätsgarantie.

Quellanker der Eröffnung:

- [objective-c-xcode.yml:52](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/.github/workflows/objective-c-xcode.yml:52) – Die CI startet die allgemeine Swift-Fixturesuite.
- [test-agent-control.sh:73](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/scripts/test-agent-control.sh:73) – Der Frameworkteil führt FrameDelivery und Snapshots aus, nicht WebRTCCompatibilityTests.
- [FrameDeliveryTests.swift:73](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/tests/FrameDeliveryTests.swift:73) – Zwei native Rendererfälle entfallen still, falls WebRTC nicht importierbar ist.
- [RemoteSnapshotTests.swift:35](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/tests/RemoteSnapshotTests.swift:35) – Ein nativer Framefall ist ebenfalls durch canImport bedingt.
- [test-webrtc-compatibility.sh:64](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/scripts/test-webrtc-compatibility.sh:64) – Hier wird die getrennte Audio-/Factory-/Peer-Kompatibilitätsprobe gestartet.

Ergänzung/Korrektur der Gegenprüfung: [native-swift-regression.log:188](/Users/doebber/.codex/artifacts/overlook-expert-review-2026-10-05/native-swift-regression.log:188) – Neuer Entwicklungsframework-Lauf meldet FrameDelivery 11/11; Zeile 213 meldet Snapshot 17/17.

<a id="r47"></a>

## R47 – CI-Fehler mit Fristen und erhaltenen Artefakten diagnostizierbar machen

Eröffnung: `Test Automation Engineer`. Evidenz: aktuell quellbelegt; Konsequenz hier nicht zwingend ausgeführt. Endbewertung: **präzisieren**, P2, Paket A; ursprüngliche Aufwandsschätzung M.

**Ausgangspunkt:** Ein verlorenes erwartetes Ereignis kann eine eigenständige Swift-Suite hängen lassen. GitHub-Konsolenausgaben bleiben verfügbar, separate Testprogramme, zusammengehörige Logs und strukturierte Resultate werden aber nicht automatisch erhalten. Das Kompatibilitätsscript zeigt bereits eine 30-Sekunden-Prozessfrist als Muster.

**Vorschlag:** Jede Suite mit begrenzter Prozessfrist starten und Name, Dauer, Exitcode sowie Stdout/Stderr in einem Evidence-Verzeichnis erfassen. Bei Fehler/Timeout Testbinary und letzte Fixture-Ereignisse behalten. CI lädt diese Artefakte auch bei fehlgeschlagenen Schritten hoch und protokolliert Xcode-, SDK-, Node- und Architekturstand.

**Kreuzprüfung (security-reviewer):** Fristen sind sinnvoll. Automatischer Binary-/Log-Upload sollte den tatsächlichen Diagnosebedarf und die Inhalte der Artefakte berücksichtigen.

**Architektur-Gegenposition:** Unbegrenzte Fixture-Continuations sind belegt; ein umfassendes strukturiertes Observability-System ist dafür unnötig. P2 zunächst Prozessfrist und erhaltene Logs bei Fehler. Binary-/Ereignisexport nur, wenn zur Reproduktion nötig.

**Entscheidung:** Kompilation/Ausführung begrenzen, Suite/Exitgrund/Ereignisse erhalten. Artefakte nur per Allowlist; keine Remote-Bilder/Secrets und keine pauschalen Binäruploads.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Zuerst Suite, Dauer, Exitgrund und synthetische Ereignisfolge bei Fehler/Timeout erhalten. Kompilation und Ausführung getrennt begrenzen. Upload-Allowlist und Redaktion verwenden; keine Credentials, Remote-Bilder oder privaten Pfade. Testbinary nur bei konkretem lokalem Diagnosebedarf behalten.

Quellanker der Eröffnung:

- [test-agent-control.sh:26](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/scripts/test-agent-control.sh:26) – Testprogramme werden ohne äußere Prozessfrist ausgeführt.
- [test-agent-control.sh:12](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/scripts/test-agent-control.sh:12) – Der Exit-Trap entfernt das temporäre Testverzeichnis.
- [SessionConnectionCoordinatorTests.swift:366](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/tests/SessionConnectionCoordinatorTests.swift:366) – Ein fehlendes Fixture-Ereignis lässt eine Continuation unbegrenzt warten.
- [objective-c-xcode.yml:62](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/.github/workflows/objective-c-xcode.yml:62) – Der Workflow endet mit dem Build und enthält keinen Ergebnis-/Log-Upload.

<a id="r48"></a>

## R48 – Snapshot-Races durch Encoder-Barrieren statt feste Wartezeiten prüfen

Eröffnung: `Test Automation Engineer`. Evidenz: aktuell quellbelegt; Konsequenz hier nicht zwingend ausgeführt. Endbewertung: **empfehlen**, P2, Paket A; ursprüngliche Aufwandsschätzung S.

**Ausgangspunkt:** Der Spätergebnis-Test bestätigt nicht ausdrücklich, dass der verzögerte Encoder vor der abschließenden Assertion wirklich fertig wurde. Bei langsamer Queue kann er deshalb vor dem interessanten Ereignis grün werden. Ein beobachteter Flake oder Produktfehler wird damit nicht behauptet.

**Vorschlag:** Die bereits injizierbare Encoder-Closure mit Signalen für begonnen, freigegeben und abgeschlossen betreiben. Erst nach bestätigtem Beginn Quelle wechseln, dann Encoder freigeben und seinen Abschluss abwarten. Den Deadlinefall durch eine blockierte Encodergrenze und gegebenenfalls kontrollierbare Zeitquelle auslösen.

**Kreuzprüfung (security-reviewer):** Der Reihenfolgeeinwand ist belegt. Zehn grüne Läufe allein beweisen die abschließende Assertion noch nicht.

**Architektur-Gegenposition:** Feste 80-ms-Nachprüfung kann vor tatsächlichem Encoderabschluss grün werden; zehn grüne Wiederholungen beweisen die Reihenfolge nicht. Gezielte P2-Testkorrektur an vorhandener Encoder-Injektion; kein Produktbug daraus ableiten.

**Entscheidung:** Encoder-Beginn und -Abschluss durch Barrieren beweisen. Fehlerhafte späte Reaktivierung muss den Test scheitern lassen; feste Prüfschlafzeiten dafür ersetzen.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Beginn und Abschluss des injizierten Encoders ausdrücklich abwarten; Quelle dazwischen wechseln. Eine gezielte fehlerhafte Reaktivierung muss die Assertion scheitern lassen. Kleine gezielte Wiederholungen genügen. Reale Deadline-Messung behalten; keine allgemeine Zeitabstraktion ohne Bedarf einführen.

Quellanker der Eröffnung:

- [RemoteSnapshotTests.swift:334](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/tests/RemoteSnapshotTests.swift:334) – testLateEncoding verzögert den Encoder um 50 ms.
- [RemoteSnapshotTests.swift:344](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/tests/RemoteSnapshotTests.swift:344) – Die Nachprüfung erfolgt nach einer festen Wartezeit von 80 ms.
- [RemoteSnapshotTests.swift:352](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/tests/RemoteSnapshotTests.swift:352) – Der Deadlinefall erzeugt Verzögerung durch 100 ms Thread.sleep.

<a id="r49"></a>

## R49 – App und MCP als dokumentiertes Rückfallpaar erproben

Eröffnung: `Test Automation Engineer`. Evidenz: belegte Prüf-/Abnahmelücke; kein damit bewiesener Produktdefekt. Endbewertung: **empfehlen**, P2, Paket B; ursprüngliche Aufwandsschätzung M.

**Ausgangspunkt:** Der Rollout bewahrt starke Rückfallartefakte. Ein dokumentierter erfolgreicher Rückwechsel des gesamten App-/Adapter-/Alias-Paars ist daraus noch nicht ersichtlich. Gesicherte Konfiguration und laufender Prozess können unterschiedliche SDK-Stände haben.

**Vorschlag:** Ein kleines Rückfallrunbook im bestehenden Dokumentationsbereich vorbereiten: App-Build/Hash, alter und neuer Adapterpfad/Lockfile, betroffene Aliase, regulärer Neustart und Nachprüfung. Bei nächster autorisierter Wartung einen Rückwechsel und Vorwärtswechsel durchführen; keinen automatischen Rollback bei bloßen Readiness-Schwankungen einführen.

**Kreuzprüfung (security-reviewer):** Der Rückfallplan ist sinnvoll; eine vorhandene private Konfigurationssicherung gehört nicht in ein teilbares Runbook oder Git.

**Architektur-Gegenposition:** Starke Rückfallartefakte existieren; der historische Update-Smoke rechtfertigt keinen vorsorglichen Rückwechsel zur Abnahme. P2-Runbook lokal vorbereiten. Rück-/Vorwärtswechsel nur bei gesonderter Wartung, keine automatische Rollbacklogik.

**Entscheidung:** App-/MCP-/Alias-Rückfallpaar als kleines Runbook vorbereiten. Tatsächlicher Wechsel bleibt eigener Wartungsschritt, private Gesamtkonfiguration bleibt außerhalb Git.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Nur App-/Adapterversionen, Hashes und relevante Alias-Pfadentscheidungen dokumentieren. Exakten begrenzten Rückfall vorbereiten, private Konfiguration unveröffentlicht lassen. Aktiven Wechsel separat freigeben; vorher laufende Eingaben geordnet beenden. Discovery/Status beweisen weiterhin keine Gerätefunktion.

Quellanker der Eröffnung:

- [2026-10-02-overlook-m154-mcp22-rollout.md:44](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/docs/reviews/2026-10-02-overlook-m154-mcp22-rollout.md:44) – Die bytegleichen M109-Appkopien und Konfigurationssicherung sind vorhanden.
- [2026-10-02-overlook-m154-mcp22-rollout.md:40](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/docs/reviews/2026-10-02-overlook-m154-mcp22-rollout.md:40) – Zusätzlicher Projektalias und gecachte Adapterprozesse beeinflussen die aktive SDK-Version.
- [build-agent-release.sh:2](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/scripts/build-agent-release.sh:2) – Das Release-Script erstellt ein Artefakt; Installation und Rückfall sind getrennte Vorgänge.

<a id="r50"></a>

## R50 – Prüfvoraussetzungen und Testbelege an den geprüften Stand binden

Eröffnung: `Test Automation Engineer`. Evidenz: aktuell quellbelegt; Konsequenz hier nicht zwingend ausgeführt. Endbewertung: **präzisieren**, P3, Paket A; ursprüngliche Aufwandsschätzung S.

**Ausgangspunkt:** Die Berichte grenzen Coverage korrekt ein. Heute bestand der Swift-Teilumfang, der Gesamttreiber endete aber mit Exit 127 wegen fehlendem tsc im Checkout. Die separat installierte unveränderte MCP-Kopie bestand 65/65 samt Build. Das ist kein Produktbug und kein grüner Gesamttreiber. Das Buildmanifest bindet Testläufe noch nicht automatisch an ihren Scope und Stand.

**Vorschlag:** Vor dem Lauf Compiler, SDK, Frameworkmodul und lokale MCP-Abhängigkeiten prüfen. Ein kleines Evidence-Manifest ergänzt Produkt-/Testdigest, Dependencyversionen, Toolchain, ausgeführte Suites und Logpfade. Separate Läufe mit ihren Voraussetzungen bewahren; Hardware-Smoke und Coveragebereiche getrennt erfassen. Den aktuellen Gesamttreiber als an der Voraussetzung gescheitert dokumentieren.

**Kreuzprüfung (security-reviewer):** Die Evidenzbindung hilft. Der frühere fehlgeschlagene Gesamttreiber darf nach erfolgreicher Wiederholung nicht als aktueller Abschlussstand fortgeschrieben werden.

**Architektur-Gegenposition:** Exit 127 war fehlendes tsc im ersten Checkoutlauf; Scratch-MCP 65/65 und vollständige native Swift-Suite bestehen inzwischen getrennt. P3-Evidenzmanifest mit R46/R47 bündeln; Voraussetzungenfehler ist kein Produktdefekt und widerlegt erfolgreiche getrennte Läufe nicht.

**Entscheidung:** Vorbedingungen und kleines Testmanifest binden den geprüften Scope an Commit/Quellen/Toolchain. Erster Gesamtlauf Exit127, korrigierte native Suite Exit0 und separate MCP65/65 transparent bewahren. Optionales Manifest mit R46/R47 bündeln; die vorhandenen getrennten Nachweise sind bereits brauchbar.

**Präzisierter Prüfvorschlag aus der Kreuzprüfung:** Ein kleines lokales Manifest genügt: Commit-/Produkt-/Testdigest, Toolchain, Scope, Exitcode und redigierte Logreferenz. Frühere Teilversuche und neuesten vollständigen Lauf getrennt datieren. Fehlende Voraussetzungen vorab erklären; keine Dependencies ungefragt installieren. Coverage-Nenner und offene Hardwaregrenzen erhalten.

Quellanker der Eröffnung:

- [build-agent-release.sh:19](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/scripts/build-agent-release.sh:19) – Der Produktfingerabdruck umfasst Produkt-/Build-/MCP-Dateien, nicht die Tests.
- [build-agent-release.sh:73](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/scripts/build-agent-release.sh:73) – Das Manifest beschreibt Build, Toolchain und Apphashes ohne Testlauf-Zuordnung.
- [package.json:11](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/mcp/overlook-control/package.json:11) – npm test setzt einen installierten TypeScript-Compiler voraus.
- [2026-10-02-overlook-implementation.md:46](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/docs/reviews/2026-10-02-overlook-implementation.md:46) – Die Coveragewerte gelten ausdrücklich nur für ausgewählte geänderte Bereiche.
- [2026-10-02-overlook-implementation.md:58](/Users/doebber/.codex/worktrees/overlook-webrtc154-2026-10-02/docs/reviews/2026-10-02-overlook-implementation.md:58) – App-Gesamtabdeckung und Branch-Coverage sind ausdrücklich nicht gemessen.

## Evidenzgrenzen

Die korrigierte native Swift-Suite mit vollständigem M154-Entwicklungsframework endete mit Exit 0 (Frame 11/11, Snapshot 17/17). Die separate unveränderte MCP-Testkopie bestand Build und 65/65 Tests. Der erste Gesamttreiber scheiterte an fehlendem lokalem tsc; sein installiertes Framework hatte vorher drei native Fälle ausgelassen. Diese Versuche bleiben getrennte Nachweise. Keine Gesamtcoverage, kein neuer vollständiger App-Build, keine neuen Fehlerfalltests und keine Geräte-/VoiceOver-Abnahme heute. App und Produktquellen unverändert; null Remote-Aktionen.
