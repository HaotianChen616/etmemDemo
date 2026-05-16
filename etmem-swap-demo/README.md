# etmem swap cold-page demo

This is a minimal piercing test for openEuler etmem `slide`.

It creates one target process that allocates anonymous memory, touches every page once, then keeps only a small hot range active. etmem should identify the inactive pages as cold and swap them out.

## What It Proves

The demo passes only when all of the following are visible:

- target process `VmRSS` drops
- target process `VmSwap` grows
- system `MemAvailable` usually rises, allowing for normal Linux noise

This validates the basic path:

```text
anonymous cold pages -> etmem scan -> etmem swap -> lower resident memory
```

It does not prove OpenClaw performance safety. After this passes, run the same metric style against the real VM or guest process workload.

## Prerequisites

- openEuler kernel with `etmem_scan` and `etmem_swap`
- `etmem` and `etmemd` installed
- root privileges
- enabled swap, preferably zram or NVMe swap for tests

Quick checks:

```bash
command -v etmem etmemd
modprobe etmem_scan
modprobe etmem_swap
swapon --show
```

## Run

```bash
cd /path/to/etmem-swap-demo
sudo ./run_etmem_swap_demo.sh
```

For a stronger signal:

```bash
sudo TOTAL_MB=4096 HOT_MB=128 DURATION_SEC=180 ./run_etmem_swap_demo.sh
```

Optional refault check:

```bash
sudo REFAULT_AFTER=1 ./run_etmem_swap_demo.sh
```

`REFAULT_AFTER=1` sends `SIGUSR1` to the target process after etmem stops, causing it to touch all memory again. RSS should rise again as swapped pages fault back in.

## Main Tunables

- `TOTAL_MB`: total anonymous memory allocated by the target, default `1024`
- `HOT_MB`: memory continuously touched by the target, default `64`
- `DURATION_SEC`: etmem running time, default `120`
- `ETMEM_T`: etmem cold-page threshold, default `1`
- `ETMEM_INTERVAL`: scan interval in seconds, default `5`
- `ETMEM_SLEEP`: sleep time between etmem scan/swap rounds, default `10`
- `ETMEM_SWAP_THRESHOLD`: process memory threshold, default `0g`

## Pass Criteria

The script prints `PASS` when:

- RSS drop is at least `HOT_MB`
- VmSwap growth is at least `HOT_MB`

For a real report, prefer a stronger threshold such as:

- RSS drops by at least 30% of `TOTAL_MB - HOT_MB`
- VmSwap grows by roughly the same order
- no large sustained major-fault growth during the hot loop

## Expected Output Shape

```text
before     rss=   1035 MB  vmswap=      0 MB  memavail=  64000 MB  swapfree=   8192 MB
running    rss=    620 MB  vmswap=    410 MB  memavail=  64410 MB  swapfree=   7782 MB
running    rss=    160 MB  vmswap=    875 MB  memavail=  64870 MB  swapfree=   7317 MB
after      rss=    150 MB  vmswap=    885 MB  memavail=  64880 MB  swapfree=   7307 MB

PASS: etmem swapped cold anonymous pages and lowered target resident memory.
```

## Common Failures

- `/proc/<pid>/idle_pages is missing`: `etmem_scan` is unavailable or kernel lacks etmem support.
- `/proc/<pid>/swap_pages is missing`: `etmem_swap` is unavailable or kernel lacks etmem support.
- no `VmSwap` growth: swap is disabled, config parsing failed, threshold is too strict, or the process was still touching most pages.
- RSS drops but performance is bad: swap backend is slow. Use zram/NVMe and keep hot pages out of swap.

