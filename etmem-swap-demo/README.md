# etmem swap cold-page demo

这个 demo 用 openEuler etmem `slide` 策略做最小换出验证：

```text
冷匿名页 -> etmem scan -> etmem swap -> 进程 VmRSS 下降
```

它会启动一个合成靶进程，分配匿名内存，只持续触碰一小段热内存，其余页面保持冷。随后启动 `etmemd`，通过 `slide` 将冷页换出到 swap。

和 scan-only demo 不同，这个 demo 会真正生成 etmem 配置，并调用 `etmemd` / `etmem`。默认配置文件放在 `/tmp/etmem-swap-demo.*/`，也可以用 `CONFIG_DIR=/etc/etmem` 放到标准目录。

## 1. 前置条件

目标机需要：

- openEuler etmem-capable kernel
- root 权限
- `python3`
- `etmem` 和 `etmemd`
- `etmem_scan` 和 `etmem_swap`
- 已启用 swap

检查：

```bash
command -v etmem
command -v etmemd
sudo modprobe etmem_scan
sudo modprobe etmem_swap
lsmod | grep etmem
swapon --show
grep -E 'SwapTotal|SwapFree' /proc/meminfo
```

如果 `SwapTotal` 为 0，先启用 swap。测试建议用 zram 或 NVMe swap。

## 2. 运行

```bash
cd /path/to/etmemDemo/etmem-swap-demo
sudo ./run_etmem_swap_demo.sh
```

更强信号：

```bash
sudo TOTAL_MB=4096 HOT_MB=128 DURATION_SEC=180 ./run_etmem_swap_demo.sh
```

使用 `/etc/etmem` 保存本次生成的配置：

```bash
sudo CONFIG_DIR=/etc/etmem TOTAL_MB=4096 HOT_MB=128 DURATION_SEC=180 ./run_etmem_swap_demo.sh
```

说明：etmem 官方示例通常把配置放在 `/etc/etmem`，但 `etmem obj add -f <config>` 接收的是配置文件路径。为了让每次 demo 互相隔离，脚本默认写到 `/tmp/etmem-swap-demo.*/`；如果你希望按标准目录留档，设置 `CONFIG_DIR=/etc/etmem` 即可。

可选 refault 验证：

```bash
sudo REFAULT_AFTER=1 ./run_etmem_swap_demo.sh
```

`REFAULT_AFTER=1` 会在 etmem 停止后给靶进程发 `SIGUSR1`，让它重新触碰全部内存。此时 RSS 应该回升，用来证明被换出的页可以正常 fault back。

## 3. 脚本做了什么

`run_etmem_swap_demo.sh` 会：

1. 创建 `/tmp/etmem-swap-demo.*` 工作目录。
2. 启动 `coldmem_target.py`，默认分配 1024 MB 匿名内存。
3. 等待靶进程触碰全部页面并进入稳定热循环。
4. 生成 etmem `slide` 配置文件。
5. 启动 `etmemd`。
6. 执行 `etmem obj add` 和 `etmem project start`。
7. 周期采样目标进程的 `VmRSS`、`VmSwap`、系统 `MemAvailable`、`SwapFree` 和 major fault。
8. 默认在每次采样前额外展示一次 scan snapshot，包括 hot/cold/present/coverage/top VMA。
9. 停止 etmem project，输出 PASS/FAIL。

工作目录中会保留：

- `metrics.csv`
- `scan.log`
- `scan/*.csv`
- `etmem-demo-slide-<script_pid>.conf`
- `etmem.log`
- `etmemd.log`
- `coldmem_target.log`

脚本运行时会打印生成的配置文件路径和完整配置内容。

配置示例：

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

实际调用的 etmem 命令：

```bash
etmemd -l 0 -s etmem_demo_<script_pid>
etmem obj add -f <generated_config_file> -s etmem_demo_<script_pid>
etmem project start -n demo_slide -s etmem_demo_<script_pid>
etmem project stop -n demo_slide -s etmem_demo_<script_pid>
etmem obj del -f <generated_config_file> -s etmem_demo_<script_pid>
```

## 4. 主要参数

```bash
TOTAL_MB=1024              # 靶进程总匿名内存
HOT_MB=64                  # 持续触碰的热内存
DURATION_SEC=120           # etmem 运行时长
SAMPLE_INTERVAL_SEC=5      # 采样间隔
SHOW_SCAN=1                # 每次采样展示一次 scan snapshot；设为 0 可关闭
SCAN_TOP=5                 # scan snapshot 展示最冷的前 N 个 VMA
SCAN_PRIME_SEC=5           # before 采样前先清 accessed bit 并等待的秒数
ETMEM_LOOP=3               # slide 每轮扫描次数
ETMEM_INTERVAL=5           # slide 扫描间隔
ETMEM_SLEEP=10             # slide 轮次间 sleep
ETMEM_T=1                  # 冷页阈值
ETMEM_MAX_THREADS=1        # etmem task 线程数
ETMEM_SWAP_THRESHOLD=0g    # 进程阈值，demo 设为容易触发
REFAULT_AFTER=0            # 是否做回读验证
CONFIG_DIR=/tmp/...        # etmem 配置目录；可设为 /etc/etmem
```

示例：

```bash
sudo TOTAL_MB=2048 HOT_MB=128 ETMEM_T=1 DURATION_SEC=180 ./run_etmem_swap_demo.sh
```

如果只想看 etmem 换出结果，不想让额外 scan snapshot 干扰 etmem 的 accessed-bit 统计：

```bash
sudo SHOW_SCAN=0 ./run_etmem_swap_demo.sh
```

## 5. 通过标准

脚本内置的基础通过标准：

- RSS drop 至少达到 `HOT_MB`
- `VmSwap` growth 至少达到 `HOT_MB`

更适合写报告的标准：

- RSS 下降达到 `TOTAL_MB - HOT_MB` 的 30% 以上
- `VmSwap` 增长和 RSS 下降同量级
- `MemAvailable` 有可解释回升
- 热循环期间 major fault 没有持续尖刺

预期输出：

```text
priming scan window: clear accessed bits, then wait 5s

scan snapshot before 'before' sample:
sample=1 elapsed=0.1s hot=64.0MB cold=960.0MB other=0.0MB holes=0.0MB present=1024.0MB scanned_vma_rss=1035.0MB scan_rss_ratio=98.9% process_rss=1035.0MB process_coverage=98.9% swap=0.0MB majflt=0
  cold_ratio=93.8% (cold / scanned present pages)
before     rss=   1035 MB  vmswap=      0 MB  memavail=  64000 MB  swapfree=   8192 MB  majflt=0

scan snapshot before 'running' sample:
sample=1 elapsed=0.1s hot=64.0MB cold=640.0MB other=0.0MB holes=320.0MB present=704.0MB scanned_vma_rss=715.0MB scan_rss_ratio=98.5% process_rss=715.0MB process_coverage=98.5% swap=320.0MB majflt=0
  cold_ratio=90.9% (cold / scanned present pages)
running    rss=    715 MB  vmswap=    320 MB  memavail=  64320 MB  swapfree=   7872 MB  majflt=0

scan snapshot before 'after' sample:
sample=1 elapsed=0.1s hot=64.0MB cold=80.0MB other=0.0MB holes=880.0MB present=144.0MB scanned_vma_rss=151.0MB scan_rss_ratio=95.4% process_rss=151.0MB process_coverage=95.4% swap=884.0MB majflt=0
  cold_ratio=55.6% (cold / scanned present pages)
after      rss=    151 MB  vmswap=    884 MB  memavail=  64880 MB  swapfree=   7308 MB  majflt=0

PASS: etmem swapped cold anonymous pages and lowered target resident memory.
```

注意：scan snapshot 通过读取 `/proc/<pid>/idle_pages` 展示当前窗口冷热分布，这个读取动作会清 accessed bit。它适合 demo 解释过程；做纯 etmem 效果测量时建议设置 `SHOW_SCAN=0`。

## 6. 和真实业务的关系

这个 demo 只证明 etmem 冷页换出链路可用，不证明真实业务安全。

迁移到 OpenClaw / VM 前建议：

1. 先用 `etmem-scan-demo` 观测真实进程或 QEMU PID 的冷热分布。
2. 在真实流量下连续采样，确认 cold ratio 稳定。
3. 小规模开启 swap 验证。
4. 同时观察业务 QPS/FPS、p95/p99、失败率、major fault、`pswpin/pswpout`。
5. 如果 p99 或 major fault 抖动明显，降低换出强度或只对业务标记的可换出区域做处理。

## 7. 常见问题

`missing command(s): etmem etmemd`：

安装 etmem 包，或从 openEuler etmem 源码编译。

`no swap is enabled`：

开启 zram 或 NVMe swap 后重试。

`/proc/<pid>/idle_pages is missing`：

```bash
sudo modprobe etmem_scan
```

`/proc/<pid>/swap_pages is missing`：

```bash
sudo modprobe etmem_swap
```

`etmem obj add failed`：

- 看脚本输出的 `etmem.log`
- 确认配置文件属主是 root，权限是 `600`
- 确认 `etmemd` 已启动
- 确认当前 etmem 版本支持 `slide` 配置项

没有明显 `VmSwap` 增长：

- 增大 `TOTAL_MB`
- 延长 `DURATION_SEC`
- 确认靶进程没有持续触碰全部内存
- 检查 `ETMEM_T`、`ETMEM_INTERVAL`、`ETMEM_SLEEP`
- 查看 `etmemd.log`

RSS 降了但系统性能变差：

- swap 后端可能太慢
- 换出强度过高
- 真实业务热页被误换出
- 先回到 scan-only 阶段，确认冷热窗口
