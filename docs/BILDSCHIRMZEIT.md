# Bildschirmzeit-Steuerung

## Bausteine (nur öffentliche Apple-APIs)
| Baustein | Zweck |
|---|---|
| `FamilyControls` | Berechtigung (`AuthorizationCenter.requestAuthorization(for: .individual)`) und Auswahl (`familyActivityPicker`) |
| `ManagedSettings` | Sperre über einen eigenen, benannten `ManagedSettingsStore("lernfokus")` |
| `DeviceActivity` | Zeitpläne, die die Erweiterung auch bei geschlossener App wecken |
| `ActivityMonitorExtension` | wertet bei Beginn/Ende eines Zeitplans aus und setzt/entfernt die Sperre |
| `ShieldConfigurationExtension` | ruhiger, erklärender Sperrbildschirm |
| `ShieldActionExtension` | Taste „Zu LernFokus“ (Mitteilung zum Öffnen der App) |

## Eine Quelle der Wahrheit
`ShieldDecisionEngine.decide(policy, ledger, environment, now, calendar)` (Paket `ShieldLogic`) leitet aus dem per
App Group geteilten Zustand ab, ob **jetzt** gesperrt sein muss. App und Erweiterung rufen dieselbe Funktion auf und
wenden das Ergebnis an (`ShieldController.reconcile`). Es gibt kein verteiltes Umschalten – widersprüchliche
Zustände sind dadurch ausgeschlossen. Die UI zeigt zusätzlich, ob die Sperre im System tatsächlich gesetzt ist.

Zustände: `disabled`, `notConfigured`, `permissionMissing`, `locked(Grund, bis)`, `rewardWindow(bis)`,
`emergencyPause(bis)`, `dailyGoalReached`, `outsideLockTimes(nächste Sperre)`, `fullDayUnlock(Tag)`.

Reihenfolge der Auswertung: aus → keine Auswahl → keine Berechtigung → **100 %-Tagesfreigabe** → Notfall-Pause →
Sperrbedarf laut Modus → eingelöste Belohnung (nicht im strengen Modus während der Lernzeit) → gesperrt.

## Modi
| Modus | Gesperrt |
|---|---|
| Fokus | während der Lernzeitfenster; Belohnung als Pause einlösbar |
| Streng | während der Lernzeitfenster, ohne Einlösen |
| Tagesziel | ab Uhrzeit X, bis das Tagesziel erreicht ist |
| Kombiniert (Standard) | während der Lernzeitfenster, bis das Tagesziel erreicht ist |

## Vollständige Tagesfreigabe bei 100 %
1. Nach jeder Überprüfung prüft `FullMasteryEvaluator` die Kriterien.
2. Bei Erfüllung **und** einer an diesem Tag bestandenen Überprüfung bzw. Simulation (`unlockEarnedToday`) speichert
   `UnlockActions.grantFullMasteryUnlock` den **lokalen Kalendertag** (`DayKey`). Ein bloßes Öffnen der App am
   Folgetag gibt also nichts frei – dort gilt wieder die normale Logik; eine bestandene Wiederholung bei weiterhin
   100 % gibt diesen Tag erneut frei.
3. `reconcile` entfernt die Sperre (`clearAllSettings`).
4. Jeder spätere Rückruf am selben Tag (Lernfenster-Beginn, Tagesziel-Start …) sieht die Freigabe zuerst → keine erneute Sperre.
   Das Ende des Tagesintervalls (23:59) wird bewusst nicht vorgezogen ausgewertet.
5. Der Zeitplan `lf.daily` (00:00–23:59, täglich) weckt die Erweiterung um Mitternacht → neuer Tag → reguläre Regeln.
6. Zeitzone: der Tag wird stets in der **aktuellen** Gerätezeitzone berechnet (Reise nach Westen: Freigabe bleibt bis zur dortigen Mitternacht; nach Osten: neuer Tag beginnt früher). Sommerzeitwechsel getestet.
7. Neustart: ManagedSettings bleibt vom System erhalten; der Zustand liegt in der App Group; beim Öffnen der App und per Hintergrundaktualisierung wird erneut abgeglichen.

## Technische Grenzen (iOS)
- **Mindestdauer 15 Minuten** je DeviceActivity-Zeitplan: kürzere Belohnungsfenster werden mit einem in der Vergangenheit liegenden Beginn registriert (entscheidend ist das Ende).
- iOS liefert Rückrufe gelegentlich **verzögert** oder einige Sekunden zu früh; zu frühe Rückrufe werden an der jeweiligen Grenze ausgewertet, verspätete beim nächsten Öffnen/Hintergrundlauf korrigiert.
- Max. ~20 überwachte Aktivitäten: höchstens 14 Lernzeitfenster.
- Die Sperre ist eine **Selbstverpflichtung**: Nutzer können die Berechtigung in den iOS-Einstellungen entziehen. Telefon, Notruf und Systemfunktionen sind nicht sperrbar.
- Im **Simulator** funktionieren Berechtigung und Sperre nicht – Test auf einem echten Gerät nötig.
- Für die Veröffentlichung im App Store muss das **Family Controls (Distribution)**-Entitlement bei Apple beantragt werden.
