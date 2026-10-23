# Architektur und Abläufe

## Datenfluss beim Import
1. `AppModel.importFile` → `DocumentImportService.extract` (PDFKit / Vision-OCR / `DocumentPipeline.extract` für DOCX, PPTX, Text)
2. `DocumentPipeline.analyze` (Hintergrund): Struktur → Abschnitte (≤ 2.600 Zeichen) → Duplikate → Begriffe → Qualitätsprüfung
3. Abschnitte werden je Dokument gespeichert (`FileStore.saveChunks`)
4. Mit KI: `AIBatcher` (≤ 10 Abschnitte / 14.000 Zeichen je Anfrage) → `/v1/analyze` → `AIResponseValidator.curriculum` (Zitatprüfung)
5. `MaterialIntegrator.integrate`: KI-Ergebnis + lokale Ergänzung nicht abgedeckter Abschnitte, Zusammenführen gleichnamiger Themen, lokale Fragen
6. `LearningCoach.replan(.newMaterial)` → Lernplan, ggf. Kalender-Abgleich

## Lerneinheit
1. `startSession(for:)` wählt Lernziele und Fragen (`QuestionSelector`, adaptive Schwierigkeit), ergänzt bei Bedarf KI-Fragen
2. Jede Antwort wird sofort gespeichert (`record`), der Sitzungszustand ebenfalls (`session.json`)
3. `finishSession` → `LearningCoach.completeCheck` (idempotent über die Sitzungs-ID): Belohnung, Tagesziel, Einheit erledigt
4. `refresh` → `ScreenTimeService.syncAchievements` → Tagesziel-/100-%-Freigabe → `ShieldController.reconcile`

## Tageswechsel
- Erweiterung: `lf.daily` beginnt um 00:00 → `reconcile` → neue Tagesperiode
- App: beim ersten Öffnen am Tag `replan(.routine)` (verpasste Einheiten), neues Tagesziel
- Fallback: Hintergrundaktualisierung (`BGAppRefreshTask`)

## Persistenz
- `state.json` (atomar, mit `state.previous.json` als Sicherung), `session.json`, `chunks/<Dokument>.json`, `documents/` (Originaldateien)
- iOS Data Protection (`completeFileProtectionUntilFirstUserAuthentication`)
- Sperrzustand und App-Auswahl in der App Group (`UserDefaults(suiteName:)`), Zugangscode im Schlüsselbund
