# etmemDemo

这是一个面向 openEuler etmem 的最小穿刺验证仓库，用来在上真实 VM / OpenClaw 之前，先回答两个问题：

1. 当前服务器的 etmem 扫描链路是否可用，能否观察某个进程的冷热内存分布。
2. 当前服务器的 etmem `slide` 换出链路是否可用，能否把冷匿名页换到 swap，从而降低进程 resident memory。

仓库包含两个 demo：

- `etmem-scan-demo`：只读 `/proc/<pid>/idle_pages`，不启动 `etmemd`，不写 swap，用于观测一个实例或进程的冷热分布。
- `etmem-swap-demo`：启动 `etmemd` 和 `slide` 工程，把合成靶进程的冷匿名页换出，用 `VmRSS` / `VmSwap` / `MemAvailable` 验证效果。

先澄清两个容易混淆的词：

- `sample` / `samples` 是“采样点/采样次数”。例如 `--samples 5` 或 `SCAN_SAMPLES=5` 表示 warmup 之后输出 5 次冷热扫描结果。
- scan-only demo 不需要 `/etc/etmem` 配置，也不调用 `etmem` 命令，它直接读内核接口 `/proc/<pid>/idle_pages`。swap demo 才会生成 etmem project 配置，并调用 `etmemd`、`etmem obj add`、`etmem project start`。

官方背景参考：

- openEuler etmem 用户指南：<https://docs.openeuler.org/zh/docs/22.03_LTS_SP4/server/memory_storage/etmem/etmem_user_guide.html>
- etmem 仓库：<https://gitee.com/openeuler/etmem>

## 0. 适用范围

适合先做本机穿刺验证：

- 验证 openEuler 内核是否提供 `etmem_scan` / `etmem_swap`
- 验证 etmem 用户态工具 `etmem` / `etmemd` 是否能正常工作
- 在不触碰业务的情况下，确认“冷页识别”和“冷页换出”两条链路
- 对真实进程、QEMU 进程或 OpenClaw 实例做冷热观测

不直接证明生产收益：

- 合成 demo 不能替代真实业务压测
- swap 后端太慢时，内存下降可能伴随明显尾延迟
- 直接对 QEMU 进程做 swap 前，需要先确认热路径不会被换出

## 1. 从零开始准备服务器

在 openEuler 目标服务器上执行。

### 1.1 获取 demo

```bash
git clone https://github.com/HaotianChen616/etmemDemo.git
cd etmemDemo
```

如果服务器只能走 SSH：

```bash
git clone git@github.com:HaotianChen616/etmemDemo.git
cd etmemDemo
```

### 1.2 检查基础命令

```bash
python3 --version
uname -a
cat /etc/os-release
```

scan-only demo 只需要 `python3` 和内核 `/proc/<pid>/idle_pages` 接口。

swap demo 还需要：

```bash
command -v etmem
command -v etmemd
```

### 1.3 安装或编译 etmem 用户态工具

如果发行版仓库中已有包，优先使用包管理器：

```bash
sudo dnf install -y etmem || sudo yum install -y etmem
```

如果没有包，按 openEuler 官方文档从源码编译：

```bash
sudo yum -y install libboundscheck cmake gcc gcc-c++ make
git clone https://atomgit.com/openeuler/etmem.git
cd etmem
mkdir -p build
cd build
cmake ..
make
```

编译后需要确保 `etmem` 和 `etmemd` 在 `PATH` 中，或把二进制复制到服务器标准路径。

### 1.4 加载内核模块

```bash
sudo modprobe etmem_scan
sudo modprobe etmem_swap
lsmod | grep etmem
```

预期至少看到：

```text
etmem_scan
etmem_swap
```

如果只是跑 `etmem-scan-demo`，只需要 `etmem_scan`。如果跑 `etmem-swap-demo`，两个模块都需要。

### 1.5 检查 swap 后端

swap demo 必须启用 swap：

```bash
swapon --show
grep -E 'SwapTotal|SwapFree' /proc/meminfo
```

如果 `SwapTotal` 为 0，先配置 swap。测试优先使用 zram 或 NVMe swap，避免慢盘把结论变成 IO 抖动。

## 2. 第一阶段：只扫描冷热分布

先跑合成靶进程，确认 scan 链路：

```bash
cd etmem-scan-demo
sudo ./run_etmem_scan_demo.sh
```

更强信号：

```bash
sudo TOTAL_MB=4096 HOT_MB=128 SCAN_INTERVAL_SEC=15 SCAN_SAMPLES=5 ./run_etmem_scan_demo.sh
```

预期现象：

- 输出中 `hot` 接近 `HOT_MB`
- `cold` 接近 `TOTAL_MB - HOT_MB`
- `cold_ratio` 稳定在较高水平
- 生成 summary CSV 和 per-VMA CSV

扫描真实进程：

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

扫描 QEMU / VM 进程可从这个参数组合开始：

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

注意：读取 `idle_pages` 会清 accessed bit。`--warmup` 的作用是先清一次基线，再等待一个观测窗口，后续样本才更接近“这段窗口内谁热、谁冷”。

## 3. 第二阶段：验证冷页换出

回到仓库根目录或进入 swap demo：

```bash
cd ../etmem-swap-demo
sudo ./run_etmem_swap_demo.sh
```

更强信号：

```bash
sudo TOTAL_MB=4096 HOT_MB=128 DURATION_SEC=180 ./run_etmem_swap_demo.sh
```

如果希望按常规习惯把 etmem 配置文件放到 `/etc/etmem`，这样跑：

```bash
sudo CONFIG_DIR=/etc/etmem TOTAL_MB=4096 HOT_MB=128 DURATION_SEC=180 ./run_etmem_swap_demo.sh
```

说明：etmem 官方示例常把配置放在 `/etc/etmem`，但 `etmem obj add -f <config>` 接收的是配置文件路径，并不要求 demo 必须写死到 `/etc/etmem`。本仓库默认把配置写到 `/tmp/etmem-swap-demo.*/`，便于一次运行一个隔离工作目录；使用 `CONFIG_DIR=/etc/etmem` 时，脚本会把生成的 `etmem-demo-slide-<pid>.conf` 放到 `/etc/etmem`。

可选回读验证：

```bash
sudo REFAULT_AFTER=1 ./run_etmem_swap_demo.sh
```

预期通过条件：

- `VmRSS` 明显下降
- `VmSwap` 明显上升
- `MemAvailable` 通常回升
- 脚本输出 `PASS`

输出示例：

```text
before     rss=   1035 MB  vmswap=      0 MB  memavail=  64000 MB  swapfree=   8192 MB
running    rss=    160 MB  vmswap=    875 MB  memavail=  64870 MB  swapfree=   7317 MB
after      rss=    150 MB  vmswap=    885 MB  memavail=  64880 MB  swapfree=   7307 MB

PASS: etmem swapped cold anonymous pages and lowered target resident memory.
```

swap demo 实际执行的 etmem 配置类似这样，脚本运行时也会直接打印：

```ini
[project]
name=demo_slide
loop=3
interval=5
sleep=10
sysmem_threshold=100
swapcache_high_wmark=5
swapcache_low_wmark=3

[engine]
name=slide
project=demo_slide

[task]
project=demo_slide
engine=slide
name=coldmem_demo
type=pid
value=<coldmem_target_pid>
T=1
max_threads=1
swap_threshold=0g
swap_flag=no
```

脚本实际调用的 etmem 命令是：

```bash
etmemd -l 0 -s etmem_demo_<script_pid>
etmem obj add -f <generated_config_file> -s etmem_demo_<script_pid>
etmem project start -n demo_slide -s etmem_demo_<script_pid>
etmem project stop -n demo_slide -s etmem_demo_<script_pid>
etmem obj del -f <generated_config_file> -s etmem_demo_<script_pid>
```

## 4. 第三阶段：迁移到真实实例或 OpenClaw

建议按这个顺序做，不要直接上 swap：

1. 用 `etmem-scan-demo` 扫真实进程或 QEMU PID，观察真实 workload 下的冷热比例。
2. 连续采样至少 5 到 10 个窗口，确认 cold ratio 稳定，而不是业务空闲假象。
3. 同时采集业务指标：QPS/FPS、p50/p95/p99、失败率、模型输出质量。
4. 如果冷数据集中在可接受的匿名缓冲区，再做小流量 swap 验证。
5. 先保守参数，确认没有明显 major fault 尖刺，再逐步扩大换出规模。

真实进程建议采集：

```bash
pid=<PID>
cat /proc/$pid/status | grep -E 'VmRSS|VmSwap'
cat /proc/$pid/smaps_rollup
pidstat -r -u -d -p $pid 5
vmstat 5
```

QEMU / VM 场景额外采集：

```bash
numastat -p <QEMU_PID>
grep -E 'AnonHugePages|Rss|Pss|Swap' /proc/<QEMU_PID>/smaps_rollup
```

## 5. 结果判定

scan-only 阶段通过：

- `/proc/<pid>/idle_pages` 存在
- 合成 demo 能看到接近 `HOT_MB` 的热内存和接近 `TOTAL_MB - HOT_MB` 的冷内存
- 真实进程的 cold ratio 在业务负载期间稳定可解释

swap 阶段通过：

- `/proc/<pid>/swap_pages` 存在
- `etmemd` 能启动，`etmem obj add` 和 `project start` 成功
- 合成 demo 的 `VmRSS` 下降，`VmSwap` 上升
- 可选 `REFAULT_AFTER=1` 后 RSS 能回升，证明换出的页可正常 fault back

真实业务阶段通过：

- 内存收益达到预期，例如 DRAM/RSS 降低 15% 到 30%
- QPS/FPS 下降在可接受范围内
- p95/p99 没有持续尖刺
- `pswpin`、major fault 不在热路径持续增长

## 6. 常见问题

`/proc/<pid>/idle_pages` 不存在：

```bash
sudo modprobe etmem_scan
```

如果仍不存在，说明当前内核不包含 etmem scan 支持，或模块没有随内核安装。

`/proc/<pid>/swap_pages` 不存在：

```bash
sudo modprobe etmem_swap
```

如果仍不存在，无法跑 swap demo，只能做 scan-only 观测。

`command -v etmem` 失败：

先用包管理器安装，或按官方文档源码编译 etmem。

swap demo 没有 `VmSwap` 增长：

- 检查 `swapon --show`
- 检查 `etmem-swap-demo` 输出的 `etmem.log`
- 增大 `TOTAL_MB`
- 增大 `DURATION_SEC`
- 降低业务访问强度，确保目标页真的冷下来

RSS 降了但业务抖动：

- 换用 zram 或 NVMe swap
- 增大观测窗口，只换出更冷的页
- 对真实业务优先考虑 `MADV_SWAPFLAG` 方式标记可换出的内存区域
- 不要直接把模型权重、KV cache 或推理热路径内存纳入换出候选

## 7. 文件结构

```text
.
├── README.md
├── etmem-scan-demo
│   ├── README.md
│   ├── run_etmem_scan_demo.sh
│   └── scan_idle_pages.py
└── etmem-swap-demo
    ├── README.md
    ├── coldmem_target.py
    └── run_etmem_swap_demo.sh
```
