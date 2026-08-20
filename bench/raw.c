#include "benchmark.h"

#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

enum { message_size = 12 };

static uint64_t
parse_count(const char *value, const char *name)
{
	char *end;
	unsigned long long result;

	errno = 0;
	result = strtoull(value, &end, 10);
	if (errno != 0 || *value == '\0' || *end != '\0') {
		fprintf(stderr, "invalid %s: %s\n", name, value);
		exit(EXIT_FAILURE);
	}
	return (uint64_t) result;
}

static uint64_t
monotonic_ns(void)
{
	struct timespec time;

	if (clock_gettime(CLOCK_MONOTONIC_RAW, &time) < 0) {
		perror("clock_gettime");
		exit(EXIT_FAILURE);
	}
	return (uint64_t) time.tv_sec * UINT64_C(1000000000) +
	       (uint64_t) time.tv_nsec;
}

static int
write_all(int fd, const void *data, size_t size)
{
	const uint8_t *cursor = data;

	while (size > 0) {
		ssize_t written = write(fd, cursor, size);
		if (written < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		cursor += written;
		size -= (size_t) written;
	}
	return 0;
}

static int
read_all(int fd, void *data, size_t size)
{
	uint8_t *cursor = data;

	while (size > 0) {
		ssize_t received = read(fd, cursor, size);
		if (received <= 0) {
			if (received < 0 && errno == EINTR)
				continue;
			return -1;
		}
		cursor += received;
		size -= (size_t) received;
	}
	return 0;
}

static int
server(int fd, const struct benchmark_options *options)
{
	uint8_t buffer[64 * 1024];
	uint64_t phase_counts[] = {options->warmup, options->messages};
	size_t phase;

	for (phase = 0; phase < 2; phase++) {
		uint64_t bytes = phase_counts[phase] * message_size;
		uint8_t ack = (uint8_t) phase;
		while (bytes > 0) {
			size_t wanted = bytes < sizeof buffer ? (size_t) bytes : sizeof buffer;
			ssize_t received = read(fd, buffer, wanted);
			if (received <= 0) {
				if (received < 0 && errno == EINTR)
					continue;
				return EXIT_FAILURE;
			}
			bytes -= (uint64_t) received;
		}
		if (write_all(fd, &ack, sizeof ack) < 0)
			return EXIT_FAILURE;
	}
	return EXIT_SUCCESS;
}

static int
send_phase(int fd, uint64_t count, uint32_t batch, uint8_t expected_ack)
{
	size_t capacity = (size_t) batch * message_size;
	uint8_t *buffer = malloc(capacity);
	uint64_t remaining = count;
	uint8_t ack;

	if (buffer == NULL)
		return -1;
	memset(buffer, 0, capacity);
	while (remaining > 0) {
		uint64_t chunk = remaining < batch ? remaining : batch;
		if (write_all(fd, buffer, (size_t) chunk * message_size) < 0) {
			free(buffer);
			return -1;
		}
		remaining -= chunk;
	}
	free(buffer);
	if (read_all(fd, &ack, 1) < 0 || ack != expected_ack)
		return -1;
	return 0;
}

int
main(int argc, char **argv)
{
	struct benchmark_options options = {
		.warmup = 100000,
		.messages = 1000000,
		.batch = 256,
	};
	uint64_t start, elapsed;
	int sockets[2], child_status;
	pid_t child;

	if (argc > 1)
		options.messages = parse_count(argv[1], "message count");
	if (argc > 2)
		options.batch = (uint32_t) parse_count(argv[2], "batch size");
	if (argc > 3)
		options.warmup = parse_count(argv[3], "warmup count");
	if (options.messages == 0 || options.batch == 0 ||
	    options.warmup == 0) {
		fprintf(stderr, "counts and batch size must be nonzero\n");
		return EXIT_FAILURE;
	}

	if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sockets) < 0) {
		perror("socketpair");
		return EXIT_FAILURE;
	}
	child = fork();
	if (child < 0) {
		perror("fork");
		return EXIT_FAILURE;
	}
	if (child == 0) {
		close(sockets[0]);
		_exit(server(sockets[1], &options));
	}
	close(sockets[1]);

	if (send_phase(sockets[0], options.warmup, options.batch, 0) < 0) {
		perror("warmup");
		return EXIT_FAILURE;
	}
	start = monotonic_ns();
	if (send_phase(sockets[0], options.messages, options.batch, 1) < 0) {
		perror("benchmark");
		return EXIT_FAILURE;
	}
	elapsed = monotonic_ns() - start;
	close(sockets[0]);

	printf("backend=raw messages=%" PRIu64 " batch=%" PRIu32
	       " elapsed_ns=%" PRIu64 " messages_per_second=%.0f\n",
	       options.messages, options.batch, elapsed,
	       (double) options.messages * 1000000000.0 / (double) elapsed);

	if (waitpid(child, &child_status, 0) < 0 || !WIFEXITED(child_status) ||
	    WEXITSTATUS(child_status) != 0) {
		fprintf(stderr, "server failed\n");
		return EXIT_FAILURE;
	}
	return EXIT_SUCCESS;
}
