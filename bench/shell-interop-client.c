#include "xdg-interop.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>

struct shell_client_state {
	struct wl_compositor *compositor;
	struct wl_shell *shell;
	int ping;
	int configure;
	int popup_done;
};

static void
shell_surface_ping(void *data, struct wl_shell_surface *surface, uint32_t serial)
{
	struct shell_client_state *state = data;
	if (serial == 41) {
		wl_shell_surface_pong(surface, serial);
		state->ping = 1;
	}
}

static void
shell_surface_configure(void *data, struct wl_shell_surface *surface,
                        uint32_t edges, int32_t width, int32_t height)
{
	struct shell_client_state *state = data;
	(void) surface;
	if (edges == WL_SHELL_SURFACE_RESIZE_BOTTOM_RIGHT && width == 800 && height == 600)
		state->configure = 1;
}

static void
shell_surface_popup_done(void *data, struct wl_shell_surface *surface)
{
	struct shell_client_state *state = data;
	(void) surface;
	state->popup_done = 1;
}

static const struct wl_shell_surface_listener shell_surface_listener = {
	.ping = shell_surface_ping,
	.configure = shell_surface_configure,
	.popup_done = shell_surface_popup_done,
};

static void
registry_global(void *data, struct wl_registry *registry, uint32_t name,
                const char *interface, uint32_t version)
{
	struct shell_client_state *state = data;
	if (strcmp(interface, wl_compositor_interface.name) == 0)
		state->compositor = wl_registry_bind(
			registry, name, &wl_compositor_interface, version < 4 ? version : 4);
	else if (strcmp(interface, wl_shell_interface.name) == 0)
		state->shell = wl_registry_bind(registry, name, &wl_shell_interface, 1);
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
shell_client_fd(int fd)
{
	struct shell_client_state state = {0};
	struct wl_display *display = wl_display_connect_to_fd(fd);
	struct wl_registry *registry;
	struct wl_surface *surface = NULL;
	struct wl_shell_surface *shell_surface = NULL;
	int status = EXIT_FAILURE;

	if (display == NULL)
		return EXIT_FAILURE;
	registry = wl_display_get_registry(display);
	wl_registry_add_listener(registry, &registry_listener, &state);
	if (wl_display_roundtrip(display) < 0 || state.compositor == NULL ||
	    state.shell == NULL)
		goto cleanup;
	surface = wl_compositor_create_surface(state.compositor);
	shell_surface = wl_shell_get_shell_surface(state.shell, surface);
	if (surface == NULL || shell_surface == NULL)
		goto cleanup;
	wl_shell_surface_add_listener(shell_surface, &shell_surface_listener, &state);
	wl_shell_surface_set_title(shell_surface, "wayring-shell");
	wl_shell_surface_set_class(shell_surface, "wayring");
	wl_shell_surface_set_toplevel(shell_surface);
	if (wl_display_roundtrip(display) < 0 || !state.ping || !state.configure ||
	    !state.popup_done)
		goto cleanup;
	wl_shell_surface_destroy(shell_surface);
	shell_surface = NULL;
	wl_surface_destroy(surface);
	surface = NULL;
	if (wl_display_roundtrip(display) < 0)
		goto cleanup;
	status = EXIT_SUCCESS;

cleanup:
	if (shell_surface != NULL)
		wl_shell_surface_destroy(shell_surface);
	if (surface != NULL)
		wl_surface_destroy(surface);
	if (state.shell != NULL)
		wl_shell_destroy(state.shell);
	if (state.compositor != NULL)
		wl_compositor_destroy(state.compositor);
	wl_registry_destroy(registry);
	wl_display_flush(display);
	wl_display_disconnect(display);
	return status;
}
