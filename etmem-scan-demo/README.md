# etmem scan-only demo

This demo uses only the openEuler etmem scan interface:

```text
/proc/<pid>/idle_pages
```

It does not start `etmemd`, does not create an etmem project, and does not write to `/proc/<pid>/swap_pages`. The goal is to observe hot/cold memory distribution for a process before deciding whether swap-based optimization is safe.

## Important Semantics

Reading `idle_pages` reports page access state and clears access bits. Because of that, use a warmup scan first, wait for an observation interval, and treat the next scan as "pages accessed during this window" versus "pages idle during this window".

In this demo:

- hot means accessed or dirty pages reported by etmem_scan
- cold means idle pages reported by etmem_scan
- holes are unmapped or non-present ranges and are excluded from the cold ratio

## Run the Built-In Target Demo

This starts the same synthetic target used by the swap demo: it allocates memory, keeps a small hot range active, and leaves the rest idle.

```bash
cd /path/to/etmemDemo/etmem-scan-demo
sudo ./run_etmem_scan_demo.sh
```

For a stronger signal:

```bash
sudo TOTAL_MB=4096 HOT_MB=128 SCAN_INTERVAL_SEC=15 SCAN_SAMPLES=5 ./run_etmem_scan_demo.sh
```

Expected shape:

```text
warmup scan: clears accessed bits and establishes the observation window
sample=1 elapsed=15.2s hot=64.0MB cold=960.0MB other=0.0MB holes=0.0MB cold_ratio=93.8% rss=1036.0MB swap=0.0MB majflt=0
  #1  cold=   960.0MB hot=    64.0MB ratio= 93.8% range=... perms=rw-p path=[anonymous]
```

## Scan a Real Process

```bash
sudo python3 ./scan_idle_pages.py \
  --pid <PID> \
  --warmup \
  --interval 30 \
  --samples 5 \
  --vma-filter anon \
  --csv /tmp/etmem-scan-summary.csv \
  --vma-csv /tmp/etmem-scan-vmas.csv
```

For QEMU or a VM process, start with:

```bash
sudo python3 ./scan_idle_pages.py \
  --pid <QEMU_PID> \
  --warmup \
  --interval 30 \
  --samples 5 \
  --vma-filter rw-private \
  --min-vma-kb 2048 \
  --csv /tmp/qemu-scan-summary.csv \
  --vma-csv /tmp/qemu-scan-vmas.csv
```

## Main Options

- `--pid`: target process PID
- `--warmup`: discard the first scan and establish the observation window
- `--interval`: seconds between scans
- `--samples`: number of reported samples
- `--vma-filter`: `anon`, `rw-private`, or `all`
- `--min-vma-kb`: skip small VMAs to reduce noise
- `--csv`: summary output
- `--vma-csv`: per-VMA output
- `--huge`: request huge-page scan mode
- `--dirty`: request dirty-page classification

## How to Read the Result

Use the summary CSV to answer:

- how much target memory is hot in the current window
- how much appears cold and could be considered for swap/migration
- whether the cold ratio is stable across samples

Use the per-VMA CSV to answer:

- which memory ranges are mostly cold
- whether cold memory is concentrated in anonymous buffers, heap, or VM memory mappings
- whether the candidate ranges are large enough to optimize safely

For a real OpenClaw or VM workload, only consider swap/migration after the cold ratio is stable while the workload is serving realistic traffic.

