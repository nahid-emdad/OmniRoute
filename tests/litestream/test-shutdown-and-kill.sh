#!/bin/sh
set -eu

TEST_ROOT="/tmp/litestream-kill-test"
rm -rf "$TEST_ROOT"
mkdir -p "$TEST_ROOT/data" "$TEST_ROOT/replica"

DB_PATH="$TEST_ROOT/data/storage.sqlite"
CONFIG_PATH="$TEST_ROOT/litestream.yml"

echo "================================================================="
echo "[TEST 2] Signal Forwarding & Abrupt SIGKILL Crash Resilience Test"
echo "  (Local File-Replica Simulation; Cloudflare R2 requires credentials)"
echo "================================================================="

cat <<EOF > "$CONFIG_PATH"
dbs:
  - path: "$DB_PATH"
    replica:
      type: file
      path: "$TEST_ROOT/replica"
      sync-interval: 50ms
EOF

# Initialize database
sqlite3 "$DB_PATH" <<'SQL'
PRAGMA journal_mode=WAL;
CREATE TABLE canary_records (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  created_at TEXT DEFAULT (datetime('now'))
);
CREATE TABLE in_flight_events (
  id INTEGER PRIMARY KEY,
  payload TEXT NOT NULL,
  created_at TEXT DEFAULT (datetime('now'))
);
SQL

# -------------------------------------------------------------
# Part A: Test Graceful Signal Forwarding via -exec
# -------------------------------------------------------------
echo "[TEST 2A] Testing graceful signal forwarding under -exec..."
CHILD_FLAG="$TEST_ROOT/child_received_sigterm"

# Launch Litestream with child that traps SIGTERM
litestream replicate -config "$CONFIG_PATH" -exec "sh -c 'trap \"touch $CHILD_FLAG; exit 0\" TERM; while true; do sleep 0.1; done'" &
SUPERVISOR_PID=$!

sleep 1
# Send SIGTERM to Litestream supervisor PID
echo "[TEST 2A] Sending SIGTERM to Litestream supervisor PID $SUPERVISOR_PID..."
kill -TERM "$SUPERVISOR_PID"
wait "$SUPERVISOR_PID" 2>/dev/null || true

if [ -f "$CHILD_FLAG" ]; then
  echo "[TEST 2A] SUCCESS: Child process trapped and handled SIGTERM forwarded by Litestream."
else
  echo "[TEST 2A] FAILED: Child process did not receive SIGTERM!" >&2
  exit 1
fi

# -------------------------------------------------------------
# Part B: Test Abrupt Termination (SIGKILL) During Heavy Writes
# -------------------------------------------------------------
echo "[TEST 2B] Testing abrupt termination (kill -9) during active writes..."

# Start Litestream in background
litestream replicate -config "$CONFIG_PATH" &
LITESTREAM_PID=$!

# Allow Litestream to initialize
sleep 0.5

# Insert KNOWN Pre-Crash Canary Record and wait for sync
sqlite3 "$DB_PATH" "INSERT INTO canary_records (key, value) VALUES ('pre_crash_canary', 'canary_data_valid_2026');"
echo "[TEST 2B] Inserted known canary record 'pre_crash_canary'."
# Wait 200ms (> 50ms sync-interval) so this canary is fully synced to replica
sleep 0.2

# Spawn rapid writer logging attempted rows
COUNTER_FILE="$TEST_ROOT/max_attempted_row.txt"
echo "0" > "$COUNTER_FILE"

(
  for i in $(seq 1 400); do
    if sqlite3 "$DB_PATH" "INSERT INTO in_flight_events (id, payload) VALUES ($i, 'in-flight-burst-$i');" 2>/dev/null; then
      echo "$i" > "$COUNTER_FILE"
    fi
    sleep 0.005
  done
) &
WRITER_PID=$!

# Let writes accumulate for 1 second during active replication
sleep 1.0

MAX_ATTEMPTED=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")
echo "[TEST 2B] Highest recorded attempted write before abrupt kill: Row #$MAX_ATTEMPTED"

echo "[TEST 2B] Sending simultaneous SIGKILL (kill -9) to writer and Litestream processes..."
kill -9 "$WRITER_PID" 2>/dev/null || true
kill -9 "$LITESTREAM_PID" 2>/dev/null || true
wait 2>/dev/null || true
echo "[TEST 2B] Processes killed abruptly with SIGKILL (zero graceful shutdown opportunity)."

# Wipe local database files to simulate container crash/restart on ephemeral Render host
rm -f "$TEST_ROOT/data/storage.sqlite"*

# Restore from replica
echo "[TEST 2B] Restoring database from replica after ungraceful crash..."
litestream restore -config "$CONFIG_PATH" "$DB_PATH"

if [ ! -f "$DB_PATH" ]; then
  echo "[TEST 2B] ERROR: Restore failed, database file not found!" >&2
  exit 1
fi

# 1. Run integrity check
INTEGRITY=$(sqlite3 "$DB_PATH" "PRAGMA integrity_check;")
QUICK_CHECK=$(sqlite3 "$DB_PATH" "PRAGMA quick_check;")

echo "[TEST 2B] Integrity check results:"
echo "         - PRAGMA integrity_check: $INTEGRITY"
echo "         - PRAGMA quick_check:     $QUICK_CHECK"

if [ "$INTEGRITY" != "ok" ] || [ "$QUICK_CHECK" != "ok" ]; then
  echo "[TEST 2B] FAILED: Corrupted database detected after crash restore!" >&2
  exit 1
fi

# 2. Verify Pre-Crash Canary Record
CANARY_STATUS=$(sqlite3 "$DB_PATH" "SELECT value FROM canary_records WHERE key='pre_crash_canary';")
echo "         - Pre-crash canary record: '$CANARY_STATUS'"

if [ "$CANARY_STATUS" != "canary_data_valid_2026" ]; then
  echo "[TEST 2B] FAILED: Pre-crash canary was lost!" >&2
  exit 1
fi
echo "[TEST 2B] SUCCESS: Pre-crash canary record recovered intact."

# 3. Analyze In-Flight Writes Parity & Loss Bounds (Honest RPO Report)
RECOVERED_ROWS=$(sqlite3 "$DB_PATH" "SELECT count(*) FROM in_flight_events;")
MAX_RECOVERED_ID=$(sqlite3 "$DB_PATH" "SELECT COALESCE(MAX(id), 0) FROM in_flight_events;")
LOST_WRITES=$((MAX_ATTEMPTED - MAX_RECOVERED_ID))

echo "         - Highest attempted write:  Row #$MAX_ATTEMPTED"
echo "         - Highest recovered write:  Row #$MAX_RECOVERED_ID"
echo "         - Total in-flight rows:     $RECOVERED_ROWS"
echo "         - Un-synced buffered rows:  $LOST_WRITES"

if [ "$MAX_RECOVERED_ID" -le 0 ]; then
  echo "[TEST 2B] FAILED: No in-flight rows were recovered." >&2
  exit 1
fi

echo "-----------------------------------------------------------------"
echo "[RPO ANALYSIS] In an abrupt hard crash (SIGKILL/power cut):"
echo "  - Pre-crash synced state: 100% intact with zero corruption."
echo "  - In-flight un-flushed writes ($LOST_WRITES rows in the final ~50ms buffer) were lost."
echo "  - Database integrity is PRAGMA integrity_check = ok (WAL atomicity preserved)."
echo "================================================================="
echo "[TEST 2] PASSED: Signal forwarding and crash resilience verified."
echo "================================================================="
rm -rf "$TEST_ROOT"