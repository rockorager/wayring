#include "benchmark.h"
#include "wayring-benchmark-client.h"

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/eventfd.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>

enum { max_connections = 64, max_objects = 64 };

#ifdef WAYRING_PEER_ONLY
#define MAIN_ONLY __attribute__((unused))
#else
#define MAIN_ONLY
#endif

struct client_state {
	struct wl_display *display;
	struct wl_registry *registry;
	struct wp_wayring_benchmark_v1 *benchmark;
	struct wp_wayring_benchmark_v1 *benchmarks[max_objects];
	uint32_t benchmark_global;
	uint32_t benchmark_version;
	uint32_t object_count;
	uint32_t object_cursor;
	uint32_t ack;
	uint64_t received;
	int fd_valid;
};

static MAIN_ONLY uint64_t
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
flush_blocking(struct wl_display *display)
{
	struct pollfd pollfd = {
		.fd = wl_display_get_fd(display),
		.events = POLLOUT,
	};

	while (wl_display_flush(display) < 0) {
		if (errno != EAGAIN)
			return -1;
		if (poll(&pollfd, 1, -1) < 0 && errno != EINTR)
			return -1;
	}
	return 0;
}

static int
read_exact(int fd, void *data, size_t size)
{
	uint8_t *cursor = data;

	while (size > 0) {
		ssize_t received = read(fd, cursor, size);
		if (received < 0 && errno == EINTR)
			continue;
		if (received <= 0)
			return -1;
		cursor += received;
		size -= (size_t) received;
	}
	return 0;
}

static int
write_exact(int fd, const void *data, size_t size)
{
	const uint8_t *cursor = data;

	while (size > 0) {
		ssize_t written = write(fd, cursor, size);
		if (written < 0 && errno == EINTR)
			continue;
		if (written <= 0)
			return -1;
		cursor += written;
		size -= (size_t) written;
	}
	return 0;
}

static int
raw_drain_phase(int fd, uint64_t bytes, uint8_t acknowledgement)
{
	uint8_t storage[64 * 1024];

	while (bytes > 0) {
		size_t wanted = bytes < sizeof storage ? (size_t) bytes : sizeof storage;
		if (read_exact(fd, storage, wanted) < 0)
			return -1;
		bytes -= wanted;
	}
	return write_exact(fd, &acknowledgement, sizeof acknowledgement);
}

static int
wait_for_raw_drain(int fd, uint8_t acknowledgement)
{
	uint8_t received;

	return read_exact(fd, &received, sizeof received) == 0 &&
	       received == acknowledgement ? 0 : -1;
}

static void
handle_global(void *data, struct wl_registry *registry, uint32_t name,
              const char *interface, uint32_t version)
{
	struct client_state *state = data;

	if (strcmp(interface, wp_wayring_benchmark_v1_interface.name) == 0) {
		state->benchmark_global = name;
		state->benchmark_version = version < 1 ? version : 1;
		state->benchmark = wl_registry_bind(
			registry, name, &wp_wayring_benchmark_v1_interface,
			state->benchmark_version);
		state->benchmarks[0] = state->benchmark;
	}
}

static void
handle_global_remove(void *data, struct wl_registry *registry, uint32_t name)
{
	(void) data;
	(void) registry;
	(void) name;
}

static const struct wl_registry_listener registry_listener = {
	.global = handle_global,
	.global_remove = handle_global_remove,
};

static void
handle_pong(void *data, struct wp_wayring_benchmark_v1 *benchmark,
            uint32_t sequence)
{
	struct client_state *state = data;

	(void) benchmark;
	state->ack = sequence;
	state->received++;
}

static void
handle_pong_fd(void *data, struct wp_wayring_benchmark_v1 *benchmark,
               uint32_t sequence, int32_t descriptor)
{
	struct client_state *state = data;
	int flags = fcntl(descriptor, F_GETFD);

	(void) benchmark;
	state->fd_valid = sequence == 0 && flags >= 0 &&
	                  (flags & FD_CLOEXEC) != 0;
	close(descriptor);
}

static const struct wp_wayring_benchmark_v1_listener benchmark_listener = {
	.pong = handle_pong,
	.pong_fd = handle_pong_fd,
};

static int run_latency(struct client_state *states, size_t connections,
                       const struct benchmark_options *options,
                       struct benchmark_result *result);

static int
connect_client(struct client_state *state, int fd,
               const struct benchmark_options *options)
{
	uint32_t i;

	state->display = wl_display_connect_to_fd(fd);
	if (state->display == NULL)
		return -1;
	state->registry = wl_display_get_registry(state->display);
	wl_registry_add_listener(state->registry, &registry_listener, state);
	if (wl_display_roundtrip(state->display) < 0 || state->benchmark == NULL)
		return -1;
	state->object_count = options->objects;
	for (i = 1; i < state->object_count; i++)
		state->benchmarks[i] = wl_registry_bind(
			state->registry, state->benchmark_global,
			&wp_wayring_benchmark_v1_interface, state->benchmark_version);
	for (i = 0; i < state->object_count; i++) {
		if (state->benchmarks[i] == NULL)
			return -1;
		wp_wayring_benchmark_v1_set_user_data(state->benchmarks[i], state);
		wp_wayring_benchmark_v1_add_listener(
			state->benchmarks[i], &benchmark_listener, state);
	}
	if (flush_blocking(state->display) < 0)
		return -1;
	return 0;
}

static int
wait_for_ack(struct client_state *state, uint32_t ack)
{
	while (state->ack != ack) {
		if (wl_display_dispatch(state->display) < 0)
			return -1;
	}
	return 0;
}

static int
send_phase(struct client_state *states, size_t connections, uint64_t count,
           uint32_t batch, uint32_t ack)
{
	uint64_t remaining = count;
	size_t connection;

	while (remaining > 0) {
		uint64_t chunk = remaining < batch ? remaining : batch;
		uint64_t i;

		for (connection = 0; connection < connections; connection++) {
			for (i = 0; i < chunk; i++) {
				wp_wayring_benchmark_v1_ping(
					states[connection].benchmarks[
						states[connection].object_cursor], ack);
				states[connection].object_cursor++;
				if (states[connection].object_cursor ==
				    states[connection].object_count)
					states[connection].object_cursor = 0;
			}
		}
		for (connection = 0; connection < connections; connection++) {
			if (flush_blocking(states[connection].display) < 0)
				return -1;
		}
		remaining -= chunk;
	}
	for (connection = 0; connection < connections; connection++) {
		if (wait_for_ack(&states[connection], ack) < 0)
			return -1;
	}
	return 0;
}

int
benchmark_client_fd(int fd, const struct benchmark_options *options,
                    struct benchmark_result *result)
{
	struct client_state state = {0};
	uint64_t start;
	int descriptor;
	int status = EXIT_FAILURE;

	if (result == NULL)
		return EXIT_FAILURE;
	result->elapsed_ns = 0;
	result->messages = 0;
	result->mean_ns = 0;
	result->p50_ns = 0;
	result->p95_ns = 0;
	result->p99_ns = 0;
	result->max_ns = 0;
	if (options == NULL || options->warmup == 0 || options->messages == 0 ||
	    options->batch == 0 || options->objects == 0 ||
	    options->objects > max_objects)
		return EXIT_FAILURE;
	if (connect_client(&state, fd, options) < 0)
		goto cleanup;
	descriptor = eventfd(0, EFD_CLOEXEC);
	if (descriptor < 0)
		goto cleanup;
	wp_wayring_benchmark_v1_ping_fd(state.benchmark, 0, descriptor);
	close(descriptor);
	if (flush_blocking(state.display) < 0)
		goto cleanup;
	while (!state.fd_valid) {
		if (wl_display_dispatch(state.display) < 0)
			goto cleanup;
	}
	if (options->latency) {
		if (run_latency(&state, 1, options, result) < 0)
			goto cleanup;
		result->messages = options->messages;
		status = EXIT_SUCCESS;
		goto cleanup;
	}
	if (send_phase(&state, 1, options->warmup, options->batch, 1) < 0)
		goto cleanup;
	start = monotonic_ns();
	if (send_phase(&state, 1, options->messages, options->batch, 2) < 0)
		goto cleanup;
	result->elapsed_ns = monotonic_ns() - start;
	result->messages = options->messages;
	status = EXIT_SUCCESS;

cleanup:
	while (state.object_count > 0)
		wp_wayring_benchmark_v1_destroy(
			state.benchmarks[--state.object_count]);
	if (state.registry != NULL)
		wl_registry_destroy(state.registry);
	if (state.display != NULL)
		wl_display_disconnect(state.display);
	return status;
}

static MAIN_ONLY int
transmit_phase(struct client_state *state, uint64_t count, uint32_t batch,
               uint32_t sequence)
{
	uint64_t remaining = count;

	while (remaining > 0) {
		uint64_t chunk = remaining < batch ? remaining : batch;
		uint64_t i;

		for (i = 0; i < chunk; i++)
			wp_wayring_benchmark_v1_ping(state->benchmark, sequence);
		if (flush_blocking(state->display) < 0)
			return -1;
		remaining -= chunk;
	}
	return 0;
}

static MAIN_ONLY int
client_transmit_main(const struct benchmark_options *options)
{
	/* get_registry is 12 bytes and the dynamic bind is 48 bytes. */
	const uint64_t setup_bytes = 60;
	struct client_state state = {0};
	uint64_t start, elapsed;
	int sockets[2], child_status;
	pid_t child;

	if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sockets) < 0)
		return EXIT_FAILURE;
	child = fork();
	if (child < 0)
		return EXIT_FAILURE;
	if (child == 0) {
		close(sockets[0]);
		if (raw_drain_phase(sockets[1], setup_bytes, 0) < 0 ||
		    raw_drain_phase(sockets[1], options->warmup * 12, 1) < 0 ||
		    raw_drain_phase(sockets[1], options->messages * 12, 2) < 0)
			_exit(EXIT_FAILURE);
		close(sockets[1]);
		_exit(EXIT_SUCCESS);
	}
	close(sockets[1]);
	state.display = wl_display_connect_to_fd(sockets[0]);
	if (state.display == NULL)
		return EXIT_FAILURE;
	state.registry = wl_display_get_registry(state.display);
	state.benchmark = wl_registry_bind(
		state.registry, 1, &wp_wayring_benchmark_v1_interface, 1);
	if (state.registry == NULL || state.benchmark == NULL ||
	    flush_blocking(state.display) < 0 || wait_for_raw_drain(sockets[0], 0) < 0)
		return EXIT_FAILURE;
	if (transmit_phase(&state, options->warmup, options->batch, 1) < 0 ||
	    wait_for_raw_drain(sockets[0], 1) < 0)
		return EXIT_FAILURE;
	start = monotonic_ns();
	if (transmit_phase(&state, options->messages, options->batch, 2) < 0 ||
	    wait_for_raw_drain(sockets[0], 2) < 0)
		return EXIT_FAILURE;
	elapsed = monotonic_ns() - start;

	wp_wayring_benchmark_v1_destroy(state.benchmark);
	wl_registry_destroy(state.registry);
	wl_display_disconnect(state.display);
	if (waitpid(child, &child_status, 0) < 0 || !WIFEXITED(child_status) ||
	    WEXITSTATUS(child_status) != 0)
		return EXIT_FAILURE;
	printf("backend=libwayland scope=client-tx messages=%" PRIu64
	       " batch=%" PRIu32 " elapsed_ns=%" PRIu64
	       " messages_per_second=%.0f\n",
	       options->messages, options->batch, elapsed,
	       (double) options->messages * 1000000000.0 / (double) elapsed);
	return EXIT_SUCCESS;
}

static int
raw_write_phase(int fd, uint64_t count, uint32_t batch, uint32_t sequence)
{
	size_t capacity = (size_t) batch * 12;
	uint32_t *storage = malloc(capacity);
	uint64_t remaining = count;

	if (storage == NULL)
		return -1;
	while (remaining > 0) {
		uint64_t chunk = remaining < batch ? remaining : batch;
		uint64_t i;

		for (i = 0; i < chunk; i++) {
			storage[i * 3] = 3;
			storage[i * 3 + 1] = UINT32_C(12) << 16;
			storage[i * 3 + 2] = sequence;
		}
		if (write_exact(fd, storage, (size_t) chunk * 12) < 0) {
			free(storage);
			return -1;
		}
		remaining -= chunk;
	}
	free(storage);
	return 0;
}

static int
receive_phase(struct client_state *state, uint64_t count, uint32_t sequence)
{
	uint64_t target = state->received + count;

	while (state->received < target) {
		if (wl_display_dispatch(state->display) < 0)
			return -1;
	}
	return state->received == target && state->ack == sequence ? 0 : -1;
}

static MAIN_ONLY int
client_receive_main(const struct benchmark_options *options)
{
	const uint64_t setup_bytes = 60;
	struct client_state state = {0};
	uint64_t start, elapsed;
	uint8_t acknowledgement;
	int sockets[2], child_status;
	pid_t child;

	if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sockets) < 0)
		return EXIT_FAILURE;
	child = fork();
	if (child < 0)
		return EXIT_FAILURE;
	if (child == 0) {
		close(sockets[0]);
		if (raw_drain_phase(sockets[1], setup_bytes, 0) < 0 ||
		    raw_write_phase(sockets[1], options->warmup, options->batch, 1) < 0 ||
		    read_exact(sockets[1], &acknowledgement, 1) < 0 || acknowledgement != 1 ||
		    raw_write_phase(sockets[1], options->messages, options->batch, 2) < 0 ||
		    read_exact(sockets[1], &acknowledgement, 1) < 0 || acknowledgement != 2)
			_exit(EXIT_FAILURE);
		close(sockets[1]);
		_exit(EXIT_SUCCESS);
	}
	close(sockets[1]);
	state.display = wl_display_connect_to_fd(sockets[0]);
	if (state.display == NULL)
		return EXIT_FAILURE;
	state.registry = wl_display_get_registry(state.display);
	state.benchmark = wl_registry_bind(
		state.registry, 1, &wp_wayring_benchmark_v1_interface, 1);
	if (state.registry == NULL || state.benchmark == NULL ||
	    wp_wayring_benchmark_v1_add_listener(
		    state.benchmark, &benchmark_listener, &state) < 0 ||
	    flush_blocking(state.display) < 0 || wait_for_raw_drain(sockets[0], 0) < 0)
		return EXIT_FAILURE;
	if (receive_phase(&state, options->warmup, 1) < 0 ||
	    write_exact(sockets[0], "\1", 1) < 0)
		return EXIT_FAILURE;
	start = monotonic_ns();
	if (receive_phase(&state, options->messages, 2) < 0)
		return EXIT_FAILURE;
	elapsed = monotonic_ns() - start;
	if (write_exact(sockets[0], "\2", 1) < 0)
		return EXIT_FAILURE;

	wp_wayring_benchmark_v1_destroy(state.benchmark);
	wl_registry_destroy(state.registry);
	wl_display_disconnect(state.display);
	if (waitpid(child, &child_status, 0) < 0 || !WIFEXITED(child_status) ||
	    WEXITSTATUS(child_status) != 0)
		return EXIT_FAILURE;
	printf("backend=libwayland scope=client-rx messages=%" PRIu64
	       " batch=%" PRIu32 " elapsed_ns=%" PRIu64
	       " messages_per_second=%.0f\n",
	       options->messages, options->batch, elapsed,
	       (double) options->messages * 1000000000.0 / (double) elapsed);
	return EXIT_SUCCESS;
}

static int
latency_round(struct client_state *states, size_t connections, uint32_t sequence)
{
	size_t connection;

	for (connection = 0; connection < connections; connection++)
		wp_wayring_benchmark_v1_ping(states[connection].benchmark, sequence);
	for (connection = 0; connection < connections; connection++) {
		if (flush_blocking(states[connection].display) < 0)
			return -1;
	}
	for (connection = 0; connection < connections; connection++) {
		if (wait_for_ack(&states[connection], sequence) < 0)
			return -1;
	}
	return 0;
}

static int
compare_u64(const void *left, const void *right)
{
	uint64_t a = *(const uint64_t *) left;
	uint64_t b = *(const uint64_t *) right;

	return (a > b) - (a < b);
}

static uint64_t
percentile(const uint64_t *samples, uint64_t count, uint64_t percent)
{
	uint64_t rank = (count * percent + 99) / 100;

	return samples[rank == 0 ? 0 : rank - 1];
}

static int
run_latency(struct client_state *states, size_t connections,
            const struct benchmark_options *options,
            struct benchmark_result *result)
{
	uint64_t *samples = malloc((size_t) options->messages * sizeof *samples);
	long double sum = 0;
	uint64_t i;

	if (samples == NULL)
		return -1;
	for (i = 0; i < options->warmup; i++) {
		if (latency_round(states, connections, (uint32_t) i + 1) < 0) {
			free(samples);
			return -1;
		}
	}
	for (i = 0; i < options->messages; i++) {
		uint64_t start = monotonic_ns();
		if (latency_round(states, connections,
		                  (uint32_t) (options->warmup + i + 1)) < 0) {
			free(samples);
			return -1;
		}
		samples[i] = monotonic_ns() - start;
		sum += samples[i];
	}
	qsort(samples, (size_t) options->messages, sizeof *samples, compare_u64);
	if (result != NULL) {
		result->mean_ns = (uint64_t) (sum / options->messages);
		result->p50_ns = percentile(samples, options->messages, 50);
		result->p95_ns = percentile(samples, options->messages, 95);
		result->p99_ns = percentile(samples, options->messages, 99);
		result->max_ns = samples[options->messages - 1];
	} else {
		printf("backend=libwayland connections=%zu latency_scope=round_trip_all "
		       "rounds=%" PRIu64 " operations=%" PRIu64
		       " mean_ns=%.0Lf p50_ns=%" PRIu64 " p95_ns=%" PRIu64
		       " p99_ns=%" PRIu64 " max_ns=%" PRIu64 "\n",
		       connections, options->messages, options->messages * connections,
		       sum / options->messages,
		       percentile(samples, options->messages, 50),
		       percentile(samples, options->messages, 95),
		       percentile(samples, options->messages, 99),
		       samples[options->messages - 1]);
	}
	free(samples);
	return 0;
}

#ifndef WAYRING_PEER_ONLY
int
main(int argc, char **argv)
{
	struct benchmark_options options = {
		.warmup = 100000,
		.messages = 1000000,
		.batch = 256,
		.objects = 1,
	};
	struct client_state *states;
	int (*sockets)[2];
	int *server_fds;
	uint64_t connections = 1;
	int client_tx = 0;
	int client_rx = 0;
	int idle = 0;
	uint64_t idle_ms = 1000;
	uint64_t start, elapsed, total_messages;
	int child_status;
	pid_t child;
	size_t i;

	if (argc > 1)
		options.messages = parse_count(argv[1], "message count");
	if (argc > 2)
		options.batch = (uint32_t) parse_count(argv[2], "batch size");
	if (argc > 3)
		options.warmup = parse_count(argv[3], "warmup count");
	if (argc > 4)
		connections = parse_count(argv[4], "connection count");
	if (argc > 5) {
		if (strcmp(argv[5], "latency") == 0) {
			options.latency = 1;
		} else if (strcmp(argv[5], "client-tx") == 0) {
			client_tx = 1;
		} else if (strcmp(argv[5], "client-rx") == 0) {
			client_rx = 1;
		} else if (strcmp(argv[5], "idle") == 0) {
			idle = 1;
		} else if (strcmp(argv[5], "round-trip") != 0) {
			fprintf(stderr, "invalid benchmark mode: %s\n", argv[5]);
			return EXIT_FAILURE;
		}
	}
	if (argc > 6)
		options.objects = (uint32_t) parse_count(argv[6], "object count");
	if (argc > 7)
		idle_ms = parse_count(argv[7], "idle duration");
	if (options.messages == 0 || options.batch == 0 || options.warmup == 0 ||
	    options.objects == 0 || options.objects > max_objects ||
	    connections == 0 || connections > max_connections ||
	    (options.objects > 1 &&
	     (connections != 1 || options.latency || client_tx || client_rx || idle)) ||
	    (idle && idle_ms == 0) ||
	    (options.latency && options.messages + options.warmup > UINT32_MAX)) {
		fprintf(stderr, "counts must be nonzero and connections at most 64\n");
		return EXIT_FAILURE;
	}
	if (client_tx) {
		if (connections != 1) {
			fprintf(stderr, "client-tx requires one connection\n");
			return EXIT_FAILURE;
		}
		return client_transmit_main(&options);
	}
	if (client_rx) {
		if (connections != 1) {
			fprintf(stderr, "client-rx requires one connection\n");
			return EXIT_FAILURE;
		}
		return client_receive_main(&options);
	}

	sockets = calloc((size_t) connections, sizeof *sockets);
	server_fds = calloc((size_t) connections, sizeof *server_fds);
	states = calloc((size_t) connections, sizeof *states);
	if (sockets == NULL || server_fds == NULL || states == NULL)
		return EXIT_FAILURE;
	for (i = 0; i < connections; i++) {
		if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sockets[i]) < 0) {
			perror("socketpair");
			return EXIT_FAILURE;
		}
		server_fds[i] = sockets[i][1];
	}

	child = fork();
	if (child < 0) {
		perror("fork");
		return EXIT_FAILURE;
	}
	if (child == 0) {
		for (i = 0; i < connections; i++)
			close(sockets[i][0]);
		_exit(benchmark_server_multi(server_fds, (size_t) connections,
		                             &options));
	}
	for (i = 0; i < connections; i++) {
		close(sockets[i][1]);
		if (connect_client(&states[i], sockets[i][0], &options) < 0) {
			fprintf(stderr, "failed to connect libwayland client\n");
			return EXIT_FAILURE;
		}
	}
	if (idle && benchmark_resource_sample(
		    "libwayland", "idle", (size_t) connections, child, idle_ms) < 0) {
		perror("idle sample");
		return EXIT_FAILURE;
	}

	if (options.latency) {
		if (run_latency(states, (size_t) connections, &options, NULL) < 0) {
			perror("latency");
			return EXIT_FAILURE;
		}
	} else {
		if (send_phase(states, (size_t) connections, options.warmup,
		               options.batch, 1) < 0) {
			perror("warmup");
			return EXIT_FAILURE;
		}
		if (idle && benchmark_resource_sample(
			    "libwayland", "active", (size_t) connections, child, 0) < 0) {
			perror("active sample");
			return EXIT_FAILURE;
		}
		start = monotonic_ns();
		if (send_phase(states, (size_t) connections, options.messages,
		               options.batch, 2) < 0) {
			perror("benchmark");
			return EXIT_FAILURE;
		}
		elapsed = monotonic_ns() - start;
		total_messages = options.messages * connections;
		if (!idle) printf("backend=libwayland connections=%" PRIu64 " objects=%" PRIu32
		       " messages=%" PRIu64 " batch=%" PRIu32
		       " elapsed_ns=%" PRIu64 " messages_per_second=%.0f\n",
		       connections, options.objects, total_messages, options.batch, elapsed,
		       (double) total_messages * 1000000000.0 / (double) elapsed);
	}

	for (i = 0; i < connections; i++) {
		while (states[i].object_count > 0)
			wp_wayring_benchmark_v1_destroy(
				states[i].benchmarks[--states[i].object_count]);
		wl_registry_destroy(states[i].registry);
		wl_display_disconnect(states[i].display);
	}
	if (waitpid(child, &child_status, 0) < 0 || !WIFEXITED(child_status) ||
	    WEXITSTATUS(child_status) != 0) {
		fprintf(stderr, "server failed\n");
		return EXIT_FAILURE;
	}
	free(states);
	free(server_fds);
	free(sockets);
	return EXIT_SUCCESS;
}
#endif
