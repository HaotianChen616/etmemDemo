# etmem scan-only demo

这个 demo 是 fallback，不是首选的 etmem 用户态分析流程。它只使用 openEuler etmem 的底层扫描接口：

```text
/proc/<pid>/idle_pages
```

它不启动 `etmemd`，不创建 etmem project，也不写 `/proc/<pid>/swap_pages`。用途是在 cslide 不适用或需要排查内核扫描接口时，直接观察扫描结果。

这里没有 `/etc/etmem` 配置过程是刻意的：scan-only demo 只验证内核扫描接口，不走 etmem 用户态 project 管理。要“用 etmem 分析冷热温”，请优先看 `../etmem-cslide-hotness-demo`；需要 etmem 配置文件的是 cslide hotness demo 和 `etmem-swap-demo` 这一类会启动 `etmemd` 并执行 project 的场景。

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
sample=1 elapsed=15.2s hot=64.0MB cold=960.0MB other=0.0MB holes=0.0MB cold_ratio=93.8% rss=1036.0MB swap=0.0MB majflt=0
  #1  cold=   960.0MB hot=    64.0MB ratio= 93.8% range=... perms=rw-p path=[anonymous]
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
  --vma-filter anon \
  --csv /tmp/etmem-scan-summary.csv \
  --vma-csv /tmp/etmem-scan-vmas.csv
```

参数建议：

- `--samples`：输出多少次扫描结果，不是内存页数量。
- 普通应用进程：先用 `--vma-filter anon`
- QEMU / VM 进程：先用 `--vma-filter rw-private --min-vma-kb 2048`
- 想看全部可读映射：使用 `--vma-filter all`
- 观察窗口太短时容易把偶发访问误判为热，建议从 `--interval 30` 起步

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

## 4. 关键语义

读取 `idle_pages` 会报告页面访问状态，并清除 accessed bit。所以：

- 第一次扫描通常用来建立基线。
- `--warmup` 会丢弃第一次扫描结果。
- 后续样本表示“上一次扫描后到本次扫描前”这个窗口内的冷热状态。

本工具中的分类：

- `hot`：etmem_scan 报告为 accessed 或 dirty 的页面
- `cold`：etmem_scan 报告为 idle 的页面
- `holes`：未映射或 non-present 范围，不计入 cold ratio
- `other`：当前脚本未归入 hot/cold/hole 的状态

## 5. 输出文件

`--csv` summary 字段：

- `sample`
- `elapsed_sec`
- `hot_mb`
- `cold_mb`
- `other_mb`
- `hole_mb`
- `present_mb`
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
- `cold_ratio`

## 6. 如何解读

适合进入 swap 验证的信号：

- cold ratio 在真实负载下连续几个窗口稳定
- 冷内存集中在大块匿名 VMA 或明确可接受的缓存区域
- major fault 没有持续增长
- 业务 p95/p99 没有异常波动

不建议直接换出的信号：

- 只有业务空闲时 cold ratio 高，压测期间迅速降低
- 冷热分布在样本间剧烈波动
- 冷页疑似包含模型权重、KV cache 或推理热路径
- 扫描目标是 QEMU，但无法确认 guest 内部业务访问模式

## 7. 常见问题

`/proc/<pid>/idle_pages does not exist`：

```bash
sudo modprobe etmem_scan
```

仍然不存在时，当前内核很可能没有 etmem scan 支持。

`no permission to inspect PID`：

用 root 运行。

扫描结果全是热：

- 目标进程确实持续访问这些页面
- 观测窗口太短，增大 `--interval`
- 第一次扫描没有丢弃，使用 `--warmup`

扫描结果全是冷：

- 目标进程在观测窗口内没有实际负载
- 业务流量没有打到该实例
- 选错 PID
