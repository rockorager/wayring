#include "xdg-interop.h"
#include "presentation-time-client-protocol.h"
#include "xdg-shell-client-protocol.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <wayland-client.h>

struct client_state {
	struct wl_compositor *compositor;
	struct xdg_wm_base *wm_base;
	struct wp_presentation *presentation;
	int pinged;
	int configured;
	int clock_seen;
	int presented;
	int discarded;
};

static void
handle_clock_id(void *data, struct wp_presentation *presentation,
                uint32_t clock_id)
{
	struct client_state *state = data;

	(void) presentation;
	if (clock_id == 1)
		state->clock_seen = 1;
}

static const struct wp_presentation_listener presentation_listener = {
	.clock_id = handle_clock_id,
};

static void
handle_feedback_sync_output(void *data,
                            struct wp_presentation_feedback *feedback,
                            struct wl_output *output)
{
	(void) data;
	(void) feedback;
	(void) output;
}

static void
handle_feedback_presented(void *data,
                          struct wp_presentation_feedback *feedback,
                          uint32_t tv_sec_hi, uint32_t tv_sec_lo,
                          uint32_t tv_nsec, uint32_t refresh,
                          uint32_t seq_hi, uint32_t seq_lo, uint32_t flags)
{
	struct client_state *state = data;

	(void) feedback;
	if (tv_sec_hi == 1 && tv_sec_lo == 2 && tv_nsec == 3 &&
	    refresh == 16666667 && seq_hi == 4 && seq_lo == 5 &&
	    flags == WP_PRESENTATION_FEEDBACK_KIND_VSYNC)
		state->presented = 1;
}

static void
handle_feedback_discarded(void *data,
                          struct wp_presentation_feedback *feedback)
{
	struct client_state *state = data;

	(void) feedback;
	state->discarded = 1;
}

static const struct wp_presentation_feedback_listener feedback_listener = {
	.sync_output = handle_feedback_sync_output,
	.presented = handle_feedback_presented,
	.discarded = handle_feedback_discarded,
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
	} else if (strcmp(interface, wp_presentation_interface.name) == 0) {
		state->presentation = wl_registry_bind(
			registry, name, &wp_presentation_interface, 1);
		wp_presentation_add_listener(
			state->presentation, &presentation_listener, state);
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
	struct wp_presentation_feedback *feedback;
	int status = EXIT_FAILURE;

	if (display == NULL)
		return EXIT_FAILURE;
	registry = wl_display_get_registry(display);
	wl_registry_add_listener(registry, &registry_listener, &state);
	if (wl_display_roundtrip(display) < 0 || state.compositor == NULL ||
	    state.wm_base == NULL || state.presentation == NULL ||
	    wl_display_roundtrip(display) < 0 || !state.pinged || !state.clock_seen)
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
	feedback = wp_presentation_feedback(state.presentation, surface);
	if (feedback == NULL)
		goto cleanup_toplevel;
	wp_presentation_feedback_add_listener(feedback, &feedback_listener, &state);
	wl_surface_commit(surface);
	while (!state.configured || !state.presented) {
		if (wl_display_dispatch(display) < 0)
			goto cleanup_toplevel;
	}
	feedback = wp_presentation_feedback(state.presentation, surface);
	if (feedback == NULL)
		goto cleanup_toplevel;
	wp_presentation_feedback_add_listener(feedback, &feedback_listener, &state);
	wl_surface_commit(surface);
	while (!state.discarded) {
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
	if (state.presentation != NULL)
		wp_presentation_destroy(state.presentation);
	if (state.compositor != NULL)
		wl_compositor_destroy(state.compositor);
	wl_registry_destroy(registry);
	wl_display_flush(display);
	wl_display_disconnect(display);
	return status;
}
