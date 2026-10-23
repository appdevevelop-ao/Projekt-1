import http from "node:http";
import { fileURLToPath } from "node:url";
import Anthropic from "@anthropic-ai/sdk";
import { loadConfig, configProblems } from "./config.js";
import { authenticate, RateLimiter, signInstallation, isValidInstallationId } from "./auth.js";
import { callStructured, ServiceError, mapError } from "./claude.js";
import { analyzeSchema, questionsSchema, gradeSchema, explainSchema } from "./schema.js";
import { ANALYZE_SYSTEM, QUESTIONS_SYSTEM, GRADE_SYSTEM, EXPLAIN_SYSTEM, analyzeUser, questionsUser, gradeUser, explainUser } from "./prompts.js";
import { parseAnalyze, parseQuestions, parseGrade, parseExplain, filterAnalysis, filterQuestions, filterExplanation, clampGrade } from "./requests.js";

// Endpunkte: Eingabe prüfen → Claude mit festem Ausgabeschema aufrufen → Ergebnis prüfen und filtern.
const ENDPOINTS = {
  "/v1/analyze": {
    parse: parseAnalyze,
    run: (client, config, req, log) =>
      callStructured(client, config, { system: ANALYZE_SYSTEM, content: analyzeUser(req), schema: analyzeSchema, effort: "medium", maxTokens: 16_000, log }).then((r) => filterAnalysis(r, req)),
  },
  "/v1/questions": {
    parse: parseQuestions,
    run: (client, config, req, log) =>
      callStructured(client, config, { system: QUESTIONS_SYSTEM, content: questionsUser(req), schema: questionsSchema, effort: "medium", maxTokens: 16_000, log }).then((r) => filterQuestions(r, req)),
  },
  "/v1/grade": {
    parse: parseGrade,
    run: (client, config, req, log) =>
      callStructured(client, config, { system: GRADE_SYSTEM, content: gradeUser(req), schema: gradeSchema, effort: "medium", maxTokens: 8_000, log }).then(clampGrade),
  },
  "/v1/explain": {
    parse: parseExplain,
    run: (client, config, req, log) =>
      callStructured(client, config, { system: EXPLAIN_SYSTEM, content: explainUser(req), schema: explainSchema, effort: "low", maxTokens: 6_000, log }).then((r) => filterExplanation(r, req)),
  },
};

function send(res, status, body, extraHeaders = {}) {
  const data = JSON.stringify(body);
  res.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(data),
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
    ...extraHeaders,
  });
  res.end(data);
}

function readJSON(req, maxBytes) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const parts = [];
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > maxBytes) {
        reject(new ServiceError(413, "too_large", "Die Anfrage ist zu groß."));
        req.destroy();
        return;
      }
      parts.push(chunk);
    });
    req.on("end", () => {
      try {
        resolve(JSON.parse(Buffer.concat(parts).toString("utf8") || "{}"));
      } catch {
        reject(new ServiceError(400, "invalid_json", "Die Anfrage ist kein gültiges JSON."));
      }
    });
    req.on("error", reject);
  });
}

export function createApp({ client, config, logger = () => {}, now = () => Date.now() }) {
  const limiter = new RateLimiter({ perHour: config.rateLimitPerHour, perDay: config.dailyLimit, now });
  const registrationLimiter = new RateLimiter({ perHour: 10, perDay: 30, now });

  return async function handle(req, res) {
    const started = now();
    const url = new URL(req.url ?? "/", "http://localhost");
    let subject = "-";
    let usage;
    const finish = (status, body, headers) => {
      send(res, status, body, headers);
      // Nur Metadaten protokollieren – niemals Lerninhalte oder Antworten.
      logger({ method: req.method, path: url.pathname, status, ms: now() - started, subject, usage });
    };

    try {
      if (req.method === "GET" && url.pathname === "/health") {
        return finish(200, { status: "ok", model: config.model });
      }
      if (req.method === "POST" && url.pathname === "/v1/register") {
        if (!config.openRegistration || !config.tokenSecret) throw new ServiceError(404, "not_found", "Registrierung ist auf diesem Server nicht aktiviert.");
        const ip = req.socket.remoteAddress ?? "unknown";
        const limit = registrationLimiter.check(`reg:${ip}`);
        if (!limit.allowed) throw new ServiceError(429, "rate_limited", "Zu viele Registrierungen. Bitte später erneut versuchen.", limit.retryAfterSeconds);
        const body = await readJSON(req, 10_000);
        if (!isValidInstallationId(body.installationId)) throw new ServiceError(400, "invalid_request", "Ungültige Installations-ID.");
        return finish(200, { token: signInstallation(body.installationId, config.tokenSecret) });
      }
      const endpoint = ENDPOINTS[url.pathname];
      if (!endpoint) throw new ServiceError(404, "not_found", "Unbekannter Endpunkt.");
      if (req.method !== "POST") throw new ServiceError(405, "method_not_allowed", "Nur POST ist erlaubt.");

      const auth = authenticate(req.headers.authorization, config);
      if (!auth.ok) throw new ServiceError(401, "unauthorized", "Zugriffstoken fehlt oder ist ungültig.");
      subject = auth.subject;
      const limit = limiter.check(subject);
      if (!limit.allowed) throw new ServiceError(429, "rate_limited", "Das Nutzungslimit ist erreicht. Bitte später erneut versuchen.", limit.retryAfterSeconds);

      const body = await readJSON(req, config.maxBodyBytes);
      const request = endpoint.parse(body);
      const result = await endpoint.run(client, config, request, (info) => { usage = info.usage; });
      return finish(200, result);
    } catch (error) {
      const e = error instanceof ServiceError ? error : mapError(error);
      const headers = e.retryAfterSeconds ? { "Retry-After": String(e.retryAfterSeconds) } : {};
      return finish(e.status, { error: e.code, message: e.message }, headers);
    }
  };
}

async function main() {
  const config = loadConfig();
  const problems = configProblems(config);
  if (problems.length > 0) {
    console.error("LernFokus-KI-Server kann nicht starten:\n- " + problems.join("\n- "));
    process.exit(1);
  }
  const client = new Anthropic({ maxRetries: 2, timeout: 120_000 });
  const handler = createApp({
    client,
    config,
    logger: (entry) => console.log(JSON.stringify({ t: new Date().toISOString(), ...entry, usage: entry.usage ? { in: entry.usage.input_tokens, out: entry.usage.output_tokens, cacheRead: entry.usage.cache_read_input_tokens } : undefined })),
  });
  const server = http.createServer(handler);
  server.requestTimeout = 180_000;
  server.listen(config.port, config.host, () => {
    console.log(`LernFokus-KI-Server läuft auf http://${config.host}:${config.port} (Modell: ${config.model})`);
  });
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main();
}
