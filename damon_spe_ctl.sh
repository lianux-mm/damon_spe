#!/bin/bash
# damon_spe_ctl.sh - SPE-informed DAMOS_SPLIT control plane
#
# End-to-end pipeline:
#   perf record (SPE) → spe_hist → pfn_to_va → DAMON address filter → DAMOS_SPLIT
#
# Architecture:
#   Userspace                                    Kernel
#   ─────────                                    ──────
#   perf record (SPE phys addr)
#        ↓
#   perf script → spe_hist
#     (per-THP hot_fraction)
#        ↓
#   pfn_to_va (read /proc/pagemap)
#     (PA → VA reverse lookup)
#        ↓
#   configure DAMON sysfs ─────────────────────→ DAMOS_SPLIT
#     (address filters)                           split_folio_to_order()
#
# Usage:
#   # build tools
#   gcc -O2 -o spe_hist spe_hist.c
#   gcc -O2 -o pfn_to_va pfn_to_va.c
#
#   # one-shot mode
#   sudo ./damon_spe_ctl.sh --pid <PID> --start <ADDR> --end <ADDR>
#
#   # continuous mode (production)
#   sudo ./damon_spe_ctl.sh --pid <PID> --start <ADDR> --end <ADDR> --continuous
#
#   # dry-run (see what would be split without touching DAMON)
#   sudo ./damon_spe_ctl.sh --pid <PID> --start <ADDR> --end <ADDR> --dry-run
#
# Requires: perf (ARM SPE), spe_hist, pfn_to_va, DAMON sysfs kernel support

set -e

DAMON=/sys/kernel/mm/damon/admin
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SPE_HIST="${SCRIPT_DIR}/spe_hist"
PFN_TO_VA="${SCRIPT_DIR}/pfn_to_va"

# defaults
TARGET_PID=""
REGION_START=""
REGION_END=""
TARGET_ORDER=2
SPE_INTERVAL=10
HOT_THRESHOLD=30
DAMON_RUN_TIME=60
MAX_FILTERS=256
CONTINUOUS=0
DRY_RUN=0
LOOP_DELAY=30
NO_SPE=0
ACCESS_MIN=0

# cumulative stats
STAT_CYCLES=0
STAT_TOTAL_SPLIT=0
STAT_TOTAL_SPARSE=0

die()  { echo "[ERROR] $*" >&2; exit 1; }
warn() { echo "[WARN]  $*" >&2; }
info() { echo "[$(date +%H:%M:%S)] $*"; }
verb() { echo "         $*"; }

usage() {
	cat <<EOF
Usage: $0 --pid PID --start ADDR --end ADDR [OPTIONS]

Required:
  --pid PID         Target process PID
  --start ADDR      Monitoring region start (hex, e.g. 0x7f0000000000)
  --end ADDR        Monitoring region end (hex)

Options:
  --order N         Split target order (default: 2 = 16KB)
  --interval N      SPE sampling duration in seconds (default: 10)
  --threshold N     Hot fraction threshold % (default: 30)
  --run-time N      DAMON run time per cycle in seconds (default: 60)
  --max-filters N   Max address filters per cycle (default: 256)
  --continuous      Run in continuous loop (default: one-shot)
  --loop-delay N    Delay between continuous cycles in seconds (default: 30)
  --no-spe          Use /proc/smaps scanning instead of ARM SPE (for VMs)
  --access-min N    Min nr_accesses for DAMON scheme (default: 0)
  --dry-run         Analyze SPE and show split candidates without configuring DAMON

Examples:
  # one-shot
  sudo $0 --pid 12345 --start 0x7f0000000000 --end 0x7f0200000000

  # dry-run first to check what would happen
  sudo $0 --pid 12345 --start 0x7f0000000000 --end 0x7f0200000000 --dry-run

  # continuous production mode
  sudo $0 --pid 12345 --start 0x7f0000000000 --end 0x7f0200000000 --continuous --loop-delay 30
EOF
	exit 1
}

parse_args() {
	while [ $# -gt 0 ]; do
		case "$1" in
		--pid)        TARGET_PID="$2"; shift 2;;
		--start)      REGION_START="$2"; shift 2;;
		--end)        REGION_END="$2"; shift 2;;
		--order)      TARGET_ORDER="$2"; shift 2;;
		--interval)   SPE_INTERVAL="$2"; shift 2;;
		--threshold)  HOT_THRESHOLD="$2"; shift 2;;
		--run-time)   DAMON_RUN_TIME="$2"; shift 2;;
		--max-filters) MAX_FILTERS="$2"; shift 2;;
		--loop-delay) LOOP_DELAY="$2"; shift 2;;
		--continuous) CONTINUOUS=1; shift;;
		--no-spe)     NO_SPE=1; shift;;
		--access-min) ACCESS_MIN="$2"; shift 2;;
		--dry-run)    DRY_RUN=1; shift;;
		-h|--help)    usage;;
		*)            die "unknown option: $1";;
		esac
	done
	[ -n "$TARGET_PID" ] && [ -n "$REGION_START" ] && [ -n "$REGION_END" ] || {
		warn "missing required arguments"
		usage
	}
}

check_tools() {
	[ "$DRY_RUN" -eq 1 ] && return

	if [ "$NO_SPE" -eq 0 ]; then
		[ -x "$SPE_HIST" ]  || die "spe_hist not found (run: gcc -O2 -o spe_hist spe_hist.c)"
		[ -x "$PFN_TO_VA" ] || die "pfn_to_va not found (run: gcc -O2 -o pfn_to_va pfn_to_va.c)"
		command -v perf >/dev/null || die "perf not found"
	fi
	[ -d "$DAMON" ] || die "DAMON sysfs not found at $DAMON"
	kill -0 "$TARGET_PID" 2>/dev/null || die "PID $TARGET_PID not running"
	[ "$(id -u)" -eq 0 ] || die "must run as root for DAMON sysfs"
}

# ===== smaps fallback: find all THP-backed ranges without SPE =====
step_smaps_scan() {
	local out="$1"
	local pid="$2"

	info "step 1/3: scanning /proc/$pid/smaps for THP-backed ranges..."

	awk -v region_start="$REGION_START" -v region_end="$REGION_END" '
	/^[0-9a-f]+-[0-9a-f]+/ {
		split($1, a, "-")
		seg_start = strtonum("0x" a[1])
		seg_end   = strtonum("0x" a[2])
	}
	/AnonHugePages:/ && $2 > 0 {
		# this VMA has THP, only output 2MB-aligned ranges within monitoring region
		pmd = 2 * 1024 * 1024
		s = seg_start
		if (s % pmd != 0) s = s + pmd - (s % pmd)
		while (s + pmd <= seg_end) {
			printf "0x%lx 0x%lx 0\n", s, s + pmd
			s += pmd
		}
	}' "/proc/$pid/smaps" > "$out"

	local nr=$(wc -l < "$out")
	verb "found $nr THP-backed 2MB ranges"
	[ "$nr" -gt 0 ] && return 0
	return 1
}

# ===== Step 1: Collect ARM SPE samples =====
step_collect_spe() {
	local out="$1"

	info "step 1/5: collecting ARM SPE data (${SPE_INTERVAL}s)..."

	local rc=0
	perf record -e arm_spe_0/ts_enable=1,pa_enable=1,min_latency=0/ \
		-p "$TARGET_PID" -o "$out/perf.data" -- sleep "$SPE_INTERVAL" 2>"$out/perf_record.log" || rc=$?

	local sz=$(wc -c < "$out/perf.data" 2>/dev/null || echo 0)
	verb "recorded ${sz} bytes"

	if [ "$sz" -lt 4096 ]; then
		warn "SPE data too small (${sz} bytes) — check perf record errors:"
		cat "$out/perf_record.log" >&2
		return 1
	fi
	return 0
}

# ===== Step 2: Build heatmap, identify sparse THPs =====
step_analyze() {
	local tmp="$1"
	local out="$tmp/sparse_thps.txt"

	info "step 2/5: building heatmap (threshold=${HOT_THRESHOLD}%)..."

	perf script -i "$tmp/perf.data" -F phys_addr 2>/dev/null | \
		"$SPE_HIST" --threshold "$HOT_THRESHOLD" \
		> "$out" 2>"$tmp/spe_hist.log"

	local nr=$(wc -l < "$out")
	verb "$nr sparse THPs identified (hot_fraction < ${HOT_THRESHOLD}%)"
	cat "$tmp/spe_hist.log" >&2
}

# ===== Step 3: PFN → VA reverse lookup =====
step_pfn_to_va() {
	local tmp="$1"
	local out="$tmp/va_ranges.txt"

	info "step 3/5: resolving PFN → VA for pid $TARGET_PID..."

	"$PFN_TO_VA" --pid "$TARGET_PID" \
		< "$tmp/sparse_thps.txt" \
		> "$out" 2>"$tmp/pfn_to_va.log"

	local nr=$(wc -l < "$out")
	cat "$tmp/pfn_to_va.log" >&2

	if [ "$nr" -eq 0 ]; then
		verb "no VA ranges resolved — sparse THPs may not belong to target PID"
		return 1
	fi

	# merge adjacent 2MB ranges to reduce filter count.
	# Skip the merged result if it collapses everything into a single
	# filter that covers the entire monitoring region — DAMON address
	# filter shows sz_tried=0 in that case (boundary condition with
	# monitoring region exactly matching filter range).  Fall back to
	# unmerged individual ranges.
	local merged="$tmp/va_ranges_merged.txt"
	sort -k1,1 "$out" | awk -v pmd=$((2*1024*1024)) '
	BEGIN { count=0 }
	{
		va=$1; end_va=$2; pct=$3
		if (NR == 1) { last_va=va; last_end=end_va; count=1; next }
		# merge if adjacent and same alignment
		if (va == last_end) { last_end = end_va; count++ }
		else { printf "0x%lx 0x%lx %d\n", last_va, last_end, count; last_va=va; last_end=end_va; count=1 }
	}
	END { if (NR > 0) printf "0x%lx 0x%lx %d\n", last_va, last_end, count }
	' > "$merged"

	local orig_nr=$nr
	nr=$(wc -l < "$merged")
	if [ "$nr" -eq 1 ] && [ "$orig_nr" -gt 1 ]; then
		verb "merge would collapse $orig_nr ranges to 1, keeping unmerged"
	else
		[ "$orig_nr" -ne "$nr" ] && verb "merged $orig_nr ranges → $nr ranges"
		cp "$merged" "$out"
	fi

	# cap at MAX_FILTERS
	if [ "$nr" -gt "$MAX_FILTERS" ]; then
		verb "capping at $MAX_FILTERS filters (was $nr)"
		head -n "$MAX_FILTERS" "$out" > "$merged"
		cp "$merged" "$out"
		nr=$MAX_FILTERS
	fi

	STAT_TOTAL_SPARSE=$((STAT_TOTAL_SPARSE + nr))
	echo "$nr" > "$tmp/va_count.txt"
}

# ===== Step 4: Configure DAMON sysfs =====
step_configure_damon() {
	local tmp="$1"
	local va_file="$tmp/va_ranges.txt"
	local nr_filters=$(cat "$tmp/va_count.txt" 2>/dev/null || wc -l < "$va_file")

	info "step 4/5: configuring DAMON with $nr_filters address filters..."

	# Reset DAMON cleanly
	echo 0 > "$DAMON/kdamonds/nr_kdamonds" 2>/dev/null || true
	sleep 0.5
	echo 1 > "$DAMON/kdamonds/nr_kdamonds"

	# wait for kdamonds/0/ to appear
	local retry=10
	while [ ! -d "$DAMON/kdamonds/0" ] && [ "$retry" -gt 0 ]; do
		sleep 0.1
		retry=$((retry - 1))
	done
	[ -d "$DAMON/kdamonds/0" ] || die "kdamonds/0 not created after reset"

	local ctx=$DAMON/kdamonds/0/contexts
	echo 1 > $ctx/nr_contexts
	echo vaddr > $ctx/0/operations

	# target process
	echo 1 > $ctx/0/targets/nr_targets
	echo "$TARGET_PID" > $ctx/0/targets/0/pid_target

	# monitoring region
	echo 1 > $ctx/0/targets/0/regions/nr_regions
	echo "$REGION_START" > $ctx/0/targets/0/regions/0/start
	echo "$REGION_END"   > $ctx/0/targets/0/regions/0/end

	# scheme: action=split, target_order=N
	local sch=$ctx/0/schemes
	echo 1 > $sch/nr_schemes

	# detect available action name: v2 kernel uses "split", v1 uses "mthp_split"
	local action=""
	for try in split mthp_split; do
		if echo "$try" > $sch/0/action 2>/dev/null; then
			action="$try"
			break
		fi
	done
	[ -n "$action" ] || die "neither split nor mthp_split action supported by this kernel"

	echo "$TARGET_ORDER" > $sch/0/target_order

	# access pattern: default min=0 to handle both T1 blind spot and T2 inflation
	# the address filter does the fine-grained selection
	local ap=$sch/0/access_pattern
	printf "0x%lx" $((4096))             > $ap/sz/min
	printf "0x%lx" $((1024*1024*1024*1024)) > $ap/sz/max
	echo "$ACCESS_MIN" > $ap/nr_accesses/min
	echo 1000          > $ap/nr_accesses/max
	echo 0    > $ap/age/min
	echo $((1024*1024)) > $ap/age/max

	# address filters
	local flt=$sch/0/filters
	echo "$nr_filters" > "$flt/nr_filters"

	local i=0
	while read -r va_start va_end merged_count; do
		[ "$i" -ge "$MAX_FILTERS" ] && break
		echo addr > "$flt/$i/type"
		echo Y    > "$flt/$i/matching"
		echo Y    > "$flt/$i/allow"
		echo "$va_start" > "$flt/$i/addr_start"
		echo "$va_end"   > "$flt/$i/addr_end"
		i=$((i + 1))
	done < "$va_file"

	verb "$i filters configured"
}

# ===== Step 5: Run DAMON and report =====
step_run() {
	info "step 5/5: running DAMON (${DAMON_RUN_TIME}s)..."

	echo on > $DAMON/kdamonds/0/state || die "failed to start kdamond"
	sleep "$DAMON_RUN_TIME"
	# sync stats from running context to sysfs before stopping
	echo update_schemes_stats > $DAMON/kdamonds/0/state
	echo off > $DAMON/kdamonds/0/state

	local stats=$DAMON/kdamonds/0/contexts/0/schemes/0/stats
	local tried=$(cat "$stats/sz_tried" 2>/dev/null || echo 0)
	local applied=$(cat "$stats/sz_applied" 2>/dev/null || echo 0)

	printf -v tried_fmt "%'d" "$tried" 2>/dev/null || tried_fmt="$tried"
	printf -v applied_fmt "%'d" "$applied" 2>/dev/null || applied_fmt="$applied"

	info "result: sz_tried=${tried_fmt}  sz_applied=${applied_fmt}"

	local nr_split=0
	if [ "$applied" -ge $((2*1024*1024)) ]; then
		nr_split=$((applied / (2*1024*1024)))
	fi

	if [ "$nr_split" -gt 0 ]; then
		info "PASS: ~$nr_split THP(s) split ($applied bytes)"
	else
		verb "no THPs split this cycle"
	fi

	STAT_CYCLES=$((STAT_CYCLES + 1))
	STAT_TOTAL_SPLIT=$((STAT_TOTAL_SPLIT + applied))
}

# ===== Dry-run: analyze without touching DAMON =====
dry_run() {
	local tmp="$1"
	local mode="SPE"

	[ "$NO_SPE" -eq 1 ] && mode="smaps"
	info "=== DRY RUN ($mode) ==="
	info ""
	info "  pid:       $TARGET_PID"
	info "  region:    $REGION_START - $REGION_END"
	info "  order:     $TARGET_ORDER (→ $(( (1 << (12 + TARGET_ORDER)) / 1024 ))KB)"
	info "  threshold: ${HOT_THRESHOLD}%"
	info ""

	if [ "$NO_SPE" -eq 1 ]; then
		step_smaps_scan "$tmp/va_ranges.txt" "$TARGET_PID" || {
			info "no THP ranges found via smaps"
			return 0
		}
	else
		step_collect_spe "$tmp" || return 1
		step_analyze "$tmp"

		local nr_sparse=$(wc -l < "$tmp/sparse_thps.txt" 2>/dev/null || echo 0)
		if [ "$nr_sparse" -eq 0 ]; then
			info "no sparse THPs found, nothing to split"
			return 0
		fi

		step_pfn_to_va "$tmp" || {
			info "no PFN→VA matches — sparse THPs may not belong to pid $TARGET_PID"
			info ""
			info "top sparse THPs (physical PFNs):"
			head -5 "$tmp/sparse_thps.txt" | while read -r line; do
				echo "  $line"
			done
			return 0
		}
	fi

	local nr_va=$(wc -l < "$tmp/va_ranges.txt")
	info ""
	info "would configure $nr_va DAMON address filters:"
	head -10 "$tmp/va_ranges.txt" | while read -r va_start va_end cnt; do
		printf "  %s - %s (%d THP merged)\n" "$va_start" "$va_end" "$cnt"
	done
	[ "$nr_va" -gt 10 ] && echo "  ... ($nr_va total)"
	info ""
	info "then: echo on > kdamonds/0/state, wait ${DAMON_RUN_TIME}s, split"
}

# ===== Main one-shot cycle =====
run_one_cycle() {
	local tmp=$(mktemp -d)
	local mode="SPE"

	[ "$NO_SPE" -eq 1 ] && mode="smaps"
	info "=== $mode → DAMOS_SPLIT cycle #${STAT_CYCLES} ==="
	info ""

	if [ "$NO_SPE" -eq 1 ]; then
		# smaps-based: scan /proc/<pid>/smaps for THP ranges
		step_smaps_scan "$tmp/va_ranges.txt" "$TARGET_PID" || {
			verb "no THP ranges found via smaps"
			rm -rf "$tmp"
			return 0
		}
	else
		# SPE-based: perf → spe_hist → pfn_to_va
		step_collect_spe "$tmp" || { rm -rf "$tmp"; return 1; }
		step_analyze "$tmp"

		local nr_sparse=$(wc -l < "$tmp/sparse_thps.txt" 2>/dev/null || echo 0)
		if [ "$nr_sparse" -eq 0 ]; then
			verb "no sparse THPs this cycle, skipping split"
			rm -rf "$tmp"
			return 0
		fi

		step_pfn_to_va "$tmp" || { rm -rf "$tmp"; return 0; }
	fi

	local nr_ranges=$(wc -l < "$tmp/va_ranges.txt" 2>/dev/null || echo 0)
	if [ "$nr_ranges" -gt "$MAX_FILTERS" ]; then
		verb "capping at $MAX_FILTERS (was $nr_ranges)"
		head -n "$MAX_FILTERS" "$tmp/va_ranges.txt" > "$tmp/va_ranges_capped.txt"
		mv "$tmp/va_ranges_capped.txt" "$tmp/va_ranges.txt"
	fi
	echo "$(wc -l < "$tmp/va_ranges.txt")" > "$tmp/va_count.txt"

	step_configure_damon "$tmp"
	step_run
	rm -rf "$tmp"
}

# ===== Summary =====
print_summary() {
	info ""
	info "=== cumulative stats ==="
	info "  cycles:      $STAT_CYCLES"
	printf -v split_fmt "%'d" "$STAT_TOTAL_SPLIT" 2>/dev/null || split_fmt="$STAT_TOTAL_SPLIT"
	info "  total split: ${split_fmt} bytes"
	local thp_equiv=$((STAT_TOTAL_SPLIT / (2*1024*1024)))
	info "  ~$thp_equiv THPs split"
}

# ===== Signal handler =====
cleanup() {
	info "cleaning up DAMON..."
	echo 0 > "$DAMON/kdamonds/nr_kdamonds" 2>/dev/null || true
	info "done"
	exit 0
}

# ===== Main =====
parse_args "$@"
check_tools

info "=== DAMON SPE-informed split control plane ==="
info "pid=$TARGET_PID  region=$REGION_START-$REGION_END"
info "order=$TARGET_ORDER (→ $(( (1 << (12 + TARGET_ORDER)) / 1024 ))KB)  threshold=${HOT_THRESHOLD}%"
info ""

if [ "$DRY_RUN" -eq 1 ]; then
	tmp=$(mktemp -d)
	dry_run "$tmp"
	rm -rf "$tmp"
	exit 0
fi

trap cleanup SIGINT SIGTERM

run_one_cycle

if [ "$CONTINUOUS" -eq 1 ]; then
	info "entering continuous mode (loop_delay=${LOOP_DELAY}s, Ctrl-C to stop)"
	while true; do
		sleep "$LOOP_DELAY"
		run_one_cycle || {
			warn "cycle failed, retrying after $LOOP_DELAY seconds..."
			sleep "$LOOP_DELAY"
		}
	done
fi

print_summary
