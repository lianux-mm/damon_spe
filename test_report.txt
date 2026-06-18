  Objective

  Validate that the DAMON mTHP split patch series corrects THP-induced hotspot
  overestimation on ARM64.

  Platform

  Kunpeng 920 (Taishan V110), 256 cores, 249GB RAM, L1 D-TLB=48 entries, L2
  TLB=2048 entries (4KB reach=8MB, 2MB THP reach=4GB). Kernel 7.1.0-rc5+. Two
  builds compared: build #10 with the full patch series, build #14 with the
  series reverted.

  ---
  Part 1: Problem Confirmation

  All tests in this section ran on both builds with consistent results. The data
   below is from build #14; build #10 results are identical.

  T1 — DAMON Blind Spot

  Three workloads (16MB THP / 512MB 4KB / 16GB THP), all touching every page.
  DAMON stat action with nr_accesses/min=1.

  ┌──────┬────────┬───────┬──────┬─────────────────┬─────────────────┐
  │ Step │  THP   │  WSS  │ PMDs │ L2 TLB Coverage │ nr_tried(min=1) │
  ├──────┼────────┼───────┼──────┼─────────────────┼─────────────────┤
  │ T1A  │ always │ 16MB  │ 8    │ 0.4%            │ 0               │
  ├──────┼────────┼───────┼──────┼─────────────────┼─────────────────┤
  │ T1B  │ never  │ 512MB │ N/A  │ <1% (4KB PTEs)  │ 20              │
  ├──────┼────────┼───────┼──────┼─────────────────┼─────────────────┤
  │ T1C  │ always │ 16GB  │ 8192 │ 400%            │ 20              │
  └──────┴────────┴───────┴──────┴─────────────────┴─────────────────┘

  8 PMD entries in T1A are fully cached in the 2048-entry L2 TLB. After DAMON
  clears the AF, the hardware never resets it because ARM64 sets AF only on TLB
  miss, not on TLB hit. The workload continuously touches pages via TLB hits,
  never triggering a page table walk. The larger WSS in T1B (131K PTEs) and T1C
  (8192 PMDs) both exceed L2 TLB capacity, causing sufficient TLB thrashing for
  normal AF updates.

  T2 — THP Hotspot Inflation

  8GB mmap. Phase A: touch every page for THP eligibility. Phase B: wait for
  khugepaged collapse. Phase C: clear all AF bits via /proc/self/clear_refs.
  Phase D: touch 1 page per 2MB (4096 pages = 16MB = 0.2%). Phase E: loop to
  sustain the sparse pattern. DAMON stat comparison between THP=always and
  THP=never.

  ┌────────┬───────────────┬─────────────────┬─────────────────┬────────────┐
  │  Mode  │ AnonHugePages │ nr_tried(min=1) │ sz_tried(min=1) │ vs actual  │
  │        │               │                 │                 │ hot (16MB) │
  ├────────┼───────────────┼─────────────────┼─────────────────┼────────────┤
  │ always │ 8388608 kB    │ 200/200         │ 16 GB           │ 1024x      │
  ├────────┼───────────────┼─────────────────┼─────────────────┼────────────┤
  │ never  │ 0 kB          │ 0~6/100         │ 0~491 MB        │ 0~30x      │
  │        │               │ (varies)        │                 │            │
  └────────┴───────────────┴─────────────────┴─────────────────┴────────────┘

  Note: sz_tried under THP=never varies from 0 to 491MB across runs. DAMON picks
   one random sampling address per region. With only 0.2% of pages touched, the
  probability of any given run hitting a touched page is low. This is inherent
  sampling variance and does not affect the directional conclusion: THP=always
  consistently reports orders of magnitude more hot memory than THP=never.

  T3 — RocksDB Immunity

  RocksDB db_bench v9.7.4, 10M keys × 1KB values, 32GB block cache, readrandom
  with zipfian distribution.

  AnonHugePages=0 kB (fragmented allocations prevent THP formation). DAMON
  detects 50/50 regions (100%). RocksDB cannot serve as a reproduction workload
  for THP hotspot inflation.

  T5 — ARM SPE Hardware Corroboration

  10-second system-wide ARM SPE sampling at period=1024. perf script decodes
  physical addresses, a userspace histogram builder (spe_hist) aggregates
  per-4KB-subpage access counts at THP granularity.

  Two independent samples captured 1,392 and 2,005 THPs respectively, with
  95-97% showing <10% of their 4KB subpages actually accessed. In a
  representative trace, PFN 0x820db800 accumulated 39,794 hardware accesses
  concentrated in 3 of 512 subpages (0.6%).

  ---
  Part 2: Solution Verification

  All tests in this section ran only on build #10 (with the full patch series).
  On build #14 the DAMOS_MTHP_SPLIT action is not present, so T4 and the
  end-to-end test cannot execute.

  T4 — min=0 Split Breaks the Deadlock

  256MB THP workload (128 PMDs, 6% L2 TLB). Step 1: confirm DAMON blindness
  (min=1 yields 0 regions). Step 2: configure DAMOS_MTHP_SPLIT with
  target_order=2 and nr_accesses/min=0, which unconditionally calls
  split_folio_to_order() on every THP folio. Step 3: verify DAMON recovers.

  ┌──────────────┬───────────────────────────────────────┬─────────────────┐
  │    Phase     │              Page layout              │ nr_tried(min=1) │
  ├──────────────┼───────────────────────────────────────┼─────────────────┤
  │ Before split │ 2MB THP ×128 (L2 TLB cached)          │ 0               │
  ├──────────────┼───────────────────────────────────────┼─────────────────┤
  │ After split  │ 16KB mTHP ×16384 (far exceeds L2 TLB) │ 20              │
  └──────────────┴───────────────────────────────────────┴─────────────────┘

  Post-split: 256MB / 16KB = 16,384 TLB entries >> 2,048 L2 TLB. TLB thrashing
  resumes, the hardware sets AF normally, and DAMON recovers. The
  nr_accesses/min=0 setting ensures the split does not depend on DAMON's own
  access data.

  End-to-End SPE Feedback

  Two THPs receive 460 (90% hot) and 128 (25% cold) SPE-recorded accesses via
  debugfs spe_feed. The kernel rbtree accumulates per-4KB-subpage
  access_count[]. DAMOS_MTHP_SPLIT is configured with target_order=2.
  damon_spe_folio_heatmap() queries the rbtree and returns a hot bitmap;
  damon_spe_hot_fraction() computes the ratio. THPs with hot_pct < 80% are
  split.

  ┌───────┬────────────────────┬─────────┬───────────┬───────────────────┐
  │  THP  │      PFNs fed      │ hot_pct │ Decision  │      Result       │
  ├───────┼────────────────────┼─────────┼───────────┼───────────────────┤
  │ THP-0 │ 460 (90% subpages) │ ~90%    │ preserved │ 2MB THP unchanged │
  ├───────┼────────────────────┼─────────┼───────────┼───────────────────┤
  │ THP-1 │ 128 (25% subpages) │ ~25%    │ split     │ 128×16KB mTHP     │
  └───────┴────────────────────┴─────────┴───────────┴───────────────────┘

  Full pipeline: perf script → spe_hist → debugfs spe_feed → kernel rbtree → 
  damon_spe_folio_heatmap() → split decision, verified end-to-end.

  ---
  Conclusion

  1. THP-induced hotspot overestimation is a real structural problem. A
  PMD-level AF bit amplifies one 4KB access into a 2MB hot signal. ARM SPE
  hardware data independently confirms that 95%+ of production THPs have <10% of
   their subpages actually accessed.
  2. mTHP split reduces DAMON's detection granularity from 512 pages to 4 pages
  (when splitting to 16KB), substantially improving hotspot localization.
  3. The SPE feedback pipeline (debugfs spe_feed → rbtree → heatmap → split
  decision) enables access-pattern-driven split decisions, verified end-to-end.
  4. Known limitations: (a) full KVM+Oracle production chain not yet benchmarked
   end-to-end; (b) khugepaged may re-collapse mTHPs that DAMON has split,
  requiring a coordination mechanism; (c) the ARM64 blind spot (WSS < L2 TLB
  reach) can be worked around with nr_accesses/min=0, or is naturally absent in
  production workloads exceeding the L2 TLB threshold.
