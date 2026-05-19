#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TOTAL_MB="${TOTAL_MB:-1024}"
HOT_MB="${HOT_MB:-64}"
DURATION_SEC="${DURATION_SEC:-120}"
SAMPLE_INTERVAL_SEC="${SAMPLE_INTERVAL_SEC:-5}"
SHOW_SCAN="${SHOW_SCAN:-1}"
SCAN_TOP="${SCAN_TOP:-5}"
SCAN_PRIME_SEC="${SCAN_PRIME_SEC:-5}"
ETMEM_LOOP="${ETMEM_LOOP:-3}"
ETMEM_INTERVAL="${ETMEM_INTERVAL:-5}"
ETMEM_SLEEP="${ETMEM_SLEEP:-10}"
ETMEM_T="${ETMEM_T:-1}"
ETMEM_MAX_THREADS="${ETMEM_MAX_THREADS:-1}"
ETMEM_SWAP_THRESHOLD="${ETMEM_SWAP_THRESHOLD:-0g}"
REFAULT_AFTER="${REFAULT_AFTER:-0}"

PROJECT_NAME="demo_slide"
ENGINE_NAME="slide"
TASK_NAME="coldmem_demo"
SOCKET_NAME="etmem_demo_$$"

WORKDIR="$(mktemp -d /tmp/etmem-swap-demo.XXXXXX)"
CONFIG_DIR="${CONFIG_DIR:-$WORKDIR}"
READY_FILE="$WORKDIR/ready"
PID_FILE="$WORKDIR/target.pid"
CONFIG_FILE="$CONFIG_DIR/etmem-demo-slide-$$.conf"
METRICS_FILE="$WORKDIR/metrics.csv"
SCAN_DIR="$WORKDIR/scan"
SCAN_LOG="$WORKDIR/scan.log"
TARGET_LOG="$WORKDIR/coldmem_target.log"
ETMEMD_LOG="$WORKDIR/etmemd.log"
ETMEM_LOG="$WORKDIR/etmem.log"

TARGET_PID=""
ETMEMD_PID=""

die() {
  echo "ERROR: $*" >&2
  echo "workdir: $WORKDIR" >&2
  exit 1
}

cleanup() {
  set +e
  if [[ -n "$ETMEMD_PID" ]]; then
    etmem project stop -n "$PROJECT_NAME" -s "$SOCKET_NAME" >>"$ETMEM_LOG" 2>&1
    etmem obj del -f "$CONFIG_FILE" -s "$SOCKET_NAME" >>"$ETMEM_LOG" 2>&1
    kill "$ETMEMD_PID" >>"$ETMEM_LOG" 2>&1
    wait "$ETMEMD_PID" >>"$ETMEM_LOG" 2>&1
  fi
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
  for cmd in python3 etmem etmemd awk sed date mktemp; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    die "missing command(s): ${missing[*]}"
  fi
}

try_load_modules() {
  modprobe etmem_scan >/dev/null 2>&1 || true
  modprobe etmem_swap >/dev/null 2>&1 || true
}

require_swap() {
  local swap_total_kb
  swap_total_kb="$(awk '$1 == "SwapTotal:" {print $2}' /proc/meminfo)"
  if [[ -z "$swap_total_kb" || "$swap_total_kb" == "0" ]]; then
    die "no swap is enabled. Enable zram/NVMe swap first, then rerun."
  fi
}

status_value_kb() {
  local pid="$1"
  local key="$2"
  awk -v key="$key:" '$1 == key {print $2 + 0}' "/proc/$pid/status"
}

meminfo_value_kb() {
  local key="$1"
  awk -v key="$key:" '$1 == key {print $2 + 0}' /proc/meminfo
}

major_faults() {
  local pid="$1"
  sed -E 's/^[0-9]+ \(.+\) //' "/proc/$pid/stat" | awk '{print $10 + 0}'
}

sample_once() {
  local phase="$1"
  local ts rss_kb swap_kb memavail_kb swapfree_kb majflt
  ts="$(date +%s)"

  if [[ "$SHOW_SCAN" == "1" ]]; then
    mkdir -p "$SCAN_DIR"
    local scan_summary_file="$SCAN_DIR/${phase}-${ts}-summary.csv"
    local scan_vma_file="$SCAN_DIR/${phase}-${ts}-vmas.csv"
    echo
    echo "scan snapshot before '$phase' sample:"
    python3 "$SCRIPT_DIR/../etmem-scan-demo/scan_idle_pages.py" \
      --pid "$TARGET_PID" \
      --samples 1 \
      --top "$SCAN_TOP" \
      --vma-filter anon \
      --min-vma-kb 0 \
      --csv "$scan_summary_file" \
      --vma-csv "$scan_vma_file" \
      2>&1 | tee -a "$SCAN_LOG"
    echo "  scan csv: $scan_summary_file"
    echo "  vma csv : $scan_vma_file"
  fi

  rss_kb="$(status_value_kb "$TARGET_PID" VmRSS)"
  swap_kb="$(status_value_kb "$TARGET_PID" VmSwap)"
  memavail_kb="$(meminfo_value_kb MemAvailable)"
  swapfree_kb="$(meminfo_value_kb SwapFree)"
  majflt="$(major_faults "$TARGET_PID")"
  printf "%s,%s,%s,%s,%s,%s,%s\n" \
    "$ts" "$phase" "$rss_kb" "$swap_kb" "$memavail_kb" "$swapfree_kb" "$majflt" >>"$METRICS_FILE"
  printf "%-10s rss=%7d MB  vmswap=%7d MB  memavail=%7d MB  swapfree=%7d MB  majflt=%s\n" \
    "$phase" "$((rss_kb / 1024))" "$((swap_kb / 1024))" "$((memavail_kb / 1024))" \
    "$((swapfree_kb / 1024))" "$majflt"
}

prime_scan_window() {
  if [[ "$SHOW_SCAN" != "1" ]]; then
    return
  fi

  echo
  echo "priming scan window: clear accessed bits, then wait ${SCAN_PRIME_SEC}s"
  python3 "$SCRIPT_DIR/../etmem-scan-demo/scan_idle_pages.py" \
    --pid "$TARGET_PID" \
    --samples 1 \
    --top 0 \
    --vma-filter anon \
    --min-vma-kb 0 \
    >>"$SCAN_LOG" 2>&1 || true
  sleep "$SCAN_PRIME_SEC"
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

write_config() {
  mkdir -p "$CONFIG_DIR"
  cat >"$CONFIG_FILE" <<EOF
[project]
name=$PROJECT_NAME
loop=$ETMEM_LOOP
interval=$ETMEM_INTERVAL
sleep=$ETMEM_SLEEP
sysmem_threshold=100
swapcache_high_wmark=5
swapcache_low_wmark=3

[engine]
name=$ENGINE_NAME
project=$PROJECT_NAME

[task]
project=$PROJECT_NAME
engine=$ENGINE_NAME
name=$TASK_NAME
type=pid
value=$TARGET_PID
T=$ETMEM_T
max_threads=$ETMEM_MAX_THREADS
swap_threshold=$ETMEM_SWAP_THRESHOLD
swap_flag=no
EOF
  chmod 600 "$CONFIG_FILE"
}

show_config() {
  echo
  echo "generated etmem config: $CONFIG_FILE"
  sed 's/^/  /' "$CONFIG_FILE"
  echo
}

start_target() {
  python3 "$SCRIPT_DIR/coldmem_target.py" \
    --total-mb "$TOTAL_MB" \
    --hot-mb "$HOT_MB" \
    --ready-file "$READY_FILE" \
    --pid-file "$PID_FILE" \
    >"$TARGET_LOG" 2>&1 &
  TARGET_PID="$!"
  wait_for_ready
  [[ -e "/proc/$TARGET_PID/idle_pages" ]] || die "/proc/$TARGET_PID/idle_pages is missing; etmem_scan is unavailable"
  [[ -e "/proc/$TARGET_PID/swap_pages" ]] || die "/proc/$TARGET_PID/swap_pages is missing; etmem_swap is unavailable"
}

start_etmem() {
  echo "starting etmem daemon: etmemd -l 0 -s $SOCKET_NAME"
  etmemd -l 0 -s "$SOCKET_NAME" >"$ETMEMD_LOG" 2>&1 &
  ETMEMD_PID="$!"
  sleep 2
  kill -0 "$ETMEMD_PID" 2>/dev/null || die "etmemd failed to start; see $ETMEMD_LOG"

  echo "loading etmem config: etmem obj add -f $CONFIG_FILE -s $SOCKET_NAME"
  etmem obj add -f "$CONFIG_FILE" -s "$SOCKET_NAME" >>"$ETMEM_LOG" 2>&1 || die "etmem obj add failed; see $ETMEM_LOG"

  echo "starting etmem project: etmem project start -n $PROJECT_NAME -s $SOCKET_NAME"
  etmem project start -n "$PROJECT_NAME" -s "$SOCKET_NAME" >>"$ETMEM_LOG" 2>&1 || die "etmem project start failed; see $ETMEM_LOG"
}

summarize() {
  local first last before_rss after_rss before_swap after_swap before_mem after_mem
  first="$(awk -F, 'NR == 2 {print; exit}' "$METRICS_FILE")"
  last="$(awk -F, 'END {print}' "$METRICS_FILE")"
  before_rss="$(awk -F, 'NR == 2 {print $3; exit}' "$METRICS_FILE")"
  after_rss="$(awk -F, 'END {print $3}' "$METRICS_FILE")"
  before_swap="$(awk -F, 'NR == 2 {print $4; exit}' "$METRICS_FILE")"
  after_swap="$(awk -F, 'END {print $4}' "$METRICS_FILE")"
  before_mem="$(awk -F, 'NR == 2 {print $5; exit}' "$METRICS_FILE")"
  after_mem="$(awk -F, 'END {print $5}' "$METRICS_FILE")"

  local rss_drop_mb swap_inc_mb memavail_inc_mb
  rss_drop_mb="$(((before_rss - after_rss) / 1024))"
  swap_inc_mb="$(((after_swap - before_swap) / 1024))"
  memavail_inc_mb="$(((after_mem - before_mem) / 1024))"

  echo
  echo "summary:"
  echo "  first sample: $first"
  echo "  last sample : $last"
  echo "  target RSS drop     : ${rss_drop_mb} MB"
  echo "  target VmSwap growth: ${swap_inc_mb} MB"
  echo "  MemAvailable change : ${memavail_inc_mb} MB"
  echo "  metrics             : $METRICS_FILE"
  echo "  scan csv directory  : $SCAN_DIR"
  echo "  scan log            : $SCAN_LOG"
  echo "  etmem config         : $CONFIG_FILE"
  echo "  etmem log            : $ETMEM_LOG"
  echo "  etmemd log           : $ETMEMD_LOG"
  echo "  target log           : $TARGET_LOG"

  if (( rss_drop_mb >= HOT_MB && swap_inc_mb >= HOT_MB )); then
    echo "PASS: etmem swapped cold anonymous pages and lowered target resident memory."
  else
    echo "FAIL: RSS/Swap movement was too small. Try larger TOTAL_MB, longer DURATION_SEC, or check etmem logs."
    return 1
  fi
}

main() {
  require_root
  require_commands
  require_swap
  try_load_modules

  echo "workdir: $WORKDIR"
  echo "config: TOTAL_MB=$TOTAL_MB HOT_MB=$HOT_MB DURATION_SEC=$DURATION_SEC ETMEM_T=$ETMEM_T SHOW_SCAN=$SHOW_SCAN"
  echo "timestamp,phase,rss_kb,vmswap_kb,memavailable_kb,swapfree_kb,major_faults" >"$METRICS_FILE"

  start_target
  write_config
  show_config
  prime_scan_window
  sample_once "before"

  start_etmem
  local elapsed=0
  while (( elapsed < DURATION_SEC )); do
    sleep "$SAMPLE_INTERVAL_SEC"
    elapsed=$((elapsed + SAMPLE_INTERVAL_SEC))
    sample_once "running"
  done

  etmem project stop -n "$PROJECT_NAME" -s "$SOCKET_NAME" >>"$ETMEM_LOG" 2>&1 || true
  sample_once "after"

  if [[ "$REFAULT_AFTER" == "1" ]]; then
    kill -USR1 "$TARGET_PID"
    sleep 20
    sample_once "refault"
  fi

  summarize
}

main "$@"
