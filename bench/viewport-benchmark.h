#ifndef WAYRING_VIEWPORT_BENCHMARK_H
#define WAYRING_VIEWPORT_BENCHMARK_H

#include <stdint.h>

struct viewport_benchmark_result {
	uint64_t elapsed_ns;
	uint64_t operations;
};

int viewport_benchmark_client_fd(int fd, uint64_t operations, uint32_t batch,
                                 uint64_t warmup,
                                 struct viewport_benchmark_result *result);
int viewport_benchmark_server_fd(int fd);

#endif
