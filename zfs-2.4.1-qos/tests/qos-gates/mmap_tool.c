// SPDX-License-Identifier: CDDL-1.0
/*
 * mmap_tool.c — the accesses through a memory mapping that
 * diag_mmap_charge.sh measures. Built on the test machine by that script.
 *
 *   mmap_tool read FILE    read every byte of FILE through a mapping
 *   mmap_tool write FILE   overwrite every byte of FILE through a shared
 *                          mapping, then msync(MS_SYNC)
 *   mmap_tool hold FILE    map FILE, read every byte so that its pages are
 *                          resident, print "ready", then keep the mapping
 *                          until standard input reaches end of file
 *
 * read and write print "bytes=<n> seconds=<s>".
 */

#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static double
now(void)
{
	struct timespec ts;

	(void) clock_gettime(CLOCK_MONOTONIC, &ts);
	return (ts.tv_sec + ts.tv_nsec / 1e9);
}

static int
usage(void)
{
	(void) fprintf(stderr, "usage: mmap_tool read|write|hold FILE\n");
	return (2);
}

int
main(int argc, char **argv)
{
	struct stat st;
	unsigned char *p;
	volatile unsigned long sum = 0;
	double t0;
	int fd, wr, hold;
	off_t i;
	char c;

	if (argc != 3)
		return (usage());
	wr = (strcmp(argv[1], "write") == 0);
	hold = (strcmp(argv[1], "hold") == 0);
	if (!wr && !hold && strcmp(argv[1], "read") != 0)
		return (usage());

	fd = open(argv[2], wr ? O_RDWR : O_RDONLY);
	if (fd < 0 || fstat(fd, &st) != 0) {
		perror(argv[2]);
		return (1);
	}
	if (st.st_size == 0) {
		(void) fprintf(stderr, "%s is empty\n", argv[2]);
		return (1);
	}
	p = mmap(NULL, st.st_size, wr ? PROT_READ | PROT_WRITE : PROT_READ,
	    MAP_SHARED, fd, 0);
	if (p == MAP_FAILED) {
		perror("mmap");
		return (1);
	}

	t0 = now();
	if (wr) {
		(void) memset(p, 0x5a, st.st_size);
		if (msync(p, st.st_size, MS_SYNC) != 0) {
			perror("msync");
			return (1);
		}
	} else {
		for (i = 0; i < st.st_size; i++)
			sum += p[i];
	}

	if (hold) {
		(void) printf("ready\n");
		(void) fflush(stdout);
		while (read(0, &c, 1) > 0)
			;
	} else {
		(void) printf("bytes=%lld seconds=%.3f\n",
		    (long long)st.st_size, now() - t0);
	}
	(void) munmap(p, st.st_size);
	(void) close(fd);
	return (0);
}
