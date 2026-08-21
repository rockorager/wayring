#include "xdg-interop.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>

struct touch_client_state {
	struct wl_compositor *compositor;
	struct wl_seat *seat;
	int capabilities;
	int name;
	int down;
	int motion;
	int shape;
	int orientation;
	int up;
	int frames;
	int cancel;
};

static void
seat_capabilities(void *data, struct wl_seat *seat, uint32_t capabilities)
{
	struct touch_client_state *state = data;

	(void) seat;
	if (capabilities == WL_SEAT_CAPABILITY_TOUCH)
		state->capabilities = 1;
}

static void
seat_name(void *data, struct wl_seat *seat, const char *name)
{
	struct touch_client_state *state = data;

	(void) seat;
	if (strcmp(name, "wayring-seat") == 0)
		state->name = 1;
}

static const struct wl_seat_listener seat_listener = {
	.capabilities = seat_capabilities,
	.name = seat_name,
};

static void
touch_down(void *data, struct wl_touch *touch, uint32_t serial, uint32_t time,
           struct wl_surface *surface, int32_t id, wl_fixed_t x, wl_fixed_t y)
{
	struct touch_client_state *state = data;

	(void) touch;
	if (((state->down == 0 && serial == 51 && time == 200 && id == 7 &&
	      x == wl_fixed_from_double(1.5) && y == wl_fixed_from_int(-2)) ||
	     (state->down == 1 && serial == 53 && time == 203 && id == 8 &&
	      x == 0 && y == 0)) && surface != NULL)
		state->down++;
}

static void
touch_up(void *data, struct wl_touch *touch, uint32_t serial, uint32_t time,
         int32_t id)
{
	struct touch_client_state *state = data;

	(void) touch;
	if (serial == 52 && time == 202 && id == 7)
		state->up = 1;
}

static void
touch_motion(void *data, struct wl_touch *touch, uint32_t time, int32_t id,
             wl_fixed_t x, wl_fixed_t y)
{
	struct touch_client_state *state = data;

	(void) touch;
	if (time == 201 && id == 7 && x == wl_fixed_from_int(3) &&
	    y == wl_fixed_from_int(4))
		state->motion = 1;
}

static void
touch_frame(void *data, struct wl_touch *touch)
{
	struct touch_client_state *state = data;

	(void) touch;
	state->frames++;
}

static void
touch_cancel(void *data, struct wl_touch *touch)
{
	struct touch_client_state *state = data;

	(void) touch;
	if (state->down == 2)
		state->cancel = 1;
}

static void
touch_shape(void *data, struct wl_touch *touch, int32_t id,
            wl_fixed_t major, wl_fixed_t minor)
{
	struct touch_client_state *state = data;

	(void) touch;
	if (id == 7 && major == wl_fixed_from_int(5) && minor == wl_fixed_from_int(2))
		state->shape = 1;
}

static void
touch_orientation(void *data, struct wl_touch *touch, int32_t id,
                  wl_fixed_t orientation)
{
	struct touch_client_state *state = data;

	(void) touch;
	if (id == 7 && orientation == wl_fixed_from_int(-45))
		state->orientation = 1;
}

static const struct wl_touch_listener touch_listener = {
	.down = touch_down,
	.up = touch_up,
	.motion = touch_motion,
	.frame = touch_frame,
	.cancel = touch_cancel,
	.shape = touch_shape,
	.orientation = touch_orientation,
};

static void
registry_global(void *data, struct wl_registry *registry, uint32_t name,
                const char *interface, uint32_t version)
{
	struct touch_client_state *state = data;

	if (strcmp(interface, wl_compositor_interface.name) == 0) {
		state->compositor = wl_registry_bind(
			registry, name, &wl_compositor_interface,
			version < 4 ? version : 4);
	} else if (strcmp(interface, wl_seat_interface.name) == 0) {
		state->seat = wl_registry_bind(
			registry, name, &wl_seat_interface, version < 8 ? version : 8);
		wl_seat_add_listener(state->seat, &seat_listener, state);
	}
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
touch_client_fd(int fd)
{
	struct touch_client_state state = {0};
	struct wl_display *display = wl_display_connect_to_fd(fd);
	struct wl_registry *registry;
	struct wl_surface *surface = NULL;
	struct wl_touch *touch = NULL;
	int status = EXIT_FAILURE;

	if (display == NULL)
		return EXIT_FAILURE;
	registry = wl_display_get_registry(display);
	wl_registry_add_listener(registry, &registry_listener, &state);
	if (wl_display_roundtrip(display) < 0 || state.compositor == NULL ||
	    state.seat == NULL || wl_display_roundtrip(display) < 0 ||
	    !state.capabilities || !state.name)
		goto cleanup;
	surface = wl_compositor_create_surface(state.compositor);
	touch = wl_seat_get_touch(state.seat);
	if (surface == NULL || touch == NULL)
		goto cleanup;
	wl_touch_add_listener(touch, &touch_listener, &state);
	if (wl_display_roundtrip(display) < 0 || state.down != 2 || !state.motion ||
	    !state.shape || !state.orientation || !state.up || state.frames != 2 ||
	    !state.cancel)
		goto cleanup;
	status = EXIT_SUCCESS;

cleanup:
	if (touch != NULL)
		wl_touch_release(touch);
	if (surface != NULL)
		wl_surface_destroy(surface);
	if (state.seat != NULL)
		wl_seat_release(state.seat);
	if (state.compositor != NULL)
		wl_compositor_destroy(state.compositor);
	wl_registry_destroy(registry);
	wl_display_flush(display);
	wl_display_disconnect(display);
	return status;
}
