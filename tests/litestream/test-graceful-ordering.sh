#!/bin/sh
set -eu

TEST_ROOT="/tmp/litestream-graceful-test"
rm -rf "$TEST_ROOT"
mkdir -p "$TEST_ROOT/data" "$TEST_ROOT/replica"

DB_PATH="$TEST_ROOT/data/storage.sqlite"
CONFIG_PATH="$TEST_ROOT/litestream.yml"

echo "================================================================="
echo "[TEST 3] Graceful Shutdown Ordering & Verification Test"
echo "  (Local File-Replica Simulation; sync-interval: 1m)"
echo "================================================================="

# 1. Litestream v0.5 replica configuration with cost-conscious 1m interval
cat <<EOF > "$CONFIG_PATH"
dbs:
  - path: "$DB_PATH"
    replica:
      type: file
      path: "$TEST_ROOT/replica"
      sync-interval: 1m
EOF

# 2. Emulate OmniRoute child process with SQLite WAL and graceful SIGTERM trap
cat << 'EOF' > "$TEST_ROOT/omniroute_mock.sh"
#!/bin/sh
set -e

DB="$1"

# Initialize SQLite database in WAL mode
sqlite3 "$DB" "PRAGMA journal_mode=WAL;"
sqlite3 "$DB" "CREATE TABLE items (id TEXT PRIMARY KEY, value TEXT, updated_at TEXT);"
sqlite3 "$DB" "INSERT INTO items VALUES ('initial_seed', 'val_0', datetime('now'));"

echo "[OmniRoute Mock] Initialized database in WAL mode."

# Trap SIGTERM to emulate OmniRoute's closeDbInstance() wal_checkpoint(TRUNCATE)
trap '
echo "[OmniRoute Mock] Received SIGTERM signal. Executing shutdown handler..."
echo "[OmniRoute Mock] Writing final canary right before checkpoint..."
sqlite3 "$DB" "INSERT INTO items VALUES ('\''graceful_shutdown_canary'\'', '\''zero_data_loss_verified'\'', datetime('\''now'\''));"
echo "[OmniRoute Mock] Running PRAGMA wal_checkpoint(TRUNCATE)..."
sqlite3 "$DB" "PRAGMA wal_checkpoint(TRUNCATE);"
echo "[OmniRoute Mock] Checkpoint complete. Database closed. Exiting 0."
exit 0
' TERM

echo "[OmniRoute Mock] Ready and listening for SIGTERM..."
while true; do
  sleep 0.1
done
EOF
chmod +x "$TEST_ROOT/omniroute_mock.sh"

# 3. Start Litestream supervisor executing OmniRoute mock
echo "[TEST 3] Starting Litestream supervisor with OmniRoute mock..."
litestream replicate -config "$CONFIG_PATH" -exec "$TEST_ROOT/omniroute_mock.sh $DB_PATH" &
SUPERVISOR_PID=$!

# Wait 2 seconds (far less than 1m sync-interval)
sleep 2

# 4. Trigger Graceful Shutdown via SIGTERM to Litestream supervisor
SHUTDOWN_START=$(date +%s)
echo "[TEST 3] Sending SIGTERM to Litestream supervisor PID $SUPERVISOR_PID..."
kill -TERM "$SUPERVISOR_PID"
wait "$SUPERVISOR_PID" 2>/dev/null || true
SHUTDOWN_END=$(date +%s)
SHUTDOWN_DURATION=$((SHUTDOWN_END - SHUTDOWN_START))
echo "[TEST 3] Litestream supervisor exited in ${SHUTDOWN_DURATION}s (immediate flush, not waiting 1m)."

# 5. Simulate container destruction and restore from replica
echo "[TEST 3] Wiping local database files to simulate cold start..."
rm -f "$TEST_ROOT/data/storage.sqlite"*

echo "[TEST 3] Executing litestream restore..."
litestream restore -config "$CONFIG_PATH" "$DB_PATH"

# 6. Verify restored data
INTEGRITY=$(sqlite3 "$DB_PATH" "PRAGMA integrity_check;")
CANARY_VAL=$(sqlite3 "$DB_PATH" "SELECT value FROM items WHERE id='graceful_shutdown_canary';")
ROW_COUNT=$(sqlite3 "$DB_PATH" "SELECT count(*) FROM items;")

echo "[TEST 3] Verification results:"
echo "         - PRAGMA integrity_check:        $INTEGRITY"
echo "         - Total items restored:          $ROW_COUNT"
echo "         - Graceful shutdown canary:      '$CANARY_VAL'"
echo "         - Shutdown flush elapsed:        ${SHUTDOWN_DURATION}s"

if [ "$INTEGRITY" != "ok" ]; then
  echo "[TEST 3] FAILED: Integrity check failed!" >&2
  exit 1
fi

if [ "$CANARY_VAL" != "zero_data_loss_verified" ]; then
  echo "[TEST 3] FAILED: Graceful shutdown canary not found in restored database!" >&2
  exit 1
fi

echo "================================================================="
echo "[TEST 3] PASSED: Graceful shutdown ordering and zero-loss parity verified with 1m sync."
echo "================================================================="
rm -rf "$TEST_ROOT"
