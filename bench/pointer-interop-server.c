#include "xdg-interop.h"

#include <stdint.h>
#include <stdlib.h>
#include <wayland-server.h>

struct pointer_server_state {
	struct wl_display *display;
	struct wl_listener client_destroy;
	struct wl_resource *surface;
	int pointer_released;
	int surface_destroyed;
	int seat_released;
};

static void
pointer_set_cursor(struct wl_client *client, struct wl_resource *resource,
                   uint32_t serial, struct wl_resource *surface,
                   int32_t hotspot_x, int32_t hotspot_y)
{
	(void) resource;
	(void) serial;
	(void) surface;
	(void) hotspot_x;
	(void) hotspot_y;
	wl_client_post_implementation_error(client, "unexpected cursor");
}

static void
pointer_release(struct wl_client *client, struct wl_resource *resource)
{
	struct pointer_server_state *state = wl_resource_get_user_data(resource);

	(void) client;
	state->pointer_released = 1;
	wl_resource_destroy(resource);
}

static const struct wl_pointer_interface pointer_implementation = {
	.set_cursor = pointer_set_cursor,
	.release = pointer_release,
};

static void
seat_get_pointer(struct wl_client *client, struct wl_resource *resource, uint32_t id)
{
	struct pointer_server_state *state = wl_resource_get_user_data(resource);
	struct wl_resource *pointer;

	if (state->surface == NULL) {
		wl_client_post_implementation_error(client, "pointer without surface");
		return;
	}
	pointer = wl_resource_create(
		client, &wl_pointer_interface, wl_resource_get_version(resource), id);
	if (pointer == NULL) {
		wl_client_post_no_memory(client);
		return;
	}
	wl_resource_set_implementation(pointer, &pointer_implementation, state, NULL);
	wl_pointer_send_enter(pointer, 41, state->surface,
	                      wl_fixed_from_double(3.5), wl_fixed_from_double(-2.25));
	wl_pointer_send_motion(pointer, 100, wl_fixed_from_int(4), wl_fixed_from_int(5));
	wl_pointer_send_button(pointer, 42, 101, 0x110, WL_POINTER_BUTTON_STATE_PRESSED);
	wl_pointer_send_axis_source(pointer, WL_POINTER_AXIS_SOURCE_WHEEL);
	wl_pointer_send_axis(pointer, 102, WL_POINTER_AXIS_VERTICAL_SCROLL,
	                     wl_fixed_from_int(-1));
	wl_pointer_send_axis_discrete(pointer, WL_POINTER_AXIS_VERTICAL_SCROLL, -1);
	wl_pointer_send_axis_value120(pointer, WL_POINTER_AXIS_VERTICAL_SCROLL, -120);
	wl_pointer_send_axis_stop(pointer, 103, WL_POINTER_AXIS_VERTICAL_SCROLL);
	wl_pointer_send_frame(pointer);
}

static void
seat_get_keyboard(struct wl_client *client, struct wl_resource *resource, uint32_t id)
{
	(void) resource;
	(void) id;
	wl_client_post_implementation_error(client, "unexpected keyboard");
}

static void
seat_get_touch(struct wl_client *client, struct wl_resource *resource, uint32_t id)
{
	(void) resource;
	(void) id;
	wl_client_post_implementation_error(client, "unexpected touch");
}

static void
seat_release(struct wl_client *client, struct wl_resource *resource)
{
	struct pointer_server_state *state = wl_resource_get_user_data(resource);

	(void) client;
	state->seat_released = 1;
	wl_resource_destroy(resource);
}

static const struct wl_seat_interface seat_implementation = {
	.get_pointer = seat_get_pointer,
	.get_keyboard = seat_get_keyboard,
	.get_touch = seat_get_touch,
	.release = seat_release,
};

static void
bind_seat(struct wl_client *client, void *data, uint32_t version, uint32_t id)
{
	struct wl_resource *resource = wl_resource_create(
		client, &wl_seat_interface, version < 8 ? (int) version : 8, id);

	if (resource == NULL) {
		wl_client_post_no_memory(client);
		return;
	}
	wl_resource_set_implementation(resource, &seat_implementation, data, NULL);
	wl_seat_send_capabilities(resource, WL_SEAT_CAPABILITY_POINTER);
	wl_seat_send_name(resource, "wayring-seat");
}

static void
surface_destroy(struct wl_client *client, struct wl_resource *resource)
{
	struct pointer_server_state *state = wl_resource_get_user_data(resource);

	(void) client;
	state->surface_destroyed = 1;
	state->surface = NULL;
	wl_resource_destroy(resource);
}

static const struct wl_surface_interface surface_implementation = {
	.destroy = surface_destroy,
};

static void
compositor_create_surface(struct wl_client *client, struct wl_resource *resource,
                          uint32_t id)
{
	struct pointer_server_state *state = wl_resource_get_user_data(resource);
	struct wl_resource *surface = wl_resource_create(
		client, &wl_surface_interface, wl_resource_get_version(resource), id);

	if (surface == NULL) {
		wl_client_post_no_memory(client);
		return;
	}
	wl_resource_set_implementation(surface, &surface_implementation, state, NULL);
	state->surface = surface;
}

static void
compositor_create_region(struct wl_client *client, struct wl_resource *resource,
                         uint32_t id)
{
	(void) resource;
	(void) id;
	wl_client_post_implementation_error(client, "unexpected region");
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
handle_client_destroy(struct wl_listener *listener, void *data)
{
	struct pointer_server_state *state =
		wl_container_of(listener, state, client_destroy);

	(void) data;
	wl_display_terminate(state->display);
}

int
pointer_server_fd(int fd)
{
	struct pointer_server_state state = {0};
	struct wl_client *client;

	state.display = wl_display_create();
	if (state.display == NULL)
		return EXIT_FAILURE;
	if (wl_global_create(state.display, &wl_compositor_interface, 4,
	                     &state, bind_compositor) == NULL ||
	    wl_global_create(state.display, &wl_seat_interface, 8,
	                     &state, bind_seat) == NULL) {
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
	return state.pointer_released && state.surface_destroyed && state.seat_released ?
	       EXIT_SUCCESS : EXIT_FAILURE;
}
