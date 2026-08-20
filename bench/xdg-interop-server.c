#include "xdg-interop.h"
#include "xdg-shell-server-protocol.h"

#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>
#include <wayland-server.h>

struct server_state {
	struct wl_display *display;
	struct wl_listener client_destroy;
	int ponged;
	int configured;
	int toplevel_destroyed;
	int xdg_surface_destroyed;
	int surface_destroyed;
	int wm_base_destroyed;
};

static void
surface_commit(struct wl_client *client, struct wl_resource *resource)
{
	(void) client;
	(void) resource;
}

static void
surface_destroy(struct wl_client *client, struct wl_resource *resource)
{
	struct server_state *state = wl_resource_get_user_data(resource);

	(void) client;
	if (state->xdg_surface_destroyed)
		state->surface_destroyed = 1;
	wl_resource_destroy(resource);
}

static const struct wl_surface_interface surface_implementation = {
	.destroy = surface_destroy,
	.commit = surface_commit,
};

static void
compositor_create_surface(struct wl_client *client, struct wl_resource *resource,
                          uint32_t id)
{
	struct wl_resource *surface = wl_resource_create(
		client, &wl_surface_interface, wl_resource_get_version(resource), id);

	if (surface == NULL) {
		wl_client_post_no_memory(client);
		return;
	}
	wl_resource_set_implementation(surface, &surface_implementation,
	                               wl_resource_get_user_data(resource), NULL);
}

static void
compositor_create_region(struct wl_client *client, struct wl_resource *resource,
                         uint32_t id)
{
	(void) resource;
	(void) id;
	wl_client_post_implementation_error(client, "unexpected create_region");
}

static const struct wl_compositor_interface compositor_implementation = {
	.create_surface = compositor_create_surface,
	.create_region = compositor_create_region,
};

static void
bind_compositor(struct wl_client *client, void *data, uint32_t version,
                uint32_t id)
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
toplevel_destroy(struct wl_client *client, struct wl_resource *resource)
{
	struct server_state *state = wl_resource_get_user_data(resource);

	(void) client;
	state->toplevel_destroyed = 1;
	wl_resource_destroy(resource);
}

static const struct xdg_toplevel_interface toplevel_implementation = {
	.destroy = toplevel_destroy,
};

static void
xdg_surface_get_toplevel(struct wl_client *client, struct wl_resource *resource,
                         uint32_t id)
{
	struct wl_resource *toplevel = wl_resource_create(
		client, &xdg_toplevel_interface, wl_resource_get_version(resource), id);
	struct wl_array states;

	if (toplevel == NULL) {
		wl_client_post_no_memory(client);
		return;
	}
	wl_resource_set_implementation(toplevel, &toplevel_implementation,
	                               wl_resource_get_user_data(resource), NULL);
	wl_array_init(&states);
	xdg_toplevel_send_configure(toplevel, 0, 0, &states);
	wl_array_release(&states);
	xdg_surface_send_configure(resource, 77);
}

static void
xdg_surface_ack_configure(struct wl_client *client, struct wl_resource *resource,
                          uint32_t serial)
{
	struct server_state *state = wl_resource_get_user_data(resource);

	(void) client;
	if (serial == 77)
		state->configured = 1;
}

static void
xdg_surface_destroy(struct wl_client *client, struct wl_resource *resource)
{
	struct server_state *state = wl_resource_get_user_data(resource);

	(void) client;
	if (state->toplevel_destroyed)
		state->xdg_surface_destroyed = 1;
	wl_resource_destroy(resource);
}

static const struct xdg_surface_interface xdg_surface_implementation = {
	.destroy = xdg_surface_destroy,
	.get_toplevel = xdg_surface_get_toplevel,
	.ack_configure = xdg_surface_ack_configure,
};

static void
wm_base_create_positioner(struct wl_client *client, struct wl_resource *resource,
                          uint32_t id)
{
	(void) resource;
	(void) id;
	wl_client_post_implementation_error(client, "unexpected create_positioner");
}

static void
wm_base_get_xdg_surface(struct wl_client *client, struct wl_resource *resource,
                        uint32_t id, struct wl_resource *surface)
{
	struct wl_resource *xdg_surface;

	(void) surface;
	xdg_surface = wl_resource_create(
		client, &xdg_surface_interface, wl_resource_get_version(resource), id);
	if (xdg_surface == NULL) {
		wl_client_post_no_memory(client);
		return;
	}
	wl_resource_set_implementation(xdg_surface, &xdg_surface_implementation,
	                               wl_resource_get_user_data(resource), NULL);
}

static void
wm_base_pong(struct wl_client *client, struct wl_resource *resource,
             uint32_t serial)
{
	struct server_state *state = wl_resource_get_user_data(resource);

	(void) client;
	if (serial == 41)
		state->ponged = 1;
}

static void
wm_base_destroy(struct wl_client *client, struct wl_resource *resource)
{
	struct server_state *state = wl_resource_get_user_data(resource);

	(void) client;
	if (state->surface_destroyed)
		state->wm_base_destroyed = 1;
	wl_resource_destroy(resource);
}

static const struct xdg_wm_base_interface wm_base_implementation = {
	.destroy = wm_base_destroy,
	.create_positioner = wm_base_create_positioner,
	.get_xdg_surface = wm_base_get_xdg_surface,
	.pong = wm_base_pong,
};

static void
bind_wm_base(struct wl_client *client, void *data, uint32_t version, uint32_t id)
{
	struct wl_resource *resource = wl_resource_create(
		client, &xdg_wm_base_interface, version < 5 ? (int) version : 5, id);

	if (resource == NULL) {
		wl_client_post_no_memory(client);
		return;
	}
	wl_resource_set_implementation(resource, &wm_base_implementation, data, NULL);
	xdg_wm_base_send_ping(resource, 41);
}

static void
handle_client_destroy(struct wl_listener *listener, void *data)
{
	struct server_state *state = wl_container_of(listener, state, client_destroy);

	(void) data;
	wl_display_terminate(state->display);
}

int
xdg_server_fd(int fd)
{
	struct server_state state = {0};
	struct wl_client *client;

	state.display = wl_display_create();
	if (state.display == NULL)
		return EXIT_FAILURE;
	if (wl_global_create(state.display, &wl_compositor_interface, 4,
	                     &state, bind_compositor) == NULL ||
	    wl_global_create(state.display, &xdg_wm_base_interface, 5,
	                     &state, bind_wm_base) == NULL) {
		wl_display_destroy(state.display);
		return EXIT_FAILURE;
	}
	client = wl_client_create(state.display, fd);
	if (client == NULL) {
		wl_display_destroy(state.display);
		return EXIT_FAILURE;
	}
	state.client_destroy.notify = handle_client_destroy;
	wl_client_add_destroy_listener(client, &state.client_destroy);
	wl_display_run(state.display);
	wl_display_destroy(state.display);
	return state.ponged && state.configured && state.toplevel_destroyed &&
	       state.xdg_surface_destroyed && state.surface_destroyed &&
	       state.wm_base_destroyed ? EXIT_SUCCESS : EXIT_FAILURE;
}
