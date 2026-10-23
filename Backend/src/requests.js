import { ServiceError } from "./claude.js";
import { QUESTION_KINDS } from "./schema.js";

// Eingabeprüfung: Größenbegrenzungen schützen vor Missbrauch und unkontrolliert großen KI-Aufrufen.

const LIMITS = {
  analyze: { chunks: 12, chars: 24_000 },
  questions: { chunks: 6, chars: 16_000 },
  explain: { chunks: 4, chars: 10_000 },
};

function fail(message) {
  throw new ServiceError(400, "invalid_request", message);
}

const isString = (v, max = 100_000) => typeof v === "string" && v.length <= max;
const stringList = (v, maxItems, maxLen) => Array.isArray(v) && v.length <= maxItems && v.every((s) => isString(s, maxLen));

function language(v) {
  return typeof v === "string" && /^[a-z]{2}(-[A-Z]{2})?$/.test(v) ? v : "de";
}

function chunks(v, limit) {
  if (!Array.isArray(v) || v.length === 0) fail("Es wurden keine Textabschnitte übermittelt.");
  if (v.length > limit.chunks) fail(`Höchstens ${limit.chunks} Abschnitte pro Anfrage.`);
  let total = 0;
  const result = v.map((c) => {
    if (!c || !isString(c.id, 64) || !isString(c.text, limit.chars)) fail("Ungültiger Abschnitt.");
    total += c.text.length;
    return { id: c.id, section: isString(c.section, 300) ? c.section : "", pages: isString(c.pages, 40) ? c.pages : "", text: c.text };
  });
  if (total > limit.chars) fail(`Zu viel Text in einer Anfrage (max. ${limit.chars} Zeichen).`);
  return result;
}

function exam(v) {
  if (!v || !isString(v.title, 200)) fail("Prüfungsangaben fehlen.");
  return { title: v.title, format: isString(v.format, 40) ? v.format : "unknown", additionalRequirements: isString(v.additionalRequirements, 2_000) ? v.additionalRequirements : "" };
}

function objective(v) {
  if (!v || !isString(v.title, 300)) fail("Lernziel fehlt.");
  return {
    title: v.title,
    description: isString(v.description, 1_000) ? v.description : "",
    bloom: ["remember", "understand", "apply", "analyze"].includes(v.bloom) ? v.bloom : "understand",
    keyTerms: stringList(v.keyTerms, 20, 100) ? v.keyTerms : [],
  };
}

export function parseAnalyze(body) {
  return {
    exam: exam(body.exam),
    language: language(body.language),
    chunks: chunks(body.chunks, LIMITS.analyze),
    knownTopics: stringList(body.knownTopics, 60, 200) ? body.knownTopics : [],
  };
}

export function parseQuestions(body) {
  const d = body.difficulties ?? {};
  const count = (n) => (Number.isInteger(n) && n >= 0 && n <= 8 ? n : 0);
  const difficulties = { easy: count(d.easy), medium: count(d.medium), hard: count(d.hard) };
  if (difficulties.easy + difficulties.medium + difficulties.hard === 0) fail("Mindestens eine Frage anfordern.");
  if (difficulties.easy + difficulties.medium + difficulties.hard > 12) fail("Höchstens 12 Fragen pro Anfrage.");
  const kinds = Array.isArray(body.kinds) ? body.kinds.filter((k) => QUESTION_KINDS.includes(k)) : [];
  return {
    exam: exam(body.exam),
    objective: objective(body.objective),
    language: language(body.language),
    chunks: chunks(body.chunks, LIMITS.questions),
    difficulties,
    kinds: kinds.length ? kinds : QUESTION_KINDS,
    avoidPrompts: stringList(body.avoidPrompts, 40, 400) ? body.avoidPrompts : [],
  };
}

export function parseGrade(body) {
  if (!isString(body.prompt, 2_000) || !isString(body.answer, 4_000) || !isString(body.referenceAnswer, 3_000)) fail("Aufgabe, Antwort oder Musterlösung fehlt oder ist zu lang.");
  if (body.answer.trim().length === 0) fail("Die Antwort ist leer.");
  return {
    language: language(body.language),
    prompt: body.prompt,
    referenceAnswer: body.referenceAnswer,
    rubric: stringList(body.rubric, 10, 400) ? body.rubric : [],
    sourceExcerpt: isString(body.sourceExcerpt, 6_000) ? body.sourceExcerpt : "",
    answer: body.answer,
  };
}

export function parseExplain(body) {
  return {
    language: language(body.language),
    mode: ["simpler", "example", "mistake"].includes(body.mode) ? body.mode : "simpler",
    objective: objective(body.objective),
    chunks: chunks(body.chunks, LIMITS.explain),
    questionPrompt: isString(body.questionPrompt, 2_000) ? body.questionPrompt : null,
    correctAnswer: isString(body.correctAnswer, 1_000) ? body.correctAnswer : null,
    userAnswer: isString(body.userAnswer, 2_000) ? body.userAnswer : null,
  };
}

// Nachbearbeitung: Verweise auf nicht gesendete Abschnitte entfernen (die App prüft Zitate zusätzlich).

export function filterAnalysis(result, request) {
  const ids = new Set(request.chunks.map((c) => c.id));
  const topics = result.topics
    .map((t) => ({ ...t, objectives: t.objectives.map((o) => ({ ...o, chunkIds: o.chunkIds.filter((id) => ids.has(id)) })).filter((o) => o.chunkIds.length > 0) }))
    .filter((t) => t.objectives.length > 0);
  return { topics, terms: result.terms.filter((t) => ids.has(t.chunkId)), warnings: result.warnings };
}

export function filterQuestions(result, request) {
  const ids = new Set(request.chunks.map((c) => c.id));
  const allowed = new Set(request.kinds);
  const questions = result.questions.filter((q) => {
    if (!ids.has(q.chunkId) || !allowed.has(q.kind)) return false;
    if (q.kind === "multipleChoice") return q.correctOptionIndices.length === 1 && q.correctOptionIndices[0] >= 0 && q.correctOptionIndices[0] < q.options.length;
    if (q.kind === "numeric") return q.numeric !== null;
    return true;
  });
  return { questions, insufficientMaterial: result.insufficientMaterial || questions.length < result.questions.length };
}

export function filterExplanation(result, request) {
  const ids = new Set(request.chunks.map((c) => c.id));
  return { ...result, chunkIds: result.chunkIds.filter((id) => ids.has(id)) };
}

export function clampGrade(result) {
  return { ...result, score: Math.min(1, Math.max(0, result.score)) };
}
