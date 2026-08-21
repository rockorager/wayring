#include "xdg-interop.h"

#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>
#include <wayland-server.h>

struct shm_server_state {
	struct wl_display *display;
	struct wl_listener client_destroy;
	struct wl_resource *buffer;
	struct wl_resource *frame;
	int pool_created;
	int buffer_created;
	int buffer_destroyed;
	int pool_destroyed;
	int surface_created;
	int surface_destroyed;
	int attached;
	int damaged;
	int damaged_buffer;
	int committed;
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
	state->buffer = buffer;
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
surface_destroy(struct wl_client *client, struct wl_resource *resource)
{
	struct shm_server_state *state = wl_resource_get_user_data(resource);

	(void) client;
	state->surface_destroyed = 1;
	wl_resource_destroy(resource);
}

static void
surface_attach(struct wl_client *client, struct wl_resource *resource,
               struct wl_resource *buffer, int32_t x, int32_t y)
{
	struct shm_server_state *state = wl_resource_get_user_data(resource);

	if (buffer != state->buffer || x != 2 || y != -3) {
		wl_client_post_implementation_error(client, "invalid surface attach");
		return;
	}
	state->attached = 1;
}

static void
surface_damage(struct wl_client *client, struct wl_resource *resource,
               int32_t x, int32_t y, int32_t width, int32_t height)
{
	struct shm_server_state *state = wl_resource_get_user_data(resource);

	if (x != 1 || y != 2 || width != 3 || height != 4) {
		wl_client_post_implementation_error(client, "invalid surface damage");
		return;
	}
	state->damaged = 1;
}

static void
surface_frame(struct wl_client *client, struct wl_resource *resource, uint32_t id)
{
	struct shm_server_state *state = wl_resource_get_user_data(resource);

	state->frame = wl_resource_create(client, &wl_callback_interface, 1, id);
	if (state->frame == NULL)
		wl_client_post_no_memory(client);
}

static void
surface_commit(struct wl_client *client, struct wl_resource *resource)
{
	struct shm_server_state *state = wl_resource_get_user_data(resource);

	if (!state->attached || !state->damaged || !state->damaged_buffer ||
	    state->frame == NULL) {
		wl_client_post_implementation_error(client, "incomplete surface commit");
		return;
	}
	wl_buffer_send_release(state->buffer);
	wl_callback_send_done(state->frame, 123);
	wl_resource_destroy(state->frame);
	state->frame = NULL;
	state->committed = 1;
}

static void
surface_damage_buffer(struct wl_client *client, struct wl_resource *resource,
                      int32_t x, int32_t y, int32_t width, int32_t height)
{
	struct shm_server_state *state = wl_resource_get_user_data(resource);

	if (x != 5 || y != 6 || width != 7 || height != 8) {
		wl_client_post_implementation_error(client, "invalid buffer damage");
		return;
	}
	state->damaged_buffer = 1;
}

static const struct wl_surface_interface surface_implementation = {
	.destroy = surface_destroy,
	.attach = surface_attach,
	.damage = surface_damage,
	.frame = surface_frame,
	.commit = surface_commit,
	.damage_buffer = surface_damage_buffer,
};

static void
compositor_create_surface(struct wl_client *client, struct wl_resource *resource,
                          uint32_t id)
{
	struct shm_server_state *state = wl_resource_get_user_data(resource);
	struct wl_resource *surface = wl_resource_create(
		client, &wl_surface_interface, wl_resource_get_version(resource), id);

	if (surface == NULL) {
		wl_client_post_no_memory(client);
		return;
	}
	wl_resource_set_implementation(surface, &surface_implementation, state, NULL);
	state->surface_created = 1;
}

static void
compositor_create_region(struct wl_client *client, struct wl_resource *resource,
                         uint32_t id)
{
	(void) resource;
	(void) id;
	wl_client_post_implementation_error(client, "unexpected region");
}

static const struct wl_compositor_interface compositor_implementation = {
	.create_surface = compositor_create_surface,
	.create_region = compositor_create_region,
};

static void
bind_compositor(struct wl_client *client, void *data, uint32_t version, uint32_t id)
{
	struct wl_resource *resource = wl_resource_create(
		client, &wl_compositor_interface, version < 4 ? (int) version : 4, id);

	if (resource == NULL) {
		wl_client_post_no_memory(client);
		return;
	}
	wl_resource_set_implementation(resource, &compositor_implementation, data, NULL);
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
	                     &state, bind_shm) == NULL ||
	    wl_global_create(state.display, &wl_compositor_interface, 4,
	                     &state, bind_compositor) == NULL) {
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
	       state.pool_destroyed && state.surface_created && state.surface_destroyed &&
	       state.committed ? EXIT_SUCCESS : EXIT_FAILURE;
}
