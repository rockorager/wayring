#include "xdg-interop.h"
#include "linux-dmabuf-server-protocol.h"

#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>
#include <wayland-server.h>

#define DRM_FORMAT_ARGB8888 0x34325241u
#define DRM_FORMAT_MOD_INVALID_HI 0x00ffffffu
#define DRM_FORMAT_MOD_INVALID_LO 0xffffffffu

struct dmabuf_server_state {
	struct wl_display *display;
	struct wl_listener client_destroy;
	int params_created;
	int plane_added;
	int buffer_created;
	int buffer_destroyed;
	int params_destroyed;
	int dmabuf_destroyed;
};

static void
dmabuf_buffer_destroy(struct wl_client *client, struct wl_resource *resource)
{
	struct dmabuf_server_state *state = wl_resource_get_user_data(resource);

	(void) client;
	state->buffer_destroyed = 1;
	wl_resource_destroy(resource);
}

static const struct wl_buffer_interface dmabuf_buffer_implementation = {
	.destroy = dmabuf_buffer_destroy,
};

static void
params_destroy(struct wl_client *client, struct wl_resource *resource)
{
	struct dmabuf_server_state *state = wl_resource_get_user_data(resource);

	(void) client;
	if (state->buffer_destroyed)
		state->params_destroyed = 1;
	wl_resource_destroy(resource);
}

static void
params_add(struct wl_client *client, struct wl_resource *resource, int fd,
           uint32_t plane_idx, uint32_t offset, uint32_t stride,
           uint32_t modifier_hi, uint32_t modifier_lo)
{
	struct dmabuf_server_state *state = wl_resource_get_user_data(resource);
	int flags = fcntl(fd, F_GETFD);

	if (flags < 0 || (flags & FD_CLOEXEC) == 0 || plane_idx != 0 ||
	    offset != 0 || stride != 4 ||
	    modifier_hi != DRM_FORMAT_MOD_INVALID_HI ||
	    modifier_lo != DRM_FORMAT_MOD_INVALID_LO) {
		close(fd);
		wl_client_post_implementation_error(client, "invalid dmabuf plane");
		return;
	}
	close(fd);
	state->plane_added = 1;
}

static void
params_create(struct wl_client *client, struct wl_resource *resource,
              int32_t width, int32_t height, uint32_t format, uint32_t flags)
{
	(void) resource;
	(void) width;
	(void) height;
	(void) format;
	(void) flags;
	wl_client_post_implementation_error(client, "unexpected asynchronous create");
}

static void
params_create_immed(struct wl_client *client, struct wl_resource *resource,
                    uint32_t id, int32_t width, int32_t height,
                    uint32_t format, uint32_t flags)
{
	struct dmabuf_server_state *state = wl_resource_get_user_data(resource);
	struct wl_resource *buffer;

	if (!state->plane_added || width != 1 || height != 1 ||
	    format != DRM_FORMAT_ARGB8888 || flags != 0) {
		wl_client_post_implementation_error(client, "invalid dmabuf buffer");
		return;
	}
	buffer = wl_resource_create(client, &wl_buffer_interface, 1, id);
	if (buffer == NULL) {
		wl_client_post_no_memory(client);
		return;
	}
	wl_resource_set_implementation(
		buffer, &dmabuf_buffer_implementation, state, NULL);
	state->buffer_created = 1;
}

static const struct zwp_linux_buffer_params_v1_interface params_implementation = {
	.destroy = params_destroy,
	.add = params_add,
	.create = params_create,
	.create_immed = params_create_immed,
};

static void
dmabuf_destroy(struct wl_client *client, struct wl_resource *resource)
{
	struct dmabuf_server_state *state = wl_resource_get_user_data(resource);

	(void) client;
	if (state->params_destroyed)
		state->dmabuf_destroyed = 1;
	wl_resource_destroy(resource);
}

static void
dmabuf_create_params(struct wl_client *client, struct wl_resource *resource,
                     uint32_t id)
{
	struct dmabuf_server_state *state = wl_resource_get_user_data(resource);
	struct wl_resource *params = wl_resource_create(
		client, &zwp_linux_buffer_params_v1_interface,
		wl_resource_get_version(resource), id);

	if (params == NULL) {
		wl_client_post_no_memory(client);
		return;
	}
	wl_resource_set_implementation(params, &params_implementation, state, NULL);
	state->params_created = 1;
}

static const struct zwp_linux_dmabuf_v1_interface dmabuf_implementation = {
	.destroy = dmabuf_destroy,
	.create_params = dmabuf_create_params,
};

static void
bind_dmabuf(struct wl_client *client, void *data, uint32_t version, uint32_t id)
{
	struct wl_resource *resource = wl_resource_create(
		client, &zwp_linux_dmabuf_v1_interface,
		version < 3 ? (int) version : 3, id);

	if (resource == NULL) {
		wl_client_post_no_memory(client);
		return;
	}
	wl_resource_set_implementation(resource, &dmabuf_implementation, data, NULL);
	zwp_linux_dmabuf_v1_send_modifier(
		resource, DRM_FORMAT_ARGB8888,
		DRM_FORMAT_MOD_INVALID_HI, DRM_FORMAT_MOD_INVALID_LO);
}

static void
handle_dmabuf_client_destroy(struct wl_listener *listener, void *data)
{
	struct dmabuf_server_state *state =
		wl_container_of(listener, state, client_destroy);

	(void) data;
	wl_display_terminate(state->display);
}

int
dmabuf_server_fd(int fd)
{
	struct dmabuf_server_state state = {0};
	struct wl_client *client;

	state.display = wl_display_create();
	if (state.display == NULL)
		return EXIT_FAILURE;
	if (wl_global_create(state.display, &zwp_linux_dmabuf_v1_interface, 3,
	                     &state, bind_dmabuf) == NULL) {
		wl_display_destroy(state.display);
		return EXIT_FAILURE;
	}
	client = wl_client_create(state.display, fd);
	if (client == NULL) {
		wl_display_destroy(state.display);
		return EXIT_FAILURE;
	}
	state.client_destroy.notify = handle_dmabuf_client_destroy;
	wl_client_add_destroy_listener(client, &state.client_destroy);
	wl_display_run(state.display);
	wl_display_destroy(state.display);
	return state.params_created && state.plane_added && state.buffer_created &&
	       state.buffer_destroyed && state.params_destroyed &&
	       state.dmabuf_destroyed ? EXIT_SUCCESS : EXIT_FAILURE;
}
