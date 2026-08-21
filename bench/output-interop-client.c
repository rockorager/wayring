#include "xdg-interop.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>

struct output_client_state {
	struct wl_output *output;
	int geometry;
	int mode;
	int scale;
	int name;
	int description;
	int done;
};

static void
output_geometry(void *data, struct wl_output *output, int32_t x, int32_t y,
                int32_t physical_width, int32_t physical_height,
                int32_t subpixel, const char *make, const char *model,
                int32_t transform)
{
	struct output_client_state *state = data;

	(void) output;
	if (x == -10 && y == 20 && physical_width == 600 &&
	    physical_height == 340 && subpixel == WL_OUTPUT_SUBPIXEL_HORIZONTAL_RGB &&
	    strcmp(make, "Wayring") == 0 && strcmp(model, "Virtual-1") == 0 &&
	    transform == WL_OUTPUT_TRANSFORM_90)
		state->geometry = 1;
}

static void
output_mode(void *data, struct wl_output *output, uint32_t flags,
            int32_t width, int32_t height, int32_t refresh)
{
	struct output_client_state *state = data;

	(void) output;
	if (flags == (WL_OUTPUT_MODE_CURRENT | WL_OUTPUT_MODE_PREFERRED) &&
	    width == 1920 && height == 1080 && refresh == 60000)
		state->mode = 1;
}

static void
output_done(void *data, struct wl_output *output)
{
	struct output_client_state *state = data;

	(void) output;
	state->done = 1;
}

static void
output_scale(void *data, struct wl_output *output, int32_t factor)
{
	struct output_client_state *state = data;

	(void) output;
	if (factor == 2)
		state->scale = 1;
}

static void
output_name(void *data, struct wl_output *output, const char *name)
{
	struct output_client_state *state = data;

	(void) output;
	if (strcmp(name, "WL-1") == 0)
		state->name = 1;
}

static void
output_description(void *data, struct wl_output *output, const char *description)
{
	struct output_client_state *state = data;

	(void) output;
	if (strcmp(description, "Wayring virtual output") == 0)
		state->description = 1;
}

static const struct wl_output_listener output_listener = {
	.geometry = output_geometry,
	.mode = output_mode,
	.done = output_done,
	.scale = output_scale,
	.name = output_name,
	.description = output_description,
};

static void
registry_global(void *data, struct wl_registry *registry, uint32_t name,
                const char *interface, uint32_t version)
{
	struct output_client_state *state = data;

	if (strcmp(interface, wl_output_interface.name) != 0)
		return;
	state->output = wl_registry_bind(
		registry, name, &wl_output_interface, version < 4 ? version : 4);
	wl_output_add_listener(state->output, &output_listener, state);
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

int
output_client_fd(int fd)
{
	struct output_client_state state = {0};
	struct wl_display *display = wl_display_connect_to_fd(fd);
	struct wl_registry *registry;
	int status = EXIT_FAILURE;

	if (display == NULL)
		return EXIT_FAILURE;
	registry = wl_display_get_registry(display);
	wl_registry_add_listener(registry, &registry_listener, &state);
	if (wl_display_roundtrip(display) < 0 || state.output == NULL ||
	    wl_display_roundtrip(display) < 0 ||
	    !state.geometry || !state.mode || !state.scale || !state.name ||
	    !state.description || !state.done)
		goto cleanup;
	status = EXIT_SUCCESS;

cleanup:
	if (state.output != NULL)
		wl_output_release(state.output);
	wl_registry_destroy(registry);
	wl_display_flush(display);
	wl_display_disconnect(display);
	return status;
}
