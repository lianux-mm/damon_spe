# DAMON mTHP Collapse/Split 测试方法 / Test Methodology

## 目录 / Table of Contents

1. [内核编译 / Kernel Build](#1-内核编译)
2. [VM 功能测试 / VM Functional Test](#2-vm-功能测试)
3. [ARM SPE 子页热点测试 / SPE Sub-Page Heatmap Test](#3-spe-子页热点测试)
4. [Debugfs 数据管道测试 / Debugfs Feed Test](#4-debugfs-数据管道测试)
5. [注意事项 / Pitfalls](#5-注意事项)

---

## 1. 内核编译 / Kernel Build

```bash
# Patch 基于 mm-unstable 或 mainline 6.15+
# Patches apply on mm-unstable or mainline 6.15+

cd linux
git am /path/to/patches/*.patch

# 开启必要配置 / Enable required configs
make defconfig
scripts/config -e CONFIG_DAMON -e CONFIG_DAMON_VADDR -e CONFIG_DAMON_SYSFS \
               -e CONFIG_TRANSPARENT_HUGEPAGE -e CONFIG_TRANSPARENT_HUGEPAGE_MTHP \
               -e CONFIG_DAMON_SPE    # SPE 反馈，可选
make olddefconfig
make -j$(nproc) Image

# ARM64 安装 / Install
cp arch/arm64/boot/Image /boot/vmlinuz-$(make kernelrelease)
reboot
```

## 2. VM 功能测试 / VM Functional Test

### 目标 / Goal
验证 collapse 和 split 动作正确执行，split→collapse 回环完整，无死锁。
Verify collapse and split actions, full round-trip, no deadlocks.

### 2.1 测试程序 / Test Workload

创建文件 `thp_test.c`，编译 `gcc -O2 -o thp_test thp_test.c`：

```c
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>
#include <signal.h>
#define SZ (64UL*1024*1024)    // 64MB anon memory
#define AL (2UL*1024*1024)     // 2MB alignment buffer
volatile int k=1;
void h(int s){k=0;}
int main(void){
    signal(SIGTERM,h);signal(SIGINT,h);
    char *b=mmap(NULL,SZ+AL,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0);
    unsigned long p=(SZ+AL)/4096,i;
    for(i=0;i<p;i++)b[i*4096]=(char)i;           // touch every page
    printf("PID=%d\n",getpid());fflush(stdout);
    madvise(b,SZ+AL,MADV_HUGEPAGE);              // ask khugepaged to make THPs
    while(k){volatile unsigned long s=0;for(i=0;i<p;i+=8)s+=(unsigned char)b[i*4096];usleep(500000);}
    return 0;
}
```

行为说明 / Behavior: 分配 64MB 匿名内存，逐页 touch，MADV_HUGEPAGE 让 khugepaged 提升为 PMD THP，循环访问保持热度。
Allocate 64MB anon, touch all pages, let khugepaged promote to PMD THPs, keep accessing.

### 2.2 Split 测试 / Split Test

**目的**: 将 PMD-mapped THP (2048KB) 拆分为 16KB mTHP
**Goal**: Split PMD THPs (2048KB) into 16KB mTHPs

```bash
# Terminal 1: 启动测试程序 / Start workload
./thp_test &
PID=$!

# Terminal 2: 配置 DAMON split scheme / Set up DAMON split

# 环境变量 / Shortcuts
THP_STATS=/sys/kernel/mm/transparent_hugepage/hugepages

# 清理旧配置 / Cleanup previous config
echo 0 > /sys/kernel/mm/damon/admin/kdamonds/nr_kdamonds 2>/dev/null
sleep 1

# 获取测试程序的内存区域地址 / Get the anon region address
ANON_ADDR=$(grep -B1 'Size:.*[0-9][0-9][0-9][0-9][0-9]' /proc/$PID/smaps | head -1 | awk '{print $1}' | sed 's/-.*//')
ANON_END=$(grep -B1 'Size:.*[0-9][0-9][0-9][0-9][0-9]' /proc/$PID/smaps | head -1 | awk '{print $1}' | sed 's/.*-//')
echo "Region: $ANON_ADDR - $ANON_END"

# 创建 kdamond / Create kdamond
echo 1 > /sys/kernel/mm/damon/admin/kdamonds/nr_kdamonds
D=/sys/kernel/mm/damon/admin/kdamonds/0
echo 1000 > $D/refresh_ms
echo 1 > $D/contexts/nr_contexts
C=$D/contexts/0
echo fvaddr > $C/operations

# 监控间隔 / Monitoring intervals
echo 5000   > $C/monitoring_attrs/intervals/sample_us
echo 100000 > $C/monitoring_attrs/intervals/aggr_us
echo 1000000 > $C/monitoring_attrs/intervals/update_us
echo 10  > $C/monitoring_attrs/nr_regions/min
echo 200 > $C/monitoring_attrs/nr_regions/max

# 目标进程 / Target
echo 1 > $C/targets/nr_targets
echo $PID > $C/targets/0/pid_target

# 监控区域 / Region (use actual addresses from smaps)
echo 1  > $C/targets/0/regions/nr_regions
echo "0x${ANON_ADDR}" > $C/targets/0/regions/0/start
echo "0x${ANON_END}" > $C/targets/0/regions/0/end

# Scheme: split to order-2 (16KB)
echo 1 > $C/schemes/nr_schemes
S=$C/schemes/0
echo mthp_split > $S/action
echo 2 > $S/target_order                    # 2 -> 16KB

# 【关键】sz/max 必须设为最大值，否则 region 通不过 size check!
# [CRITICAL] sz/max defaults to 0, must be max!
echo 0     > $S/access_pattern/sz/min
echo 18446744073709551615 > $S/access_pattern/sz/max
echo 0     > $S/access_pattern/nr_accesses/min
echo 65535 > $S/access_pattern/nr_accesses/max
echo 0     > $S/access_pattern/age/min
echo 65535 > $S/access_pattern/age/max

# 记录测试前数据 / Record before stats
echo "=== Before split ==="
echo "2048kB THPs: $(cat $THP_STATS/2048kB/stats/nr_anon)"
echo "16kB mTHPs:  $(cat $THP_STATS/16kB/stats/nr_anon)"

# 启动 DAMON / Start DAMON
echo on > $D/state
echo "DAMON running..."
sleep 15        # 等待聚合和动作 / Wait for aggregation + action
echo off > $D/state

# 验证结果 / Verify
echo "=== After split ==="
echo "2048kB THPs: $(cat $THP_STATS/2048kB/stats/nr_anon)"
echo "16kB mTHPs:  $(cat $THP_STATS/16kB/stats/nr_anon)"
echo "nr_tried:    $(cat $S/stats/nr_tried)"
echo "sz_tried:    $(cat $S/stats/sz_tried)"
echo "nr_applied:  $(cat $S/stats/nr_applied)"
echo "sz_applied:  $(cat $S/stats/sz_applied)"

# 预期结果 / Expected:
#   2048kB THPs: 减少 ~33
#   16kB mTHPs:  增加 ~4224 (33 * 128 = 4224)
#   nr_applied:  ~11
#   sz_applied:  ~70MB
```

### 2.3 Collapse 测试 / Collapse Test

**目的**: 将 16KB mTHP 重新聚合为 PMD THP，验证无死锁
**Goal**: Collapse 16KB mTHPs back to PMD THPs, verify no deadlock

```bash
# 紧接 split 测试后 / Right after split test

# 切换 scheme 为 collapse / Change scheme to collapse
echo collapse > $S/action
echo 9 > $S/target_order    # 9 -> 2MB PMD

echo "=== Before collapse ==="
echo "2048kB THPs: $(cat $THP_STATS/2048kB/stats/nr_anon)"
echo "16kB mTHPs:  $(cat $THP_STATS/16kB/stats/nr_anon)"

echo on > $D/state
echo "DAMON collapse running..."
sleep 20
echo off > $D/state

echo "=== After collapse ==="
echo "2048kB THPs: $(cat $THP_STATS/2048kB/stats/nr_anon)"
echo "16kB mTHPs:  $(cat $THP_STATS/16kB/stats/nr_anon)"
echo "nr_applied:  $(cat $S/stats/nr_applied)"
echo "sz_applied:  $(cat $S/stats/sz_applied)"

# 预期结果 / Expected:
#   2048kB THPs: 恢复到原始值
#   16kB mTHPs:  0
#   nr_applied:  ~10
#   sz_applied:  ~66MB
#   【重要】系统无死锁、无崩溃

# 验证 AnonHugePages / Verify in smaps
cat /proc/$PID/smaps | grep -A1 'Size:.*67584' | grep AnonHuge
# 应输出: AnonHugePages:     67584 kB

# 清理 / Cleanup
kill $PID
echo 0 > /sys/kernel/mm/damon/admin/kdamonds/nr_kdamonds
```

### 2.4 回环验证汇总 / Round-Trip Summary

| 阶段 / Phase | 2048kB THP | 16kB mTHP | AnonHugePages | nr_applied |
|-------------|------------|-----------|---------------|-----------|
| workload 开始后 | ~400 | 0 | 67584 kB | — |
| Split 后 | -33 | +4224 | 0 kB | ~11 |
| Collapse 后 | +33 | -4224 | 67584 kB | ~10 |

## 3. SPE 子页热点测试 / SPE Sub-Page Heatmap Test

### 前提条件 / Prerequisites

- ARMv8.2+ CPU 含 SPE (如 Kunpeng 920, Ampere Altra, AWS Graviton3)
- 内核: `CONFIG_ARM_SPE_PMU=y`
- Perf: `perf version` >= 5.10，支持 arm_spe
- `perf_event_paranoid` <= 0 或 root 权限

### 3.1 工具编译 / Build Tools

```bash
# 拷贝到 ARM 服务器 / Copy to ARM server
scp spe_hist.c hot_workload.c spe_test.sh user@arm-server:/tmp/

# 编译 / Compile
ssh user@arm-server "gcc -O2 -o /tmp/spe_hist /tmp/spe_hist.c"
ssh user@arm-server "gcc -O2 -o /tmp/hot_workload /tmp/hot_workload.c"
```

### 3.2 自动化测试 / Automated Test

```bash
# 一键运行，默认 15 秒
# One-shot test, default 15s
ssh user@arm-server "sudo /tmp/spe_test.sh 30"
```

输出解读 / Output interpretation:
- 热力图的 `#` 应集中在前 25% 区域（与工作负载匹配）
- 冷区域显示为 `.`
- 符合预期模式: `##......` (热点在前)

### 3.3 手动测试 / Manual Test

```bash
# Terminal 1: 受控工作负载 / Controlled workload
# 只访问每个 THP 的前 25% 子页
# Only touch first 25% of subpages in each THP
./hot_workload 120 25 &
WL_PID=$!
echo "Workload PID: $WL_PID"

# 等 khugepaged 提升为 THP / Wait for THP promotion
sleep 5
grep AnonHuge /proc/$WL_PID/smaps | head -3

# Terminal 2: 采集 SPE 数据 / Collect SPE samples
# pa_enable=1  : 记录物理地址 / record physical address
# load_filter=0: 包含 load  / include loads
# store_filter=0: 包含 store / include stores
# branch_filter=1: 排除分支 / exclude branches
perf record \
  -e arm_spe/pa_enable=1,load_filter=0,store_filter=0,branch_filter=1/ \
  -p $WL_PID \
  -o /tmp/spe.data \
  -- sleep 60

# 检查采集结果 / Check collection
ls -lh /tmp/spe.data

# 解码并构建直方图 / Decode and build histogram
perf script -i /tmp/spe.data -F phys_addr,event,pid 2>/dev/null | /tmp/spe_hist

# 预期输出 / Expected output:
#   heatmap: ########........................
#   热点集中在每个 THP 的前 25% 子页
#   Hot pages concentrated in first ~25% of each THP

# 查看原始 SPE 记录 / View raw SPE records
perf script -i /tmp/spe.data -F phys_addr,event,pid 2>/dev/null | head -30
```

### 3.4 验证标准 / Verification Criteria

- SPE 热力图热点集中在 THP 前 ~25% (匹配 workload 行为)
- 物理地址捕获正确 (非零，范围合理)
- perf 无错误或警告
- CPU overhead <5% (sample_period=1024 时)
- SPE 采样间隔为 1024 次 ld/st 操作时，60 秒内至少采集到数千条记录

## 4. Debugfs 数据管道测试 / Debugfs Feed Test

### 目的 / Goal
验证 userspace SPE daemon → kernel rbtree → split decision 的完整数据管线。
Verify the full Phase 2b data pipeline.

### 4.1 检查 debugfs 接口

```bash
# 确认 debugfs 已挂载 / Ensure debugfs mounted
mount | grep debugfs
# 如果没有: mount -t debugfs none /sys/kernel/debug

# 检查 DAMON SPE 接口 / Check SPE interface
ls /sys/kernel/debug/damon/
# 应输出 / Should show: spe_feed  spe_stats

# 查看当前统计 / View stats
cat /sys/kernel/debug/damon/spe_stats
# 初始为空 / Initially empty: nr_entries=0 total_accesses=0
```

### 4.2 模拟数据注入 / Inject Simulated Data

```bash
# 模拟 128 次对 PFN 0x100000 的访问 (THP 的前 1/4 子页)
# Simulate 128 accesses to PFN 0x100000 (first 1/4 subpages of a THP)
for i in $(seq 0 127); do
    echo $((0x100000 + i * 1)) > /sys/kernel/debug/damon/spe_feed
done

# 模拟 256 次对 PFN 0x200000 的访问 (前 1/2 子页)
# Simulate 256 accesses to a different THP
for i in $(seq 0 255); do
    echo $((0x200000 + i * 1)) > /sys/kernel/debug/damon/spe_feed
done

# 查看统计 / Check stats
cat /sys/kernel/debug/damon/spe_stats
# 预期 / Expected:
#   nr_entries=2 total_accesses=384
#   pfn=0x100000 total=128 hot_pages=128/512
#   pfn=0x200000 total=256 hot_pages=256/512
```

### 4.3 完整管线验证 / Full Pipeline

```bash
# 场景: 运行 DAMON split scheme + SPE daemon 喂数据
# Scenario: DAMON split scheme + SPE daemon feeding data

# 1. 启动 workload 和 DAMON split scheme (同 2.2)
#    Start workload and DAMON split scheme (same as 2.2)

# 2. 同时运行: SPE daemon 采集并喂数据
#    Concurrently: SPE daemon collects and feeds data
#    (在有 SPE 硬件的服务器上)
#    (On server with SPE hardware)
perf record -e arm_spe/pa_enable=1,load_filter=0,store_filter=0/ \
    -p $PID -o - -- sleep 30 | \
  perf script -i - -F phys_addr 2>/dev/null | \
  while read pfn; do
      echo $pfn > /sys/kernel/debug/damon/spe_feed
  done

# 3. DAMON split 决策将使用真实的子页热图
#    DAMON split decisions will use actual sub-page heatmap
#    不再是无条件 split，而是基于 SPE 数据的智能决策

# 4. 验证 / Verify
cat /sys/kernel/debug/damon/spe_stats
cat $S/stats/nr_applied
# nr_applied 应该比无条件模式少（只有真正冷的 THP 才被拆分）
```

## 5. 注意事项 / Pitfalls

| 陷阱 / Pitfall | 说明 / Description | 解决 / Fix |
|---------------|-------------------|-----------|
| **sz/max 默认为 0** | DAMON scheme 的 access_pattern/sz/max 默认为 0，导致所有 region 通不过 size check，`nr_tried=0` | 必须设为 18446744073709551615 (UINT64_MAX) |
| **内核未更新** | `make install` 在 LOCALVERSION 不变时跳过复制 | 手动 `cp arch/arm64/boot/Image /boot/vmlinuz-$(uname -r)` |
| **Region 地址** | DAMON 监控区域必须匹配实际进程地址空间 | 从 `/proc/$PID/smaps` 动态获取，勿硬编码 |
| **ASLR** | 每次运行时 mmap 地址不同 | 测试脚本每次动态获取地址 |
| **THP mode** | `never` 模式不会分配 THP | 设为 `madvise`，workload 使用 `MADV_HUGEPAGE` |
| **khugepaged 乒乓** | khugepaged 会重新聚合 DAMON 刚拆分的 mTHP | disable: `echo 0 > /sys/kernel/mm/transparent_hugepage/khugepaged/defrag` |
| **SPE 独占** | SPE PMU 同一个 CPU 只能开一个 event | 测试时关闭其他 perf 进程 |
| **服务器安全** | 内核改动可能导致死锁/panic | **先在 VM 验证**，SPE 在 userspace 验证后再内核集成 |

---

## 附录: 文件清单 / Appendix: File Inventory

### 用户空间工具 / Userspace Tools
- `spe_hist.c` — SPE 直方图构建工具 / SPE histogram builder
- `hot_workload.c` — 受控子页访问测试 / Controlled subpage access test
- `spe_test.sh` — 自动化 SPE 测试脚本 / Automated SPE test script
- `TEST_METHODOLOGY.md` — 本文档 / This document

### 内核 Patch / Kernel Patches
- `0001` — DAMOS_COLLAPSE target_order
- `0002` — khugepaged damon_collapse_folio_range()
- `0003` — vaddr collapse 实现
- `0004` — DAMOS_MTHP_SPLIT action
- `0005` — vaddr split 实现
- `0006` — SPE 反馈原型 (PTE)
- `0007` — collapse 死锁修复 + sysfs 校验修复
- `0008` — SPE rbtree 直方图 + debugfs 接口

### 服务器测试脚本 / Server Test Scripts
- 拷贝到 ARM 服务器 `/tmp/` 目录
- 运行 `sudo ./spe_test.sh 30`
- 验证 SPE 热力图模式是否正确
