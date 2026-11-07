#!/bin/sh
set -eu

TEST_ROOT="/tmp/litestream-recovery-test"
rm -rf "$TEST_ROOT"
mkdir -p "$TEST_ROOT/data" "$TEST_ROOT/replica"

DB_PATH="$TEST_ROOT/data/storage.sqlite"
CONFIG_PATH="$TEST_ROOT/litestream.yml"

echo "================================================================="
echo "[TEST 1] Litestream Data Recovery & PRAGMA Integrity Check Test"
echo "  (Local File-Replica Simulation; Cloudflare R2 requires credentials)"
echo "================================================================="

# 1. Create Litestream v0.5 test configuration with singular replica object
cat <<EOF > "$CONFIG_PATH"
dbs:
  - path: "$DB_PATH"
    replica:
      type: file
      path: "$TEST_ROOT/replica"
      sync-interval: 100ms
EOF

# 2. Create initial SQLite database with WAL mode and test tables
sqlite3 "$DB_PATH" <<'SQL'
PRAGMA journal_mode=WAL;
CREATE TABLE provider_connections (
  id TEXT PRIMARY KEY,
  provider TEXT NOT NULL,
  api_key TEXT,
  priority INTEGER DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
INSERT INTO provider_connections (id, provider, api_key, priority) VALUES
  ('conn_1', 'openai', 'enc:v1:test_token_1', 1),
  ('conn_2', 'anthropic', 'enc:v1:test_token_2', 2),
  ('conn_3', 'gemini', 'enc:v1:test_token_3', 3);
INSERT INTO settings (key, value) VALUES
  ('system.theme', 'dark'),
  ('system.quota_mode', 'standard');
SQL

echo "[TEST 1] Seeded initial database with 3 connections and 2 settings."

# 3. Start Litestream replication in background
litestream replicate -config "$CONFIG_PATH" &
REPLICATE_PID=$!
echo "[TEST 1] Litestream started with PID $REPLICATE_PID."

# Wait for initial replication sync
sleep 1

# 4. Perform live writes while Litestream is replicating
sqlite3 "$DB_PATH" <<'SQL'
INSERT INTO provider_connections (id, provider, api_key, priority) VALUES
  ('conn_4', 'groq', 'enc:v1:test_token_4', 4);
INSERT INTO settings (key, value) VALUES
  ('system.version', '3.8.54');
SQL
echo "[TEST 1] Performed live concurrent writes."

# Allow sync interval to capture writes
sleep 1

# 5. Gracefully terminate Litestream
echo "[TEST 1] Sending SIGTERM to Litestream PID $REPLICATE_PID..."
kill -TERM "$REPLICATE_PID"
wait "$REPLICATE_PID" 2>/dev/null || true
echo "[TEST 1] Litestream stopped cleanly."

# 6. Simulate container destruction (wipe local SQLite database and WAL files)
echo "[TEST 1] Wiping local database files to simulate fresh ephemeral container..."
rm -f "$TEST_ROOT/data/storage.sqlite"*
if [ -f "$DB_PATH" ]; then
  echo "[TEST 1] ERROR: Failed to delete local database." >&2
  exit 1
fi

# 7. Execute restore from replica
echo "[TEST 1] Executing litestream restore..."
litestream restore -config "$CONFIG_PATH" -if-db-not-exists -if-replica-exists "$DB_PATH"

if [ ! -f "$DB_PATH" ]; then
  echo "[TEST 1] ERROR: Restored database not found at $DB_PATH!" >&2
  exit 1
fi

# 8. Verify Data Parity
CONN_COUNT=$(sqlite3 "$DB_PATH" "SELECT count(*) FROM provider_connections;")
SETTINGS_COUNT=$(sqlite3 "$DB_PATH" "SELECT count(*) FROM settings;")
CANARY_VAL=$(sqlite3 "$DB_PATH" "SELECT api_key FROM provider_connections WHERE id='conn_4';")

echo "[TEST 1] Verification results:"
echo "         - Total connections restored: $CONN_COUNT (expected: 4)"
echo "         - Total settings restored:    $SETTINGS_COUNT (expected: 3)"
echo "         - Canary record (conn_4):     $CANARY_VAL"

if [ "$CONN_COUNT" != "4" ] || [ "$SETTINGS_COUNT" != "3" ] || [ "$CANARY_VAL" != "enc:v1:test_token_4" ]; then
  echo "[TEST 1] FAILED: Data parity check failed!" >&2
  exit 1
fi

# 9. Verify SQLite Integrity
INTEGRITY=$(sqlite3 "$DB_PATH" "PRAGMA integrity_check;")
QUICK_CHECK=$(sqlite3 "$DB_PATH" "PRAGMA quick_check;")

echo "         - PRAGMA integrity_check:    $INTEGRITY"
echo "         - PRAGMA quick_check:        $QUICK_CHECK"

if [ "$INTEGRITY" != "ok" ] || [ "$QUICK_CHECK" != "ok" ]; then
  echo "[TEST 1] FAILED: Database corruption detected after restore!" >&2
  exit 1
fi

echo "================================================================="
echo "[TEST 1] PASSED: Full recovery and integrity verified successfully."
echo "================================================================="
rm -rf "$TEST_ROOT"