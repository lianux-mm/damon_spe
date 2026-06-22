#!/bin/bash
# damon_spe_ctl.sh - SPE-informed DAMOS_SPLIT control plane
#
# End-to-end pipeline:
#   perf record (SPE) → spe_hist → pfn_to_va → DAMON address filter → DAMOS_SPLIT
#
# Usage:
#   # build tools first
#   gcc -O2 -o spe_hist spe_hist.c
#   gcc -O2 -o pfn_to_va pfn_to_va.c
#
#   # run control plane
#   sudo ./damon_spe_ctl.sh --pid <PID> --start <ADDR> --end <ADDR>
#
# Requires: perf (with ARM SPE support), spe_hist, pfn_to_va

set -e

DAMON=/sys/kernel/mm/damon/admin
TARGET_PID=""
REGION_START=""
REGION_END=""
TARGET_ORDER=2
SPE_INTERVAL=10
HOT_THRESHOLD=30
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SPE_HIST="${SCRIPT_DIR}/spe_hist"
PFN_TO_VA="${SCRIPT_DIR}/pfn_to_va"

die() { echo "FAIL: $*" >&2; exit 1; }
info() { echo "[$(date +%H:%M:%S)] $*"; }

usage() {
	cat <<EOF
Usage: $0 --pid PID --start ADDR --end ADDR [OPTIONS]

Required:
  --pid PID        Target process PID
  --start ADDR     Monitoring region start address (hex)
  --end ADDR       Monitoring region end address (hex)

Options:
  --order N        Split target order (default: 2, i.e. 16KB)
  --interval N     SPE sampling duration in seconds (default: 10)
  --threshold N    Hot fraction threshold % (default: 30)

Example:
  sudo $0 --pid 12345 --start 0x7f0000000000 --end 0x7f0200000000
EOF
	exit 1
}

parse_args() {
	while [ $# -gt 0 ]; do
		case "$1" in
		--pid)       TARGET_PID="$2"; shift 2;;
		--start)     REGION_START="$2"; shift 2;;
		--end)       REGION_END="$2"; shift 2;;
		--order)     TARGET_ORDER="$2"; shift 2;;
		--interval)  SPE_INTERVAL="$2"; shift 2;;
		--threshold) HOT_THRESHOLD="$2"; shift 2;;
		-h|--help)   usage;;
		*)           die "unknown option: $1";;
		esac
	done
	[ -n "$TARGET_PID" ] && [ -n "$REGION_START" ] && [ -n "$REGION_END" ] || usage
}

check_tools() {
	[ -x "$SPE_HIST" ]  || die "spe_hist not found at $SPE_HIST (run: gcc -O2 -o spe_hist spe_hist.c)"
	[ -x "$PFN_TO_VA" ] || die "pfn_to_va not found at $PFN_TO_VA (run: gcc -O2 -o pfn_to_va pfn_to_va.c)"
	command -v perf >/dev/null || die "perf not found"
	[ -d "$DAMON" ] || die "DAMON sysfs not found at $DAMON (kernel support missing?)"
	kill -0 "$TARGET_PID" 2>/dev/null || die "PID $TARGET_PID not running"
}

# ===== Step 1: Collect ARM SPE samples =====
step_collect_spe() {
	local tmpdir="$1"

	info "step 1: collecting ARM SPE data for ${SPE_INTERVAL}s..."
	perf record -e arm_spe_0/ts_enable=1,pa_enable=1,min_latency=0/ \
		-p "$TARGET_PID" -o "$tmpdir/perf.data" -- sleep "$SPE_INTERVAL" 2>"$tmpdir/perf_record.log"

	info "  $(wc -c < "$tmpdir/perf.data") bytes recorded"
}

# ===== Step 2: Build heatmap and identify sparse THPs =====
step_analyze() {
	local tmpdir="$1"

	info "step 2: analyzing SPE data (threshold=${HOT_THRESHOLD}%)..."
	perf script -i "$tmpdir/perf.data" -F phys_addr 2>/dev/null | \
		"$SPE_HIST" --threshold "$HOT_THRESHOLD" \
		> "$tmpdir/sparse_thps.txt" 2>"$tmpdir/spe_hist.log"

	local nr=$(wc -l < "$tmpdir/sparse_thps.txt")
	info "  found $nr sparse THPs (hot_fraction < ${HOT_THRESHOLD}%)"
	cat "$tmpdir/spe_hist.log" >&2
}

# ===== Step 3: Reverse-map PFN → VA via pagemap =====
step_pfn_to_va() {
	local tmpdir="$1"

	info "step 3: resolving PFN → VA for pid $TARGET_PID..."
	"$PFN_TO_VA" --pid "$TARGET_PID" \
		< "$tmpdir/sparse_thps.txt" \
		> "$tmpdir/va_ranges.txt" 2>"$tmpdir/pfn_to_va.log"

	local nr=$(wc -l < "$tmpdir/va_ranges.txt")
	info "  resolved $nr virtual address ranges"
	cat "$tmpdir/pfn_to_va.log" >&2

	if [ "$nr" -eq 0 ]; then
		info "  no VA ranges found — THPs may not belong to pid $TARGET_PID"
		return 1
	fi
	return 0
}

# ===== Step 4: Configure DAMON sysfs =====
step_configure_damon() {
	local tmpdir="$1"
	local va_file="$tmpdir/va_ranges.txt"
	local nr_filters=$(wc -l < "$va_file")

	info "step 4: configuring DAMON with $nr_filters address filters..."

	# Reset DAMON: writing nr_kdamonds creates kdamonds/0/ directory.
	# Must do this BEFORE accessing kdamonds/0/state.
	echo 0 > $DAMON/kdamonds/nr_kdamonds 2>/dev/null || true
	echo 1 > $DAMON/kdamonds/nr_kdamonds

	local ctx=$DAMON/kdamonds/0/contexts
	echo 1 > $ctx/nr_contexts
	echo vaddr > $ctx/0/operations

	# target process
	echo 1 > $ctx/0/targets/nr_targets
	echo $TARGET_PID > $ctx/0/targets/0/pid_target

	# monitoring region
	echo 1 > $ctx/0/targets/0/regions/nr_regions
	echo $REGION_START > $ctx/0/targets/0/regions/0/start
	echo $REGION_END > $ctx/0/targets/0/regions/0/end

	# scheme: action=split
	local sch=$ctx/0/schemes
	echo 1 > $sch/nr_schemes
	echo split > $sch/0/action
	echo $TARGET_ORDER > $sch/0/target_order

	# access pattern: match all (filter does the real selection)
	local ap=$sch/0/access_pattern
	echo 0    > $ap/sz/min
	echo $((1024*1024*1024*1024)) > $ap/sz/max
	echo 0    > $ap/nr_accesses/min
	echo 1000 > $ap/nr_accesses/max
	echo 0    > $ap/age/min
	echo $((1024*1024)) > $ap/age/max

	# address filters: one per sparse THP
	local flt=$sch/0/filters
	echo $nr_filters > $flt/nr_filters

	local i=0
	while read -r va_start va_end hot_pct; do
		echo addr > $flt/$i/type
		echo Y    > $flt/$i/matching
		echo Y    > $flt/$i/allow
		echo $va_start > $flt/$i/addr_start
		echo $va_end   > $flt/$i/addr_end
		i=$((i + 1))
	done < "$va_file"

	info "  $i address filters configured"
}

# ===== Step 5: Run DAMON and report =====
step_run() {
	info "step 5: starting DAMON..."
	echo on > $DAMON/kdamonds/0/state || die "failed to start kdamond"

	info "  running for 5s..."
	sleep 5

	# Sync stats from running context to sysfs before stopping
	echo update_schemes_stats > $DAMON/kdamonds/0/state
	echo off > $DAMON/kdamonds/0/state

	local stats=$DAMON/kdamonds/0/contexts/0/schemes/0/stats
	local tried=$(cat $stats/sz_tried 2>/dev/null || echo 0)
	local applied=$(cat $stats/sz_applied 2>/dev/null || echo 0)

	info "  result: sz_tried=$tried sz_applied=$applied"

	if [ "$applied" -gt 0 ]; then
		info "PASS: split applied $applied bytes"
	else
		info "WARN: split applied 0 bytes"
	fi
}

# ===== Main =====
parse_args "$@"
check_tools

tmpdir=$(mktemp -d)
trap "rm -rf $tmpdir" EXIT

info "=== DAMON SPE-informed split control plane ==="
info "pid=$TARGET_PID region=$REGION_START-$REGION_END"
info "order=$TARGET_ORDER threshold=${HOT_THRESHOLD}%"
info ""

step_collect_spe "$tmpdir"
step_analyze "$tmpdir"
step_pfn_to_va "$tmpdir" || exit 0
step_configure_damon "$tmpdir"
step_run

info ""
info "=== complete ==="
