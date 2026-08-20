#include "xdg-interop.h"

#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>
#include <wayland-server.h>

struct shm_server_state {
	struct wl_display *display;
	struct wl_listener client_destroy;
	int pool_created;
	int buffer_created;
	int buffer_destroyed;
	int pool_destroyed;
};

static void
buffer_destroy(struct wl_client *client, struct wl_resource *resource)
{
	struct shm_server_state *state = wl_resource_get_user_data(resource);

	(void) client;
	state->buffer_destroyed = 1;
	wl_resource_destroy(resource);
}

static const struct wl_buffer_interface buffer_implementation = {
	.destroy = buffer_destroy,
};

static void
pool_create_buffer(struct wl_client *client, struct wl_resource *resource,
                   uint32_t id, int32_t offset, int32_t width, int32_t height,
                   int32_t stride, uint32_t format)
{
	struct shm_server_state *state = wl_resource_get_user_data(resource);
	struct wl_resource *buffer;

	if (offset != 0 || width != 1 || height != 1 || stride != 4 ||
	    format != WL_SHM_FORMAT_ARGB8888) {
		wl_client_post_implementation_error(client, "invalid shm buffer");
		return;
	}
	buffer = wl_resource_create(client, &wl_buffer_interface, 1, id);
	if (buffer == NULL) {
		wl_client_post_no_memory(client);
		return;
	}
	wl_resource_set_implementation(buffer, &buffer_implementation, state, NULL);
	state->buffer_created = 1;
}

static void
pool_destroy(struct wl_client *client, struct wl_resource *resource)
{
	struct shm_server_state *state = wl_resource_get_user_data(resource);

	(void) client;
	if (state->buffer_destroyed)
		state->pool_destroyed = 1;
	wl_resource_destroy(resource);
}

static void
pool_resize(struct wl_client *client, struct wl_resource *resource, int32_t size)
{
	(void) resource;
	(void) size;
	wl_client_post_implementation_error(client, "unexpected shm pool resize");
}

static const struct wl_shm_pool_interface pool_implementation = {
	.create_buffer = pool_create_buffer,
	.destroy = pool_destroy,
	.resize = pool_resize,
};

static void
shm_create_pool(struct wl_client *client, struct wl_resource *resource,
                uint32_t id, int fd, int32_t size)
{
	struct shm_server_state *state = wl_resource_get_user_data(resource);
	struct wl_resource *pool;
	int flags = fcntl(fd, F_GETFD);

	if (size != 4096 || flags < 0 || (flags & FD_CLOEXEC) == 0) {
		close(fd);
		wl_client_post_implementation_error(client, "invalid shm pool");
		return;
	}
	close(fd);
	pool = wl_resource_create(client, &wl_shm_pool_interface, 1, id);
	if (pool == NULL) {
		wl_client_post_no_memory(client);
		return;
	}
	wl_resource_set_implementation(pool, &pool_implementation, state, NULL);
	state->pool_created = 1;
}

static const struct wl_shm_interface shm_implementation = {
	.create_pool = shm_create_pool,
};

static void
bind_shm(struct wl_client *client, void *data, uint32_t version, uint32_t id)
{
	struct wl_resource *resource = wl_resource_create(
		client, &wl_shm_interface, version < 1 ? (int) version : 1, id);

	if (resource == NULL) {
		wl_client_post_no_memory(client);
		return;
	}
	wl_resource_set_implementation(resource, &shm_implementation, data, NULL);
	wl_shm_send_format(resource, WL_SHM_FORMAT_ARGB8888);
}

static void
handle_shm_client_destroy(struct wl_listener *listener, void *data)
{
	struct shm_server_state *state =
		wl_container_of(listener, state, client_destroy);

	(void) data;
	wl_display_terminate(state->display);
}

int
shm_server_fd(int fd)
{
	struct shm_server_state state = {0};
	struct wl_client *client;

	state.display = wl_display_create();
	if (state.display == NULL)
		return EXIT_FAILURE;
	if (wl_global_create(state.display, &wl_shm_interface, 1,
	                     &state, bind_shm) == NULL) {
		wl_display_destroy(state.display);
		return EXIT_FAILURE;
	}
	client = wl_client_create(state.display, fd);
	if (client == NULL) {
		wl_display_destroy(state.display);
		return EXIT_FAILURE;
	}
	state.client_destroy.notify = handle_shm_client_destroy;
	wl_client_add_destroy_listener(client, &state.client_destroy);
	wl_display_run(state.display);
	wl_display_destroy(state.display);
	return state.pool_created && state.buffer_created && state.buffer_destroyed &&
	       state.pool_destroyed ? EXIT_SUCCESS : EXIT_FAILURE;
}
