/*
 * spe_hist.c — ARM SPE sub-page access histogram builder
 *
 * Reads decoded SPE records from stdin (perf script pipe format) and builds
 * a per-THP sub-page access histogram.  The perf tool handles all SPE packet
 * decoding; this tool only does aggregation and reporting.
 *
 * Usage:
 *   perf record -e arm_spe/pa_enable=1,load_filter=0,store_filter=0/ \
 *               -a -o spe.data -- sleep 10
 *   perf script -i spe.data -F phys_addr,ip,event,pid,tid | ./spe_hist
 *
 * Output: per-THP heatmap showing access count per 4KB subpage.
 *
 * Copyright (C) 2026 Wang Lian <lianux.mm@gmail.com>
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <time.h>

/* 2MB THP = 512 * 4KB subpages */
#define PMD_PAGES	512
#define PAGE_SHIFT	12
#define PMD_SHIFT	21	/* 2MB */
#define PMD_MASK	((1UL << PMD_SHIFT) - 1)

/* Track up to this many distinct THPs */
#define MAX_THPS	4096

struct thp_entry {
	unsigned long pfn_base;		/* THP-aligned PFN */
	unsigned long counts[PMD_PAGES]; /* access count per 4KB subpage */
	unsigned long total;
	unsigned long loads;
	unsigned long stores;
};

static struct thp_entry hist[MAX_THPS];
static int nr_thps;
static unsigned long total_records;
static unsigned long skipped_no_pa;
static unsigned long skipped_no_event;

/* Find or create histogram slot for a physical address */
static struct thp_entry *find_or_create(unsigned long pa)
{
	unsigned long pfn = pa >> PAGE_SHIFT;
	unsigned long pfn_base = pfn & ~(unsigned long)(PMD_PAGES - 1);
	int i;

	for (i = 0; i < nr_thps; i++) {
		if (hist[i].pfn_base == pfn_base)
			return &hist[i];
	}

	if (nr_thps >= MAX_THPS)
		return NULL;

	hist[nr_thps].pfn_base = pfn_base;
	hist[nr_thps].total = 0;
	hist[nr_thps].loads = 0;
	hist[nr_thps].stores = 0;
	memset(hist[nr_thps].counts, 0, sizeof(hist[nr_thps].counts));
	return &hist[nr_thps++];
}

/* Parse one line of perf script output.
 * Format varies; we handle two common field orders.
 * Fields: phys_addr ip event pid tid ...
 * We need phys_addr and event (LOAD/STORE/BRANCH/etc.) */
static void process_line(char *line)
{
	char *save, *tok, *phys_str = NULL, *event_str = NULL;
	int field = 0;
	unsigned long phys_addr;

	/* perf script -F outputs tab-separated fields; first line is header */
	if (line[0] == ' ' || line[0] == '\t' || strstr(line, "phys_addr"))
		return;

	tok = strtok_r(line, "\t\n", &save);
	while (tok) {
		/* Try to parse as hex phys_addr */
		if (tok[0] == '0' && tok[1] == 'x') {
			char *end;
			unsigned long v = strtoul(tok, &end, 16);
			/* phys_addr is typically large (40+ bits) */
			if (v > 0x1000 && !phys_str && end && *end == '\0')
				phys_str = tok;
		}
		/* event field: LS, LD, ST, B, etc. */
		if (tok[0] == 'L' && (tok[1] == 'D' || tok[1] == 'S' || tok[1] == 'O'))
			event_str = tok;
		if (!strcmp(tok, "STORE") || !strcmp(tok, "LOAD"))
			event_str = tok;

		tok = strtok_r(NULL, "\t\n", &save);
		field++;
	}

	/* Alternative parsing: if fields are named, try to find phys_addr= */
	if (!phys_str) {
		char *p = strstr(line, "phys_addr");
		if (p) {
			p = strchr(p, ' ');
			if (!p) p = strchr(line, '\t');
			if (p)
				phys_str = strdup(p + 1); /* leak ok in prototype */
		}
	}

	total_records++;

	if (!phys_str) {
		skipped_no_pa++;
		return;
	}

	phys_addr = strtoul(phys_str, NULL, 16);
	if (!phys_addr) {
		skipped_no_pa++;
		return;
	}

	{
		struct thp_entry *e = find_or_create(phys_addr);
		unsigned long pfn = phys_addr >> PAGE_SHIFT;
		unsigned int idx = pfn & (PMD_PAGES - 1);

		if (!e)
			return;

		e->counts[idx]++;
		e->total++;
		if (event_str) {
			if (strstr(event_str, "S") || strstr(event_str, "STORE"))
				e->stores++;
			else if (strstr(event_str, "L") || strstr(event_str, "LOAD"))
				e->loads++;
		}
	}
}

/* Compare function for sorting THPs by total access count */
static int cmp_thp(const void *a, const void *b)
{
	const struct thp_entry *ta = a, *tb = b;
	if (ta->total > tb->total)
		return -1;
	if (ta->total < tb->total)
		return 1;
	return 0;
}

/* Print heatmap for top-N hottest THPs */
static void print_report(void)
{
	int i, j;
	int top = 10;

	qsort(hist, nr_thps, sizeof(hist[0]), cmp_thp);

	fprintf(stderr, "\n========== SPE Sub-Page Access Heatmap ==========\n");
	fprintf(stderr, "Total records: %lu  Skipped(no PA): %lu  THPs tracked: %d\n",
		total_records, skipped_no_pa, nr_thps);
	fprintf(stderr, "Top %d THP regions by access count:\n\n", top);

	for (i = 0; i < nr_thps && i < top; i++) {
		struct thp_entry *e = &hist[i];

		printf("PFN 0x%lx  total_accesses=%lu  loads=%lu  stores=%lu\n",
			e->pfn_base, e->total, e->loads, e->stores);

		/* Print ASCII heatmap: 64 columns, each = 8 subpages */
		printf("  heatmap: ");
		for (j = 0; j < 64; j++) {
			unsigned long sum = 0;
			int k;
			for (k = 0; k < 8; k++)
				sum += e->counts[j * 8 + k];
			if (sum == 0)       putchar('.');
			else if (sum < 10)  putchar('1');
			else if (sum < 50)  putchar('2');
			else if (sum < 100) putchar('3');
			else if (sum < 500) putchar('4');
			else                putchar('#');
		}
		printf("\n");

		/* Print detailed stats: hot subpages count (those accessed at least 10% of max) */
		{
			unsigned long max_cnt = 0, hot_pages = 0;
			unsigned long total_4kb = 0;
			for (j = 0; j < PMD_PAGES; j++) {
				if (e->counts[j] > max_cnt)
					max_cnt = e->counts[j];
				if (e->counts[j])
					total_4kb++;
			}
			for (j = 0; j < PMD_PAGES; j++) {
				if (e->counts[j] >= max_cnt / 10)
					hot_pages++;
			}
			printf("  4KB pages with access: %lu/%d  hot(>=10%%max): %lu  "
			       "max_access: %lu  hot_fraction: %lu%%\n",
				total_4kb, PMD_PAGES, hot_pages, max_cnt,
				(e->total > 0) ? (hot_pages * 100 / PMD_PAGES) : 0);
		}
		printf("\n");
	}

	/* Summary: count THPs by hot_fraction bucket */
	printf("=== Hot fraction distribution (hot_fraction = 4KB pages with any access / 512) ===\n");
	{
		int buckets[11] = {0}; /* 0-10%, 10-20%, ... 90-100% */
		for (i = 0; i < nr_thps; i++) {
			unsigned long accessed_pages = 0;
			int bucket;
			for (j = 0; j < PMD_PAGES; j++)
				if (hist[i].counts[j])
					accessed_pages++;
			bucket = (accessed_pages * 100 / PMD_PAGES) / 10;
			if (bucket > 10) bucket = 10;
			buckets[bucket]++;
		}
		for (i = 0; i <= 10; i++) {
			if (buckets[i])
				printf("  %d-%d%% hot: %d THPs\n",
					i * 10, (i + 1) * 10, buckets[i]);
		}
	}
}

int main(int argc, char **argv)
{
	char *line = NULL;
	size_t len = 0;
	ssize_t n;
	int max_lines = 0;

	if (argc > 1)
		max_lines = atoi(argv[1]);

	fprintf(stderr, "SPE histogram builder ready, reading from stdin...\n");

	while ((n = getline(&line, &len, stdin)) > 0) {
		if (n > 1)
			process_line(line);
		if (max_lines && total_records >= (unsigned long)max_lines)
			break;
	}

	free(line);
	print_report();
	return 0;
}
