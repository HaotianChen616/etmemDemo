# etmem Demo

Minimal demos for validating openEuler etmem behavior before applying it to VM or OpenClaw workloads.

## Demos

- `etmem-swap-demo`: uses etmem `slide` to scan and swap cold anonymous pages, then checks whether target `VmRSS` drops and `VmSwap` grows.
- `etmem-scan-demo`: uses only the etmem scan interface, `/proc/<pid>/idle_pages`, to observe hot/cold memory distribution for a target process.

## Recommended Flow

1. Run `etmem-scan-demo` to verify the kernel scan path and understand the target process hot/cold shape.
2. Run `etmem-swap-demo` to verify that cold pages can be swapped out and resident memory can be reduced.
3. Apply the same metrics to the real VM or OpenClaw process.

Both demos require an openEuler kernel with etmem support. Run them as root on the target server.

