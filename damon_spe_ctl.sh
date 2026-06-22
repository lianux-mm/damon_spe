#!/bin/bash
# damon_spe_ctl.sh - SPE-informed DAMOS_SPLIT control plane
#
# Bridges ARM SPE profiling data to DAMON address filters.
# Replaces the debugfs approach with the upstream-friendly sysfs path.
#
# Usage:
#   sudo ./damon_spe_ctl.sh --pid <PID> --start <ADDR> --end <ADDR> \
#        [--order 2] [--interval 30] [--threshold 30]
#
# Workflow:
#   1. perf record -e arm_spe_0// -a sleep <interval>
#   2. perf script → spe_hist → per-THP hot fraction
#   3. THPs with hot_fraction < threshold → DAMON address filters
#   4. DAMOS_SPLIT fires on filtered regions only
#
# Requires: perf, spe_hist (from https://github.com/lianux-mm/damon_spe)

set -e

DAMON=/sys/kernel/mm/damon/admin
TARGET_PID=""
REGION_START=""
REGION_END=""
TARGET_ORDER=2
SPE_INTERVAL=10
HOT_THRESHOLD=30
SPE_HIST="./spe_hist"
KDAMOND=0
CTX=0
SCHEME=0

usage() {
	echo "Usage: $0 --pid PID --start ADDR --end ADDR [OPTIONS]"
	echo "  --pid PID        Target process PID"
	echo "  --start ADDR     Monitoring region start (hex)"
	echo "  --end ADDR       Monitoring region end (hex)"
	echo "  --order N        Split target order (default: 2 = 16KB)"
	echo "  --interval N     SPE sampling interval in seconds (default: 10)"
	echo "  --threshold N    Hot subpage percentage threshold (default: 30)"
	echo "  --spe-hist PATH  Path to spe_hist tool"
	exit 1
}

die() { echo "FAIL: $*" >&2; exit 1; }
info() { echo "[$(date +%H:%M:%S)] $*"; }

parse_args() {
	while [ $# -gt 0 ]; do
		case "$1" in
		--pid) TARGET_PID="$2"; shift 2;;
		--start) REGION_START="$2"; shift 2;;
		--end) REGION_END="$2"; shift 2;;
		--order) TARGET_ORDER="$2"; shift 2;;
		--interval) SPE_INTERVAL="$2"; shift 2;;
		--threshold) HOT_THRESHOLD="$2"; shift 2;;
		--spe-hist) SPE_HIST="$2"; shift 2;;
		*) usage;;
		esac
	done
	[ -n "$TARGET_PID" ] || usage
	[ -n "$REGION_START" ] || usage
	[ -n "$REGION_END" ] || usage
}

# Collect SPE samples and output sparse-hot THP addresses
# Output format: one address range per line: <start_hex> <end_hex> <hot_pct>
collect_spe() {
	local tmpdir=$(mktemp -d)
	info "collecting SPE data for ${SPE_INTERVAL}s..."

	perf record -e arm_spe_0/ts_enable=1,pa_enable=1,min_latency=0/ \
		-a -o "$tmpdir/perf.data" -- sleep "$SPE_INTERVAL" 2>/dev/null

	info "decoding SPE data..."
	perf script -i "$tmpdir/perf.data" -F phys_addr 2>/dev/null | \
		"$SPE_HIST" --threshold "$HOT_THRESHOLD" --pid "$TARGET_PID" \
		> "$tmpdir/sparse_thps.txt" 2>/dev/null

	cat "$tmpdir/sparse_thps.txt"
	rm -rf "$tmpdir"
}

# Fallback: scan /proc/<pid>/smaps for large THP regions
# Outputs all THP-backed 2MB-aligned ranges as split candidates
scan_thp_ranges() {
	info "scanning /proc/$TARGET_PID/smaps for THP regions..."
	awk -v start="$REGION_START" -v end_addr="$REGION_END" '
	/^[0-9a-f]+-[0-9a-f]+/ {
		split($1, a, "-")
		seg_start = strtonum("0x" a[1])
		seg_end = strtonum("0x" a[2])
	}
	/AnonHugePages:/ && $2 > 0 {
		# this segment has THP, output 2MB-aligned ranges
		align = 2 * 1024 * 1024
		s = seg_start
		if (s % align != 0) s = s + align - (s % align)
		while (s + align <= seg_end) {
			printf "0x%lx 0x%lx\n", s, s + align
			s += align
		}
	}' /proc/$TARGET_PID/smaps
}

# Configure DAMON with DAMOS_SPLIT and address filters
setup_damon_split() {
	local addr_file="$1"
	local nr_filters=$(wc -l < "$addr_file")

	[ "$nr_filters" -gt 0 ] || die "no split targets found"
	info "configuring DAMON with $nr_filters address filters"

	# stop if running
	echo off > $DAMON/kdamonds/$KDAMOND/state 2>/dev/null || true

	echo 1 > $DAMON/kdamonds/nr_kdamonds
	local ctx=$DAMON/kdamonds/$KDAMOND/contexts
	echo 1 > $ctx/nr_contexts
	echo vaddr > $ctx/$CTX/operations

	# target
	local tgt=$ctx/$CTX/targets
	echo 1 > $tgt/nr_targets
	echo $TARGET_PID > $tgt/0/pid_target
	local regions=$tgt/0/regions
	echo 1 > $regions/nr_regions
	echo $REGION_START > $regions/0/start
	echo $REGION_END > $regions/0/end

	# scheme: split
	local sch=$ctx/$CTX/schemes
	echo 1 > $sch/nr_schemes
	echo split > $sch/$SCHEME/action
	echo $TARGET_ORDER > $sch/$SCHEME/target_order

	# access pattern: target all regions (filter does the selection)
	local ap=$sch/$SCHEME/access_pattern
	echo 0 > $ap/sz/min
	echo $((1024*1024*1024*1024)) > $ap/sz/max
	echo 0 > $ap/nr_accesses/min
	echo 1000 > $ap/nr_accesses/max
	echo 0 > $ap/age/min
	echo $((1024*1024)) > $ap/age/max

	# address filters from SPE analysis
	local flt=$sch/$SCHEME/filters
	echo $nr_filters > $flt/nr_filters

	local i=0
	while read -r addr_start addr_end rest; do
		echo addr > $flt/$i/type
		echo Y > $flt/$i/matching
		echo Y > $flt/$i/allow
		echo $addr_start > $flt/$i/addr_start
		echo $addr_end > $flt/$i/addr_end
		i=$((i + 1))
	done < "$addr_file"

	info "filters configured ($i entries)"
}

run_split_cycle() {
	info "starting DAMON split cycle"
	echo on > $DAMON/kdamonds/$KDAMOND/state || die "failed to start"

	sleep 5

	echo off > $DAMON/kdamonds/$KDAMOND/state

	local stats=$DAMON/kdamonds/$KDAMOND/contexts/$CTX/schemes/$SCHEME/stats
	local applied=$(cat $stats/sz_applied 2>/dev/null || echo 0)
	local tried=$(cat $stats/sz_tried 2>/dev/null || echo 0)
	info "split result: tried=$tried applied=$applied"
}

# --- main ---
parse_args "$@"

# try SPE first, fall back to smaps scan
addr_file=$(mktemp)
if command -v perf >/dev/null && [ -x "$SPE_HIST" ]; then
	collect_spe > "$addr_file"
fi

if [ ! -s "$addr_file" ]; then
	info "SPE not available or no data, falling back to smaps scan"
	scan_thp_ranges > "$addr_file"
fi

nr=$(wc -l < "$addr_file")
info "found $nr THP ranges to split"

if [ "$nr" -eq 0 ]; then
	info "no split targets, exiting"
	rm -f "$addr_file"
	exit 0
fi

head -5 "$addr_file"
[ "$nr" -gt 5 ] && echo "  ... ($nr total)"

setup_damon_split "$addr_file"
run_split_cycle

rm -f "$addr_file"
info "done"
