#include "benchmark.h"
#include "wayring-benchmark-server.h"

#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>
#include <wayland-server.h>

struct server_state {
	struct wl_display *display;
	const struct benchmark_options *options;
	size_t expected_clients;
	size_t destroyed_clients;
	uint64_t received;
	int valid;
};

struct connection_state {
	struct server_state *server;
	struct wl_listener client_destroy;
	uint64_t received;
	uint64_t next_ack;
	uint64_t final_ack;
};

static void
handle_ping(struct wl_client *client, struct wl_resource *resource,
            uint32_t sequence)
{
	struct connection_state *connection =
		wl_resource_get_user_data(resource);
	struct server_state *server = connection->server;

	(void) client;
	connection->received++;
	server->received++;
	if (connection->received > connection->final_ack)
		server->valid = 0;
	if (server->options->latency ||
	    connection->received == connection->next_ack) {
		wp_wayring_benchmark_v1_send_pong(resource, sequence);
		wl_client_flush(wl_resource_get_client(resource));
		if (!server->options->latency &&
		    connection->next_ack != connection->final_ack)
			connection->next_ack = connection->final_ack;
	}
}

static void
handle_ping_fd(struct wl_client *client, struct wl_resource *resource,
               uint32_t sequence, int32_t descriptor)
{
	(void) client;
	wp_wayring_benchmark_v1_send_pong_fd(resource, sequence, descriptor);
	close(descriptor);
	wl_client_flush(wl_resource_get_client(resource));
}

static const struct wp_wayring_benchmark_v1_interface implementation = {
	.ping = handle_ping,
	.ping_fd = handle_ping_fd,
};

static void
handle_client_destroy(struct wl_listener *listener, void *data)
{
	struct connection_state *connection =
		wl_container_of(listener, connection, client_destroy);
	struct server_state *server = connection->server;

	(void) data;
	if (connection->received != connection->final_ack)
		server->valid = 0;
	server->destroyed_clients++;
	free(connection);
	if (server->destroyed_clients == server->expected_clients)
		wl_display_terminate(server->display);
}

static void
bind_benchmark(struct wl_client *client, void *data, uint32_t version,
               uint32_t id)
{
	struct server_state *server = data;
	struct connection_state *connection;
	struct wl_resource *resource;

	connection = calloc(1, sizeof *connection);
	resource = wl_resource_create(client, &wp_wayring_benchmark_v1_interface,
	                              (int) version, id);
	if (connection == NULL || resource == NULL) {
		free(connection);
		wl_client_post_no_memory(client);
		return;
	}

	connection->server = server;
	connection->next_ack = server->options->warmup;
	connection->final_ack = server->options->warmup +
	                        server->options->messages;
	wl_resource_set_implementation(resource, &implementation, connection, NULL);
	connection->client_destroy.notify = handle_client_destroy;
	wl_client_add_destroy_listener(client, &connection->client_destroy);
}

int
benchmark_server_multi(const int *fds, size_t count,
                       const struct benchmark_options *options)
{
	struct server_state state = {
		.options = options,
		.expected_clients = count,
		.valid = 1,
	};
	struct wl_global *global;
	size_t i;

	state.display = wl_display_create();
	if (state.display == NULL)
		return EXIT_FAILURE;
	global = wl_global_create(state.display,
	                          &wp_wayring_benchmark_v1_interface, 1, &state,
	                          bind_benchmark);
	if (global == NULL) {
		wl_display_destroy(state.display);
		return EXIT_FAILURE;
	}
	for (i = 0; i < count; i++) {
		if (wl_client_create(state.display, fds[i]) == NULL) {
			wl_display_destroy(state.display);
			return EXIT_FAILURE;
		}
	}

	wl_display_run(state.display);
	wl_display_destroy(state.display);
	return state.valid &&
	       state.received == (options->warmup + options->messages) * count
	       ? EXIT_SUCCESS : EXIT_FAILURE;
}

int
benchmark_server(int fd, const struct benchmark_options *options)
{
	return benchmark_server_multi(&fd, 1, options);
}
