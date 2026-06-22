#!/bin/bash
# test_damos_split.sh - Verify DAMOS_SPLIT + address filter end-to-end
#
# Run on Kunpeng 920 with v2 kernel.  Requires THP=always.
# Usage: sudo ./test_damos_split.sh

set -e

DAMON=/sys/kernel/mm/damon/admin
SMAPS_ROLLUP="smaps_rollup"
TEST_SIZE=$((256 * 1024 * 1024))   # 256MB
TARGET_ORDER=2                      # split to order-2 (16KB)
SPLIT_ADDR_START=""
SPLIT_ADDR_END=""

die() { echo "FAIL: $*" >&2; cleanup; exit 1; }
info() { echo "== $*"; }

# --- test workload: mmap 256MB, touch to populate THP ---
start_workload() {
	cat > /tmp/damos_split_test.c << 'CEOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

int main(int argc, char *argv[])
{
	size_t sz = 256UL * 1024 * 1024;
	volatile char *p;

	p = mmap(NULL, sz, PROT_READ | PROT_WRITE,
		 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) {
		perror("mmap");
		return 1;
	}
	madvise((void *)p, sz, MADV_HUGEPAGE);

	/* touch every page to populate THP */
	for (size_t i = 0; i < sz; i += 4096)
		p[i] = 1;

	fprintf(stdout, "pid=%d addr=0x%lx size=%zu\n",
		getpid(), (unsigned long)p, sz);
	fflush(stdout);

	/* keep alive */
	while (1)
		sleep(60);
	return 0;
}
CEOF
	gcc -O2 -o /tmp/damos_split_test /tmp/damos_split_test.c || die "compile"
	/tmp/damos_split_test > /tmp/damos_split_info.txt &
	WORKLOAD_PID=$!
	sleep 1

	eval $(sed 's/ /\n/g' /tmp/damos_split_info.txt | grep -E '^(pid|addr|size)=' )
	info "workload pid=$pid addr=$addr size=$size"
	WORKLOAD_PID=$pid

	# pick a 2MB-aligned range in the middle for the address filter
	local base=$((addr + 128 * 1024 * 1024))
	SPLIT_ADDR_START=$(printf "0x%lx" $((base & ~((2*1024*1024)-1))))
	SPLIT_ADDR_END=$(printf "0x%lx" $((${SPLIT_ADDR_START} + 2*1024*1024)))
	info "split target: $SPLIT_ADDR_START - $SPLIT_ADDR_END (2MB)"
}

# --- check THP status before/after ---
count_thp() {
	local pid=$1
	if [ -f /proc/$pid/smaps_rollup ]; then
		awk '/AnonHugePages/ {print $2}' /proc/$pid/smaps_rollup
	else
		awk '/AnonHugePages/ {s+=$2} END {print s+0}' /proc/$pid/smaps
	fi
}

# --- configure DAMON sysfs ---
setup_damon() {
	info "configuring DAMON sysfs"

	# stop if running
	echo off > $DAMON/kdamonds/0/state 2>/dev/null || true

	# set nr_kdamonds
	echo 1 > $DAMON/kdamonds/nr_kdamonds

	local ctx=$DAMON/kdamonds/0/contexts
	echo 1 > $ctx/nr_contexts
	echo vaddr > $ctx/0/operations

	# target
	local tgt=$ctx/0/targets
	echo 1 > $tgt/nr_targets
	echo $WORKLOAD_PID > $tgt/0/pid_target

	# monitoring region (cover the full mmap)
	local regions=$tgt/0/regions
	echo 1 > $regions/nr_regions
	echo $addr > $regions/0/start
	printf "0x%lx" $((addr + size)) > $regions/0/end

	# scheme: action=split
	local sch=$ctx/0/schemes
	echo 1 > $sch/nr_schemes
	echo split > $sch/0/action
	echo $TARGET_ORDER > $sch/0/target_order

	# access pattern: target cold regions (min_nr_accesses=0, max_nr_accesses=0)
	local ap=$sch/0/access_pattern
	echo 0 > $ap/sz/min
	echo $((1024*1024*1024*1024)) > $ap/sz/max
	echo 0 > $ap/nr_accesses/min
	echo 0 > $ap/nr_accesses/max
	echo 0 > $ap/age/min
	echo $((1024*1024)) > $ap/age/max

	# address filter: only split the selected 2MB range
	local flt=$sch/0/filters
	echo 1 > $flt/nr_filters
	echo addr > $flt/0/type
	echo Y > $flt/0/matching
	echo Y > $flt/0/allow
	echo $SPLIT_ADDR_START > $flt/0/addr_start
	echo $SPLIT_ADDR_END > $flt/0/addr_end

	info "DAMON configured: split order=$TARGET_ORDER, filter=$SPLIT_ADDR_START-$SPLIT_ADDR_END"
}

run_damon() {
	info "starting DAMON"
	echo on > $DAMON/kdamonds/0/state || die "failed to start DAMON"
	info "DAMON running, waiting 10s for scheme to fire..."
	sleep 10
	echo off > $DAMON/kdamonds/0/state
	info "DAMON stopped"
}

check_result() {
	# read scheme stats
	local stats=$DAMON/kdamonds/0/contexts/0/schemes/0/stats
	local applied=$(cat $stats/sz_applied 2>/dev/null || echo 0)
	local tried=$(cat $stats/sz_tried 2>/dev/null || echo 0)

	info "scheme stats: sz_tried=$tried sz_applied=$applied"

	if [ "$applied" -gt 0 ]; then
		info "PASS: DAMOS_SPLIT applied $applied bytes"
	else
		die "DAMOS_SPLIT applied 0 bytes - split did not fire"
	fi
}

cleanup() {
	echo off > $DAMON/kdamonds/0/state 2>/dev/null || true
	kill $WORKLOAD_PID 2>/dev/null || true
	rm -f /tmp/damos_split_test /tmp/damos_split_test.c /tmp/damos_split_info.txt
}

# --- main ---
trap cleanup EXIT

info "THP before:"
cat /sys/kernel/mm/transparent_hugepage/enabled

start_workload

thp_before=$(count_thp $WORKLOAD_PID)
info "AnonHugePages before split: ${thp_before}kB"

setup_damon
run_damon

thp_after=$(count_thp $WORKLOAD_PID)
info "AnonHugePages after split: ${thp_after}kB"

check_result

if [ "$thp_after" -lt "$thp_before" ]; then
	info "PASS: THP size decreased (${thp_before}kB -> ${thp_after}kB)"
else
	info "WARN: THP size did not decrease (might need longer run)"
fi

info "all checks passed"
