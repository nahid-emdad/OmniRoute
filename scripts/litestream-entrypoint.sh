#!/bin/sh
set -e

DB_DIR="${DATA_DIR:-/app/data}"
DB_PATH="${DB_DIR}/storage.sqlite"
LITESTREAM_CONFIG="${LITESTREAM_CONFIG:-/etc/litestream.yml}"

# Default command if no arguments are passed
if [ $# -eq 0 ]; then
  set -- node dev/run-standalone.mjs
fi

# 1. Check for explicit local development mode (opt-out of replication)
if [ "${LITESTREAM_ENABLED}" = "false" ] || [ "${LITESTREAM_ENABLED}" = "0" ]; then
  echo "[Litestream] LITESTREAM_ENABLED is set to '${LITESTREAM_ENABLED}'. Replication disabled."
  echo "[Litestream] Starting OmniRoute in standalone SQLite local mode..."
  exec /app/check-permissions.sh "$@"
fi

# 2. Validate required Cloudflare R2 credentials
MISSING_VARS=""
if [ -z "$CLOUDFLARE_ACCOUNT_ID" ]; then
  MISSING_VARS="${MISSING_VARS} CLOUDFLARE_ACCOUNT_ID"
fi
if [ -z "$LITESTREAM_BUCKET" ]; then
  MISSING_VARS="${MISSING_VARS} LITESTREAM_BUCKET"
fi
if [ -z "$LITESTREAM_ACCESS_KEY_ID" ]; then
  MISSING_VARS="${MISSING_VARS} LITESTREAM_ACCESS_KEY_ID"
fi
if [ -z "$LITESTREAM_SECRET_ACCESS_KEY" ]; then
  MISSING_VARS="${MISSING_VARS} LITESTREAM_SECRET_ACCESS_KEY"
fi

if [ -n "$MISSING_VARS" ]; then
  echo "================================================================================" >&2
  echo "[Litestream] FATAL: Missing required Cloudflare R2 credentials for Litestream:" >&2
  echo "[Litestream] Missing variables:${MISSING_VARS}" >&2
  echo "[Litestream]" >&2
  echo "[Litestream] For production deployments (e.g. Render Free), set these environment variables." >&2
  echo "[Litestream] For local development without replication, explicitly set: LITESTREAM_ENABLED=false" >&2
  echo "================================================================================" >&2
  exit 1
fi

# 3. Ensure data directory exists
mkdir -p "$DB_DIR"

# 4. Restore database if it does not exist locally
if [ ! -f "$DB_PATH" ]; then
  echo "[Litestream] Local database '${DB_PATH}' not found."
  echo "[Litestream] Querying Cloudflare R2 for existing replica..."

  if litestream restore -config "$LITESTREAM_CONFIG" -if-db-not-exists -if-replica-exists "$DB_PATH"; then
    if [ -f "$DB_PATH" ]; then
      echo "[Litestream] SUCCESS: Restored database from Cloudflare R2 replica."
    else
      echo "[Litestream] NOTICE: No replica found in R2 bucket (first deployment). OmniRoute will initialize clean database."
    fi
  else
    echo "[Litestream] ERROR: Litestream restore failed." >&2
    exit 1
  fi
else
  echo "[Litestream] Existing local database found at '${DB_PATH}'. Skipping restore."
fi

# 5. Start Litestream replication and supervise child process
echo "[Litestream] Starting Litestream replication supervisor..."

# Build safely escaped command string for litestream -exec to preserve exact arguments
APP_CMD="/app/check-permissions.sh"
for arg in "$@"; do
  escaped_arg=$(printf "%s" "$arg" | sed "s/'/'\\\\''/g")
  APP_CMD="${APP_CMD} '${escaped_arg}'"
done

exec litestream replicate -config "$LITESTREAM_CONFIG" -restore-if-db-not-exists -exec "$APP_CMD"