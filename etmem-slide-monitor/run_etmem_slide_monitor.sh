#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PID=""
LOOP=3
INTERVAL=30
T=2
SLEEP_SEC=10
DURATION_SEC=0
SAMPLE_INTERVAL_SEC=30
SHOW_HEAT=1
HEAT_VMA_FILTER="slide-anon"
HEAT_MIN_VMA_KB=0
HEAT_TOP=5
CONFIG_DIR="/etc/etmem"
PROJECT_NAME=""
TASK_NAME=""
SOCKET_NAME=""
SYSMEM_THRESHOLD=100
SWAP_THRESHOLD="999999g"
SWAP_FLAG="no"
MAX_THREADS=1

TARGET_CMD=()
TARGET_PID=""
TARGET_STARTED_BY_SCRIPT=0
WORKDIR="$(mktemp -d /tmp/etmem-slide-monitor.XXXXXX)"
CONFIG_FILE=""
METRICS_FILE="$WORKDIR/metrics.csv"
HEAT_DIR="$WORKDIR/heat"
HEAT_LOG="$WORKDIR/heat.log"
ETMEMD_LOG="$WORKDIR/etmemd.log"
ETMEM_LOG="$WORKDIR/etmem.log"
TARGET_LOG="$WORKDIR/target.log"
ETMEMD_PID=""

usage() {
  cat <<'EOF'
Usage:
  sudo ./run_etmem_slide_monitor.sh --pid <PID> [options]
  sudo ./run_etmem_slide_monitor.sh [options] -- <command> [args...]

Options:
  --pid PID                 Attach to an existing process.
  --loop N                  etmem project loop, default 3.
  --interval SEC            etmem scan-job timer interval, default 30.
  --t N                     etmem slide cold threshold T, default 2.
  --sleep SEC               etmem sleep after each inner scan round, default 10.
  --duration SEC            Stop after SEC seconds. 0 means until target exits or Ctrl+C.
  --sample-interval SEC     Metrics print interval, default 30.
  --show-heat 0|1           Print hot/cold diagnostic snapshots, default 1.
  --heat-vma-filter MODE    slide-anon, anon, rw-private, or all. Default slide-anon.
  --heat-min-vma-kb KB      Skip smaller VMAs for heat snapshots, default 0.
  --heat-top N              Print top cold VMAs in heat snapshots, default 5.
  --config-dir DIR          Config output dir, default /etc/etmem.
  --project-name NAME       etmem project name. Default slide_monitor_<pid>.
  --task-name NAME          etmem task name. Default target_<pid>.
  --socket NAME             etmemd socket name. Default etmem_slide_<pid>.
  --sysmem-threshold N      slide sysmem_threshold, default 100.
  --swap-threshold VALUE    slide swap_threshold, default 999999g for monitor-first runs.
  --swap-flag yes|no        slide swap_flag, default no.
  --max-threads N           slide task max_threads, default 1.

Examples:
  sudo ./run_etmem_slide_monitor.sh --pid 12345 --loop 3 --sleep 10 --interval 30 --t 2

  sudo ./run_etmem_slide_monitor.sh --loop 3 --sleep 10 --interval 30 --t 2 -- \
    /path/to/your_app --arg

Note:
  slide itself does not expose a hot/cold report command. SHOW_HEAT=1 uses
  etmem_scan (/proc/<pid>/idle_pages) to print diagnostic hot/cold ratios.
  Disable it with --show-heat 0 for cleaner slide-only swap measurements.
EOF
}

die() {
  echo "ERROR: $*" >&2
  echo "workdir: $WORKDIR" >&2
  exit 1
}

parse_args() {
  while (($#)); do
    case "$1" in
      --pid) PID="${2:-}"; shift 2 ;;
      --loop) LOOP="${2:-}"; shift 2 ;;
      --interval) INTERVAL="${2:-}"; shift 2 ;;
      --t) T="${2:-}"; shift 2 ;;
      --sleep) SLEEP_SEC="${2:-}"; shift 2 ;;
      --duration) DURATION_SEC="${2:-}"; shift 2 ;;
      --sample-interval) SAMPLE_INTERVAL_SEC="${2:-}"; shift 2 ;;
      --show-heat) SHOW_HEAT="${2:-}"; shift 2 ;;
      --heat-vma-filter) HEAT_VMA_FILTER="${2:-}"; shift 2 ;;
      --heat-min-vma-kb) HEAT_MIN_VMA_KB="${2:-}"; shift 2 ;;
      --heat-top) HEAT_TOP="${2:-}"; shift 2 ;;
      --config-dir) CONFIG_DIR="${2:-}"; shift 2 ;;
      --project-name) PROJECT_NAME="${2:-}"; shift 2 ;;
      --task-name) TASK_NAME="${2:-}"; shift 2 ;;
      --socket) SOCKET_NAME="${2:-}"; shift 2 ;;
      --sysmem-threshold) SYSMEM_THRESHOLD="${2:-}"; shift 2 ;;
      --swap-threshold) SWAP_THRESHOLD="${2:-}"; shift 2 ;;
      --swap-flag) SWAP_FLAG="${2:-}"; shift 2 ;;
      --max-threads) MAX_THREADS="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      --) shift; TARGET_CMD=("$@"); break ;;
      *) die "unknown argument: $1" ;;
    esac
  done
}

require_root() {
  [[ "$(id -u)" == "0" ]] || die "run as root"
}

require_commands() {
  local missing=()
  for cmd in python3 etmem etmemd awk sed date mktemp tee; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  ((${#missing[@]} == 0)) || die "missing command(s): ${missing[*]}"
}

require_numbers() {
  [[ "$LOOP" =~ ^[0-9]+$ && "$LOOP" -ge 1 ]] || die "--loop must be >= 1"
  [[ "$INTERVAL" =~ ^[0-9]+$ && "$INTERVAL" -ge 1 ]] || die "--interval must be >= 1"
  [[ "$T" =~ ^[0-9]+$ ]] || die "--t must be >= 0"
  [[ "$T" -le "$((LOOP * 3))" ]] || die "--t must be <= --loop * 3"
  [[ "$SLEEP_SEC" =~ ^[0-9]+$ && "$SLEEP_SEC" -ge 1 ]] || die "--sleep must be >= 1"
  [[ "$DURATION_SEC" =~ ^[0-9]+$ ]] || die "--duration must be >= 0"
  [[ "$SAMPLE_INTERVAL_SEC" =~ ^[0-9]+$ && "$SAMPLE_INTERVAL_SEC" -ge 1 ]] || die "--sample-interval must be >= 1"
}

try_load_modules() {
  modprobe etmem_scan >/dev/null 2>&1 || true
  modprobe etmem_swap >/dev/null 2>&1 || true
}

cleanup() {
  set +e
  if [[ -n "$ETMEMD_PID" ]]; then
    etmem project stop -n "$PROJECT_NAME" -s "$SOCKET_NAME" >>"$ETMEM_LOG" 2>&1
    etmem obj del -f "$CONFIG_FILE" -s "$SOCKET_NAME" >>"$ETMEM_LOG" 2>&1
    kill "$ETMEMD_PID" >>"$ETMEM_LOG" 2>&1
    wait "$ETMEMD_PID" >>"$ETMEM_LOG" 2>&1
  fi
  if [[ "$TARGET_STARTED_BY_SCRIPT" == "1" && -n "$TARGET_PID" ]]; then
    kill "$TARGET_PID" >>"$TARGET_LOG" 2>&1
    wait "$TARGET_PID" >>"$TARGET_LOG" 2>&1
  fi
}
trap cleanup EXIT

resolve_target() {
  if [[ -n "$PID" && ${#TARGET_CMD[@]} -gt 0 ]]; then
    die "use either --pid or -- <command>, not both"
  fi

  if [[ -n "$PID" ]]; then
    [[ "$PID" =~ ^[0-9]+$ ]] || die "--pid must be numeric"
    [[ -d "/proc/$PID" ]] || die "PID $PID is not alive"
    TARGET_PID="$PID"
    return
  fi

  if ((${#TARGET_CMD[@]} == 0)); then
    die "set --pid or provide a command after --"
  fi

  echo "starting target command: ${TARGET_CMD[*]}"
  "${TARGET_CMD[@]}" >"$TARGET_LOG" 2>&1 &
  TARGET_PID="$!"
  TARGET_STARTED_BY_SCRIPT=1
  sleep 1
  kill -0 "$TARGET_PID" 2>/dev/null || die "target command exited early; see $TARGET_LOG"
  echo "target pid: $TARGET_PID"
}

fill_names() {
  PROJECT_NAME="${PROJECT_NAME:-slide_monitor_${TARGET_PID}}"
  TASK_NAME="${TASK_NAME:-target_${TARGET_PID}}"
  SOCKET_NAME="${SOCKET_NAME:-etmem_slide_${TARGET_PID}_$$}"
  CONFIG_FILE="$CONFIG_DIR/etmem-slide-monitor-${TARGET_PID}-$$.conf"
}

write_config() {
  mkdir -p "$CONFIG_DIR"
  cat >"$CONFIG_FILE" <<EOF
[project]
name=$PROJECT_NAME
loop=$LOOP
interval=$INTERVAL
sleep=$SLEEP_SEC
sysmem_threshold=$SYSMEM_THRESHOLD
swapcache_high_wmark=5
swapcache_low_wmark=3

[engine]
name=slide
project=$PROJECT_NAME

[task]
project=$PROJECT_NAME
engine=slide
name=$TASK_NAME
type=pid
value=$TARGET_PID
T=$T
max_threads=$MAX_THREADS
swap_threshold=$SWAP_THRESHOLD
swap_flag=$SWAP_FLAG
EOF
  chmod 600 "$CONFIG_FILE"
}

print_config() {
  echo "workdir: $WORKDIR"
  echo "target pid: $TARGET_PID"
  echo "generated etmem slide config: $CONFIG_FILE"
  sed 's/^/  /' "$CONFIG_FILE"
  echo
  if [[ "$SHOW_HEAT" == "1" ]]; then
    echo "heat diagnostics: enabled"
    echo "  The heat ratio is observed via etmem_scan idle_pages using the same loop/sleep/interval/T."
    echo "  This can affect accessed bits. Use --show-heat 0 for slide-only measurement."
  else
    echo "heat diagnostics: disabled"
  fi
}

start_etmem() {
  echo "starting etmem daemon: etmemd -l 0 -s $SOCKET_NAME"
  etmemd -l 0 -s "$SOCKET_NAME" >"$ETMEMD_LOG" 2>&1 &
  ETMEMD_PID="$!"
  sleep 2
  kill -0 "$ETMEMD_PID" 2>/dev/null || die "etmemd failed to start; see $ETMEMD_LOG"

  echo "loading config: etmem obj add -f $CONFIG_FILE -s $SOCKET_NAME"
  etmem obj add -f "$CONFIG_FILE" -s "$SOCKET_NAME" >>"$ETMEM_LOG" 2>&1 || die "etmem obj add failed; see $ETMEM_LOG"

  echo "starting project: etmem project start -n $PROJECT_NAME -s $SOCKET_NAME"
  etmem project start -n "$PROJECT_NAME" -s "$SOCKET_NAME" >>"$ETMEM_LOG" 2>&1 || die "etmem project start failed; see $ETMEM_LOG"
}

status_value_kb() {
  local key="$1"
  awk -v key="$key:" '$1 == key {print $2 + 0}' "/proc/$TARGET_PID/status"
}

meminfo_value_kb() {
  local key="$1"
  awk -v key="$key:" '$1 == key {print $2 + 0}' /proc/meminfo
}

major_faults() {
  sed -E 's/^[0-9]+ \(.+\) //' "/proc/$TARGET_PID/stat" | awk '{print $10 + 0}'
}

sample_metrics() {
  local phase="$1"
  local ts rss_kb swap_kb memavail_kb swapfree_kb majflt
  ts="$(date +%s)"
  rss_kb="$(status_value_kb VmRSS)"
  swap_kb="$(status_value_kb VmSwap)"
  memavail_kb="$(meminfo_value_kb MemAvailable)"
  swapfree_kb="$(meminfo_value_kb SwapFree)"
  majflt="$(major_faults)"
  printf "%s,%s,%s,%s,%s,%s,%s\n" \
    "$ts" "$phase" "$rss_kb" "$swap_kb" "$memavail_kb" "$swapfree_kb" "$majflt" >>"$METRICS_FILE"
  printf "%-8s rss=%8d MB  vmswap=%8d MB  memavail=%8d MB  swapfree=%8d MB  majflt=%s\n" \
    "$phase" "$((rss_kb / 1024))" "$((swap_kb / 1024))" "$((memavail_kb / 1024))" \
    "$((swapfree_kb / 1024))" "$majflt"
}

sample_heat() {
  [[ "$SHOW_HEAT" == "1" ]] || return
  mkdir -p "$HEAT_DIR"
  local ts
  ts="$(date +%s)"
  local summary_file="$HEAT_DIR/heat-${ts}-summary.csv"
  local vma_file="$HEAT_DIR/heat-${ts}-vmas.csv"

  echo
  echo "heat sample at $(date '+%F %T')"
  python3 "$ROOT_DIR/etmem-scan-demo/scan_idle_pages.py" \
    --pid "$TARGET_PID" \
    --loop "$LOOP" \
    --sleep "$SLEEP_SEC" \
    --interval "$INTERVAL" \
    --t "$T" \
    --samples 1 \
    --top "$HEAT_TOP" \
    --vma-filter "$HEAT_VMA_FILTER" \
    --min-vma-kb "$HEAT_MIN_VMA_KB" \
    --csv "$summary_file" \
    --vma-csv "$vma_file" \
    2>&1 | tee -a "$HEAT_LOG"
  echo "  heat summary csv: $summary_file"
  echo "  heat vma csv    : $vma_file"
}

monitor_loop() {
  echo "timestamp,phase,rss_kb,vmswap_kb,memavailable_kb,swapfree_kb,major_faults" >"$METRICS_FILE"
  sample_metrics "start"

  local start_ts now elapsed
  start_ts="$(date +%s)"
  while kill -0 "$TARGET_PID" 2>/dev/null; do
    now="$(date +%s)"
    elapsed=$((now - start_ts))
    if [[ "$DURATION_SEC" != "0" && "$elapsed" -ge "$DURATION_SEC" ]]; then
      echo "duration reached: ${DURATION_SEC}s"
      break
    fi

    sample_heat
    sample_metrics "sample"
    sleep "$SAMPLE_INTERVAL_SEC"
  done
}

summarize() {
  echo
  echo "summary:"
  echo "  workdir       : $WORKDIR"
  echo "  metrics csv   : $METRICS_FILE"
  echo "  heat csv dir  : $HEAT_DIR"
  echo "  heat log      : $HEAT_LOG"
  echo "  etmem config  : $CONFIG_FILE"
  echo "  etmem log     : $ETMEM_LOG"
  echo "  etmemd log    : $ETMEMD_LOG"
  echo "  target log    : $TARGET_LOG"
}

main() {
  parse_args "$@"
  require_root
  require_commands
  require_numbers
  try_load_modules
  resolve_target
  fill_names
  write_config
  print_config
  start_etmem
  monitor_loop
  summarize
}

main "$@"
