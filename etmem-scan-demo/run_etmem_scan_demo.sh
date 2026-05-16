#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

TOTAL_MB="${TOTAL_MB:-1024}"
HOT_MB="${HOT_MB:-64}"
SCAN_INTERVAL_SEC="${SCAN_INTERVAL_SEC:-10}"
SCAN_SAMPLES="${SCAN_SAMPLES:-4}"
VMA_FILTER="${VMA_FILTER:-anon}"
MIN_VMA_KB="${MIN_VMA_KB:-1024}"

WORKDIR="$(mktemp -d /tmp/etmem-scan-demo.XXXXXX)"
READY_FILE="$WORKDIR/ready"
PID_FILE="$WORKDIR/target.pid"
TARGET_LOG="$WORKDIR/coldmem_target.log"
SUMMARY_CSV="$WORKDIR/scan-summary.csv"
VMA_CSV="$WORKDIR/scan-vmas.csv"

TARGET_PID=""

die() {
  echo "ERROR: $*" >&2
  echo "workdir: $WORKDIR" >&2
  exit 1
}

cleanup() {
  set +e
  if [[ -n "$TARGET_PID" ]]; then
    kill "$TARGET_PID" >>"$TARGET_LOG" 2>&1
    wait "$TARGET_PID" >>"$TARGET_LOG" 2>&1
  fi
}
trap cleanup EXIT

require_root() {
  if [[ "$(id -u)" != "0" ]]; then
    die "run as root, for example: sudo $0"
  fi
}

require_commands() {
  local missing=()
  for cmd in python3 awk date mktemp; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    die "missing command(s): ${missing[*]}"
  fi
}

try_load_module() {
  modprobe etmem_scan >/dev/null 2>&1 || true
}

wait_for_ready() {
  local i
  for i in {1..120}; do
    if [[ -f "$READY_FILE" && -s "$PID_FILE" ]]; then
      TARGET_PID="$(cat "$PID_FILE")"
      kill -0 "$TARGET_PID" 2>/dev/null || die "target pid $TARGET_PID is not alive"
      return
    fi
    sleep 1
  done
  die "target did not become ready; see $TARGET_LOG"
}

start_target() {
  python3 "$ROOT_DIR/etmem-swap-demo/coldmem_target.py" \
    --total-mb "$TOTAL_MB" \
    --hot-mb "$HOT_MB" \
    --ready-file "$READY_FILE" \
    --pid-file "$PID_FILE" \
    >"$TARGET_LOG" 2>&1 &
  TARGET_PID="$!"
  wait_for_ready
  [[ -e "/proc/$TARGET_PID/idle_pages" ]] || die "/proc/$TARGET_PID/idle_pages is missing; etmem_scan is unavailable"
}

main() {
  require_root
  require_commands
  try_load_module

  echo "workdir: $WORKDIR"
  echo "config: TOTAL_MB=$TOTAL_MB HOT_MB=$HOT_MB SCAN_INTERVAL_SEC=$SCAN_INTERVAL_SEC SCAN_SAMPLES=$SCAN_SAMPLES"

  start_target

  python3 "$SCRIPT_DIR/scan_idle_pages.py" \
    --pid "$TARGET_PID" \
    --warmup \
    --interval "$SCAN_INTERVAL_SEC" \
    --samples "$SCAN_SAMPLES" \
    --vma-filter "$VMA_FILTER" \
    --min-vma-kb "$MIN_VMA_KB" \
    --csv "$SUMMARY_CSV" \
    --vma-csv "$VMA_CSV"

  echo
  echo "summary csv : $SUMMARY_CSV"
  echo "per-vma csv : $VMA_CSV"
  echo "target log  : $TARGET_LOG"
}

main "$@"
