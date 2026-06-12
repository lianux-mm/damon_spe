---
name: damon-mthp-design
description: DAMON mTHP collapse/split 设计现状、社区顾虑、两阶段策略（collapse 稳 + PMU 深）
metadata:
  node_type: memory
  type: project
  originSessionId: a00e9707-9d64-489c-9ee3-861e0ec329f8
---

DAMON mTHP collapse/split 当前在 `damon_dev` 分支。

**两阶段策略 (2026-06-04)**：

Phase 1 — collapse-only series (3 patches)，论证完整、有 benchmark 数据，独立可合入：
- patch 1: DAMOS_MTHP_COLLAPSE action + target_order (damon.h, sysfs-schemes.c)
- patch 2: khugepaged wrapper (khugepaged.c)
- patch 3: vaddr collapse 实现 (vaddr.c)
- 已修复: sysfs target_order 校验 (非 PMD order 时 warn + reset)
- 已修复: `damos_va_collapse()` 死锁——移除外部 mmap_read_lock/unlock

Phase 2 — PMU 辅助监测 (ARM SPE)，原型验证，解决 split 精度问题：
- ARMv8.2+ SPE 提供 per-instruction VA/PA 采样
- 不替代 page table walking，作为第二数据源在聚合阶段叠加 sub-THP 直方图
- 最小原型: userspace spe_probe.c → perf_event_open arm_spe → 构建直方图 → 验证可行性
- 有 ARM 服务器可用，先 userspace 再内核集成
- 目标: 用实测数据向社区论证 split 的前进路径

**实测收益数据**: 256MB anon 随机访问 60s, ARM64 VM:
- DAMON madvise +43.8% throughput vs baseline, +8.9% vs always-mode
- 全量 collapse 在 ~2.5s 内完成

**VM 测试状态 (2026-06-12)**：
- ARM64 VMware VM root@172.16.213.132, kernel 7.1.0-rc5+ build #21
- **mthp_split 验证成功**: target_order=2 (16KB), AnonHugePages 67584kB→0kB, nr_applied=11, sz_applied=73400320, 16kB nr_anon: 0→4224
- **collapse 死锁已修复**: `damos_va_collapse()` 中 `mmap_read_lock`/`mmap_read_unlock` 与 `collapse_huge_page()` 内部 `mmap_write_lock` 形成 rwsem 自死锁——已移除外部锁，collapse_huge_page() 自管锁
- **collapse 验证成功**: nr_applied=10, sz_applied=69206016, 16kB nr_anon: 4224→0, 2048kB: 381→414, AnonHugePages→67584kB
- **Split→Collapse 完整回环通过**: 先 split PMD→16KB mTHP，再 collapse→PMD THP，AnonHugePages 67584→0→67584
- 修复: sysfs-schemes.c target_order 校验——原逻辑对 collapse 和 split 都要求 PMD order，改为 split 允许 < PMD order
- **关键配置陷阱**: access_pattern/sz/max 默认 0，导致所有 region 通不过 size check，必须手动设为 UINT64_MAX
- **内核安装陷阱**: `make install` 版本号不变时跳过复制，需手动 `cp arch/arm64/boot/Image /boot/vmlinuz-...`
- CONFIG_DAMON_SPE 未启用（VM 无 ARM SPE 硬件）→ damon_spe_hot_fraction 返回 -EOPNOTSUPP → 无条件 split
- AnonHugePages 归零是因为 split 到 order-2 后不再是 PMD-mapped，需确认实际的 16KB mTHP 是否已分配

**SPE 设计 (2026-06-12)**：

数据流：
```
应用 load/store → ARM SPE 采样(N ops) → SPE trace buffer(AUX)
  → 解码 {va, pa, access_type, pid} → 子页直方图 {THP-PFN → count[512]}
    → damon_spe_folio_heatmap(folio) → 热点 bitmap → DAMON split 决策
```

SPE config (perf_event_attr, 来自 drivers/perf/arm_spe_pmu.c):
- attr.config bit 1: pa_enable (物理地址——核心)
- attr.config bit 2: pct_enable (PID上下文)
- attr.config bit 32: branch_filter (1=排除分支)
- attr.config bit 33: load_filter (0=包含load)
- attr.config bit 34: store_filter (0=包含store)
- attr.sample_period: 采样间隔 (如 1024 = 每1024次ld/st采样一次)
- 模式: PERF_PMU_CAP_ITRACE (AUX buffer, 非简单采样)

SPE 数据包类型 (tools/perf/util/arm-spe-decoder/arm-spe-pkt-decoder.h):
- ARM_SPE_ADDRESS: 含 DATA_VIRT(index 2) 和 DATA_PHYS(index 3)
- ARM_SPE_OP_TYPE: load/store 类型
- ARM_SPE_CONTEXT: PID/CID
- ARM_SPE_EVENTS: TLB miss, cache miss 等
- ARM_SPE_DATA_SOURCE: 缓存层级

两阶段实施:
1. **Userspace 验证 (Phase 2a)**: spe_probe.c 用 perf_event_open + AUX mmap 采集→解码→构建直方图，服务器上零风险验证
2. **内核集成 (Phase 2b)**: perf_event_create_kernel_counter() 创建内核 SPE event，overflow handler 聚合样本到 PFN-rbtree，damon_spe_folio_heatmap() 查询

核心数据结构:
```c
struct damon_spe_folio_entry {
    struct rb_node node;
    unsigned long pfn;           // THP-aligned PFN (key)
    pid_t pid;
    unsigned long *access_count; // count[512] per 4KB subpage
    unsigned long total;
    u64 last_update;             // jiffies for aging/eviction
};
struct rb_root spe_hist_tree;    // per-CPU or per-mm
spinlock_t spe_hist_lock;
```

安全设计:
- 所有内核 SPE 代码在 CONFIG_DAMON_SPE 下，不配不编
- 每个函数有 graceful fallback → -EOPNOTSUPP
- 服务器测试先 userspace（零内核改动，不会卡死）
- SPE PMU 独占 (PERF_PMU_CAP_EXCLUSIVE)，同一 CPU 只能一个 event

**已知问题**：
- khugepaged 与 DAMON 之间存在 split/collapse ping-pong（测试期间 thp_split_pmd 和 thp_collapse_alloc 同时增长）
- SPE 采样精度与 sample_period 的 tradeoff：间隔太小→overhead 大，间隔太大→冷热区分精度下降

**Patch 导出状态 (2026-06-12)**：
- 分支: `damon_mthp_v2` (8 patches)
- 导出路径: `/tmp/patches/` (cover letter + 8 patches + tools + TEST_METHODOLOGY.md)
- 中英双语测试方法文档 + 3 个 userspace 工具 + 自动化测试脚本
- 服务器测试: 等同事提供 Kunpeng 920 访问后，运行 `spe_test.sh 30`

**Why**: DAMON mTHP 是 DAMON 从"监测"走向"监测+控制"的关键一步。Collapse 走稳（合入主线），PMU 走深（ARM 验证），两步独立、互相支撑。
**How to apply**: 修改 damon mTHP 代码或讨论合入策略时参考此分析和报告第十七/十八章。
