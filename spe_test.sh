#!/bin/bash
# spe_test.sh — ARM SPE sub-page hot/cold detection test
#
# Tests whether SPE can correctly distinguish hot subpages from cold ones
# within a 2MB THP.  Runs a controlled workload (touches first 25% of each
# THP), samples with SPE, then verifies the heatmap matches.
#
# Prerequisites:
#   - ARMv8.2+ CPU with SPE (e.g. Kunpeng 920)
#   - CONFIG_ARM_SPE_PMU=y in kernel
#   - perf tool with arm_spe support
#   - root or perf_event_paranoid <= 0
#
# Usage: sudo ./spe_test.sh [duration_sec]
#   Default duration: 15 seconds

set -e

DURATION=${1:-15}
SPE_EVENT="arm_spe/pa_enable=1,load_filter=0,store_filter=0,branch_filter=1,pct_enable=1/"
OUTDIR="/tmp/spe_test_$$"
PERF_DATA="$OUTDIR/spe.data"
PERF_SCRIPT="$OUTDIR/perf_script.txt"

cleanup() {
	kill $WL_PID 2>/dev/null || true
	rm -rf "$OUTDIR"
}
trap cleanup EXIT

echo "=== ARM SPE Sub-Page Hot/Cold Detection Test ==="
echo ""

# 1. Check SPE availability
echo "[1/5] Checking SPE availability..."
SPE_DIR=$(ls -d /sys/bus/event_source/devices/arm_spe_* 2>/dev/null | head -1)
if [ -z "$SPE_DIR" ]; then
	echo "ERROR: No ARM SPE PMU found in sysfs"
	echo "  Available PMUs:"
	ls /sys/bus/event_source/devices/ 2>/dev/null
	exit 1
fi
SPE_TYPE=$(cat "$SPE_DIR/type" 2>/dev/null)
echo "  SPE PMU found: $SPE_DIR (type=$SPE_TYPE)"
echo "  Caps: $(cat $SPE_DIR/caps/min_interval 2>/dev/null || echo N/A) min_interval"

# 2. Check perf supports arm_spe
echo "[2/5] Checking perf SPE support..."
if ! perf list 2>/dev/null | grep -q arm_spe; then
	echo "ERROR: perf does not list arm_spe event"
	echo "  Check: perf version, kernel CONFIG_ARM_SPE_PMU"
	exit 1
fi
echo "  OK"

# 3. Build tools
echo "[3/5] Building tools..."
mkdir -p "$OUTDIR"
gcc -O2 -o "$OUTDIR/hot_workload" /tmp/hot_workload.c || {
	echo "  Copy hot_workload.c to server and compile manually"
}
gcc -O2 -o "$OUTDIR/spe_hist" /tmp/spe_hist.c || {
	echo "  Copy spe_hist.c to server and compile manually"
}
echo "  OK"

# 4. Start workload
echo "[4/5] Starting test workload (hot first 25% of each THP)..."
"$OUTDIR/hot_workload" "$DURATION" 25 > "$OUTDIR/wl_pid" 2> "$OUTDIR/wl_log" &
WL_PID=$!
sleep 2

if ! kill -0 $WL_PID 2>/dev/null; then
	echo "ERROR: Workload failed to start"
	cat "$OUTDIR/wl_log"
	exit 1
fi
echo "  Workload PID=$WL_PID"

# Check if workload's pages have been promoted to THPs
sleep 1
THP_COUNT=$(grep -c AnonHugePages /proc/$WL_PID/smaps 2>/dev/null || echo 0)
echo "  THP regions in smaps: $THP_COUNT"

# 5. Collect SPE data
echo "[5/5] Collecting SPE samples for ${DURATION}s..."
perf record \
	-e "$SPE_EVENT" \
	-p "$WL_PID" \
	-o "$PERF_DATA" \
	-- sleep "$DURATION" 2> "$OUTDIR/perf_err" || {
	echo "ERROR: perf record failed"
	cat "$OUTDIR/perf_err"
	exit 1
}

SIZE=$(stat -c%s "$PERF_DATA" 2>/dev/null || stat -f%z "$PERF_DATA" 2>/dev/null)
echo "  Collected $(($SIZE / 1024))KB SPE data"

# 6. Decode and analyze
echo ""
echo "=== Decoding SPE data and building histogram ==="
perf script -i "$PERF_DATA" -F phys_addr,ip,event,pid,tid 2>/dev/null | \
	"$OUTDIR/spe_hist" 2> "$OUTDIR/hist_stderr" | head -80

echo ""
echo "=== Histogram summary ==="
cat "$OUTDIR/hist_stderr"

echo ""
echo "=== Raw SPE samples (first 20) ==="
perf script -i "$PERF_DATA" -F phys_addr,ip,event,pid,tid 2>/dev/null | head -20

echo ""
echo "=== Test complete ==="
echo "Full perf script output: $PERF_SCRIPT"
perf script -i "$PERF_DATA" -F phys_addr,ip,event,pid,tid 2>/dev/null > "$PERF_SCRIPT"
echo "Lines: $(wc -l < $PERF_SCRIPT)"

# Verify: the heatmap should show hot subpages concentrated in the first
# 25% of the THP address range.
echo ""
echo "=== Verification ==="
echo "If SPE works correctly, hot subpages should cluster in the first ~25%"
echo "of each THP (subpage index 0-127 of 512)."
echo "Check the ASCII heatmap above: '.'=cold, '#'=hot."
echo "Expected pattern: '##......' (hot at start, cold at end)"
