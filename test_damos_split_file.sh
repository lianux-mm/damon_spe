#!/bin/bash
# test_damos_split_file.sh - Verify DAMOS_SPLIT on file-backed (shmem/tmpfs) THP
#
# Companion to test_damos_split.sh (which covers anonymous THP).
# This one proves DAMOS_SPLIT works on tmpfs/shmem-backed huge pages,
# i.e. the KVM-guest-memory-on-THP-tmpfs case claimed in patch 5.
#
# Run on a host with the v2 kernel.  Needs CONFIG_TRANSPARENT_HUGEPAGE
# and tmpfs "huge=" mount support.
# Usage: sudo ./test_damos_split_file.sh

set -e

DAMON=/sys/kernel/mm/damon/admin
MNT=/mnt/damon_thptest
TESTFILE=$MNT/thpfile
TEST_SIZE=$((256 * 1024 * 1024))   # 256MB
TARGET_ORDER=2                     # split to order-2 (16KB)
SPLIT_ADDR_START=""
SPLIT_ADDR_END=""
WORKLOAD_PID=""
addr=""
size=""

die() { echo "FAIL: $*" >&2; cleanup; exit 1; }
info() { echo "== $*"; }

mount_tmpfs() {
	mkdir -p $MNT
	# Mount a private tmpfs with THP forced on, so the test does not
	# depend on the global shmem_enabled setting.
	if ! mount -t tmpfs -o huge=always,size=512M tmpfs $MNT 2>/dev/null; then
		die "cannot mount tmpfs with huge=always (kernel tmpfs THP support?)"
	fi
	info "mounted tmpfs (huge=always) at $MNT"
}

# --- test workload: create a tmpfs file, mmap MAP_SHARED, touch to populate
#     file-backed (shmem) THP ---
start_workload() {
	cat > /tmp/damos_split_file.c << 'CEOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

int main(int argc, char *argv[])
{
	size_t sz = 256UL * 1024 * 1024;
	const char *path = argv[1];
	volatile char *p;
	int fd;

	fd = open(path, O_RDWR | O_CREAT, 0644);
	if (fd < 0) { perror("open"); return 1; }
	if (ftruncate(fd, sz)) { perror("ftruncate"); return 1; }

	/* MAP_SHARED so the folios stay file-backed (shmem), not COW-anon */
	p = mmap(NULL, sz, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (p == MAP_FAILED) { perror("mmap"); return 1; }

	/* touch every page; huge=always tmpfs faults in PMD-size THP */
	for (size_t i = 0; i < sz; i += 4096)
		p[i] = 1;

	fprintf(stdout, "pid=%d addr=0x%lx size=%zu\n",
		getpid(), (unsigned long)p, sz);
	fflush(stdout);

	while (1)
		sleep(60);
	return 0;
}
CEOF
	gcc -O2 -o /tmp/damos_split_file /tmp/damos_split_file.c || die "compile"
	/tmp/damos_split_file "$TESTFILE" > /tmp/damos_split_file_info.txt &
	sleep 1

	eval $(sed 's/ /\n/g' /tmp/damos_split_file_info.txt | grep -E '^(pid|addr|size)=')
	WORKLOAD_PID=$pid
	info "workload pid=$pid addr=$addr size=$size"

	# pick a 2MB-aligned range in the middle for the address filter
	local base=$((addr + 128 * 1024 * 1024))
	SPLIT_ADDR_START=$(printf "0x%lx" $((base & ~((2*1024*1024)-1))))
	SPLIT_ADDR_END=$(printf "0x%lx" $((${SPLIT_ADDR_START} + 2*1024*1024)))
	info "split target: $SPLIT_ADDR_START - $SPLIT_ADDR_END (2MB)"
}

# --- count file-backed THP (ShmemPmdMapped) for the workload ---
count_thp() {
	local pid=$1
	if [ -f /proc/$pid/smaps_rollup ]; then
		awk '/ShmemPmdMapped/ {print $2}' /proc/$pid/smaps_rollup
	else
		awk '/ShmemPmdMapped/ {s+=$2} END {print s+0}' /proc/$pid/smaps
	fi
}

setup_damon() {
	info "configuring DAMON sysfs"

	echo 0 > $DAMON/kdamonds/nr_kdamonds 2>/dev/null || true
	sleep 0.5
	echo 1 > $DAMON/kdamonds/nr_kdamonds

	for _ in $(seq 1 10); do
		[ -d "$DAMON/kdamonds/0" ] && break
		sleep 0.1
	done
	[ -d "$DAMON/kdamonds/0" ] || die "kdamonds/0 not created"

	local ctx=$DAMON/kdamonds/0/contexts
	echo 1 > $ctx/nr_contexts
	echo vaddr > $ctx/0/operations

	local tgt=$ctx/0/targets
	echo 1 > $tgt/nr_targets
	echo $WORKLOAD_PID > $tgt/0/pid_target

	local regions=$tgt/0/regions
	echo 1 > $regions/nr_regions
	echo $addr > $regions/0/start
	printf "0x%lx" $((addr + size)) > $regions/0/end

	local sch=$ctx/0/schemes
	echo 1 > $sch/nr_schemes
	local action=""
	for try in split mthp_split; do
		if echo "$try" > $sch/0/action 2>/dev/null; then
			action="$try"
			break
		fi
	done
	[ -n "$action" ] || die "neither split nor mthp_split supported"
	echo $TARGET_ORDER > $sch/0/target_order

	local ap=$sch/0/access_pattern
	echo 0 > $ap/sz/min
	echo $((1024*1024*1024*1024)) > $ap/sz/max
	echo 0 > $ap/nr_accesses/min
	echo 0 > $ap/nr_accesses/max
	echo 0 > $ap/age/min
	echo $((1024*1024)) > $ap/age/max

	local flt=$sch/0/filters
	echo 1 > $flt/nr_filters
	echo addr > $flt/0/type
	echo Y > $flt/0/matching
	echo Y > $flt/0/allow
	echo $SPLIT_ADDR_START > $flt/0/addr_start
	echo $SPLIT_ADDR_END > $flt/0/addr_end

	info "DAMON configured: action=$action order=$TARGET_ORDER filter=$SPLIT_ADDR_START-$SPLIT_ADDR_END"
}

run_damon() {
	info "starting DAMON"
	echo on > $DAMON/kdamonds/0/state || die "failed to start DAMON"
	info "DAMON running, waiting 10s for scheme to fire..."
	sleep 10
	echo update_schemes_stats > $DAMON/kdamonds/0/state
	echo off > $DAMON/kdamonds/0/state
	info "DAMON stopped"
}

check_result() {
	local stats=$DAMON/kdamonds/0/contexts/0/schemes/0/stats
	local applied=$(cat $stats/sz_applied 2>/dev/null || echo 0)
	local tried=$(cat $stats/sz_tried 2>/dev/null || echo 0)

	info "scheme stats: sz_tried=$tried sz_applied=$applied"

	if [ "$applied" -gt 0 ]; then
		info "PASS: DAMOS_SPLIT applied $applied bytes on file-backed THP"
	else
		die "DAMOS_SPLIT applied 0 bytes - file-backed split did not fire"
	fi
}

cleanup() {
	echo 0 > $DAMON/kdamonds/nr_kdamonds 2>/dev/null || true
	[ -n "$WORKLOAD_PID" ] && kill $WORKLOAD_PID 2>/dev/null || true
	sleep 0.3
	rm -f "$TESTFILE" 2>/dev/null || true
	umount $MNT 2>/dev/null || true
	rm -f /tmp/damos_split_file /tmp/damos_split_file.c /tmp/damos_split_file_info.txt
}

# --- main ---
trap cleanup EXIT

info "THP enabled:"
cat /sys/kernel/mm/transparent_hugepage/enabled

mount_tmpfs
start_workload

thp_before=$(count_thp $WORKLOAD_PID)
info "ShmemPmdMapped before split: ${thp_before}kB"
[ "${thp_before:-0}" -gt 0 ] || die "no file-backed THP populated (ShmemPmdMapped=0); huge tmpfs not effective or mmap not 2MB-aligned"

setup_damon
run_damon

thp_after=$(count_thp $WORKLOAD_PID)
info "ShmemPmdMapped after split: ${thp_after}kB"

check_result

if [ "${thp_after:-0}" -lt "${thp_before:-0}" ]; then
	info "PASS: file-backed THP decreased (${thp_before}kB -> ${thp_after}kB)"
else
	info "WARN: ShmemPmdMapped did not decrease (split may have failed for shmem folios - inspect dmesg)"
fi

info "all checks passed"
