import { createHmac, createHash, timingSafeEqual } from "node:crypto";

// Zugriffstoken prüfen. Zwei Arten:
// 1. feste Tokens aus LF_ACCESS_TOKENS (z. B. für eigene Geräte oder eine Testgruppe)
// 2. pro Installation ausgestellte Tokens "inst.<id>.<signatur>" (HMAC mit LF_TOKEN_SECRET)
// Für den Produktivbetrieb sollte zusätzlich Apple App Attest geprüft werden (siehe README).

export function tokenFingerprint(token) {
  return createHash("sha256").update(token).digest("hex").slice(0, 12);
}

function safeEqual(a, b) {
  const x = Buffer.from(a);
  const y = Buffer.from(b);
  return x.length === y.length && timingSafeEqual(x, y);
}

export function signInstallation(installationId, secret) {
  const signature = createHmac("sha256", secret).update(installationId).digest("base64url");
  return `inst.${installationId}.${signature}`;
}

export function isValidInstallationId(id) {
  return typeof id === "string" && /^[A-Za-z0-9-]{16,64}$/.test(id);
}

export function authenticate(header, config) {
  if (config.allowAnonymous) return { ok: true, subject: "anonymous" };
  const match = /^Bearer\s+(\S+)$/.exec(header ?? "");
  if (!match) return { ok: false };
  const token = match[1];
  if (config.accessTokens.some((t) => safeEqual(t, token))) return { ok: true, subject: tokenFingerprint(token) };
  if (config.tokenSecret && token.startsWith("inst.")) {
    const parts = token.split(".");
    if (parts.length === 3 && isValidInstallationId(parts[1])) {
      const expected = signInstallation(parts[1], config.tokenSecret);
      if (safeEqual(expected, token)) return { ok: true, subject: tokenFingerprint(token) };
    }
  }
  return { ok: false };
}

/// Einfache Ratenbegrenzung im Speicher (pro Prozess). Für mehrere Instanzen einen gemeinsamen Speicher verwenden.
export class RateLimiter {
  constructor({ perHour, perDay, now = () => Date.now() }) {
    this.perHour = perHour;
    this.perDay = perDay;
    this.now = now;
    this.hits = new Map();
  }

  check(subject) {
    const t = this.now();
    const list = (this.hits.get(subject) ?? []).filter((x) => t - x < 24 * 3600 * 1000);
    const lastHour = list.filter((x) => t - x < 3600 * 1000).length;
    if (lastHour >= this.perHour || list.length >= this.perDay) {
      this.hits.set(subject, list);
      const oldestRelevant = lastHour >= this.perHour ? list.filter((x) => t - x < 3600 * 1000)[0] + 3600 * 1000 : list[0] + 24 * 3600 * 1000;
      return { allowed: false, retryAfterSeconds: Math.max(1, Math.ceil((oldestRelevant - t) / 1000)) };
    }
    list.push(t);
    this.hits.set(subject, list);
    return { allowed: true };
  }
}
