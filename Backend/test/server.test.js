import { test } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import Anthropic from "@anthropic-ai/sdk";
import { createApp } from "../src/server.js";
import { loadConfig } from "../src/config.js";

// Ein echter SDK-Client mit simuliertem Netzwerk: prüft, dass die Anfragen an die Claude API korrekt
// aufgebaut sind, ohne echte Kosten zu verursachen.
function fakeClient(respond) {
  const calls = [];
  const fetch = async (url, init) => {
    const body = JSON.parse(init.body);
    const headers = new Headers(init.headers);
    calls.push({ url: String(url), body, headers });
    const { status = 200, json, headers: extra = {} } = respond(body, calls.length);
    return new Response(JSON.stringify(json), { status, headers: { "content-type": "application/json", ...extra } });
  };
  return { client: new Anthropic({ apiKey: "test-key", fetch, maxRetries: 0 }), calls };
}

function message(text, stop = "end_turn") {
  return {
    id: "msg_test", type: "message", role: "assistant", model: "claude-opus-5-5", stop_reason: stop, stop_sequence: null,
    content: [{ type: "text", text }],
    usage: { input_tokens: 100, output_tokens: 50, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 },
  };
}

async function withServer(app, fn) {
  const server = http.createServer(app);
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    await fn(base);
  } finally {
    await new Promise((r) => server.close(r));
  }
}

const config = { ...loadConfig({}), accessTokens: ["tok"], rateLimitPerHour: 100 };
const auth = { "content-type": "application/json", authorization: "Bearer tok" };
const chunk = { id: "c1", section: "Zellteilung", pages: "S. 3", text: "Die Mitose ist die Teilung des Zellkerns." };

const questionJSON = {
  questions: [
    { kind: "cloze", prompt: "Die ___ ist die Teilung des Zellkerns.", options: [], correctOptionIndices: [], acceptedAnswers: ["Mitose"], numeric: null, pairs: [], referenceAnswer: "", rubric: [], explanation: "Laut Material.", simplerExplanation: "", commonMistakes: [], difficulty: "medium", isTransfer: false, chunkId: "c1", sourceQuote: "Die Mitose ist die Teilung des Zellkerns" },
    { kind: "cloze", prompt: "Erfundene Frage", options: [], correctOptionIndices: [], acceptedAnswers: ["x"], numeric: null, pairs: [], referenceAnswer: "", rubric: [], explanation: "", simplerExplanation: "", commonMistakes: [], difficulty: "easy", isTransfer: false, chunkId: "fremd", sourceQuote: "x" },
  ],
  insufficientMaterial: false,
};

test("Fragen-Endpunkt: korrekter API-Aufruf und gefilterte Antwort", async () => {
  const { client, calls } = fakeClient(() => ({ json: message(JSON.stringify(questionJSON)) }));
  await withServer(createApp({ client, config }), async (base) => {
    const res = await fetch(`${base}/v1/questions`, {
      method: "POST", headers: auth,
      body: JSON.stringify({ exam: { title: "Bio", format: "written" }, objective: { title: "Mitose erklären", keyTerms: ["Mitose"] }, language: "de", chunks: [chunk], difficulties: { easy: 1, medium: 1, hard: 0 }, kinds: ["cloze"], avoidPrompts: [] }),
    });
    assert.equal(res.status, 200);
    const data = await res.json();
    assert.equal(data.questions.length, 1, "Frage mit unbekanntem Abschnitt wird verworfen");
    assert.equal(data.insufficientMaterial, true);
  });
  assert.equal(calls.length, 1);
  const { url, body, headers } = calls[0];
  assert.ok(new URL(url).pathname === "/v1/messages");
  assert.equal(headers.get("anthropic-version"), "2026-10-21");
  assert.equal(body.model, "claude-opus-5-5");
  assert.equal(body.output_config.format.type, "json_schema");
  assert.equal(body.output_config.effort, "medium");
  assert.equal(body.fallbacks, "default");
  assert.ok(headers.get("anthropic-beta").includes("server-side-fallback-2026-07-01"));
  assert.equal(body.temperature, undefined);
  assert.equal(body.system[0].cache_control.type, "ephemeral");
  assert.equal(body.messages[0].content[0].cache_control.type, "ephemeral", "Material wird gecacht");
  assert.ok(body.messages[0].content[0].text.includes('<abschnitt id="c1"'));
  assert.ok([headers.get("x-api-key"), headers.get("authorization")].some((h) => h?.includes("test-key")), "Schlüssel nur serverseitig");
});

test("Bewertung offener Antworten", async () => {
  const { client } = fakeClient(() => ({ json: message(JSON.stringify({ score: 1.4, verdict: "correct", feedback: "Sehr gut.", coveredPoints: ["a"], missingPoints: [], confidence: "high" })) }));
  await withServer(createApp({ client, config }), async (base) => {
    const res = await fetch(`${base}/v1/grade`, { method: "POST", headers: auth, body: JSON.stringify({ prompt: "Erkläre Mitose", referenceAnswer: "Kernteilung", rubric: ["Kernteilung"], answer: "Teilung des Zellkerns" }) });
    assert.equal(res.status, 200);
    assert.equal((await res.json()).score, 1, "Punktzahl wird auf 0–1 begrenzt");
  });
});

test("Ablehnung, abgeschnittene und ungültige Ausgaben werden sauber gemeldet", async () => {
  const outputs = [message("", "refusal"), message('{"score":', "max_tokens"), message("kein json"), message(JSON.stringify({ score: 1 }))];
  const { client } = fakeClient((_, n) => ({ json: outputs[n - 1] }));
  await withServer(createApp({ client, config }), async (base) => {
    const body = JSON.stringify({ prompt: "P", referenceAnswer: "R", rubric: [], answer: "A" });
    const statuses = [];
    for (let i = 0; i < 4; i++) {
      const res = await fetch(`${base}/v1/grade`, { method: "POST", headers: auth, body });
      statuses.push([res.status, (await res.json()).error]);
    }
    assert.deepEqual(statuses, [[422, "refused"], [502, "incomplete"], [502, "invalid_output"], [502, "invalid_output"]]);
  });
});

test("Überlastung der KI wird als 503 mit Retry-After weitergegeben", async () => {
  const { client } = fakeClient(() => ({ status: 429, json: { type: "error", error: { type: "rate_limit_error", message: "slow down" } }, headers: { "retry-after": "12" } }));
  await withServer(createApp({ client, config }), async (base) => {
    const res = await fetch(`${base}/v1/explain`, { method: "POST", headers: auth, body: JSON.stringify({ mode: "simpler", objective: { title: "O" }, chunks: [chunk] }) });
    assert.equal(res.status, 503);
    assert.equal(res.headers.get("retry-after"), "12");
  });
});

test("Zugriffsschutz, Limits und Fehlerfälle", async () => {
  const { client, calls } = fakeClient(() => ({ json: message("{}") }));
  const limited = { ...config, rateLimitPerHour: 1 };
  await withServer(createApp({ client, config: limited }), async (base) => {
    assert.equal((await fetch(`${base}/health`)).status, 200);
    assert.equal((await fetch(`${base}/v1/grade`, { method: "POST", body: "{}" })).status, 401);
    assert.equal((await fetch(`${base}/v1/unbekannt`, { method: "POST", headers: auth, body: "{}" })).status, 404);
    assert.equal((await fetch(`${base}/v1/grade`, { method: "POST", headers: auth, body: "{kaputt" })).status, 400);
    assert.equal((await fetch(`${base}/v1/grade`, { method: "POST", headers: auth, body: "{}" })).status, 429);
  });
  assert.equal(calls.length, 0, "Ungültige Anfragen erreichen die KI nie");
});

test("Registrierung ausgestellter Installations-Tokens", async () => {
  const { client } = fakeClient(() => ({ json: message(JSON.stringify({ explanation: "Kurz.", chunkIds: ["c1", "x"], outsideMaterial: false })) }));
  const reg = { ...config, accessTokens: [], openRegistration: true, tokenSecret: "s".repeat(40) };
  await withServer(createApp({ client, config: reg }), async (base) => {
    const r = await fetch(`${base}/v1/register`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ installationId: "ABCDEF12-3456-7890-ABCD-EF1234567890" }) });
    const { token } = await r.json();
    assert.ok(token.startsWith("inst."));
    const res = await fetch(`${base}/v1/explain`, { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${token}` }, body: JSON.stringify({ mode: "simpler", objective: { title: "O" }, chunks: [chunk] }) });
    assert.equal(res.status, 200);
    assert.deepEqual((await res.json()).chunkIds, ["c1"]);
  });
});

test("Protokoll enthält keine Inhalte", async () => {
  const entries = [];
  const { client } = fakeClient(() => ({ json: message(JSON.stringify({ score: 0.5, verdict: "partial", feedback: "f", coveredPoints: [], missingPoints: [], confidence: "medium" })) }));
  await withServer(createApp({ client, config, logger: (e) => entries.push(e) }), async (base) => {
    await fetch(`${base}/v1/grade`, { method: "POST", headers: auth, body: JSON.stringify({ prompt: "Geheime Frage", referenceAnswer: "R", rubric: [], answer: "Private Antwort" }) });
  });
  const logged = JSON.stringify(entries);
  assert.ok(!logged.includes("Private Antwort") && !logged.includes("Geheime Frage"));
  assert.equal(entries[0].status, 200);
});
