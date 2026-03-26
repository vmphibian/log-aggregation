#!/usr/bin/env bash
# export-logs.sh — Export all logs from a Loki instance to NDJSON.
#
# Queries Loki's query_range API and writes results as newline-delimited JSON.
# The output file can be reimported via the Loki push API or queried offline
# with logcli. See README.md for details.
#
# Usage:
#   export LOKI_INSTANCE_NAME=lab-42
#   bash scripts/export-logs.sh
#
# All communication uses plain HTTP to localhost — Traefik is not involved.
# Do not attempt HTTPS here; TLS is terminated at Traefik, not by Loki.
#
# Environment variables:
#   LOKI_INSTANCE_NAME  (required) — instance to export from
#   LOKI_HTTP_PORT      (default: 3100) — Loki HTTP port
#   LOKI_RETENTION_PERIOD (default: 168h) — used to calculate export start time
#   LOKI_EXPORT_START   (optional) — override start time (nanosecond epoch integer)
#   LOKI_EXPORT_END     (optional) — override end time (nanosecond epoch integer)
#   LOKI_EXPORT_LIMIT   (default: 5000) — max entries per query_range request

set -euo pipefail

error() { echo "ERROR: $*" >&2; exit 1; }

# ── Defaults ──────────────────────────────────────────────────────────────────
LOKI_HTTP_PORT="${LOKI_HTTP_PORT:-3100}"
LOKI_RETENTION_PERIOD="${LOKI_RETENTION_PERIOD:-168h}"
LOKI_EXPORT_LIMIT="${LOKI_EXPORT_LIMIT:-5000}"
BASE_URL="http://localhost:${LOKI_HTTP_PORT}"

# ── Validation ────────────────────────────────────────────────────────────────
[[ -n "${LOKI_INSTANCE_NAME:-}" ]] || error "LOKI_INSTANCE_NAME is required."
[[ "$(id -u)" -eq 0 ]] && error "This script must not run as root."

# ── Time range ────────────────────────────────────────────────────────────────
# Timestamps are NANOSECOND epoch integers — required by the Loki query_range API.
# A common integration error is supplying millisecond or second epoch values.
NOW_NS=$(date +%s%N 2>/dev/null || python3 -c "import time; print(int(time.time() * 1e9))")

if [[ -n "${LOKI_EXPORT_END:-}" ]]; then
  END_NS="${LOKI_EXPORT_END}"
else
  END_NS="${NOW_NS}"
fi

if [[ -n "${LOKI_EXPORT_START:-}" ]]; then
  START_NS="${LOKI_EXPORT_START}"
else
  # Parse retention period (Golang duration: h, m, s suffixes)
  HOURS=168  # fallback
  if [[ "${LOKI_RETENTION_PERIOD}" =~ ^([0-9]+)h$ ]]; then
    HOURS="${BASH_REMATCH[1]}"
  elif [[ "${LOKI_RETENTION_PERIOD}" =~ ^([0-9]+)m$ ]]; then
    HOURS=$(( BASH_REMATCH[1] / 60 ))
  fi
  START_NS=$(( END_NS - HOURS * 3600 * 1000000000 ))
fi

OUTPUT_FILE="./loki-export-${LOKI_INSTANCE_NAME}-$(date +%Y%m%dT%H%M%S).ndjson"

echo "==> Exporting logs from Loki instance: ${LOKI_INSTANCE_NAME}"
echo "    Base URL  : ${BASE_URL}  (plain HTTP — bypasses Traefik)"
echo "    Start     : ${START_NS} ns epoch"
echo "    End       : ${END_NS} ns epoch"
echo "    Output    : ${OUTPUT_FILE}"

# ── Discover all label values for streaming ───────────────────────────────────
# Use {instance="<name>"} as the primary selector if the label exists;
# fall back to {job=~".+"} to catch all streams.
LABEL_CHECK=$(curl -sf "${BASE_URL}/loki/api/v1/label/instance/values" \
  --get --data-urlencode "start=${START_NS}" --data-urlencode "end=${END_NS}" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('found' if '${LOKI_INSTANCE_NAME}' in d.get('data',[]) else 'not_found')" 2>/dev/null || echo "error")

if [[ "${LABEL_CHECK}" == "found" ]]; then
  SELECTOR="{instance=\"${LOKI_INSTANCE_NAME}\"}"
else
  SELECTOR='{job=~".+"}'
  echo "    Note: instance label not found — exporting all streams with selector: ${SELECTOR}"
fi

# ── Paginated export ──────────────────────────────────────────────────────────
ENTRY_COUNT=0
CURRENT_START="${START_NS}"

true > "${OUTPUT_FILE}"  # create/truncate output file

while true; do
  RESPONSE=$(curl -sf "${BASE_URL}/loki/api/v1/query_range" \
    --get \
    --data-urlencode "query=${SELECTOR}" \
    --data-urlencode "start=${CURRENT_START}" \
    --data-urlencode "end=${END_NS}" \
    --data-urlencode "limit=${LOKI_EXPORT_LIMIT}" \
    --data-urlencode "direction=forward")

  # Extract entries and write as NDJSON
  BATCH_COUNT=$(echo "${RESPONSE}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
results = data.get('data', {}).get('result', [])
count = 0
for stream in results:
    labels = stream.get('stream', {})
    for ts, line in stream.get('values', []):
        print(json.dumps({'labels': labels, 'timestamp_ns': ts, 'line': line}))
        count += 1
print(count, file=sys.stderr)
" 2>/tmp/loki_export_count >> "${OUTPUT_FILE}" || true)

  BATCH_COUNT=$(cat /tmp/loki_export_count 2>/dev/null || echo 0)
  ENTRY_COUNT=$((ENTRY_COUNT + BATCH_COUNT))

  # If we got fewer entries than the limit, we've reached the end
  if [[ "${BATCH_COUNT}" -lt "${LOKI_EXPORT_LIMIT}" ]]; then
    break
  fi

  # Advance start to last entry's timestamp + 1ns to avoid duplicates
  LAST_TS=$(tail -1 "${OUTPUT_FILE}" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('timestamp_ns','0'))" 2>/dev/null || echo "0")
  if [[ "${LAST_TS}" == "0" || "${LAST_TS}" -le "${CURRENT_START}" ]]; then
    break
  fi
  CURRENT_START=$((LAST_TS + 1))
done

echo ""
if [[ "${ENTRY_COUNT}" -gt 0 ]]; then
  echo "✓ Exported ${ENTRY_COUNT} log entries to ${OUTPUT_FILE}"
  echo "  Reimport : curl -X POST http://localhost:${LOKI_HTTP_PORT}/loki/api/v1/push -H 'Content-Type: application/json' --data-binary @${OUTPUT_FILE}"
  echo "  Offline  : logcli --addr=http://localhost:${LOKI_HTTP_PORT} query '{job=~\".*\"}'"
else
  echo "  No log entries found in the specified time range."
  echo "  The output file is empty: ${OUTPUT_FILE}"
fi
