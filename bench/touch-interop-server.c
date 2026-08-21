#include "xdg-interop.h"

#include <stdint.h>
#include <stdlib.h>
#include <wayland-server.h>

struct touch_server_state {
	struct wl_display *display;
	struct wl_listener client_destroy;
	struct wl_resource *surface;
	int touch_released;
	int surface_destroyed;
	int seat_released;
};

static void
touch_release(struct wl_client *client, struct wl_resource *resource)
{
	struct touch_server_state *state = wl_resource_get_user_data(resource);

	(void) client;
	state->touch_released = 1;
	wl_resource_destroy(resource);
}

static const struct wl_touch_interface touch_implementation = {
	.release = touch_release,
};

static void
seat_get_pointer(struct wl_client *client, struct wl_resource *resource, uint32_t id)
{
	(void) resource;
	(void) id;
	wl_client_post_implementation_error(client, "unexpected pointer");
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
	struct touch_server_state *state = wl_resource_get_user_data(resource);
	struct wl_resource *touch;

	if (state->surface == NULL) {
		wl_client_post_implementation_error(client, "touch without surface");
		return;
	}
	touch = wl_resource_create(
		client, &wl_touch_interface, wl_resource_get_version(resource), id);
	if (touch == NULL) {
		wl_client_post_no_memory(client);
		return;
	}
	wl_resource_set_implementation(touch, &touch_implementation, state, NULL);
	wl_touch_send_down(touch, 51, 200, state->surface, 7,
	                   wl_fixed_from_double(1.5), wl_fixed_from_int(-2));
	wl_touch_send_motion(touch, 201, 7, wl_fixed_from_int(3), wl_fixed_from_int(4));
	wl_touch_send_shape(touch, 7, wl_fixed_from_int(5), wl_fixed_from_int(2));
	wl_touch_send_orientation(touch, 7, wl_fixed_from_int(-45));
	wl_touch_send_frame(touch);
	wl_touch_send_up(touch, 52, 202, 7);
	wl_touch_send_frame(touch);
	wl_touch_send_down(touch, 53, 203, state->surface, 8, 0, 0);
	wl_touch_send_cancel(touch);
}

static void
seat_release(struct wl_client *client, struct wl_resource *resource)
{
	struct touch_server_state *state = wl_resource_get_user_data(resource);

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
	wl_seat_send_capabilities(resource, WL_SEAT_CAPABILITY_TOUCH);
	wl_seat_send_name(resource, "wayring-seat");
}

static void
surface_destroy(struct wl_client *client, struct wl_resource *resource)
{
	struct touch_server_state *state = wl_resource_get_user_data(resource);

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
	struct touch_server_state *state = wl_resource_get_user_data(resource);
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
	struct touch_server_state *state =
		wl_container_of(listener, state, client_destroy);

	(void) data;
	wl_display_terminate(state->display);
}

int
touch_server_fd(int fd)
{
	struct touch_server_state state = {0};
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
	return state.touch_released && state.surface_destroyed && state.seat_released ?
	       EXIT_SUCCESS : EXIT_FAILURE;
}
