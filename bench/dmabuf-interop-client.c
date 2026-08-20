#include "xdg-interop.h"
#include "linux-dmabuf-client-protocol.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>

#define DRM_FORMAT_ARGB8888 0x34325241u
#define DRM_FORMAT_MOD_INVALID_HI 0x00ffffffu
#define DRM_FORMAT_MOD_INVALID_LO 0xffffffffu

struct dmabuf_client_state {
	struct zwp_linux_dmabuf_v1 *dmabuf;
	struct wl_buffer *async_buffer;
	int modifier_seen;
	int create_failed;
};

static void
handle_dmabuf_format(void *data, struct zwp_linux_dmabuf_v1 *dmabuf,
                     uint32_t format)
{
	(void) data;
	(void) dmabuf;
	(void) format;
}

static void
handle_dmabuf_modifier(void *data, struct zwp_linux_dmabuf_v1 *dmabuf,
                       uint32_t format, uint32_t modifier_hi,
                       uint32_t modifier_lo)
{
	struct dmabuf_client_state *state = data;

	(void) dmabuf;
	if (format == DRM_FORMAT_ARGB8888 &&
	    modifier_hi == DRM_FORMAT_MOD_INVALID_HI &&
	    modifier_lo == DRM_FORMAT_MOD_INVALID_LO)
		state->modifier_seen = 1;
}

static const struct zwp_linux_dmabuf_v1_listener dmabuf_listener = {
	.format = handle_dmabuf_format,
	.modifier = handle_dmabuf_modifier,
};

static void
handle_dmabuf_global(void *data, struct wl_registry *registry, uint32_t name,
                     const char *interface, uint32_t version)
{
	struct dmabuf_client_state *state = data;

	if (strcmp(interface, zwp_linux_dmabuf_v1_interface.name) != 0)
		return;
	state->dmabuf = wl_registry_bind(
		registry, name, &zwp_linux_dmabuf_v1_interface,
		version < 3 ? version : 3);
	zwp_linux_dmabuf_v1_add_listener(state->dmabuf, &dmabuf_listener, state);
}

static void
handle_dmabuf_global_remove(void *data, struct wl_registry *registry,
                            uint32_t name)
{
	(void) data;
	(void) registry;
	(void) name;
}

static const struct wl_registry_listener dmabuf_registry_listener = {
	.global = handle_dmabuf_global,
	.global_remove = handle_dmabuf_global_remove,
};

static void
handle_params_created(void *data, struct zwp_linux_buffer_params_v1 *params,
                      struct wl_buffer *buffer)
{
	struct dmabuf_client_state *state = data;

	(void) params;
	state->async_buffer = buffer;
}

static void
handle_params_failed(void *data, struct zwp_linux_buffer_params_v1 *params)
{
	struct dmabuf_client_state *state = data;

	(void) params;
	state->create_failed = 1;
}

static const struct zwp_linux_buffer_params_v1_listener params_listener = {
	.created = handle_params_created,
	.failed = handle_params_failed,
};

int
dmabuf_client_fd(int fd)
{
	struct dmabuf_client_state state = {0};
	struct wl_display *display = wl_display_connect_to_fd(fd);
	struct wl_registry *registry;
	struct zwp_linux_buffer_params_v1 *params = NULL;
	struct wl_buffer *buffer = NULL;
	int memory_fd = -1;
	int status = EXIT_FAILURE;

	if (display == NULL)
		return EXIT_FAILURE;
	registry = wl_display_get_registry(display);
	wl_registry_add_listener(registry, &dmabuf_registry_listener, &state);
	if (wl_display_roundtrip(display) < 0 || state.dmabuf == NULL ||
	    wl_display_roundtrip(display) < 0 || !state.modifier_seen)
		goto cleanup;

	memory_fd = memfd_create("wayring-dmabuf-interop", MFD_CLOEXEC);
	if (memory_fd < 0 || ftruncate(memory_fd, 4096) < 0)
		goto cleanup;
	params = zwp_linux_dmabuf_v1_create_params(state.dmabuf);
	if (params == NULL)
		goto cleanup;
	zwp_linux_buffer_params_v1_add(
		params, memory_fd, 0, 0, 4,
		DRM_FORMAT_MOD_INVALID_HI, DRM_FORMAT_MOD_INVALID_LO);
	close(memory_fd);
	memory_fd = -1;
	buffer = zwp_linux_buffer_params_v1_create_immed(
		params, 1, 1, DRM_FORMAT_ARGB8888, 0);
	if (buffer == NULL || wl_display_roundtrip(display) < 0)
		goto cleanup;

	wl_buffer_destroy(buffer);
	buffer = NULL;
	zwp_linux_buffer_params_v1_destroy(params);
	params = NULL;
	if (wl_display_roundtrip(display) < 0)
		goto cleanup;

	memory_fd = memfd_create("wayring-dmabuf-async", MFD_CLOEXEC);
	if (memory_fd < 0 || ftruncate(memory_fd, 4096) < 0)
		goto cleanup;
	params = zwp_linux_dmabuf_v1_create_params(state.dmabuf);
	if (params == NULL)
		goto cleanup;
	zwp_linux_buffer_params_v1_add_listener(params, &params_listener, &state);
	zwp_linux_buffer_params_v1_add(
		params, memory_fd, 0, 0, 4,
		DRM_FORMAT_MOD_INVALID_HI, DRM_FORMAT_MOD_INVALID_LO);
	close(memory_fd);
	memory_fd = -1;
	zwp_linux_buffer_params_v1_create(params, 1, 1, DRM_FORMAT_ARGB8888, 0);
	while (state.async_buffer == NULL) {
		if (wl_display_dispatch(display) < 0)
			goto cleanup;
	}
	wl_buffer_destroy(state.async_buffer);
	state.async_buffer = NULL;
	zwp_linux_buffer_params_v1_destroy(params);
	params = NULL;
	if (wl_display_roundtrip(display) < 0)
		goto cleanup;

	memory_fd = memfd_create("wayring-dmabuf-failure", MFD_CLOEXEC);
	if (memory_fd < 0 || ftruncate(memory_fd, 4096) < 0)
		goto cleanup;
	params = zwp_linux_dmabuf_v1_create_params(state.dmabuf);
	if (params == NULL)
		goto cleanup;
	zwp_linux_buffer_params_v1_add_listener(params, &params_listener, &state);
	zwp_linux_buffer_params_v1_add(
		params, memory_fd, 0, 0, 4,
		DRM_FORMAT_MOD_INVALID_HI, DRM_FORMAT_MOD_INVALID_LO);
	close(memory_fd);
	memory_fd = -1;
	zwp_linux_buffer_params_v1_create(params, 2, 1, DRM_FORMAT_ARGB8888, 0);
	while (!state.create_failed) {
		if (wl_display_dispatch(display) < 0)
			goto cleanup;
	}
	zwp_linux_buffer_params_v1_destroy(params);
	params = NULL;
	if (wl_display_roundtrip(display) < 0)
		goto cleanup;
	status = EXIT_SUCCESS;

cleanup:
	if (memory_fd >= 0)
		close(memory_fd);
	if (buffer != NULL)
		wl_buffer_destroy(buffer);
	if (state.async_buffer != NULL)
		wl_buffer_destroy(state.async_buffer);
	if (params != NULL)
		zwp_linux_buffer_params_v1_destroy(params);
	if (state.dmabuf != NULL)
		zwp_linux_dmabuf_v1_destroy(state.dmabuf);
	wl_registry_destroy(registry);
	wl_display_flush(display);
	wl_display_disconnect(display);
	return status;
}
