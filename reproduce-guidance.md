# Reproducible Demonstration

The issue can be reproduced reliably with three progressive experiments:

| Step                          | WSS    | L2 TLB Coverage   | nr_tried (min=1) | Result                                 |
| ----------------------------- | ------ | ----------------- | ---------------- | -------------------------------------- |
| A. THP=always, small workload | 512 MB | 100% (blind spot) | 0/24             | DAMON completely blind                 |
| B. THP=never, small workload  | 512 MB | 0.2%              | 20/20            | DAMON works normally                   |
| C. THP=always, large workload | 16 GB  | 25%               | 20/20            | Larger scale eliminates the blind spot |

Step A is the key demonstration: on ARM64, the issue appears whenever the working set fits entirely within the L2 TLB reach.

---

# Reproduction Guide

## 1. Background

DAMON monitors memory access patterns by sampling the page-table Accessed Flag (AF). However, AF update behavior differs fundamentally between x86 and ARM64:

|                   | x86                      | ARM64                                        |
| ----------------- | ------------------------ | -------------------------------------------- |
| AF update trigger | Every memory access      | TLB miss (page-table walk) only              |
| TLB hit behavior  | AF updated automatically | AF not updated                               |
| Impact on DAMON   | None                     | DAMON becomes blind when the WSS fits in TLB |

With THP (2 MB pages), a single PMD entry covers 2 MB, drastically reducing the number of required TLB entries. If the number of PMD entries in the working set is smaller than the L2 TLB capacity, all accesses become TLB hits. Hardware never re-sets the AF bit, causing DAMON to observe no accesses.

---

## 2. Prerequisites

Kernel configuration:

* `CONFIG_DAMON=y`
* `CONFIG_DAMON_VADDR=y`
* `CONFIG_DAMON_SYSFS=y`
* `CONFIG_TRANSPARENT_HUGEPAGE=y`

Root privileges are required for sysfs operations.

Verify availability:

```bash
ls /sys/kernel/mm/damon/admin/kdamonds/
cat /sys/kernel/mm/transparent_hugepage/enabled
# Expected: [always] madvise never
```

---

## 3. Determine Your L2 TLB Capacity

This is the most important step because TLB capacity varies significantly across ARM64 CPUs.

### Method A: Linus's test-tlb Tool (Recommended)

```bash
git clone https://github.com/torvalds/test-tlb
cd test-tlb
make

./test-tlb -H
./test-tlb -l 4096 -s $((4*1024*1024)) -e $((256*1024*1024))
```

Increase the stride size and identify the latency jump. The jump point corresponds to:

```text
TLB reach = TLB entries × page size
```

Example (Kunpeng 920):

* ~2048 L2 D-TLB entries
* 4 KB pages → ~8 MB reach
* 2 MB THP pages → ~4 GB reach

### Method B: Quick Approximation

```bash
cat /sys/devices/system/cpu/cpu0/cache/index2/size
lscpu | grep -i tlb
dmesg | grep -i tlb
```

### Method C: Typical Values

| CPU           | L2 D-TLB Entries | 4 KB Reach | 2 MB THP Reach |
| ------------- | ---------------- | ---------- | -------------- |
| Kunpeng 920   | 2048             | 8 MB       | 4 GB           |
| AWS Graviton3 | ~2048            | 8 MB       | 4 GB           |
| Apple M1*     | ~2048            | 32 MB      | 128 MB         |
| Ampere Altra  | 2048             | 8 MB       | 4 GB           |

* Apple M1 uses 16 KB base pages.

---

## 4. Step A: Reproduce the DAMON Blind Spot

Compile a workload with a 512 MB working set and continuous sequential accesses.

The workload size is intentionally chosen such that:

```text
512 MB / 2 MB = 256 PMD entries
256 < 2048 L2 TLB entries
```

All PMDs can remain resident in the L2 TLB.

Configure:

```bash
echo always > /sys/kernel/mm/transparent_hugepage/enabled
```

Run the workload, wait for THP promotion, configure DAMON, and compare:

```bash
nr_accesses.min = 0
```

versus

```bash
nr_accesses.min = 1
```

Expected result:

```text
min=0 : nr_tried > 0
min=1 : nr_tried = 0
```

This indicates DAMON cannot observe any accesses despite the workload continuously touching memory.

---

## 5. Step B: Disable THP

Repeat Step A with:

```bash
echo never > /sys/kernel/mm/transparent_hugepage/enabled
```

Expected result:

```text
min=0 : nr_tried > 0
min=1 : nr_tried > 0
```

DAMON works normally because 4 KB PTEs greatly exceed TLB capacity, generating frequent TLB misses and AF updates.

---

## 6. Step C: Increase the Working Set

Keep:

```bash
THP=always
```

but increase the workload size to:

```c
#define SZ (16UL * 1024 * 1024 * 1024) /* 16 GB */
```

Expected result:

```text
min=0 : nr_tried > 0
min=1 : nr_tried > 0
```

DAMON recovers because the PMD working set exceeds L2 TLB capacity.

---

## 7. Results Interpretation

| Scenario           | WSS    | L2 TLB Coverage   | min=1 Detection | Interpretation |
| ------------------ | ------ | ----------------- | --------------- | -------------- |
| THP=always, 512 MB | 512 MB | 100% (4 GB reach) | 0               | DAMON blind    |
| THP=never, 512 MB  | 512 MB | 0.2% (8 MB reach) | >0              | DAMON normal   |
| THP=always, 16 GB  | 16 GB  | 25%               | >0              | DAMON normal   |

The general rule on ARM64 is:

```text
DAMON works correctly
    ⇔ WSS > (L2_TLB_entries × page_size)

    ⇔ Enough TLB misses occur
       to trigger hardware AF updates
```

Step A does not reproduce on x86 because x86 updates the Accessed bit on every memory access.

---

## 8. Adapting to Other ARM64 Platforms

Choose a working set that fits within the L2 TLB reach:

```text
Minimum WSS ≈
    L2_TLB_entries × page_size × 1.5–2
```

Examples:

* Apple M1 (16 KB pages, 2048 entries): ~50 MB
* Ampere Altra (2 MB THP pages, 2048 entries): ~6 GB

For the blind-spot experiment (Step A), keep the working set below the effective L2 TLB reach. For the recovery experiment (Step C), increase it beyond the L2 TLB reach.
