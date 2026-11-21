// SPDX-License-Identifier: CDDL-1.0
/*
 * cfr_tool.c — copy a file with copy_file_range(2), the call that lets
 * OpenZFS clone blocks instead of copying them. Built on the test machine by
 * diag_other_ops.sh.
 *
 *   cfr_tool SRC DST
 *
 * Prints "bytes=<n> calls=<n> seconds=<s>".
 */

#define	_GNU_SOURCE
#include <sys/stat.h>
#include <fcntl.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>

static double
now(void)
{
	struct timespec ts;

	(void) clock_gettime(CLOCK_MONOTONIC, &ts);
	return (ts.tv_sec + ts.tv_nsec / 1e9);
}

int
main(int argc, char **argv)
{
	struct stat st;
	long long left, done = 0;
	int in, out, calls = 0;
	double t0;

	if (argc != 3) {
		(void) fprintf(stderr, "usage: cfr_tool SRC DST\n");
		return (2);
	}
	in = open(argv[1], O_RDONLY);
	if (in < 0 || fstat(in, &st) != 0) {
		perror(argv[1]);
		return (1);
	}
	out = open(argv[2], O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (out < 0) {
		perror(argv[2]);
		return (1);
	}
	t0 = now();
	for (left = st.st_size; left > 0; ) {
		ssize_t n = copy_file_range(in, NULL, out, NULL, left, 0);

		if (n < 0) {
			perror("copy_file_range");
			return (1);
		}
		if (n == 0)
			break;
		left -= n;
		done += n;
		calls++;
	}
	if (fsync(out) != 0) {
		perror("fsync");
		return (1);
	}
	(void) printf("bytes=%lld calls=%d seconds=%.3f\n", done, calls,
	    now() - t0);
	(void) close(in);
	(void) close(out);
	return (0);
}
