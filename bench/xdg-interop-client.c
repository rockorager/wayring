#include "xdg-interop.h"
#include "xdg-shell-client-protocol.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <wayland-client.h>

struct client_state {
	struct wl_compositor *compositor;
	struct xdg_wm_base *wm_base;
	int pinged;
	int configured;
};

static void
handle_ping(void *data, struct xdg_wm_base *wm_base, uint32_t serial)
{
	struct client_state *state = data;

	state->pinged = 1;
	xdg_wm_base_pong(wm_base, serial);
}

static const struct xdg_wm_base_listener wm_base_listener = {
	.ping = handle_ping,
};

static void
handle_global(void *data, struct wl_registry *registry, uint32_t name,
              const char *interface, uint32_t version)
{
	struct client_state *state = data;

	if (strcmp(interface, wl_compositor_interface.name) == 0) {
		state->compositor = wl_registry_bind(
			registry, name, &wl_compositor_interface,
			version < 4 ? version : 4);
	} else if (strcmp(interface, xdg_wm_base_interface.name) == 0) {
		state->wm_base = wl_registry_bind(
			registry, name, &xdg_wm_base_interface,
			version < 5 ? version : 5);
		xdg_wm_base_add_listener(state->wm_base, &wm_base_listener, state);
	}
}

static void
handle_global_remove(void *data, struct wl_registry *registry, uint32_t name)
{
	(void) data;
	(void) registry;
	(void) name;
}

static const struct wl_registry_listener registry_listener = {
	.global = handle_global,
	.global_remove = handle_global_remove,
};

static void
handle_xdg_surface_configure(void *data, struct xdg_surface *surface,
                             uint32_t serial)
{
	struct client_state *state = data;

	xdg_surface_ack_configure(surface, serial);
	state->configured = 1;
}

static const struct xdg_surface_listener xdg_surface_listener = {
	.configure = handle_xdg_surface_configure,
};

static void
handle_toplevel_configure(void *data, struct xdg_toplevel *toplevel,
                          int32_t width, int32_t height, struct wl_array *states)
{
	(void) data;
	(void) toplevel;
	(void) width;
	(void) height;
	(void) states;
}

static void
handle_toplevel_close(void *data, struct xdg_toplevel *toplevel)
{
	(void) data;
	(void) toplevel;
}

static void
handle_configure_bounds(void *data, struct xdg_toplevel *toplevel,
                        int32_t width, int32_t height)
{
	(void) data;
	(void) toplevel;
	(void) width;
	(void) height;
}

static void
handle_wm_capabilities(void *data, struct xdg_toplevel *toplevel,
                       struct wl_array *capabilities)
{
	(void) data;
	(void) toplevel;
	(void) capabilities;
}

static const struct xdg_toplevel_listener toplevel_listener = {
	.configure = handle_toplevel_configure,
	.close = handle_toplevel_close,
	.configure_bounds = handle_configure_bounds,
	.wm_capabilities = handle_wm_capabilities,
};

int
xdg_client_fd(int fd)
{
	struct client_state state = {0};
	struct wl_display *display = wl_display_connect_to_fd(fd);
	struct wl_registry *registry;
	struct wl_surface *surface = NULL;
	struct xdg_surface *xdg_surface = NULL;
	struct xdg_toplevel *toplevel = NULL;
	int status = EXIT_FAILURE;

	if (display == NULL)
		return EXIT_FAILURE;
	registry = wl_display_get_registry(display);
	wl_registry_add_listener(registry, &registry_listener, &state);
	if (wl_display_roundtrip(display) < 0 || state.compositor == NULL ||
	    state.wm_base == NULL || wl_display_roundtrip(display) < 0 ||
	    !state.pinged)
		goto cleanup_registry;

	surface = wl_compositor_create_surface(state.compositor);
	xdg_surface = xdg_wm_base_get_xdg_surface(state.wm_base, surface);
	if (surface == NULL || xdg_surface == NULL)
		goto cleanup_toplevel;
	xdg_surface_add_listener(xdg_surface, &xdg_surface_listener, &state);
	toplevel = xdg_surface_get_toplevel(xdg_surface);
	if (toplevel == NULL)
		goto cleanup_toplevel;
	xdg_toplevel_add_listener(toplevel, &toplevel_listener, &state);
	wl_surface_commit(surface);
	while (!state.configured) {
		if (wl_display_dispatch(display) < 0)
			goto cleanup_toplevel;
	}
	if (wl_display_roundtrip(display) < 0)
		goto cleanup_toplevel;
	status = EXIT_SUCCESS;

cleanup_toplevel:
	if (toplevel != NULL)
		xdg_toplevel_destroy(toplevel);
	if (xdg_surface != NULL)
		xdg_surface_destroy(xdg_surface);
	if (surface != NULL)
		wl_surface_destroy(surface);
cleanup_registry:
	if (state.wm_base != NULL)
		xdg_wm_base_destroy(state.wm_base);
	if (state.compositor != NULL)
		wl_compositor_destroy(state.compositor);
	wl_registry_destroy(registry);
	wl_display_flush(display);
	wl_display_disconnect(display);
	return status;
}
