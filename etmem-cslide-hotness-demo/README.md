# etmem cslide hotness demo

这个 demo 是“真正走 etmem 用户态分析链路”的冷热温观测：

```text
etmemd -> cslide engine -> etmem scan loops -> etmem engine showtaskpages/showhostpages
```

它不是直接读 `/proc/<pid>/idle_pages`。脚本会生成 etmem 配置，启动 `etmemd`，执行 `etmem obj add`、`etmem project start`，然后用 etmem 客户端命令查询目标 task 的页面访问热度。

## 1. 为什么需要这个 demo

`slide` 确实会按访问次数判断冷页：在一个扫描周期内，页面访问次数小于 `T` 就会被认为是冷页，并进入换出候选。但 `slide` 的主要目标是 swap，不是展示热度报表，通用 CLI 没有直接暴露“每个页面访问次数分布”的分析命令。

`cslide` 面向 VM / hugepage / 分级内存场景，提供了 etmem 客户端查询命令：

```bash
etmem engine showtaskpages ...
etmem engine showhostpages ...
```

所以如果你的目标是“用 etmem 分析一个 VM/OpenClaw 实例的冷热温”，优先用这个 demo，而不是 raw `/proc/<pid>/idle_pages` demo。

## 2. 前置条件

目标机需要：

- openEuler etmem-capable kernel
- root 权限
- `etmem` 和 `etmemd`
- `etmem_scan`
- 目标是 VM/QEMU 这类适合 `cslide` 的进程
- VM 内存最好使用 hugepage，`VM_FLAGS` 默认 `ht`
- 已知 `node_pair`

检查：

```bash
command -v etmem
command -v etmemd
sudo modprobe etmem_scan
numactl -H
ps -ef | grep qemu
```

`NODE_PAIR` 是 cslide 的迁移节点对，格式取决于服务器 NUMA/分级内存配置，例如：

```bash
NODE_PAIR=2,0
NODE_PAIR=2,0\;3,1
```

通常写法是 `<慢/冷节点>,<快/热节点>`。如果没有 AEP/PMem 这类分级内存节点，cslide 可能不适合当前服务器；这时只能用 `slide` 换出验证，或使用 raw scan fallback 观察内核扫描结果。

## 3. 运行

最小运行：

```bash
cd /path/to/etmemDemo/etmem-cslide-hotness-demo
sudo TARGET_PID=<QEMU_PID> NODE_PAIR=<AEP_NODE,DRAM_NODE> ./run_etmem_cslide_hotness_demo.sh
```

示例：

```bash
sudo TARGET_PID=12345 NODE_PAIR=2,0 SAMPLES=5 SAMPLE_INTERVAL_SEC=30 ./run_etmem_cslide_hotness_demo.sh
```

为了先分析、不主动迁移，脚本默认：

```bash
NODE_MIG_QUOTA=0
NODE_HOT_RESERVE=0
```

如果你确认要让 cslide 参与迁移，再显式设置：

```bash
sudo TARGET_PID=12345 NODE_PAIR=2,0 NODE_MIG_QUOTA=1024 NODE_HOT_RESERVE=4096 ./run_etmem_cslide_hotness_demo.sh
```

## 4. 脚本生成的 etmem 配置

配置默认写到 `/etc/etmem/etmem-cslide-hotness-<script_pid>.conf`。

示例：

```ini
[project]
name=hotness_probe
loop=3
interval=10
sleep=30

[engine]
name=cslide
project=hotness_probe
node_pair=2,0
hot_threshold=1
node_mig_quota=0
node_hot_reserve=0

[task]
project=hotness_probe
engine=cslide
name=vm_hotness
type=pid
value=12345
vm_flags=ht
anon_only=no
ign_host=no
```

实际执行的 etmem 命令：

```bash
etmemd -l 0 -s etmem_hotness_<script_pid>
etmem obj add -f /etc/etmem/etmem-cslide-hotness-<script_pid>.conf -s etmem_hotness_<script_pid>
etmem project start -n hotness_probe -s etmem_hotness_<script_pid>
etmem engine showtaskpages -t vm_hotness -n hotness_probe -e cslide -s etmem_hotness_<script_pid>
etmem engine showhostpages -n hotness_probe -e cslide -s etmem_hotness_<script_pid>
```

## 5. 参数

```bash
TARGET_PID=                 # 目标 QEMU/VM 进程 PID，必填
NODE_PAIR=                  # cslide 节点对，必填，例如 2,0
PROJECT_NAME=hotness_probe
TASK_NAME=vm_hotness
LOOP=3                      # 每轮扫描次数
INTERVAL=10                 # 单次扫描间隔，秒
SLEEP_SEC=30                # etmem project 轮次间隔
HOT_THRESHOLD=1             # 访问次数达到该值可认为偏热
NODE_MIG_QUOTA=0            # 默认 0，优先只分析不迁移
NODE_HOT_RESERVE=0
VM_FLAGS=ht                 # h: hugepage, t: touch/scan VM style
ANON_ONLY=no
IGN_HOST=no
SAMPLES=5                   # showtaskpages 采样次数
SAMPLE_INTERVAL_SEC=30      # showtaskpages 采样间隔
CONFIG_DIR=/etc/etmem
```

`SAMPLES` 是采样次数，不是页数量。

## 6. 如何看结果

脚本会输出并保存：

- `showtaskpages.log`：etmem 对目标 task 的页面热度/访问情况输出
- `showhostpages.log`：etmem 对 host pages 的输出
- `project-show.log`：project 状态
- `etmem.log`
- `etmemd.log`

用这个结果判断：

- 哪些页面或区间访问次数高，属于 hot
- 哪些页面访问次数低或长期没有访问，属于 cold
- 多个采样窗口之间是否稳定
- 如果 `HOT_THRESHOLD` 提高后仍热，说明热度更强

## 7. 和 raw scan demo 的区别

`etmem-scan-demo` 直接读 `/proc/<pid>/idle_pages`，那是 etmem 的内核扫描接口，适合验证内核能力和做 fallback。但它不经过 `etmemd`，也不使用 etmem project/engine，所以不应被当成完整 etmem 分析流程。

本 demo 才是完整 etmem 分析流程：配置 project/engine/task，由 `etmemd` 执行扫描策略，再用 etmem 客户端命令取结果。

