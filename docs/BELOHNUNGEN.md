# Belohnungen: Bildschirmzeit durch Lernen verdienen

Quellcode: `Packages/LernKern/Sources/LernKern/Rewards`. Regeln sind unter Profil → Belohnungsregeln anpassbar.

## Grundsatz
Belohnt wird **geprüfte Lernleistung** – Antworten in einer Wissensüberprüfung am Ende einer Lerneinheit
oder eine Prüfungssimulation. Öffnen der App, Lesen oder ein Timer bringen nichts.

## Wissensüberprüfung
1. **Gültige Antworten**: nicht ungültig, ≥ 3 s Bearbeitungszeit, dieselbe Frage nicht in den letzten 20 h schon richtig beantwortet.
2. Mindestens **3 gültige Antworten**, sonst keine Belohnung.
3. **Schwierigkeitsgewichtete Genauigkeit**: leicht 0,7 · mittel 1,0 · schwer 1,4 · Transfer +0,2; leichte Fragen zu bereits stabil beherrschtem, präsentem Stoff ×0,3 (keine „Trivialfragen-Farm“); Beleggewicht der Bewertung.
4. **Bestehensgrenze je Lernphase** (aus der unveränderten Prognose):

| Phase | Bedingung | Bestehen ab | Schwerpunkt |
|---|---|---|---|
| Grundlagen | > 20 Punkte unter Ziel | 50 % | kleine, erreichbare Fortschritte |
| Auf Kurs | 5–20 Punkte darunter | 60 % | |
| Feinschliff | nah am Ziel | 70 % | +1 Min. je schwerer Aufgabe (max. 3) |
| Wissen erhalten | Ziel sicher erreicht | 70 % | Tagesziel = 1 kurze Wiederholung |

5. **Grundbelohnung** bei Bestehen: `5 + round(5 · Qualität · Umfang)` Minuten (5–10), Qualität = Abstand über der Grenze, Umfang = Antworten/6.
6. **Fortschrittsboni** (auch ohne Bestehen): +2 je Lernziel neu „vorläufig“, +3 je Lernziel neu „stabil“, +1 je Lernziel nach zeitlichem Abstand richtig abgerufen (max. 3), +2 für messbare Verbesserung (Phasen Grundlagen/Auf Kurs).
7. **Grenzen**: höchstens 120 Min. pro Tag, Kontostand höchstens 240 Min.

## Prüfungssimulation
Nur wenn ≥ 80 % bearbeitet: `10 + round(10 · clamp((Ergebnis − 40 %) / 50 %))` Minuten, +5 bei Zielnote.

## Konto und Einlösen
- Jede Gutschrift hat eine eindeutige Quelle (`check:<id>`, `sim:<id>`) – nach einem Neustart wird nichts doppelt gutgeschrieben.
- Einlösen schaltet die Sperre für die gewählte Zeit frei; vorzeitiges Beenden bucht ungenutzte Minuten zurück.
- Im strengen Lernmodus kann während der Lernzeit nicht eingelöst werden.

## Tagesziel
Zu Tagesbeginn festgelegt (danach unveränderlich): Anzahl geplanter Einheiten (1–6), an lernfreien Tagen 0.
Bestandene Überprüfungen zählen 1, ernsthaft bearbeitete (≥ 3 gültige Antworten) 0,5, Simulationen 2.

## 100 %
Siehe `LERNMODELL.md`. Bei 100 % sind die gesperrten Apps **bis Mitternacht** frei – unabhängig vom Modus.
