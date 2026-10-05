#!/usr/bin/env bash
# OSC entrypoint for Grist: maps OSC platform conventions to Grist's own env vars,
# then hands over to the upstream entrypoint (which drops root and execs tini).
set -Eeuo pipefail

# Single-quote a value for safe eval.
shq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# --- Port and public URL ---------------------------------------------------
export PORT="${PORT:-8080}"
if [[ -n "${OSC_HOSTNAME:-}" && -z "${APP_HOME_URL:-}" ]]; then
  export APP_HOME_URL="https://${OSC_HOSTNAME}"
fi

# --- Home database: DATABASE_URL (postgres://user:pass@host:port/db?params) --
# Without DATABASE_URL Grist falls back to SQLite at TYPEORM_DATABASE (not persistent on OSC).
if [[ -n "${DATABASE_URL:-}" ]]; then
  eval "$(DATABASE_URL="$DATABASE_URL" node -e '
    const q = s => "\x27" + String(s).replace(/\x27/g, "\x27\\\x27\x27") + "\x27";
    const u = new URL(process.env.DATABASE_URL);
    if (!/^postgres(ql)?:$/.test(u.protocol)) { console.error("DATABASE_URL must be a postgres:// URL"); process.exit(1); }
    const out = {
      TYPEORM_TYPE: "postgres",
      TYPEORM_HOST: u.hostname,
      TYPEORM_PORT: u.port || "5432",
      TYPEORM_USERNAME: decodeURIComponent(u.username),
      TYPEORM_PASSWORD: decodeURIComponent(u.password),
      TYPEORM_DATABASE: decodeURIComponent(u.pathname.replace(/^\//, "")) || "grist",
    };
    const ssl = u.searchParams.get("sslmode");
    if (ssl && ssl !== "disable") out.TYPEORM_EXTRA = JSON.stringify({ ssl: { rejectUnauthorized: ssl === "verify-full" } });
    for (const [k, v] of Object.entries(out)) console.log("export " + k + "=" + q(v));
  ')"
fi

# --- Document storage: S3-compatible (MinIO) --------------------------------
# S3_ENDPOINT is a full URL, e.g. https://host or http://host:9000
if [[ -n "${S3_ENDPOINT:-}" ]]; then
  : "${S3_BUCKET:?S3_BUCKET is required when S3_ENDPOINT is set}"
  : "${S3_ACCESS_KEY:?S3_ACCESS_KEY is required when S3_ENDPOINT is set}"
  : "${S3_SECRET_KEY:?S3_SECRET_KEY is required when S3_ENDPOINT is set}"
  eval "$(S3_ENDPOINT="$S3_ENDPOINT" node -e '
    const u = new URL(process.env.S3_ENDPOINT);
    const ssl = u.protocol === "https:";
    console.log("export GRIST_DOCS_S3_ENDPOINT=" + u.hostname);
    console.log("export GRIST_DOCS_S3_PORT=" + (u.port || (ssl ? "443" : "80")));
    console.log("export GRIST_DOCS_S3_USE_SSL=" + (ssl ? "true" : "false"));
  ')"
  export GRIST_DOCS_S3_BUCKET="$S3_BUCKET"
  export GRIST_DOCS_S3_ACCESS_KEY="$S3_ACCESS_KEY"
  export GRIST_DOCS_S3_SECRET_KEY="$S3_SECRET_KEY"
  export GRIST_DOCS_S3_PREFIX="${S3_PREFIX:-docs/}"
  [[ -n "${S3_REGION:-}" ]] && export GRIST_DOCS_S3_BUCKET_REGION="$S3_REGION"
fi

# --- Sandbox: gVisor needs privileges OSC does not grant; never run unsandboxed --
export GRIST_SANDBOX_FLAVOR="${GRIST_SANDBOX_FLAVOR:-pyodide}"

# --- Sessions ----------------------------------------------------------------
if [[ -z "${GRIST_SESSION_SECRET:-}" ]]; then
  echo "osc-entrypoint: GRIST_SESSION_SECRET not set, generating one (sessions reset on restart)" >&2
  GRIST_SESSION_SECRET="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  export GRIST_SESSION_SECRET
fi

# Fresh Grist installs stay out of service until an operator enters a boot key from the logs.
# On OSC the instance is already behind the platform auth gate, so go live directly.
export GRIST_IN_SERVICE="${GRIST_IN_SERVICE:-true}"

# Optional admin / default owner email
if [[ -n "${ADMIN_EMAIL:-}" ]]; then
  export GRIST_DEFAULT_EMAIL="$ADMIN_EMAIL"
  export GRIST_ADMIN_EMAIL="$ADMIN_EMAIL"
fi

exec ./sandbox/docker_entrypoint.sh "$@"
