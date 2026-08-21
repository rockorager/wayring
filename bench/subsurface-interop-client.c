#include "xdg-interop.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>

struct subsurface_client_state {
	struct wl_compositor *compositor;
	struct wl_subcompositor *subcompositor;
};

static void
registry_global(void *data, struct wl_registry *registry, uint32_t name,
                const char *interface, uint32_t version)
{
	struct subsurface_client_state *state = data;

	if (strcmp(interface, wl_compositor_interface.name) == 0)
		state->compositor = wl_registry_bind(
			registry, name, &wl_compositor_interface,
			version < 4 ? version : 4);
	else if (strcmp(interface, wl_subcompositor_interface.name) == 0)
		state->subcompositor = wl_registry_bind(
			registry, name, &wl_subcompositor_interface, 1);
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
subsurface_client_fd(int fd)
{
	struct subsurface_client_state state = {0};
	struct wl_display *display = wl_display_connect_to_fd(fd);
	struct wl_registry *registry;
	struct wl_surface *parent = NULL;
	struct wl_surface *child = NULL;
	struct wl_subsurface *subsurface = NULL;
	int status = EXIT_FAILURE;

	if (display == NULL)
		return EXIT_FAILURE;
	registry = wl_display_get_registry(display);
	wl_registry_add_listener(registry, &registry_listener, &state);
	if (wl_display_roundtrip(display) < 0 || state.compositor == NULL ||
	    state.subcompositor == NULL)
		goto cleanup;
	parent = wl_compositor_create_surface(state.compositor);
	child = wl_compositor_create_surface(state.compositor);
	if (parent == NULL || child == NULL)
		goto cleanup;
	subsurface = wl_subcompositor_get_subsurface(
		state.subcompositor, child, parent);
	if (subsurface == NULL)
		goto cleanup;
	wl_subsurface_set_position(subsurface, -7, 11);
	wl_subsurface_place_above(subsurface, parent);
	wl_subsurface_place_below(subsurface, parent);
	wl_surface_commit(child);
	wl_surface_commit(parent);
	wl_subsurface_set_sync(subsurface);
	wl_surface_commit(child);
	wl_subsurface_set_desync(subsurface);
	wl_surface_destroy(parent);
	parent = NULL;
	if (wl_display_roundtrip(display) < 0)
		goto cleanup;
	status = EXIT_SUCCESS;

cleanup:
	if (subsurface != NULL)
		wl_subsurface_destroy(subsurface);
	if (child != NULL)
		wl_surface_destroy(child);
	if (parent != NULL)
		wl_surface_destroy(parent);
	if (state.subcompositor != NULL)
		wl_subcompositor_destroy(state.subcompositor);
	if (state.compositor != NULL)
		wl_compositor_destroy(state.compositor);
	wl_registry_destroy(registry);
	wl_display_flush(display);
	wl_display_disconnect(display);
	return status;
}
