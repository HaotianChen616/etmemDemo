# etmem scan-only demo

这个 demo 是 `etmem_scan` 旁路观测器。它不依赖 `etmemd` 的报表接口，而是直接使用 openEuler etmem 的底层扫描接口：

```text
/proc/<pid>/idle_pages
```

它不启动 `etmemd`，不创建 etmem project，也不写 `/proc/<pid>/swap_pages`。它读取的页面状态来自 etmem；脚本自己做的是把这些状态按 `slide` 风格累计成 hot/cold 占比报表。

这里没有 `/etc/etmem` 配置过程是刻意的：scan-only demo 走 `etmem_scan` 内核接口，不走 etmem 用户态 project 管理。要看 etmem 官方 engine 自带的热度统计，请优先看 `../etmem-cslide-hotness-demo`；需要 etmem 配置文件的是 cslide hotness demo、`etmem-slide-monitor` 和 `etmem-swap-demo` 这一类会启动 `etmemd` 并执行 project 的场景。

## 1. 前置条件

目标机需要：

- openEuler etmem-capable kernel
- root 权限
- `python3`
- `etmem_scan` 模块或内建支持

检查：

```bash
sudo modprobe etmem_scan
lsmod | grep etmem_scan
```

如果你已经有目标进程：

```bash
pid=<PID>
test -e /proc/$pid/idle_pages && echo ok
```

## 2. 先跑合成靶进程

```bash
cd /path/to/etmemDemo/etmem-scan-demo
sudo ./run_etmem_scan_demo.sh
```

脚本会：

1. 启动一个合成进程，分配 `TOTAL_MB` 匿名内存。
2. 初始触碰全部页面。
3. 持续触碰前 `HOT_MB` 内存，让这部分保持热。
4. 调用 `scan_idle_pages.py` 读取 `/proc/<pid>/idle_pages`。
5. 输出 summary 和 per-VMA CSV。

更强信号：

```bash
sudo TOTAL_MB=4096 HOT_MB=128 SCAN_INTERVAL_SEC=15 SCAN_SAMPLES=5 ./run_etmem_scan_demo.sh
```

`SCAN_SAMPLES` 的意思是采样次数。例如 `SCAN_SAMPLES=5` 表示 warmup 后输出 5 次扫描结果；每两次扫描之间等待 `SCAN_INTERVAL_SEC` 秒。命令行参数 `--samples 5` 同理。

预期输出形态：

```text
warmup scan: clears accessed bits and establishes the observation window
sample=1 elapsed=15.2s hot=64.0MB cold=960.0MB other=0.0MB holes=0.0MB present=1024.0MB scanned_vma_rss=1036.0MB scan_rss_ratio=98.8% process_rss=1036.0MB process_coverage=98.8% swap=0.0MB majflt=0
  cold_ratio=93.8% (cold / scanned present pages)
  #1  cold=   960.0MB hot=    64.0MB present=  1024.0MB smaps_rss=  1036.0MB ratio= 93.8% range=... perms=rw-p path=[anonymous]
```

合成 demo 通过标准：

- `hot` 大致接近 `HOT_MB`
- `cold` 大致接近 `TOTAL_MB - HOT_MB`
- `cold_ratio` 稳定且可解释
- 没有报 `/proc/<pid>/idle_pages` 缺失

## 3. 扫描真实进程

```bash
sudo python3 ./scan_idle_pages.py \
  --pid <PID> \
  --warmup \
  --interval 30 \
  --samples 5 \
  --vma-filter slide-anon \
  --csv /tmp/etmem-scan-summary.csv \
  --vma-csv /tmp/etmem-scan-vmas.csv
```

如果需要把每个 base page 的访问权重和最终冷热判定都输出到 CSV：

```bash
sudo python3 ./scan_idle_pages.py \
  --pid <PID> \
  --warmup \
  --interval 30 \
  --samples 1 \
  --vma-filter slide-anon \
  --min-vma-kb 0 \
  --page-csv /tmp/etmem-scan-pages.csv
```

如果还想看 `loop` 内每一轮扫描看到的页面状态，额外加 `--page-rounds`：

```bash
sudo python3 ./scan_idle_pages.py \
  --pid <PID> \
  --warmup \
  --loop 3 \
  --sleep 10 \
  --interval 30 \
  --t 2 \
  --samples 1 \
  --vma-filter slide-anon \
  --min-vma-kb 0 \
  --page-csv /tmp/etmem-scan-pages.csv \
  --page-rounds
```

注意：per-page CSV 会非常大。4 GB base page 约 100 万行，每多一个 sample 又追加一批。长时间监控时不要默认打开，只在短时间定位某段 VMA 或抽样分析时使用。

参数建议：

- `--samples`：输出多少次扫描结果，不是内存页数量。
- `--loop`：每个样本内部扫描几轮，含义对齐 etmem page scan 的 `loop`，默认 `1`。
- `--sleep`：每轮内部扫描后等待多少秒，含义对齐当前 etmem 源码中 page scan 的 `sleep`；默认 `0` 便于单轮旁路观测。
- `--interval`：开始下一次输出样本前等待多少秒，含义对齐当前 etmem 源码中调度扫描任务的 `interval`；`--warmup` 后也先等待这个窗口再输出 sample 1。
- `--t`：冷热阈值，累计访问权重 `< T` 判为 cold，`>= T` 判为 hot，默认 `1`。当前脚本按 etmem slide 权重累计：read/access=`1`，dirty/write=`3`，因此 `T` 可取 `0..loop*3`。
- 想贴近 slide 默认扫页范围：使用默认 `--vma-filter slide-anon`
- 普通旁路观测：也可用更窄的 `--vma-filter anon`
- QEMU / VM 进程：先用 `--vma-filter rw-private --min-vma-kb 2048`
- 想看全部可读映射：使用 `--vma-filter all`
- `--page-csv`：每个 base page 输出一行，包含页地址、最终 hot/cold/other 分类和累计访问权重。
- `--page-rounds`：配合 `--page-csv` 使用，额外写出每一轮扫描看到的状态，例如 `pte_accessed;pte_idle;pte_dirty`。
- `--page-include-holes`：配合 `--page-csv` 使用，把 hole/non-present 页也写进明细；通常不建议默认打开。
- 单轮观察窗口太短时容易把偶发访问误判为热，建议从 `--interval 30` 起步

按当前源码口径观察一个 etmem slide 配置 `loop=3 sleep=10 interval=30 T=2`：

```bash
sudo python3 ./scan_idle_pages.py \
  --pid <PID> \
  --warmup \
  --loop 3 \
  --sleep 10 \
  --interval 30 \
  --t 2 \
  --samples 5 \
  --vma-filter slide-anon \
  --min-vma-kb 0
```

这个模式仍然不经过 `etmemd`，但热度累计更贴近 slide：每个样本扫 3 轮，read/access 轮次加 `1`，dirty/write 轮次加 `3`，累计权重小于 `2` 就归为 cold。`interval` 是样本任务前的外层窗口；`sleep` 是这 3 轮内部扫描之间的窗口。

QEMU 示例：

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

## 4. 持续监控

持续监控用 `--watch`：

```bash
sudo python3 ./scan_idle_pages.py \
  --pid <PID> \
  --warmup \
  --interval 30 \
  --watch \
  --vma-filter slide-anon \
  --min-vma-kb 0 \
  --csv /tmp/etmem-scan-summary.csv
```

或者用 `--samples 0`，含义同样是一直跑到手动停止：

```bash
sudo python3 ./scan_idle_pages.py \
  --pid <PID> \
  --warmup \
  --interval 30 \
  --samples 0 \
  --vma-filter slide-anon \
  --min-vma-kb 0 \
  --csv /tmp/etmem-scan-summary.csv
```

限制运行时长可以用 `timeout`：

```bash
sudo timeout 1h python3 ./scan_idle_pages.py \
  --pid <PID> \
  --warmup \
  --interval 30 \
  --watch \
  --vma-filter slide-anon \
  --min-vma-kb 0 \
  --csv /tmp/etmem-scan-summary.csv
```

长时间监控建议先只写 summary CSV，不写 `--vma-csv`，否则每轮每个 VMA 都会追加一批记录，文件会增长很快。需要定位具体冷 VMA 时，再短时间打开 `--vma-csv`。

注意：每次扫描都会读取 `/proc/<pid>/idle_pages`，这个动作会清 accessed bit。因此持续监控时，每一行样本表示本次样本任务各扫描窗口累计出来的冷热结果。

如果设置了 `--loop 3 --sleep 10 --interval 30 --t 2`，warmup 后 sample 1 先观察 30 秒外层窗口，再在同一个样本任务里继续做 3 轮 page scan 累计；后两轮主要反映 `sleep=10` 的内部窗口。

## 5. 关键语义

读取 `idle_pages` 会报告页面访问状态，并清除 accessed bit。所以：

- 第一次扫描通常用来建立基线。
- `--warmup` 会丢弃第一次扫描结果。
- 默认 `--loop 1 --t 1` 时，后续样本表示外层 `interval` 窗口内 etmem_scan 看到的冷热状态。
- `--loop N --t T` 时，一个样本会扫描 N 轮，累计每页的访问权重；read/access 权重为 `1`，dirty/write 权重为 `3`；累计权重 `< T` 算 cold，`>= T` 算 hot。
- 当前 etmem 源码在每轮 page scan 后执行 `sleep`，包括最后一轮；脚本保留这个等待，因此一个样本的返回时间大致还会包含 `loop * sleep`。
- 单独运行这个 scan observer 没问题，清 accessed bit 正是它建立下一段观测窗口的方式。
- 不要让同一个 PID 同时被这个脚本、`etmemd slide` 或另一个 `idle_pages` 读取者并发扫描；先扫描的一方会切走一段访问痕迹，影响后扫描的一方看到的冷热窗口。
- slide 一次 scan job 的 `loop` 轮扫描完成后才会按累计权重和 `T` 分 hot/cold；完整流程图见根目录 `README.md` 的“slide 何时按 `T` 分冷热”。

本工具中的分类：

- `hot`：按 etmem slide 权重累计后达到 `T` 的页面
- `cold`：可分类页面中累计权重未达到 `T` 的页面；`T=1` 时通常对应观测窗口里只看到 idle 的页面
- `holes`：未映射或 non-present 范围，不计入 cold ratio
- `other`：当前脚本未归入 hot/cold/hole 的状态

## 6. 输出文件

`--csv` summary 字段：

- `sample`
- `elapsed_sec`
- `hot_mb`
- `cold_mb`
- `other_mb`
- `hole_mb`
- `present_mb`
- `scanned_vma_rss_mb`
- `scan_rss_ratio`
- `process_coverage`
- `cold_ratio`
- `rss_mb`
- `swap_mb`
- `major_faults`

`--vma-csv` per-VMA 字段：

- `sample`
- `start`
- `end`
- `perms`
- `path`
- `hot_mb`
- `cold_mb`
- `present_mb`
- `smaps_rss_mb`
- `scan_rss_ratio`
- `cold_ratio`

`--page-csv` per-page 字段：

- `sample`
- `vma_start`
- `vma_end`
- `page_addr`
- `page_index`
- `page_size_kb`
- `class`
- `access_count`
- `round_states`
- `perms`
- `path`

其中 `class` 是按当前样本内累计权重和 `T` 得出的最终分类；`access_count` 是 read/access 权重 `1`、dirty/write 权重 `3` 的累计值；`round_states` 只有打开 `--page-rounds` 时才有值。

## 7. 如何解读

适合进入 swap 验证的信号：

- cold ratio 在真实负载下连续几个窗口稳定
- 冷内存集中在大块匿名 VMA 或明确可接受的缓存区域
- `scan_rss_ratio` 接近 100%，说明 etmem_scan 统计和同一批 VMA 的 `smaps` RSS 口径接近
- `process_coverage` 足够高，说明当前筛选参数覆盖了进程主要 RSS
- major fault 没有持续增长
- 业务 p95/p99 没有异常波动

不建议直接换出的信号：

- 只有业务空闲时 cold ratio 高，压测期间迅速降低
- 冷热分布在样本间剧烈波动
- 冷页疑似包含模型权重、KV cache 或推理热路径
- 扫描目标是 QEMU，但无法确认 guest 内部业务访问模式

## 8. 常见问题

`/proc/<pid>/idle_pages does not exist`：

```bash
sudo modprobe etmem_scan
```

仍然不存在时，当前内核很可能没有 etmem scan 支持。

`no permission to inspect PID`：

用 root 运行。

扫描结果全是热：

- 目标进程确实持续访问这些页面
- 单轮观测窗口太短，增大 `--interval`
- 多轮内部窗口太短，增大 `--sleep`
- 第一次扫描没有丢弃，使用 `--warmup`

扫描结果全是冷：

- 目标进程在观测窗口内没有实际负载
- 业务流量没有打到该实例
- 选错 PID
