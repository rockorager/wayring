#include "benchmark.h"

#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>

static int
resident_bytes(pid_t pid, uint64_t *bytes)
{
	char path[64];
	FILE *statm;
	unsigned long size, resident;
	long page_size;

	if (snprintf(path, sizeof path, "/proc/%ld/statm", (long) pid) < 0)
		return -1;
	statm = fopen(path, "r");
	if (statm == NULL)
		return -1;
	if (fscanf(statm, "%lu %lu", &size, &resident) != 2) {
		fclose(statm);
		return -1;
	}
	if (fclose(statm) < 0)
		return -1;
	page_size = sysconf(_SC_PAGESIZE);
	if (page_size <= 0)
		return -1;
	*bytes = (uint64_t) resident * (uint64_t) page_size;
	return 0;
}

static int
context_switches(pid_t pid, uint64_t *voluntary, uint64_t *involuntary)
{
	char path[64];
	char line[256];
	FILE *status;
	int found = 0;

	if (snprintf(path, sizeof path, "/proc/%ld/status", (long) pid) < 0)
		return -1;
	status = fopen(path, "r");
	if (status == NULL)
		return -1;
	while (fgets(line, sizeof line, status) != NULL) {
		if (sscanf(line, "voluntary_ctxt_switches: %" SCNu64,
		           voluntary) == 1) {
			found |= 1;
		} else if (sscanf(line, "nonvoluntary_ctxt_switches: %" SCNu64,
		                  involuntary) == 1) {
			found |= 2;
		}
	}
	if (fclose(status) < 0)
		return -1;
	return found == 3 ? 0 : -1;
}

static int
sleep_ms(uint64_t milliseconds)
{
	struct timespec duration = {
		.tv_sec = (time_t) (milliseconds / 1000),
		.tv_nsec = (long) (milliseconds % 1000) * 1000000L,
	};

	while (nanosleep(&duration, &duration) < 0) {
		if (errno != EINTR)
			return -1;
	}
	return 0;
}

int
benchmark_resource_sample(const char *backend, const char *scope,
                          size_t connections, pid_t server,
                          uint64_t sample_ms)
{
	uint64_t client_rss, server_rss;
	uint64_t client_voluntary_before, client_involuntary_before;
	uint64_t server_voluntary_before, server_involuntary_before;
	uint64_t client_voluntary_after, client_involuntary_after;
	uint64_t server_voluntary_after, server_involuntary_after;

	if (connections == 0 || resident_bytes(getpid(), &client_rss) < 0 ||
	    resident_bytes(server, &server_rss) < 0)
		return -1;
	printf("backend=%s scope=%s connections=%zu sample_ms=%" PRIu64
	       " client_rss_bytes=%" PRIu64 " server_rss_bytes=%" PRIu64
	       " combined_rss_bytes=%" PRIu64
	       " server_rss_per_connection=%" PRIu64 "\n",
	       backend, scope, connections, sample_ms, client_rss, server_rss,
	       client_rss + server_rss, server_rss / connections);
	fflush(stdout);
	if (sample_ms == 0)
		return 0;
	if (context_switches(getpid(), &client_voluntary_before,
	                     &client_involuntary_before) < 0 ||
	    context_switches(server, &server_voluntary_before,
	                     &server_involuntary_before) < 0 ||
	    sleep_ms(sample_ms) < 0 ||
	    context_switches(getpid(), &client_voluntary_after,
	                     &client_involuntary_after) < 0 ||
	    context_switches(server, &server_voluntary_after,
	                     &server_involuntary_after) < 0)
		return -1;
	printf("backend=%s scope=%s-scheduler connections=%zu sample_ms=%" PRIu64
	       " client_voluntary_context_switches=%" PRIu64
	       " client_involuntary_context_switches=%" PRIu64
	       " server_voluntary_context_switches=%" PRIu64
	       " server_involuntary_context_switches=%" PRIu64 "\n",
	       backend, scope, connections, sample_ms,
	       client_voluntary_after - client_voluntary_before,
	       client_involuntary_after - client_involuntary_before,
	       server_voluntary_after - server_voluntary_before,
	       server_involuntary_after - server_involuntary_before);
	fflush(stdout);
	return 0;
}
