#!/usr/bin/env python3
import argparse
import mmap
import os
import signal
import sys
import time


PAGE_SIZE = mmap.PAGESIZE
refault_requested = False
running = True


def parse_args():
    parser = argparse.ArgumentParser(
        description="Allocate anonymous memory, keep a small hot range active, and leave the rest cold."
    )
    parser.add_argument("--total-mb", type=int, default=1024, help="anonymous memory to allocate")
    parser.add_argument("--hot-mb", type=int, default=64, help="memory range to keep hot")
    parser.add_argument("--ready-file", required=True, help="file touched after allocation")
    parser.add_argument("--pid-file", required=True, help="file where PID is written")
    parser.add_argument("--touch-sleep", type=float, default=0.05, help="seconds between hot touches")
    return parser.parse_args()


def touch_range(buf, start, length):
    end = start + length
    for offset in range(start, end, PAGE_SIZE):
        buf[offset] = (buf[offset] + 1) & 0xFF


def handle_usr1(signum, frame):
    global refault_requested
    refault_requested = True


def handle_term(signum, frame):
    global running
    running = False


def main():
    args = parse_args()
    total_bytes = args.total_mb * 1024 * 1024
    hot_bytes = min(args.hot_mb, args.total_mb) * 1024 * 1024

    signal.signal(signal.SIGUSR1, handle_usr1)
    signal.signal(signal.SIGTERM, handle_term)
    signal.signal(signal.SIGINT, handle_term)

    buf = mmap.mmap(
        -1,
        total_bytes,
        flags=mmap.MAP_PRIVATE | mmap.MAP_ANONYMOUS,
        prot=mmap.PROT_READ | mmap.PROT_WRITE,
    )

    if hasattr(buf, "madvise") and hasattr(mmap, "MADV_NOHUGEPAGE"):
        try:
            buf.madvise(mmap.MADV_NOHUGEPAGE)
        except OSError:
            pass

    print(
        f"coldmem_target pid={os.getpid()} total_mb={args.total_mb} hot_mb={args.hot_mb}",
        flush=True,
    )
    touch_range(buf, 0, total_bytes)
    print("initial_touch_done", flush=True)

    with open(args.pid_file, "w", encoding="ascii") as f:
        f.write(str(os.getpid()))
    with open(args.ready_file, "w", encoding="ascii") as f:
        f.write("ready\n")

    rounds = 0
    global refault_requested
    while running:
        touch_range(buf, 0, hot_bytes)
        rounds += 1

        if refault_requested:
            print("refault_all_start", flush=True)
            touch_range(buf, 0, total_bytes)
            print("refault_all_done", flush=True)
            refault_requested = False

        if rounds % 200 == 0:
            print(f"hot_touch_rounds={rounds}", flush=True)

        time.sleep(args.touch_sleep)

    print("coldmem_target exiting", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
