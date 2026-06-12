/*
 * hot_workload.c — THP sub-page selective access test
 *
 * Allocates N anonymous 2MB-aligned regions, touches only specific subpages
 * within each THP, creating a known hot/cold pattern for SPE verification.
 *
 * Usage: ./hot_workload [duration_sec] [hot_fraction_pct]
 *   duration_sec:     how long to run (default 120)
 *   hot_fraction_pct: what % of each THP to touch (default 25, i.e. first 1/4)
 *
 * The regions are madvised MADV_HUGEPAGE so khugepaged promotes them.
 * Accesses are random within the hot zone of each THP to simulate real workload.
 *
 * Outputs its PID on stdout for perf record -p.
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/mman.h>
#include <time.h>

#ifndef MADV_HUGEPAGE
#define MADV_HUGEPAGE 14
#endif

#define PMD_SIZE   (2UL * 1024 * 1024)   /* 2MB */
#define PAGE_SIZE  4096
#define PAGES_PER_PMD (PMD_SIZE / PAGE_SIZE) /* 512 */

/* Default: 16 x 2MB = 32MB of anon memory */
#define NR_THPS     16
#define TOTAL_SIZE  (NR_THPS * PMD_SIZE)

static volatile int running = 1;

static void sig_handler(int sig) { running = 0; }

int main(int argc, char **argv)
{
	int duration = 120;
	int hot_pct = 25;
	int hot_subpages;
	unsigned long i, j;
	char *base;
	unsigned long page_step;

	signal(SIGTERM, sig_handler);
	signal(SIGINT, sig_handler);

	if (argc > 1) duration = atoi(argv[1]);
	if (argc > 2) hot_pct   = atoi(argv[2]);
	if (hot_pct < 1 || hot_pct > 100) hot_pct = 25;

	hot_subpages = (PAGES_PER_PMD * hot_pct) / 100;
	if (hot_subpages < 1) hot_subpages = 1;
	page_step    = PAGES_PER_PMD / hot_subpages;

	base = mmap(NULL, TOTAL_SIZE + PMD_SIZE,
		    PROT_READ | PROT_WRITE,
		    MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (base == MAP_FAILED) {
		perror("mmap");
		return 1;
	}

	/* Align to 2MB boundary */
	{
		unsigned long aligned = ((unsigned long)base + PMD_SIZE - 1)
					& ~(PMD_SIZE - 1);
		base = (char *)aligned;
	}

	/* Populate all pages with initial touch */
	fprintf(stderr, "[*] Populating %d pages...\n", (int)(TOTAL_SIZE / PAGE_SIZE));
	for (i = 0; i < TOTAL_SIZE / PAGE_SIZE; i++)
		base[i * PAGE_SIZE] = (char)(i & 0xff);

	/* Ask khugepaged to make THPs */
	if (madvise(base, TOTAL_SIZE, MADV_HUGEPAGE))
		perror("madvise MADV_HUGEPAGE");

	fprintf(stderr, "[*] PID=%d  size=%luMB  hot_subpages=%d/%d per THP (%d%%)\n",
		getpid(), TOTAL_SIZE / (1024*1024), hot_subpages,
		(int)PAGES_PER_PMD, hot_pct);
	fprintf(stderr, "[*] Hot subpages: first %d of each THP\n", hot_subpages);
	fprintf(stderr, "[*] Running for %d seconds...\n", duration);

	/* Print PID for perf record -p */
	printf("%d\n", getpid());
	fflush(stdout);

	{
		time_t start = time(NULL);
		unsigned long iter = 0;

		while (running && (time(NULL) - start) < duration) {
			/* For each THP, randomly access its hot subpages */
			for (i = 0; i < NR_THPS; i++) {
				unsigned long thp_base = i * PMD_SIZE;
				/* Jump around within the hot zone */
				unsigned int hot_idx = (iter * 7 + i * 13) % hot_subpages;
				unsigned int subpage = hot_idx * page_step;
				if (subpage >= PAGES_PER_PMD)
					subpage = 0;

				volatile char *addr =
					(volatile char *)(base + thp_base +
							  subpage * PAGE_SIZE);
				*addr = (char)(iter & 0xff);
				(void)*addr; /* force load */

				/* Also touch adjacent cache lines within the hot page */
				volatile char *p = addr;
				for (j = 0; j < 64; j += 8) {
					(void)p[j];
				}
			}
			iter++;
			/* Small delay so we don't saturate SPE */
			if (!(iter & 0x3ff))
				usleep(100);
		}
	}

	fprintf(stderr, "[*] Done\n");
	return 0;
}
