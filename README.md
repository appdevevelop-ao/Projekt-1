# LernFokus

**KI-gestützte Lern-App für iPhone und iPad, die Prüfungsvorbereitung messbar macht und ablenkende Apps erst nach echtem Lernen freigibt.**

LernFokus verarbeitet deine Unterlagen, erstellt einen adaptiven Lernplan, prüft mit Fragen, was du wirklich kannst,
schätzt Note und verbleibende Lernzeit ehrlich ein – und verbindet das mit Apples Bildschirmzeit: Während der Lernzeit
sind ausgewählte Apps pausiert, durch Lernen verdienst du Bildschirmzeit, und bei **100 % Lernfortschritt sind die
gesperrten Apps bis Mitternacht frei**.

## Inhalt
- [Funktionen](#funktionen)
- [Architektur](#architektur)
- [Voraussetzungen](#voraussetzungen)
- [Installation und Start](#installation-und-start)
- [KI-Server einrichten](#ki-server-einrichten)
- [Berechtigungen und Entitlements](#berechtigungen-und-entitlements)
- [Auf dem iPhone testen](#auf-dem-iphone-testen)
- [Tests](#tests)
- [Bekannte Einschränkungen](#bekannte-einschränkungen)
- Fachliche Details: [Lernmodell](docs/LERNMODELL.md) · [Belohnungen](docs/BELOHNUNGEN.md) · [Bildschirmzeit](docs/BILDSCHIRMZEIT.md)

## Funktionen

| Bereich | Umsetzung |
|---|---|
| Onboarding | Ziel → Prüfung (Termin, Zielnote, Notenskala, Form, Vorkenntnisse, Lernzeit) → Unterlagen → Bildschirmzeit → Lernplan |
| Unterlagen | PDF (PDFKit, Texterkennung für gescannte Seiten mit Vision auf dem Gerät), Word `.docx` und PowerPoint `.pptx` (eigener ZIP/DEFLATE-Leser, inkl. Folien-Notizen), Text/Markdown, Fotos, Dokumentenkamera. Kapitelerkennung, Abschnitte mit Seitenangabe, Definitionen und Formeln, Duplikate über Dateien hinweg, Qualitätswarnungen (leere/unleserliche Seiten, unsichere Texterkennung). Lehrplan-/Themenlisten-Import als verbindliche Stoffabdeckung inkl. Prüfungsanteilen. |
| KI | Eigener Server (Claude Opus 5.5) für Lernziele, Fragen, Bewertung offener Antworten, einfachere Erklärungen. Strukturierte Ausgaben, jede Frage/jedes Lernziel muss mit einem **wörtlich im Material vorhandenen Zitat** belegt sein, sonst wird es verworfen. KI-Inhalte sind als Vorschlag gekennzeichnet und bestätigbar. Ohne KI arbeitet die App vollständig lokal (Fragen aus belegten Definitionen und Sätzen). |
| Lernplan | Konkrete Zeitblöcke mit Pausen, Schwerpunkt auf wichtigen/schwierigen/unsicheren Lernzielen, verteiltes Wiederholen, gemischte Übungen, Simulationen, Fehleranalyse, Prüfungsmodus, Puffer, mehrere Prüfungen nach Dringlichkeit. Automatische Neuplanung bei verpassten Einheiten, Schwierigkeiten, schnellem Fortschritt, neuem Material, Termin-/Ziel-/Zeitänderung – jeweils mit Begründung. Manuell verschobene Einheiten bleiben unangetastet. |
| Quiz | Multiple Choice, Richtig/Falsch, Lückentext, Kurzantwort, freie Erklärung, Rechenaufgaben (Einheiten, Zahlenformate, Größenordnung), Zuordnung. Adaptive Schwierigkeit, Tippfehler-Toleranz, Rückmeldung mit Lösung, Erklärung, Quelle und typischen Fehlern, „Einfacher erklären“, Frage melden. Prüfungssimulation mit Zeitlimit, ohne Zwischenlösungen, Auswertung je Thema. |
| Bewertung | Wissensmodell je Lernziel (Fähigkeit + Vergessenskurve), Stufen *gelernt / vorläufig / stabil beherrscht*, strenge 100-%-Definition, Notenprognose mit Spanne und Sicherheitsstufe, Zeitprognose (erste Beherrschung / stabil / Zielleistung), Prüfungstauglichkeits-Score, Schwächen-Detektor (Verwechslungen → Vergleichsübung, Einheitenfehler, Transferlücke, schnelles Vergessen). |
| Bildschirmzeit | FamilyControls-Auswahl (Apps, Kategorien, Websites), ManagedSettings-Sperre, DeviceActivity-Zeitpläne, Monitor-/Shield-Erweiterungen, Modi Fokus/Streng/Tagesziel/Kombiniert, Belohnungskonto mit Einlösen und Rückbuchen, Notfall-Pausen, Tagesfreigabe bei 100 % bis Mitternacht, Statusanzeige inkl. Abgleich mit dem tatsächlichen Systemzustand. |
| Kalender | EventKit-Abgleich nur der eigenen Termine (keine Duplikate, Wiederherstellung über Termin-URL), im Kalender verschobene Termine werden übernommen, Konflikte werden erfragt, Zielkalender und Erinnerungen wählbar, einzelne Einheiten oder ganzer Plan, `.ics`-Export ohne Berechtigung. |
| Sonstiges | Dezente, einstellbare Erinnerungen, Pausenempfehlung, aktive Lernzeit (nur im Vordergrund), Sitzungen überstehen Neustarts, tatsächliches Prüfungsergebnis eintragen (Prognosegenauigkeit), Datenschutzseite, alles löschen. |

Nicht enthalten (bewusst): Nachhilfevermittlung, Bezahlfunktionen (die Architektur trennt Funktionen so, dass ein späteres Premium-Abo möglich ist).

## Architektur

```
Packages/LernKern/            Swift-Paket, nur Foundation – unter Linux und macOS testbar
  Sources/ShieldLogic/         Sperr-Entscheidungslogik (auch von den Erweiterungen genutzt, klein gehalten)
  Sources/LernKern/
    Model/                     Datenmodelle (Prüfung, Material, Lernziele, Fragen, Antworten, Plan, …)
    Knowledge/ Progress/       Wissensmodell, Fortschritt, 100-%-Prüfung
    Forecast/                  Noten-, Zeit- und Prüfungstauglichkeitsprognose
    Planning/                  Lernplaner, Tagesziel
    Rewards/                   Belohnungsregeln und -berechnung
    Quiz/                      Antwortbewertung, lokaler Fragengenerator, Schwächen-Detektor
    Documents/                 ZIP/DEFLATE, DOCX/PPTX, Struktur, Abschnitte, Begriffe, Qualität, Lehrplan
    AI/                        Datenverträge mit dem Server, Validierung, Zitatprüfung
    Calendar/                  Synchronisierungsplanung, ICS-Export
    Engine/                    Lerncoach-Fassade, Fragenauswahl, Simulationen, Sitzungszustand, Material-Integration
    Persistence/               Dateispeicher (atomar, Sicherungskopie, Data Protection)
App/Sources/                   SwiftUI-App (iOS 17+): AppModel, Dienste (Bildschirmzeit, EventKit, Import/OCR, KI, Mitteilungen), Oberfläche
Shared/                        Gemeinsamer Code App ↔ Erweiterungen (App Group, Sperre anwenden, Zeitpläne)
Extensions/                    DeviceActivityMonitor, ShieldConfiguration, ShieldAction
Backend/                       Node.js-KI-Server (Claude API), Schlüssel nur serverseitig
project.yml                    XcodeGen-Projektdefinition
```

Designentscheidungen:
- **Swift + SwiftUI nativ**, weil die Bildschirmzeit-Funktionen eng an iOS gebunden sind.
- **Fachlogik getrennt von der Plattform** (`LernKern`): testbar, später für Web/Android portierbar (Algorithmen und Datenverträge).
- **Wissensstand wird abgeleitet, nicht gespeichert**: Quelle der Wahrheit sind die Antworten → konsistent nach Neustarts, kein künstliches Zurücksetzen.
- **Eine Entscheidungsfunktion für die Sperre** für App und Erweiterungen → keine widersprüchlichen Zustände.
- **JSON-Dateispeicher statt SwiftData**: vollständig testbar, transparente Migration, einfache vollständige Löschung; atomare Schreibvorgänge mit Sicherungskopie.

## Voraussetzungen

- macOS mit **Xcode 16 oder neuer** (getestet in CI mit Xcode 26 / iOS 26.2 Simulator)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- Mitgliedschaft im **Apple Developer Program** für Tests auf dem Gerät (kostenlose persönliche Teams unterstützen
  die Capabilities *Family Controls* und *App Groups* nicht)
- iPhone/iPad mit **iOS 17** oder neuer (Bildschirmzeit funktioniert nur auf echten Geräten)
- Optional für KI: Node.js ≥ 20 und ein Anthropic-API-Schlüssel

## Installation und Start

```bash
git clone <repo> && cd Projekt-1
brew install xcodegen
# eigene Werte gehören in Config/Local.xcconfig (nicht eingecheckt)
cat > Config/Local.xcconfig <<'CFG'
DEVELOPMENT_TEAM = DEINE_TEAM_ID
BUNDLE_ID_PREFIX = de.deinname.lernfokus
CFG
xcodegen generate
open LernFokus.xcodeproj
```

In Xcode das Schema **LernFokus** wählen und auf Simulator oder Gerät starten. Bundle-IDs der Erweiterungen und die
App Group (`group.<BUNDLE_ID_PREFIX>`) werden automatisch abgeleitet.

## KI-Server einrichten

Der Claude-API-Schlüssel liegt **nur auf dem Server** (Details: [Backend/README.md](Backend/README.md)).

```bash
cd Backend
npm ci
export ANTHROPIC_API_KEY=sk-ant-...        # niemals einchecken
export LF_ACCESS_TOKENS=$(openssl rand -hex 24)
npm start                                 # http://127.0.0.1:8787
```

In der App: **Profil → KI-Dienst** → Server-Adresse und Zugangscode eintragen → „Verbindung testen“ → Einwilligung
einschalten (unter 16 Jahren zusätzlich Bestätigung der Erziehungsberechtigten).
- Simulator: `http://127.0.0.1:8787` funktioniert direkt (für lokale Tests auch `LF_ALLOW_ANONYMOUS=1`).
- iPhone: Der Server muss per **HTTPS** erreichbar sein (z. B. Container hinter einem Reverse Proxy, `Backend/Dockerfile`).
- Standardmodell `claude-opus-5-5` (änderbar mit `LF_MODEL`).

Ohne KI-Dienst funktioniert die App vollständig mit lokaler Analyse.

## Berechtigungen und Entitlements

| Berechtigung | Wofür | Ohne Berechtigung |
|---|---|---|
| Bildschirmzeit (FamilyControls, `.individual`) | Apps sperren/freigeben | App bleibt voll nutzbar, Status „Berechtigung fehlt“, keine Sperre (wird nie simuliert) |
| Kalender (voller Zugriff) | eigene Termine anlegen, wiederfinden, Verschiebungen erkennen | `.ics`-Export |
| Mitteilungen | Erinnerungen | keine Erinnerungen |
| Kamera | Dokumentenscan | Dateien/Fotos importieren |

Entitlements (in `project.yml` hinterlegt, in Xcode unter *Signing & Capabilities* sichtbar):
- `com.apple.developer.family-controls` – App **und** alle drei Erweiterungen
- `com.apple.security.application-groups` – `group.<BUNDLE_ID_PREFIX>` für App und Erweiterungen

Für **TestFlight/App Store** muss das *Family Controls (Distribution)*-Entitlement bei Apple beantragt werden
(developer.apple.com → Family Controls). Für die Entwicklung auf eigenen Geräten genügt die Development-Variante,
die Xcode beim Hinzufügen der Capability automatisch verwendet.

## Auf dem iPhone testen

1. iPhone per Kabel verbinden, in Xcode als Ziel wählen, `Config/Local.xcconfig` mit Team-ID anlegen, `xcodegen generate`.
2. In *Signing & Capabilities* prüfen, dass App und alle drei Erweiterungen dasselbe Team und die App Group haben.
3. App starten, Onboarding durchlaufen, bei „Bildschirmzeit“ die Berechtigung erteilen und z. B. die Kategorie *Unterhaltung* auswählen.
4. **Sperre testen**: Profil → App-Sperre → Modus *Tagesziel*, „Sperre ab“ auf eine vergangene Uhrzeit setzen → die gewählte App zeigt den LernFokus-Sperrbildschirm.
5. **Belohnung testen**: eine Lerneinheit abschließen (≥ 3 Fragen bestehen) → unter *Heute* Minuten einlösen → App ist frei; nach Ablauf (oder „Vorzeitig beenden“) wieder gesperrt.
6. **100 %-Freigabe testen**: Mit einem kleinen Test-Dokument (z. B. 2–3 Definitionen) alle Lernziele bis „stabil“ bringen – das erfordert eine Wiederholung am Folgetag. Sobald eine bestandene Überprüfung 100 % bestätigt, zeigt *Heute* „100 % erreicht“, die Sperre ist bis Mitternacht aufgehoben und am nächsten Tag gilt wieder die normale Logik.
7. **Neustart testen**: App während einer Lerneinheit beenden und neu öffnen → die Sitzung wird fortgesetzt, Antworten und Minuten sind erhalten, der Sperrstatus wird abgeglichen.
8. **Kalender**: Lernplan → ⋯ → „Alle in Apple Kalender übernehmen“; erneut abgleichen erzeugt keine Duplikate; einen Termin in der Kalender-App verschieben → beim nächsten Abgleich wird die Zeit übernommen.

## Tests

```bash
# Kernlogik (Linux oder macOS) – 108 Tests
swift test --package-path Packages/LernKern
# oder ohne lokales Swift:
docker run --rm -v "$PWD/Packages/LernKern":/pkg -w /pkg swift:6.2-noble swift test

# KI-Server – echter SDK-Client mit simuliertem Netzwerk, keine Kosten
npm ci --prefix Backend && npm test --prefix Backend

# iOS-App im Simulator (baut App + 3 Erweiterungen, führt App-Tests aus)
xcodegen generate
xcodebuild test -project LernFokus.xcodeproj -scheme LernFokus -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO
```

Die GitHub-Actions-Pipeline (`.github/workflows/ci.yml`) führt alle drei Stufen aus (Linux, Node, macOS mit Xcode).

Abgedeckt u. a.: Lernfortschritt und 100-%-Grenze, Notenprognose, Zeitprognose, Belohnungsberechnung inkl.
Missbrauchsschutz, Tagesziel, Tagesfreigabe bis Mitternacht, Verhalten nach Mitternacht, Zeitzonenwechsel,
Sommerzeit, verfrühte Systemrückrufe, Lernplan (verpasste Einheiten, angeheftete Termine, mehrere Prüfungen,
zu wenig Zeit), Kalender-Synchronisierung (Duplikate, Verschiebungen, Konflikte, Löschungen), ICS,
DOCX/PPTX-Extraktion, Begriffserkennung, Duplikate, KI-Validierung (Halluzinationen), Persistenz und Wiederherstellung,
Ende-zu-Ende-Abläufe des Lerncoachs.

Die App-Tests (`App/Tests`) prüfen das App-Modell mit echtem Dateispeicher: Textimport → belegte Lernziele und Fragen →
Lernplan, Fortsetzen einer Sitzung nach Neustart, einmalige Gutschrift einer Überprüfung, kein Abbuchen ohne
eingerichtete Sperre, Löschen eines Dokuments inkl. gespeicherter Abschnitte, Schutz beschädigter Daten.

## Bekannte Einschränkungen

- **Bildschirmzeit nur auf echten Geräten**; der Simulator kann weder Berechtigung noch Sperre.
- iOS garantiert die **Pünktlichkeit** von DeviceActivity-Rückrufen nicht; Abweichungen von einigen Sekunden bis Minuten werden beim nächsten Öffnen oder per Hintergrundaktualisierung korrigiert. Zeitpläne müssen mindestens 15 Minuten lang sein (kürzere Belohnungen werden technisch korrekt abgebildet).
- Die Sperre ist eine **Selbstverpflichtung**: Die Berechtigung kann in den iOS-Einstellungen entzogen werden. Elterliche Bildschirmzeit-Regeln werden nicht verändert.
- Der Sperrbildschirm kann Apps nicht direkt öffnen; „Zu LernFokus“ sendet eine Mitteilung zum Antippen.
- **Notenprognose**: Ohne offizielle Notengrenzen sind die Grenzen geschätzt (gekennzeichnet). Das Modell ist nicht an echten Prüfungsergebnissen kalibriert – deshalb werden Wahrscheinlichkeiten nur bei hoher Datenlage und nur als Spanne gezeigt.
- **Lokale Analyse ohne KI** erkennt nur ausdrücklich definierte Begriffe und erzeugt vorwiegend Wiedergabe-/Lückentextfragen; Transfer- und Rechenaufgaben entstehen mit dem KI-Dienst.
- PDF-Mehrspaltenlayouts und Tabellen werden als Fließtext gelesen; mathematische Formeln in PDFs nur, soweit als Text vorhanden.
- Der KI-Server hält Ratenlimits im Speicher eines Prozesses; für den Produktivbetrieb mit mehreren Instanzen und zur Geräteprüfung (Apple **App Attest**) erweitern.
- Keine Cloud-Synchronisierung zwischen Geräten (Daten bleiben lokal).
