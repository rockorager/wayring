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
	struct wl_resource *region;
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
	int region_added;
	int region_subtracted;
	int region_destroyed;
	int opaque_region_set;
	int input_region_set;
	int transformed;
	int scaled;
	int offset;
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

	if (offset != 0 || width != 2 || height != 2 || stride != 8 ||
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

	if (buffer != state->buffer || x != 0 || y != 0) {
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
surface_set_opaque_region(struct wl_client *client, struct wl_resource *resource,
                          struct wl_resource *region)
{
	struct shm_server_state *state = wl_resource_get_user_data(resource);

	if (region != state->region) {
		wl_client_post_implementation_error(client, "invalid opaque region");
		return;
	}
	state->opaque_region_set = 1;
}

static void
surface_set_input_region(struct wl_client *client, struct wl_resource *resource,
                         struct wl_resource *region)
{
	struct shm_server_state *state = wl_resource_get_user_data(resource);

	if (region != state->region) {
		wl_client_post_implementation_error(client, "invalid input region");
		return;
	}
	state->input_region_set = 1;
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

static void
surface_set_buffer_transform(struct wl_client *client, struct wl_resource *resource,
                             int32_t transform)
{
	struct shm_server_state *state = wl_resource_get_user_data(resource);
	if (transform != WL_OUTPUT_TRANSFORM_90)
		wl_client_post_implementation_error(client, "invalid buffer transform");
	else
		state->transformed = 1;
}

static void
surface_set_buffer_scale(struct wl_client *client, struct wl_resource *resource,
                         int32_t scale)
{
	struct shm_server_state *state = wl_resource_get_user_data(resource);
	if (scale != 2)
		wl_client_post_implementation_error(client, "invalid buffer scale");
	else
		state->scaled = 1;
}

static void
surface_offset(struct wl_client *client, struct wl_resource *resource,
               int32_t x, int32_t y)
{
	struct shm_server_state *state = wl_resource_get_user_data(resource);
	if (x != 2 || y != -3)
		wl_client_post_implementation_error(client, "invalid surface offset");
	else
		state->offset = 1;
}

static const struct wl_surface_interface surface_implementation = {
	.destroy = surface_destroy,
	.attach = surface_attach,
	.damage = surface_damage,
	.frame = surface_frame,
	.set_opaque_region = surface_set_opaque_region,
	.set_input_region = surface_set_input_region,
	.commit = surface_commit,
	.set_buffer_transform = surface_set_buffer_transform,
	.set_buffer_scale = surface_set_buffer_scale,
	.damage_buffer = surface_damage_buffer,
	.offset = surface_offset,
};

static void
region_destroy(struct wl_client *client, struct wl_resource *resource)
{
	struct shm_server_state *state = wl_resource_get_user_data(resource);

	(void) client;
	state->region_destroyed = 1;
	state->region = NULL;
	wl_resource_destroy(resource);
}

static void
region_add(struct wl_client *client, struct wl_resource *resource,
           int32_t x, int32_t y, int32_t width, int32_t height)
{
	struct shm_server_state *state = wl_resource_get_user_data(resource);

	if (x != 1 || y != 2 || width != 3 || height != 4) {
		wl_client_post_implementation_error(client, "invalid region add");
		return;
	}
	state->region_added = 1;
}

static void
region_subtract(struct wl_client *client, struct wl_resource *resource,
                int32_t x, int32_t y, int32_t width, int32_t height)
{
	struct shm_server_state *state = wl_resource_get_user_data(resource);

	if (x != 5 || y != 6 || width != 7 || height != 8) {
		wl_client_post_implementation_error(client, "invalid region subtract");
		return;
	}
	state->region_subtracted = 1;
}

static const struct wl_region_interface region_implementation = {
	.destroy = region_destroy,
	.add = region_add,
	.subtract = region_subtract,
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
	struct shm_server_state *state = wl_resource_get_user_data(resource);

	state->region = wl_resource_create(client, &wl_region_interface, 1, id);
	if (state->region == NULL) {
		wl_client_post_no_memory(client);
		return;
	}
	wl_resource_set_implementation(
		state->region, &region_implementation, state, NULL);
}

static const struct wl_compositor_interface compositor_implementation = {
	.create_surface = compositor_create_surface,
	.create_region = compositor_create_region,
};

static void
bind_compositor(struct wl_client *client, void *data, uint32_t version, uint32_t id)
{
	struct wl_resource *resource = wl_resource_create(
		client, &wl_compositor_interface, version < 5 ? (int) version : 5, id);

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
	    wl_global_create(state.display, &wl_compositor_interface, 5,
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
	       state.committed && state.region_added && state.region_subtracted &&
	       state.region_destroyed && state.opaque_region_set && state.input_region_set ?
	       (state.transformed && state.scaled && state.offset ? EXIT_SUCCESS : EXIT_FAILURE) :
	       EXIT_FAILURE;
}
