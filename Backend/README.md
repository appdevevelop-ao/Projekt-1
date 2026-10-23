# LernFokus KI-Server

Kleiner Node.js-Server zwischen App und Claude API. **Der API-Schlüssel liegt nur hier**, nie in der App.

| Endpunkt | Zweck |
|---|---|
| `GET /health` | Erreichbarkeit prüfen |
| `POST /v1/analyze` | Abschnitte → Themen, Lernziele, Begriffe (mit Belegzitaten) |
| `POST /v1/questions` | Fragen zu einem Lernziel (mit Quelle und Zitat) |
| `POST /v1/grade` | Offene Antwort bewerten (Punktzahl, Rückmeldung, Sicherheit) |
| `POST /v1/explain` | Einfachere Erklärung / Beispiel / Fehlererklärung |
| `POST /v1/register` | (optional) Token pro Installation ausstellen |

Die Datenverträge entsprechen `Packages/LernKern/Sources/LernKern/AI/AIContracts.swift`.

## Starten

```bash
cd Backend
npm ci
cp .env.example .env   # Werte eintragen
set -a; source .env; set +a
npm start
```

Für den Test im Simulator genügt `HOST=127.0.0.1` und `LF_ALLOW_ANONYMOUS=1`. Für ein echtes iPhone
muss der Server per HTTPS erreichbar sein (z. B. hinter einem Reverse Proxy oder als Container –
siehe `Dockerfile`) und `LF_ACCESS_TOKENS` gesetzt sein. Das Token wird in der App unter
Profil → KI-Dienst eingetragen.

## Sicherheit und Datenschutz

- Strukturierte Ausgaben mit festem JSON-Schema; jede Antwort wird zusätzlich geprüft.
- Verweise auf nicht gesendete Abschnitte werden entfernt; die App prüft zudem, ob Zitate wörtlich im Material stehen.
- Lernmaterial und Antworten werden als abgegrenzte Daten übergeben (Schutz vor Prompt-Injection).
- Zugriff nur mit Token; Ratenbegrenzung pro Token (Stunde/Tag); Größenlimits je Anfrage.
- Protokolliert werden nur Metadaten (Pfad, Status, Dauer, Token-Fingerabdruck, Tokenverbrauch) – keine Inhalte.
- Der Server speichert keine Lerninhalte.
- Bei Ablehnung durch Sicherheitsfilter nutzt die API serverseitig ein Ausweichmodell (`fallbacks: "default"`); abschaltbar mit `LF_DISABLE_FALLBACKS=1`.

Für den produktiven Betrieb empfohlen: Apple **App Attest** zur Geräteprüfung, gemeinsamer
Speicher für Ratenlimits bei mehreren Instanzen, TLS-Terminierung, Datenverarbeitungsvertrag (AVV).

## Tests

```bash
npm test
```

Die Tests verwenden den echten SDK-Client mit simuliertem Netzwerk (keine Kosten, kein Schlüssel nötig).
