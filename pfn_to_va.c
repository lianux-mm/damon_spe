/*
 * pfn_to_va.c — Reverse-map physical PFNs to virtual addresses via pagemap
 *
 * Reads THP-aligned PFNs from stdin, scans /proc/<pid>/pagemap to find
 * corresponding virtual addresses.  Outputs VA ranges for DAMON address
 * filter configuration.
 *
 * Usage:
 *   spe_hist < spe_data | pfn_to_va --pid <PID>
 *
 * Input (stdin): lines containing "PFN 0x<pfn_base>" (spe_hist output format)
 * Output (stdout): <va_start_hex> <va_end_hex> <hot_pct>
 *
 * Copyright (C) 2026 Wang Lian <lianux.mm@gmail.com>
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

#define PAGE_SHIFT	12
#define PAGE_SIZE	(1UL << PAGE_SHIFT)
#define PMD_SHIFT	21
#define PMD_SIZE	(1UL << PMD_SHIFT)
#define PMD_PAGES	512

#define PM_PRESENT	(1ULL << 63)
#define PM_PFN_MASK	((1ULL << 55) - 1)

#define MAX_TARGETS	4096
#define MAX_VMAS	8192

struct pfn_target {
	unsigned long pfn_base;
	int hot_pct;
};

struct vma_range {
	unsigned long start;
	unsigned long end;
};

static struct pfn_target targets[MAX_TARGETS];
static int nr_targets;

static struct vma_range vmas[MAX_VMAS];
static int nr_vmas;

static int parse_targets(void)
{
	char line[512];
	int n = 0;

	while (fgets(line, sizeof(line), stdin)) {
		unsigned long pfn;
		char *p;

		p = strstr(line, "PFN 0x");
		if (!p)
			p = strstr(line, "PFN 0X");
		if (!p)
			continue;

		pfn = strtoul(p + 4, NULL, 16);
		if (pfn == 0)
			continue;

		/* extract hot_fraction if present */
		int hot_pct = -1;
		char *hf = strstr(line, "hot_fraction:");
		if (!hf)
			hf = strstr(line, "hot_fraction=");
		if (hf)
			hot_pct = atoi(hf + 13);

		if (n >= MAX_TARGETS)
			break;
		targets[n].pfn_base = pfn;
		targets[n].hot_pct = hot_pct;
		n++;
	}
	return n;
}

static int parse_maps(pid_t pid)
{
	char path[64];
	FILE *f;
	char line[512];
	int n = 0;

	snprintf(path, sizeof(path), "/proc/%d/maps", pid);
	f = fopen(path, "r");
	if (!f) {
		perror(path);
		return -1;
	}

	while (fgets(line, sizeof(line), f)) {
		unsigned long start, end;

		if (sscanf(line, "%lx-%lx", &start, &end) != 2)
			continue;

		/* only care about regions large enough for THP */
		if (end - start < PMD_SIZE)
			continue;

		if (n >= MAX_VMAS)
			break;
		vmas[n].start = start;
		vmas[n].end = end;
		n++;
	}

	fclose(f);
	return n;
}

static int is_target_pfn(unsigned long pfn, int *idx)
{
	int i;
	unsigned long pfn_base = pfn & ~(unsigned long)(PMD_PAGES - 1);

	for (i = 0; i < nr_targets; i++) {
		if (targets[i].pfn_base == pfn_base) {
			*idx = i;
			return 1;
		}
	}
	return 0;
}

static int scan_pagemap(pid_t pid)
{
	char path[64];
	int fd;
	int found = 0;
	int i;

	snprintf(path, sizeof(path), "/proc/%d/pagemap", pid);
	fd = open(path, O_RDONLY);
	if (fd < 0) {
		perror(path);
		return -1;
	}

	for (i = 0; i < nr_vmas; i++) {
		unsigned long va;

		/* step by PMD_SIZE to find THP-mapped pages */
		for (va = vmas[i].start & ~(PMD_SIZE - 1);
		     va < vmas[i].end; va += PMD_SIZE) {
			uint64_t entry;
			off_t offset = (va / PAGE_SIZE) * sizeof(entry);
			ssize_t n;
			int tidx;

			n = pread(fd, &entry, sizeof(entry), offset);
			if (n != sizeof(entry))
				continue;

			if (!(entry & PM_PRESENT))
				continue;

			unsigned long pfn = entry & PM_PFN_MASK;
			if (is_target_pfn(pfn, &tidx)) {
				printf("0x%lx 0x%lx %d\n",
				       va, va + PMD_SIZE,
				       targets[tidx].hot_pct);
				found++;
			}
		}
	}

	close(fd);
	return found;
}

int main(int argc, char **argv)
{
	pid_t pid = 0;
	int i;

	for (i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--pid") == 0 && i + 1 < argc)
			pid = atoi(argv[++i]);
	}

	if (pid <= 0) {
		fprintf(stderr, "Usage: %s --pid <PID>\n", argv[0]);
		fprintf(stderr, "Reads spe_hist output from stdin.\n");
		return 1;
	}

	nr_targets = parse_targets();
	if (nr_targets == 0) {
		fprintf(stderr, "no PFN targets found in input\n");
		return 1;
	}
	fprintf(stderr, "pfn_to_va: %d PFN targets for pid %d\n",
		nr_targets, pid);

	nr_vmas = parse_maps(pid);
	if (nr_vmas < 0)
		return 1;
	fprintf(stderr, "pfn_to_va: %d VMAs >= 2MB\n", nr_vmas);

	int found = scan_pagemap(pid);
	fprintf(stderr, "pfn_to_va: %d VA ranges matched\n", found);

	return found > 0 ? 0 : 1;
}
