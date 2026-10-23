import Anthropic from "@anthropic-ai/sdk";
import { validate } from "./schema.js";

/// Fehler mit HTTP-Status und verständlicher Meldung für die App.
export class ServiceError extends Error {
  constructor(status, code, message, retryAfterSeconds) {
    super(message);
    this.status = status;
    this.code = code;
    this.retryAfterSeconds = retryAfterSeconds;
  }
}

/// Ruft Claude mit strukturierter Ausgabe auf und gibt das geprüfte JSON-Objekt zurück.
export async function callStructured(client, config, { system, content, schema, effort, maxTokens, log }) {
  const params = {
    model: config.model,
    max_tokens: maxTokens,
    system: [{ type: "text", text: system, cache_control: { type: "ephemeral" } }],
    messages: [{ role: "user", content }],
    output_config: { effort, format: { type: "json_schema", schema } },
  };
  if (config.useFallbacks) {
    // Bei einer Ablehnung durch Sicherheitsfilter wählt die API serverseitig ein passendes Ausweichmodell.
    params.betas = ["server-side-fallback-2026-07-01"];
    params.fallbacks = "default";
  }

  let response;
  try {
    response = await client.beta.messages.create(params);
  } catch (error) {
    throw mapError(error);
  }

  log?.({ usage: response.usage, model: response.model, stop: response.stop_reason });

  if (response.stop_reason === "refusal") {
    throw new ServiceError(422, "refused", "Diese Anfrage kann der KI-Dienst nicht bearbeiten. Versuche es mit anderem Material oder ohne KI.");
  }
  if (response.stop_reason === "max_tokens") {
    throw new ServiceError(502, "incomplete", "Die KI-Antwort war unvollständig. Bitte mit weniger Material erneut versuchen.");
  }
  const text = response.content.filter((b) => b.type === "text").map((b) => b.text).join("");
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new ServiceError(502, "invalid_output", "Die KI-Antwort war kein gültiges Format. Bitte erneut versuchen.");
  }
  const errors = validate(parsed, schema);
  if (errors.length > 0) {
    throw new ServiceError(502, "invalid_output", `Die KI-Antwort entsprach nicht dem erwarteten Format (${errors.slice(0, 3).join("; ")}).`);
  }
  return parsed;
}

export function mapError(error) {
  if (error instanceof ServiceError) return error;
  if (error instanceof Anthropic.RateLimitError) {
    const retry = Number.parseInt(error.headers?.get?.("retry-after") ?? "", 10);
    return new ServiceError(503, "busy", "Der KI-Dienst ist gerade ausgelastet. Bitte gleich noch einmal versuchen.", Number.isFinite(retry) ? retry : 30);
  }
  if (error instanceof Anthropic.AuthenticationError || error instanceof Anthropic.PermissionDeniedError) {
    return new ServiceError(500, "server_misconfigured", "Der KI-Server ist nicht korrekt eingerichtet (API-Schlüssel).");
  }
  if (error instanceof Anthropic.BadRequestError) {
    return new ServiceError(502, "upstream_rejected", "Der KI-Dienst hat die Anfrage abgelehnt.");
  }
  if (error instanceof Anthropic.APIConnectionError) {
    return new ServiceError(503, "unreachable", "Der KI-Dienst ist nicht erreichbar. Bitte später erneut versuchen.");
  }
  if (error instanceof Anthropic.APIError) {
    return new ServiceError(503, "upstream_error", "Beim KI-Dienst ist ein Fehler aufgetreten. Bitte später erneut versuchen.");
  }
  return new ServiceError(500, "internal", "Unerwarteter Serverfehler.");
}
