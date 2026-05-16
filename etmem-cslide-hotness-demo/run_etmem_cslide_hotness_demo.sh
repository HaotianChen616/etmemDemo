#!/usr/bin/env bash
set -Eeuo pipefail

TARGET_PID="${TARGET_PID:-${1:-}}"
NODE_PAIR="${NODE_PAIR:-}"
PROJECT_NAME="${PROJECT_NAME:-hotness_probe}"
ENGINE_NAME="${ENGINE_NAME:-cslide}"
TASK_NAME="${TASK_NAME:-vm_hotness}"
LOOP="${LOOP:-3}"
INTERVAL="${INTERVAL:-10}"
SLEEP_SEC="${SLEEP_SEC:-30}"
HOT_THRESHOLD="${HOT_THRESHOLD:-1}"
NODE_MIG_QUOTA="${NODE_MIG_QUOTA:-0}"
NODE_HOT_RESERVE="${NODE_HOT_RESERVE:-0}"
VM_FLAGS="${VM_FLAGS:-ht}"
ANON_ONLY="${ANON_ONLY:-no}"
IGN_HOST="${IGN_HOST:-no}"
SAMPLES="${SAMPLES:-5}"
SAMPLE_INTERVAL_SEC="${SAMPLE_INTERVAL_SEC:-30}"
CONFIG_DIR="${CONFIG_DIR:-/etc/etmem}"
SOCKET_NAME="${SOCKET_NAME:-etmem_hotness_$$}"

WORKDIR="$(mktemp -d /tmp/etmem-cslide-hotness.XXXXXX)"
CONFIG_FILE="$CONFIG_DIR/etmem-cslide-hotness-$$.conf"
ETMEMD_LOG="$WORKDIR/etmemd.log"
ETMEM_LOG="$WORKDIR/etmem.log"
TASKPAGES_LOG="$WORKDIR/showtaskpages.log"
HOSTPAGES_LOG="$WORKDIR/showhostpages.log"
PROJECT_SHOW_LOG="$WORKDIR/project-show.log"
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
}
trap cleanup EXIT

require_root() {
  if [[ "$(id -u)" != "0" ]]; then
    die "run as root, for example: sudo TARGET_PID=<qemu-pid> NODE_PAIR=<aep,dram> $0"
  fi
}

require_args() {
  [[ -n "$TARGET_PID" ]] || die "set TARGET_PID or pass it as first arg"
  [[ "$TARGET_PID" =~ ^[0-9]+$ ]] || die "TARGET_PID must be a numeric PID"
  [[ -d "/proc/$TARGET_PID" ]] || die "PID $TARGET_PID is not alive"
  [[ -n "$NODE_PAIR" ]] || die "set NODE_PAIR, for example NODE_PAIR=2,0 or NODE_PAIR=2,0;3,1"
}

require_commands() {
  local missing=()
  for cmd in etmem etmemd awk date mkdir tee; do
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

write_config() {
  mkdir -p "$CONFIG_DIR"
  cat >"$CONFIG_FILE" <<EOF
[project]
name=$PROJECT_NAME
loop=$LOOP
interval=$INTERVAL
sleep=$SLEEP_SEC

[engine]
name=$ENGINE_NAME
project=$PROJECT_NAME
node_pair=$NODE_PAIR
hot_threshold=$HOT_THRESHOLD
node_mig_quota=$NODE_MIG_QUOTA
node_hot_reserve=$NODE_HOT_RESERVE

[task]
project=$PROJECT_NAME
engine=$ENGINE_NAME
name=$TASK_NAME
type=pid
value=$TARGET_PID
vm_flags=$VM_FLAGS
anon_only=$ANON_ONLY
ign_host=$IGN_HOST
EOF
  chmod 600 "$CONFIG_FILE"
}

print_config() {
  echo "workdir: $WORKDIR"
  echo "generated cslide config: $CONFIG_FILE"
  sed 's/^/  /' "$CONFIG_FILE"
  echo
  echo "NOTE: this is a real etmem cslide project. It uses etmemd and etmem engine showtaskpages/showhostpages."
  echo "NOTE: NODE_MIG_QUOTA defaults to 0 for analysis-first runs."
  echo
}

start_etmem_project() {
  echo "starting etmem daemon: etmemd -l 0 -s $SOCKET_NAME"
  etmemd -l 0 -s "$SOCKET_NAME" >"$ETMEMD_LOG" 2>&1 &
  ETMEMD_PID="$!"
  sleep 2
  kill -0 "$ETMEMD_PID" 2>/dev/null || die "etmemd failed to start; see $ETMEMD_LOG"

  echo "loading etmem config: etmem obj add -f $CONFIG_FILE -s $SOCKET_NAME"
  etmem obj add -f "$CONFIG_FILE" -s "$SOCKET_NAME" >>"$ETMEM_LOG" 2>&1 || die "etmem obj add failed; see $ETMEM_LOG"

  echo "starting etmem project: etmem project start -n $PROJECT_NAME -s $SOCKET_NAME"
  etmem project start -n "$PROJECT_NAME" -s "$SOCKET_NAME" >>"$ETMEM_LOG" 2>&1 || die "etmem project start failed; see $ETMEM_LOG"

  etmem project show -n "$PROJECT_NAME" -s "$SOCKET_NAME" >"$PROJECT_SHOW_LOG" 2>&1 || true
}

collect_samples() {
  local i
  local warmup_sec=$((LOOP * INTERVAL + 2))
  echo "waiting ${warmup_sec}s for the first etmem scan window to finish..."
  sleep "$warmup_sec"

  for ((i = 1; i <= SAMPLES; i++)); do
    echo
    echo "===== sample $i / $SAMPLES at $(date '+%F %T') =====" | tee -a "$TASKPAGES_LOG"
    echo "command: etmem engine showtaskpages -t $TASK_NAME -n $PROJECT_NAME -e $ENGINE_NAME -s $SOCKET_NAME" | tee -a "$TASKPAGES_LOG"
    etmem engine showtaskpages -t "$TASK_NAME" -n "$PROJECT_NAME" -e "$ENGINE_NAME" -s "$SOCKET_NAME" \
      2>&1 | tee -a "$TASKPAGES_LOG"

    echo "===== sample $i / $SAMPLES at $(date '+%F %T') =====" >>"$HOSTPAGES_LOG"
    echo "command: etmem engine showhostpages -n $PROJECT_NAME -e $ENGINE_NAME -s $SOCKET_NAME" >>"$HOSTPAGES_LOG"
    etmem engine showhostpages -n "$PROJECT_NAME" -e "$ENGINE_NAME" -s "$SOCKET_NAME" \
      >>"$HOSTPAGES_LOG" 2>&1 || true

    if (( i < SAMPLES )); then
      sleep "$SAMPLE_INTERVAL_SEC"
    fi
  done
}

summarize() {
  echo
  echo "done."
  echo "  cslide config    : $CONFIG_FILE"
  echo "  showtaskpages log: $TASKPAGES_LOG"
  echo "  showhostpages log: $HOSTPAGES_LOG"
  echo "  project show log : $PROJECT_SHOW_LOG"
  echo "  etmem log        : $ETMEM_LOG"
  echo "  etmemd log       : $ETMEMD_LOG"
}

main() {
  require_root
  require_args
  require_commands
  try_load_module
  write_config
  print_config
  start_etmem_project
  collect_samples
  summarize
}

main "$@"
