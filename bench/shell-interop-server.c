#include "xdg-interop.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-server.h>

struct shell_server_state {
	struct wl_display *display;
	struct wl_listener client_destroy;
	int shell_surface_created;
	int pong;
	int title;
	int class_name;
	int toplevel;
	int surface_destroyed;
};

static void
shell_surface_pong(struct wl_client *client, struct wl_resource *resource,
                   uint32_t serial)
{
	struct shell_server_state *state = wl_resource_get_user_data(resource);
	(void) client;
	if (serial == 41)
		state->pong = 1;
}

static void
shell_surface_move(struct wl_client *client, struct wl_resource *resource,
                   struct wl_resource *seat, uint32_t serial)
{
	(void) resource;
	(void) seat;
	(void) serial;
	wl_client_post_implementation_error(client, "unexpected shell move");
}

static void
shell_surface_resize(struct wl_client *client, struct wl_resource *resource,
                     struct wl_resource *seat, uint32_t serial, uint32_t edges)
{
	(void) resource;
	(void) seat;
	(void) serial;
	(void) edges;
	wl_client_post_implementation_error(client, "unexpected shell resize");
}

static void
shell_surface_set_toplevel(struct wl_client *client, struct wl_resource *resource)
{
	struct shell_server_state *state = wl_resource_get_user_data(resource);
	(void) client;
	state->toplevel = 1;
}

static void
shell_surface_set_transient(struct wl_client *client, struct wl_resource *resource,
                            struct wl_resource *parent, int32_t x, int32_t y,
                            uint32_t flags)
{
	(void) resource;
	(void) parent;
	(void) x;
	(void) y;
	(void) flags;
	wl_client_post_implementation_error(client, "unexpected transient shell surface");
}

static void
shell_surface_set_fullscreen(struct wl_client *client, struct wl_resource *resource,
                             uint32_t method, uint32_t framerate,
                             struct wl_resource *output)
{
	(void) resource;
	(void) method;
	(void) framerate;
	(void) output;
	wl_client_post_implementation_error(client, "unexpected fullscreen shell surface");
}

static void
shell_surface_set_popup(struct wl_client *client, struct wl_resource *resource,
                        struct wl_resource *seat, uint32_t serial,
                        struct wl_resource *parent, int32_t x, int32_t y,
                        uint32_t flags)
{
	(void) resource;
	(void) seat;
	(void) serial;
	(void) parent;
	(void) x;
	(void) y;
	(void) flags;
	wl_client_post_implementation_error(client, "unexpected popup shell surface");
}

static void
shell_surface_set_maximized(struct wl_client *client, struct wl_resource *resource,
                            struct wl_resource *output)
{
	(void) resource;
	(void) output;
	wl_client_post_implementation_error(client, "unexpected maximized shell surface");
}

static void
shell_surface_set_title(struct wl_client *client, struct wl_resource *resource,
                        const char *title)
{
	struct shell_server_state *state = wl_resource_get_user_data(resource);
	(void) client;
	if (strcmp(title, "wayring-shell") == 0)
		state->title = 1;
}

static void
shell_surface_set_class(struct wl_client *client, struct wl_resource *resource,
                        const char *class_name)
{
	struct shell_server_state *state = wl_resource_get_user_data(resource);
	(void) client;
	if (strcmp(class_name, "wayring") == 0)
		state->class_name = 1;
}

static const struct wl_shell_surface_interface shell_surface_implementation = {
	.pong = shell_surface_pong,
	.move = shell_surface_move,
	.resize = shell_surface_resize,
	.set_toplevel = shell_surface_set_toplevel,
	.set_transient = shell_surface_set_transient,
	.set_fullscreen = shell_surface_set_fullscreen,
	.set_popup = shell_surface_set_popup,
	.set_maximized = shell_surface_set_maximized,
	.set_title = shell_surface_set_title,
	.set_class = shell_surface_set_class,
};

static void
shell_get_shell_surface(struct wl_client *client, struct wl_resource *resource,
                        uint32_t id, struct wl_resource *surface)
{
	struct shell_server_state *state = wl_resource_get_user_data(resource);
	struct wl_resource *shell_surface;
	(void) surface;
	shell_surface = wl_resource_create(client, &wl_shell_surface_interface, 1, id);
	if (shell_surface == NULL) {
		wl_client_post_no_memory(client);
		return;
	}
	wl_resource_set_implementation(
		shell_surface, &shell_surface_implementation, state, NULL);
	wl_shell_surface_send_ping(shell_surface, 41);
	wl_shell_surface_send_configure(
		shell_surface, WL_SHELL_SURFACE_RESIZE_BOTTOM_RIGHT, 800, 600);
	wl_shell_surface_send_popup_done(shell_surface);
	state->shell_surface_created = 1;
}

static const struct wl_shell_interface shell_implementation = {
	.get_shell_surface = shell_get_shell_surface,
};

static void
bind_shell(struct wl_client *client, void *data, uint32_t version, uint32_t id)
{
	struct wl_resource *resource = wl_resource_create(
		client, &wl_shell_interface, version < 1 ? (int) version : 1, id);
	if (resource == NULL) {
		wl_client_post_no_memory(client);
		return;
	}
	wl_resource_set_implementation(resource, &shell_implementation, data, NULL);
}

static void
surface_destroy(struct wl_client *client, struct wl_resource *resource)
{
	struct shell_server_state *state = wl_resource_get_user_data(resource);
	(void) client;
	state->surface_destroyed = 1;
	wl_resource_destroy(resource);
}

static const struct wl_surface_interface surface_implementation = {
	.destroy = surface_destroy,
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
	wl_resource_set_implementation(
		surface, &surface_implementation, wl_resource_get_user_data(resource), NULL);
}

static void
compositor_create_region(struct wl_client *client, struct wl_resource *resource,
                         uint32_t id)
{
	(void) resource;
	(void) id;
	wl_client_post_implementation_error(client, "unexpected shell region");
}

static const struct wl_compositor_interface compositor_implementation = {
	.create_surface = compositor_create_surface,
	.create_region = compositor_create_region,
};

static void
bind_compositor(struct wl_client *client, void *data, uint32_t version, uint32_t id)
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
client_destroyed(struct wl_listener *listener, void *data)
{
	struct shell_server_state *state =
		wl_container_of(listener, state, client_destroy);
	(void) data;
	wl_display_terminate(state->display);
}

int
shell_server_fd(int fd)
{
	struct shell_server_state state = {.display = wl_display_create()};
	struct wl_client *client;
	if (state.display == NULL)
		return EXIT_FAILURE;
	if (wl_global_create(state.display, &wl_compositor_interface, 4,
	                     &state, bind_compositor) == NULL ||
	    wl_global_create(state.display, &wl_shell_interface, 1,
	                     &state, bind_shell) == NULL) {
		wl_display_destroy(state.display);
		return EXIT_FAILURE;
	}
	client = wl_client_create(state.display, fd);
	if (client == NULL) {
		wl_display_destroy(state.display);
		return EXIT_FAILURE;
	}
	state.client_destroy.notify = client_destroyed;
	wl_client_add_destroy_listener(client, &state.client_destroy);
	wl_display_run(state.display);
	wl_display_destroy(state.display);
	return state.shell_surface_created && state.pong && state.title &&
	       state.class_name && state.toplevel && state.surface_destroyed ?
	       EXIT_SUCCESS : EXIT_FAILURE;
}
