# Lernmodell: Wissensstand, 100 %, Prognosen

Alle Werte werden **aus den gespeicherten Antworten abgeleitet** (`KnowledgeTracer`) und nie direkt
gespeichert. Dadurch sind sie nach einem Neustart identisch, und Fortschritt kann nicht „künstlich“
zurückgesetzt werden. Quellcode: `Packages/LernKern/Sources/LernKern/Knowledge`, `Progress`, `Forecast`.

## 1. Wissensstand je Lernziel

### Fähigkeit (Elo-/Rasch-Modell)
- Lösungswahrscheinlichkeit: `P = g + (1 − g) · σ(θ − b)`
  - `θ` Fähigkeit, Startwert aus den angegebenen Vorkenntnissen (15 % / 35 % / 55 %)
  - `b` Schwierigkeit: leicht −1, mittel 0, schwer +1; Transfer +0,3; freier Abruf +0,2
  - `g` Rateanteil: 1/Optionen bei Multiple Choice, 0,5 bei Richtig/Falsch, 0 bei freiem Abruf
- Aktualisierung je Antwort: `θ ← θ + K · w · (Punkte − P)`, `K = max(0,3; 1,2 / (1 + 0,2 · n))`
- Beleggewicht `w`: automatisch bewertet 1,0 · KI sicher 1,0 / mittel 0,8 / unsicher 0,5 · Selbsteinschätzung 0,5 · mit Hinweis halbiert

### Gedächtnis (Vergessenskurve wie FSRS)
- Erinnerungswahrscheinlichkeit `R(t) = (1 + t / (9·S))⁻¹`, `S` = Stabilität in Tagen
- Erster erfolgreicher Abruf: `S = 1 Tag` (leicht ×0,7, schwer ×1,3)
- Erfolg: `S ← S · (1 + 25 · S^−0,15 · (e^{1,2·(1−R)} − 1) · Faktoren)` – Abruf direkt hintereinander bringt kaum etwas, Abruf nach Abstand viel
- Fehler: `S ← max(0,3; 0,4 · S)`, zählt als „Lapse“
- Wiederholung fällig, wenn `R` auf 90 % fällt (nach `S` Tagen)

### Kriterien und Stufen

| Kriterium | Standard | Stufe |
|---|---|---|
| Richtige Antworten ohne Hilfe (gewichtet) | 3 | vorläufig |
| Verschiedene Fragen richtig | 2 | vorläufig |
| P(mittelschwere Aufgabe) | ≥ 75 % | vorläufig |
| Beständigkeit | 2 der letzten 3 richtig | vorläufig |
| Wiederholung nach zeitlichem Abstand | 1× nach ≥ 20 h | stabil |
| Schwere oder Transferaufgabe richtig | 1 | stabil |
| Wissen aktuell präsent | R ≥ 85 % | 100 % |

- **Gelernt**: mindestens eine gültige Antwort
- **Vorläufig beherrscht**: alle vorläufigen Kriterien
- **Stabil beherrscht**: zusätzlich Abstand und schwere/Transferaufgabe
- **Vollständig (zählt für 100 %)**: stabil **und** aktuell präsent

Fortschritt je Lernziel: 60 % vorläufige + 40 % stabile Kriterien (gewichtet), ohne alle vorläufigen
Kriterien höchstens 59 %, 100 % nur mit allen Kriterien. Gemeldete Fragen und ungültige Antworten zählen nicht.

## 2. Was bedeutet 100 %?

`FullMasteryEvaluator`: **Jede aktive Prüfung** hat Lernziele, und **jedes** aktive Lernziel ist vollständig.
- Ein starkes Thema kann kein schwaches ausgleichen (100 % gilt je Lernziel).
- Gewichtung der Anzeige: bekannte Prüfungsanteile (z. B. aus dem Lehrplan), sonst Wichtigkeit von Thema und Lernziel.
- Die Anzeige rundet nie auf 100 auf (99 % bis wirklich alles erfüllt ist).
- Lehrplan-Themen ohne Material zählen mit (verbindliche Stoffabdeckung).
- Bei z. B. 92 % listet die App gruppiert auf, was fehlt („3 Lernziele brauchen eine Wiederholung an einem anderen Tag“).

## 3. Notenprognose („Wenn die Prüfung heute wäre“)

1. Je Lernziel: `p = P(Prüfungsmischung 30/45/25 % leicht/mittel/schwer) · (0,55 + 0,45 · R)`; ohne Daten die Vorkenntnis-Annahme mit hoher Unsicherheit.
2. Modellwert = gewichtete Summe; Leistung bei **neuen, unbekannten Fragen** fließt mit 15 % ein (ab 10 solchen Antworten).
3. **Prüfungssimulationen** (≤ 21 Tage, max. 3): Anteil `α = min(0,6; 0,35 · Anzahl) · e^{−Alter/14}`.
4. Unsicherheit: Varianz je Lernziel `p(1−p)/(n+2)` + Modellfehler 6 % (+3 % bei geschätzter Notenskala, +4 % bei geringer Abdeckung); Spanne = ±1,28 σ (≈ 80 %).
5. Sicherheit:
   - *Noch zu wenige Daten*: Abdeckung < 30 % oder < 12 Antworten (ohne Simulation) → keine Note, nur Hinweis
   - *gering*: Abdeckung < 60 % oder < 40 Antworten ohne Simulation → Note mit Spanne, **keine** Zielchance
   - *mittel* → Zielchance nur sprachlich („offen“, „wahrscheinlich“ …)
   - *hoch* (Abdeckung ≥ 85 %, aktuelle Simulation, ≥ 80 Antworten) → Zielchance als 20-Prozentpunkte-Spanne
6. Notenskala konfigurierbar (Österreich 1–5, Deutschland 1–6, Punkte, Bestanden/Nicht bestanden); ohne offizielle Grenzen als Schätzung gekennzeichnet.

Die Prognose wird **nur gelesen**, nie für Belohnungen angepasst. Nach der Prüfung kann das tatsächliche Ergebnis eingetragen werden, um die Genauigkeit zu sehen.

## 4. Zeitprognose

Je Lernziel: Erstlernzeit (nach Bloom-Stufe/Textmenge × persönlicher Tempofaktor) + erwartete Versuche bis zu den Kriterien (`fehlende Richtige / P`, Fähigkeitslücke) × persönliche Zeit pro Frage + Wiederholungen + schwere Aufgabe.
- **Erste ausreichende Beherrschung** = alle vorläufig, **stabil** = alle stabil
- **Zielleistung**: gierige Auswahl der Lernziele mit größtem Punktgewinn pro Minute, bis die Zielgrenze (+3 % bzw. +5 % Sicherheitsabstand bei geschätzter Skala) erreicht ist
- Spannen: ×0,8–1,3 (bei wenig Daten ×0,7–1,6)
- Machbarkeit gegen verfügbare Zeit (Wochenplan − Puffer − lernfreie Tage); bei knapp/unrealistisch ehrliche Szenarien: mehr Zeit pro Tag, erreichbare Note (nur Vorschlag), Kernthemen zuerst

## 5. Prüfungstauglichkeit

Abdeckung 25 % · Behalten 20 % · neue Fragen 20 % · letzte Simulation 25 % · Beständigkeit 10 %. Ohne Simulation höchstens 85.

## 6. Lernplan

`StudyPlanner`: Arbeitspakete (Verstehen, Üben, Wiederholen, gemischte Übung, Simulation, Fehleranalyse) nach
Voraussetzungen und Dokumentreihenfolge; schwierige/wichtige Themen bekommen mehr Übungszeit; nach dem Lernen
Wiederholungen am Folgetag und nach 4 Tagen; fällige Wiederholungen aus dem Gedächtnismodell haben Vorrang;
Simulationen bei ~60 % der Zeit und 2 Tage vor der Prüfung; Prüfungsmodus in den letzten 3 Tagen; 10 % Puffer;
mehrere Prüfungen nach Dringlichkeit (offene Arbeit / verbleibende Tage). Angeheftete (vom Nutzer verschobene),
erledigte und laufende Einheiten bleiben unverändert. Jede Änderung wird begründet protokolliert.
