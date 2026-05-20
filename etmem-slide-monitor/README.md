# etmem slide monitor

这个脚本用于 **没有 AEP/SCM，只能使用 etmem `slide`** 的场景。

它会真正启动 etmem：

```text
/etc/etmem config -> etmemd -> etmem obj add -> etmem project start -> slide
```

同时输出监控数据：

- 目标进程 `VmRSS`
- 目标进程 `VmSwap`
- 系统 `MemAvailable`
- 系统 `SwapFree`
- major fault
- 可选冷热占比诊断

## 重要边界

`slide` 官方目标是“扫描冷页并换出”，不是冷热报表 engine。它没有类似 `cslide showtaskpages` 的官方热度报表命令。

所以本脚本分两层：

1. **真正 etmem slide**：负责按配置里的 `loop/interval/T` 扫描并换出冷页。
2. **冷热占比诊断**：默认开启，使用 `etmem_scan` 的 `/proc/<pid>/idle_pages` 按同样 `loop/interval/T` 输出 hot/cold 比例。

为了避免监控脚本默认改变业务内存，`--swap-threshold` 默认是 `999999g`，基本等价于 monitor-first。要主动换出冷页时显式设置：

```bash
--swap-threshold 0g
```

冷热诊断会读取 `idle_pages` 并清 accessed bit，可能轻微影响 slide 自己的扫描判断。做纯换出效果测试时请关闭：

```bash
--show-heat 0
```

## 1. 监控已有 PID

```bash
cd /path/to/etmemDemo/etmem-slide-monitor
sudo ./run_etmem_slide_monitor.sh \
  --pid <PID> \
  --loop 3 \
  --interval 10 \
  --t 2 \
  --sample-interval 30
```

含义：

```text
etmem slide:
  loop=3
  interval=10
  T=2

冷热诊断:
  每个样本也用 loop=3 interval=10 T=2 统计 hot/cold
```

## 2. 由脚本启动目标进程

如果你启动前不知道 PID，让脚本启动命令并自动 attach：

```bash
sudo ./run_etmem_slide_monitor.sh \
  --loop 3 \
  --interval 10 \
  --t 2 \
  --duration 3600 \
  -- /path/to/your_app --arg1 --arg2
```

脚本会：

1. 启动目标进程。
2. 拿到 PID。
3. 生成 `/etc/etmem/etmem-slide-monitor-<pid>-<script_pid>.conf`。
4. 启动 `etmemd`。
5. 加载配置并启动 project。
6. 循环输出监控结果。

## 3. 纯 etmem slide 测量

如果你只想测 etmem slide 换出效果，不想额外冷热诊断干扰 accessed bit：

```bash
sudo ./run_etmem_slide_monitor.sh \
  --pid <PID> \
  --loop 3 \
  --interval 10 \
  --t 2 \
  --show-heat 0
```

此时只输出：

```text
VmRSS / VmSwap / MemAvailable / SwapFree / major fault
```

## 4. 主要参数

```bash
--pid PID                 监控已有进程
--loop N                  etmem project loop，默认 3
--interval SEC            etmem scan interval，默认 10
--t N                     etmem slide 冷页阈值 T，默认 2
--sleep SEC               etmem project sleep，默认 30
--duration SEC            运行多久后停止，0 表示直到目标进程退出或 Ctrl+C
--sample-interval SEC     指标打印间隔，默认 30
--show-heat 0|1           是否输出冷热占比诊断，默认 1
--heat-vma-filter MODE    anon / rw-private / all，默认 all
--heat-min-vma-kb KB      冷热诊断跳过小 VMA，默认 0
--heat-top N              冷热诊断打印最冷前 N 个 VMA，默认 5
--config-dir DIR          etmem 配置目录，默认 /etc/etmem
--project-name NAME       project 名，不填自动生成
--task-name NAME          task 名，不填自动生成
--socket NAME             etmemd socket 名，不填自动生成
--sysmem-threshold N      slide sysmem_threshold，默认 100
--swap-threshold VALUE    slide swap_threshold，默认 999999g；主动换出可设 0g
--swap-flag yes|no        slide swap_flag，默认 no
--max-threads N           slide task max_threads，默认 1
```

## 5. 生成的 etmem 配置

示例：

```ini
[project]
name=slide_monitor_12345
loop=3
interval=10
sleep=30
sysmem_threshold=100
swapcache_high_wmark=5
swapcache_low_wmark=3

[engine]
name=slide
project=slide_monitor_12345

[task]
project=slide_monitor_12345
engine=slide
name=target_12345
type=pid
value=12345
T=2
max_threads=1
swap_threshold=999999g
swap_flag=no
```

主动换出时可以把它改成 `0g` 或其他合适阈值。

实际执行：

```bash
etmemd -l 0 -s <socket>
etmem obj add -f <config> -s <socket>
etmem project start -n <project> -s <socket>
```

## 6. 输出文件

脚本会打印 `workdir`，例如：

```text
/tmp/etmem-slide-monitor.xxxxxx
```

里面包括：

- `metrics.csv`：RSS/Swap/MemAvailable 等指标
- `heat.log`：冷热占比诊断输出
- `heat/*.csv`：每轮冷热诊断 CSV
- `etmem.log`
- `etmemd.log`
- `target.log`
- 生成的 etmem 配置文件
