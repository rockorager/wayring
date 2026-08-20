#ifndef WAYRING_BENCHMARK_H
#define WAYRING_BENCHMARK_H

#include <stddef.h>
#include <stdint.h>

struct benchmark_options {
	uint64_t warmup;
	uint64_t messages;
	uint32_t batch;
	int latency;
};

struct benchmark_result {
	uint64_t elapsed_ns;
	uint64_t messages;
	uint64_t mean_ns;
	uint64_t p50_ns;
	uint64_t p95_ns;
	uint64_t p99_ns;
	uint64_t max_ns;
};

int benchmark_client_fd(int fd, const struct benchmark_options *options,
                        struct benchmark_result *result);
int benchmark_server(int fd, const struct benchmark_options *options);
int benchmark_server_multi(const int *fds, size_t count,
                           const struct benchmark_options *options);

#endif
