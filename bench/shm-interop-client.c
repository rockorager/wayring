#include "xdg-interop.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>

struct shm_client_state {
	struct wl_shm *shm;
	struct wl_compositor *compositor;
	int format_seen;
	int buffer_released;
	int frame_done;
};

static void
handle_buffer_release(void *data, struct wl_buffer *buffer)
{
	struct shm_client_state *state = data;

	(void) buffer;
	state->buffer_released = 1;
}

static const struct wl_buffer_listener buffer_listener = {
	.release = handle_buffer_release,
};

static void
handle_frame_done(void *data, struct wl_callback *callback, uint32_t time)
{
	struct shm_client_state *state = data;

	if (time == 123)
		state->frame_done = 1;
	wl_callback_destroy(callback);
}

static const struct wl_callback_listener frame_listener = {
	.done = handle_frame_done,
};

static void
handle_shm_format(void *data, struct wl_shm *shm, uint32_t format)
{
	struct shm_client_state *state = data;

	(void) shm;
	if (format == WL_SHM_FORMAT_ARGB8888)
		state->format_seen = 1;
}

static const struct wl_shm_listener shm_listener = {
	.format = handle_shm_format,
};

static void
handle_shm_global(void *data, struct wl_registry *registry, uint32_t name,
                  const char *interface, uint32_t version)
{
	struct shm_client_state *state = data;

	if (strcmp(interface, wl_shm_interface.name) == 0) {
		state->shm = wl_registry_bind(registry, name, &wl_shm_interface,
		                              version < 1 ? version : 1);
		wl_shm_add_listener(state->shm, &shm_listener, state);
	} else if (strcmp(interface, wl_compositor_interface.name) == 0) {
		state->compositor = wl_registry_bind(
			registry, name, &wl_compositor_interface,
			version < 4 ? version : 4);
	}
}

static void
handle_shm_global_remove(void *data, struct wl_registry *registry, uint32_t name)
{
	(void) data;
	(void) registry;
	(void) name;
}

static const struct wl_registry_listener shm_registry_listener = {
	.global = handle_shm_global,
	.global_remove = handle_shm_global_remove,
};

int
shm_client_fd(int fd)
{
	struct shm_client_state state = {0};
	struct wl_display *display = wl_display_connect_to_fd(fd);
	struct wl_registry *registry;
	struct wl_shm_pool *pool = NULL;
	struct wl_buffer *buffer = NULL;
	struct wl_surface *surface = NULL;
	struct wl_region *region = NULL;
	struct wl_callback *frame = NULL;
	int memory_fd = -1;
	int status = EXIT_FAILURE;

	if (display == NULL)
		return EXIT_FAILURE;
	registry = wl_display_get_registry(display);
	wl_registry_add_listener(registry, &shm_registry_listener, &state);
	if (wl_display_roundtrip(display) < 0 || state.shm == NULL ||
	    state.compositor == NULL ||
	    wl_display_roundtrip(display) < 0 || !state.format_seen)
		goto cleanup;

	memory_fd = memfd_create("wayring-shm-interop", MFD_CLOEXEC);
	if (memory_fd < 0 || ftruncate(memory_fd, 4096) < 0)
		goto cleanup;
	pool = wl_shm_create_pool(state.shm, memory_fd, 4096);
	close(memory_fd);
	memory_fd = -1;
	if (pool == NULL)
		goto cleanup;
	buffer = wl_shm_pool_create_buffer(
		pool, 0, 1, 1, 4, WL_SHM_FORMAT_ARGB8888);
	surface = wl_compositor_create_surface(state.compositor);
	if (buffer == NULL || surface == NULL)
		goto cleanup;
	wl_buffer_add_listener(buffer, &buffer_listener, &state);
	region = wl_compositor_create_region(state.compositor);
	if (region == NULL)
		goto cleanup;
	wl_region_add(region, 1, 2, 3, 4);
	wl_region_subtract(region, 5, 6, 7, 8);
	wl_surface_attach(surface, buffer, 2, -3);
	wl_surface_damage(surface, 1, 2, 3, 4);
	wl_surface_set_opaque_region(surface, region);
	wl_surface_set_input_region(surface, region);
	frame = wl_surface_frame(surface);
	if (frame == NULL)
		goto cleanup;
	wl_callback_add_listener(frame, &frame_listener, &state);
	wl_surface_damage_buffer(surface, 5, 6, 7, 8);
	wl_surface_commit(surface);
	if (wl_display_roundtrip(display) < 0 || !state.buffer_released ||
	    !state.frame_done)
		goto cleanup;
	frame = NULL;

	wl_region_destroy(region);
	region = NULL;
	wl_surface_destroy(surface);
	surface = NULL;
	wl_buffer_destroy(buffer);
	buffer = NULL;
	wl_shm_pool_destroy(pool);
	pool = NULL;
	if (wl_display_roundtrip(display) < 0)
		goto cleanup;
	status = EXIT_SUCCESS;

cleanup:
	if (memory_fd >= 0)
		close(memory_fd);
	if (buffer != NULL)
		wl_buffer_destroy(buffer);
	if (pool != NULL)
		wl_shm_pool_destroy(pool);
	if (frame != NULL)
		wl_callback_destroy(frame);
	if (surface != NULL)
		wl_surface_destroy(surface);
	if (region != NULL)
		wl_region_destroy(region);
	if (state.shm != NULL)
		wl_shm_destroy(state.shm);
	if (state.compositor != NULL)
		wl_compositor_destroy(state.compositor);
	wl_registry_destroy(registry);
	wl_display_flush(display);
	wl_display_disconnect(display);
	return status;
}
