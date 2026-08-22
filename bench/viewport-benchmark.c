#include "viewport-benchmark.h"
#include "viewporter-client-protocol.h"
#include "viewporter-server-protocol.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <wayland-client.h>
#include <wayland-server.h>

struct client_state {
	struct wl_compositor *compositor;
	struct wp_viewporter *viewporter;
};

static void
registry_global(void *data, struct wl_registry *registry, uint32_t name,
                const char *interface, uint32_t version)
{
	struct client_state *state = data;

	if (strcmp(interface, wl_compositor_interface.name) == 0)
		state->compositor = wl_registry_bind(
			registry, name, &wl_compositor_interface,
			version < 1 ? version : 1);
	else if (strcmp(interface, wp_viewporter_interface.name) == 0)
		state->viewporter = wl_registry_bind(
			registry, name, &wp_viewporter_interface,
			version < 1 ? version : 1);
}

static void
registry_global_remove(void *data, struct wl_registry *registry, uint32_t name)
{
	(void) data;
	(void) registry;
	(void) name;
}

static const struct wl_registry_listener registry_listener = {
	.global = registry_global,
	.global_remove = registry_global_remove,
};

static int
send_operations(struct wl_display *display, struct wl_surface *surface,
                struct wp_viewport *viewport, uint64_t count, uint32_t batch)
{
	uint64_t i;

	for (i = 0; i < count; i++) {
		/* One operation is two viewport state requests followed by a commit. */
		wp_viewport_set_source(viewport, wl_fixed_from_int(0),
		                       wl_fixed_from_int(0), wl_fixed_from_int(1),
		                       wl_fixed_from_int(1));
		wp_viewport_set_destination(viewport, 3, 4);
		wl_surface_commit(surface);
		if ((i + 1) % batch == 0 && wl_display_roundtrip(display) < 0)
			return -1;
	}
	if (count % batch != 0 && wl_display_roundtrip(display) < 0)
		return -1;
	return 0;
}

static int
monotonic_ns(uint64_t *value)
{
	struct timespec time;

	if (clock_gettime(CLOCK_MONOTONIC, &time) < 0)
		return -1;
	*value = (uint64_t) time.tv_sec * UINT64_C(1000000000) +
	         (uint64_t) time.tv_nsec;
	return 0;
}

int
viewport_benchmark_client_fd(int fd, uint64_t operations, uint32_t batch,
                             uint64_t warmup,
                             struct viewport_benchmark_result *result)
{
	struct client_state state = {0};
	struct wl_display *display = NULL;
	struct wl_registry *registry = NULL;
	struct wl_surface *surface = NULL;
	struct wp_viewport *viewport = NULL;
	uint64_t start;
	uint64_t end;
	int status = EXIT_FAILURE;

	if (batch == 0 || result == NULL)
		return EXIT_FAILURE;
	result->elapsed_ns = 0;
	result->operations = 0;
	display = wl_display_connect_to_fd(fd);
	if (display == NULL)
		return EXIT_FAILURE;
	registry = wl_display_get_registry(display);
	if (registry == NULL ||
	    wl_registry_add_listener(registry, &registry_listener, &state) < 0 ||
	    wl_display_roundtrip(display) < 0 || state.compositor == NULL ||
	    state.viewporter == NULL)
		goto cleanup;
	surface = wl_compositor_create_surface(state.compositor);
	if (surface == NULL)
		goto cleanup;
	viewport = wp_viewporter_get_viewport(state.viewporter, surface);
	if (viewport == NULL || wl_display_roundtrip(display) < 0)
		goto cleanup;
	if (send_operations(display, surface, viewport, warmup, batch) < 0 ||
	    monotonic_ns(&start) < 0 ||
	    send_operations(display, surface, viewport, operations, batch) < 0 ||
	    monotonic_ns(&end) < 0)
		goto cleanup;
	result->elapsed_ns = end - start;
	result->operations = operations;
	status = EXIT_SUCCESS;

cleanup:
	if (viewport != NULL)
		wp_viewport_destroy(viewport);
	if (surface != NULL)
		wl_surface_destroy(surface);
	if (state.viewporter != NULL)
		wp_viewporter_destroy(state.viewporter);
	if (state.compositor != NULL)
		wl_compositor_destroy(state.compositor);
	if (registry != NULL)
		wl_registry_destroy(registry);
	wl_display_disconnect(display);
	return status;
}

struct server_state {
	struct wl_display *display;
	struct wl_resource *surface;
	unsigned int phase;
	uint64_t sources;
	uint64_t destinations;
	uint64_t commits;
	int valid;
	int viewport_created;
	struct wl_listener client_destroy;
};

static void
surface_destroy(struct wl_client *client, struct wl_resource *resource)
{
	struct server_state *state = wl_resource_get_user_data(resource);

	(void) client;
	if (state->phase != 0)
		state->valid = 0;
	state->surface = NULL;
	wl_resource_destroy(resource);
}

static void
surface_commit(struct wl_client *client, struct wl_resource *resource)
{
	struct server_state *state = wl_resource_get_user_data(resource);

	(void) client;
	if (state->phase != 2)
		state->valid = 0;
	else
		state->commits++;
	state->phase = 0;
}

static const struct wl_surface_interface surface_implementation = {
	.destroy = surface_destroy,
	.commit = surface_commit,
};

static void
create_surface(struct wl_client *client, struct wl_resource *resource,
               uint32_t id)
{
	struct server_state *state = wl_resource_get_user_data(resource);
	struct wl_resource *surface;

	if (state->surface != NULL) {
		state->valid = 0;
		wl_client_post_implementation_error(client, "multiple surfaces");
		return;
	}
	surface = wl_resource_create(client, &wl_surface_interface, 1, id);
	if (surface == NULL) {
		wl_client_post_no_memory(client);
		return;
	}
	state->surface = surface;
	wl_resource_set_implementation(surface, &surface_implementation, state, NULL);
}

static const struct wl_compositor_interface compositor_implementation = {
	.create_surface = create_surface,
};

static void
bind_compositor(struct wl_client *client, void *data, uint32_t version,
                uint32_t id)
{
	struct wl_resource *resource = wl_resource_create(
		client, &wl_compositor_interface, version < 1 ? (int) version : 1, id);

	if (resource == NULL) {
		wl_client_post_no_memory(client);
		return;
	}
	wl_resource_set_implementation(resource, &compositor_implementation, data, NULL);
}

static void
viewport_destroy(struct wl_client *client, struct wl_resource *resource)
{
	(void) client;
	wl_resource_destroy(resource);
}

static void
viewport_set_source(struct wl_client *client, struct wl_resource *resource,
                    wl_fixed_t x, wl_fixed_t y, wl_fixed_t width,
                    wl_fixed_t height)
{
	struct server_state *state = wl_resource_get_user_data(resource);

	if (state->phase != 0 || x != wl_fixed_from_int(0) ||
	    y != wl_fixed_from_int(0) || width != wl_fixed_from_int(1) ||
	    height != wl_fixed_from_int(1)) {
		state->valid = 0;
		wl_client_post_implementation_error(client, "invalid viewport source");
		return;
	}
	state->sources++;
	state->phase = 1;
}

static void
viewport_set_destination(struct wl_client *client, struct wl_resource *resource,
                         int32_t width, int32_t height)
{
	struct server_state *state = wl_resource_get_user_data(resource);

	if (state->phase != 1 || width != 3 || height != 4) {
		state->valid = 0;
		wl_client_post_implementation_error(client,
		                                    "invalid viewport destination");
		return;
	}
	state->destinations++;
	state->phase = 2;
}

static const struct wp_viewport_interface viewport_implementation = {
	.destroy = viewport_destroy,
	.set_source = viewport_set_source,
	.set_destination = viewport_set_destination,
};

static void
viewporter_destroy(struct wl_client *client, struct wl_resource *resource)
{
	(void) client;
	wl_resource_destroy(resource);
}

static void
get_viewport(struct wl_client *client, struct wl_resource *resource, uint32_t id,
             struct wl_resource *surface)
{
	struct server_state *state = wl_resource_get_user_data(resource);
	struct wl_resource *viewport;

	if (surface != state->surface) {
		state->valid = 0;
		wl_client_post_implementation_error(client, "invalid viewport surface");
		return;
	}
	if (state->viewport_created) {
		state->valid = 0;
		wl_client_post_implementation_error(client, "multiple viewports");
		return;
	}
	viewport = wl_resource_create(client, &wp_viewport_interface, 1, id);
	if (viewport == NULL) {
		wl_client_post_no_memory(client);
		return;
	}
	state->viewport_created = 1;
	wl_resource_set_implementation(viewport, &viewport_implementation, state, NULL);
}

static const struct wp_viewporter_interface viewporter_implementation = {
	.destroy = viewporter_destroy,
	.get_viewport = get_viewport,
};

static void
bind_viewporter(struct wl_client *client, void *data, uint32_t version,
                uint32_t id)
{
	struct wl_resource *resource = wl_resource_create(
		client, &wp_viewporter_interface, version < 1 ? (int) version : 1, id);

	if (resource == NULL) {
		wl_client_post_no_memory(client);
		return;
	}
	wl_resource_set_implementation(resource, &viewporter_implementation, data, NULL);
}

static void
client_destroyed(struct wl_listener *listener, void *data)
{
	struct server_state *state =
		wl_container_of(listener, state, client_destroy);

	(void) data;
	if (state->phase != 0)
		state->valid = 0;
	wl_display_terminate(state->display);
}

int
viewport_benchmark_server_fd(int fd)
{
	struct server_state state = {.valid = 1};
	struct wl_client *client;

	state.display = wl_display_create();
	if (state.display == NULL)
		return EXIT_FAILURE;
	if (wl_global_create(state.display, &wl_compositor_interface, 1, &state,
	                     bind_compositor) == NULL ||
	    wl_global_create(state.display, &wp_viewporter_interface, 1, &state,
	                     bind_viewporter) == NULL) {
		wl_display_destroy(state.display);
		return EXIT_FAILURE;
	}
	client = wl_client_create(state.display, fd);
	if (client == NULL) {
		wl_display_destroy(state.display);
		return EXIT_FAILURE;
	}
	state.client_destroy.notify = client_destroyed;
	wl_client_add_destroy_listener(client, &state.client_destroy);
	wl_display_run(state.display);
	wl_display_destroy(state.display);
	return state.valid && state.viewport_created &&
	       state.sources == state.commits && state.destinations == state.commits
	       ? EXIT_SUCCESS : EXIT_FAILURE;
}
