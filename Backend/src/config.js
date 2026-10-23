// Konfiguration ausschließlich über Umgebungsvariablen – keine Schlüssel im Code.
export function loadConfig(env = process.env) {
  const list = (value) => (value ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  const int = (value, fallback) => {
    const n = Number.parseInt(value ?? "", 10);
    return Number.isFinite(n) && n > 0 ? n : fallback;
  };
  return {
    port: int(env.PORT, 8787),
    host: env.HOST ?? "127.0.0.1",
    model: env.LF_MODEL || "claude-opus-5-5",
    accessTokens: list(env.LF_ACCESS_TOKENS),
    tokenSecret: env.LF_TOKEN_SECRET ?? "",
    openRegistration: env.LF_OPEN_REGISTRATION === "1",
    allowAnonymous: env.LF_ALLOW_ANONYMOUS === "1",
    rateLimitPerHour: int(env.LF_RATE_LIMIT_PER_HOUR, 120),
    dailyLimit: int(env.LF_DAILY_LIMIT, 600),
    maxBodyBytes: int(env.LF_MAX_BODY_BYTES, 1_000_000),
    // Server-seitiger Ausweichmechanismus bei Ablehnungen durch Sicherheitsfilter (Claude API).
    useFallbacks: env.LF_DISABLE_FALLBACKS !== "1",
  };
}

export function configProblems(config, env = process.env) {
  const problems = [];
  if (!env.ANTHROPIC_API_KEY && !env.ANTHROPIC_AUTH_TOKEN) {
    problems.push("ANTHROPIC_API_KEY ist nicht gesetzt.");
  }
  const hasAuth = config.accessTokens.length > 0 || (config.openRegistration && config.tokenSecret.length >= 32);
  if (!hasAuth && !config.allowAnonymous) {
    problems.push("Kein Zugriffsschutz konfiguriert: LF_ACCESS_TOKENS setzen oder LF_OPEN_REGISTRATION=1 mit LF_TOKEN_SECRET (mind. 32 Zeichen). Nur lokal: LF_ALLOW_ANONYMOUS=1.");
  }
  if (config.openRegistration && config.tokenSecret.length < 32) {
    problems.push("LF_TOKEN_SECRET muss mindestens 32 Zeichen lang sein.");
  }
  if (config.allowAnonymous && config.host !== "127.0.0.1" && config.host !== "localhost") {
    problems.push("LF_ALLOW_ANONYMOUS ist nur zusammen mit HOST=127.0.0.1 erlaubt.");
  }
  return problems;
}
