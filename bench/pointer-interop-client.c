#include "xdg-interop.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>

struct pointer_client_state {
	struct wl_compositor *compositor;
	struct wl_seat *seat;
	int capabilities;
	int name;
	int enter;
	int motion;
	int button;
	int axis;
	int axis_source;
	int axis_stop;
	int axis_discrete;
	int axis_value120;
	int frame;
};

static void
seat_capabilities(void *data, struct wl_seat *seat, uint32_t capabilities)
{
	struct pointer_client_state *state = data;

	(void) seat;
	if (capabilities == WL_SEAT_CAPABILITY_POINTER)
		state->capabilities = 1;
}

static void
seat_name(void *data, struct wl_seat *seat, const char *name)
{
	struct pointer_client_state *state = data;

	(void) seat;
	if (strcmp(name, "wayring-seat") == 0)
		state->name = 1;
}

static const struct wl_seat_listener seat_listener = {
	.capabilities = seat_capabilities,
	.name = seat_name,
};

static void
pointer_enter(void *data, struct wl_pointer *pointer, uint32_t serial,
              struct wl_surface *surface, wl_fixed_t x, wl_fixed_t y)
{
	struct pointer_client_state *state = data;

	(void) pointer;
	if (serial == 41 && surface != NULL && x == wl_fixed_from_double(3.5) &&
	    y == wl_fixed_from_double(-2.25))
		state->enter = 1;
}

static void
pointer_leave(void *data, struct wl_pointer *pointer, uint32_t serial,
              struct wl_surface *surface)
{
	(void) data;
	(void) pointer;
	(void) serial;
	(void) surface;
}

static void
pointer_motion(void *data, struct wl_pointer *pointer, uint32_t time,
               wl_fixed_t x, wl_fixed_t y)
{
	struct pointer_client_state *state = data;

	(void) pointer;
	if (time == 100 && x == wl_fixed_from_int(4) && y == wl_fixed_from_int(5))
		state->motion = 1;
}

static void
pointer_button(void *data, struct wl_pointer *pointer, uint32_t serial,
               uint32_t time, uint32_t button, uint32_t button_state)
{
	struct pointer_client_state *state = data;

	(void) pointer;
	if (serial == 42 && time == 101 && button == 0x110 &&
	    button_state == WL_POINTER_BUTTON_STATE_PRESSED)
		state->button = 1;
}

static void
pointer_axis(void *data, struct wl_pointer *pointer, uint32_t time,
             uint32_t axis, wl_fixed_t value)
{
	struct pointer_client_state *state = data;

	(void) pointer;
	if (time == 102 && axis == WL_POINTER_AXIS_VERTICAL_SCROLL &&
	    value == wl_fixed_from_int(-1))
		state->axis = 1;
}

static void
pointer_frame(void *data, struct wl_pointer *pointer)
{
	struct pointer_client_state *state = data;

	(void) pointer;
	state->frame = 1;
}

static void
pointer_axis_source(void *data, struct wl_pointer *pointer, uint32_t source)
{
	struct pointer_client_state *state = data;

	(void) pointer;
	if (source == WL_POINTER_AXIS_SOURCE_WHEEL)
		state->axis_source = 1;
}

static void
pointer_axis_stop(void *data, struct wl_pointer *pointer, uint32_t time,
                  uint32_t axis)
{
	struct pointer_client_state *state = data;

	(void) pointer;
	if (time == 103 && axis == WL_POINTER_AXIS_VERTICAL_SCROLL)
		state->axis_stop = 1;
}

static void
pointer_axis_discrete(void *data, struct wl_pointer *pointer, uint32_t axis,
                      int32_t discrete)
{
	struct pointer_client_state *state = data;

	(void) pointer;
	if (axis == WL_POINTER_AXIS_VERTICAL_SCROLL && discrete == -1)
		state->axis_discrete = 1;
}

static void
pointer_axis_value120(void *data, struct wl_pointer *pointer, uint32_t axis,
                      int32_t value120)
{
	struct pointer_client_state *state = data;

	(void) pointer;
	if (axis == WL_POINTER_AXIS_VERTICAL_SCROLL && value120 == -120)
		state->axis_value120 = 1;
}

static const struct wl_pointer_listener pointer_listener = {
	.enter = pointer_enter,
	.leave = pointer_leave,
	.motion = pointer_motion,
	.button = pointer_button,
	.axis = pointer_axis,
	.frame = pointer_frame,
	.axis_source = pointer_axis_source,
	.axis_stop = pointer_axis_stop,
	.axis_discrete = pointer_axis_discrete,
	.axis_value120 = pointer_axis_value120,
};

static void
registry_global(void *data, struct wl_registry *registry, uint32_t name,
                const char *interface, uint32_t version)
{
	struct pointer_client_state *state = data;

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
pointer_client_fd(int fd)
{
	struct pointer_client_state state = {0};
	struct wl_display *display = wl_display_connect_to_fd(fd);
	struct wl_registry *registry;
	struct wl_surface *surface = NULL;
	struct wl_pointer *pointer = NULL;
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
	pointer = wl_seat_get_pointer(state.seat);
	if (surface == NULL || pointer == NULL)
		goto cleanup;
	wl_pointer_add_listener(pointer, &pointer_listener, &state);
	if (wl_display_roundtrip(display) < 0 || !state.enter || !state.motion ||
	    !state.button || !state.axis || !state.axis_source || !state.axis_stop ||
	    !state.axis_discrete || !state.axis_value120 || !state.frame)
		goto cleanup;
	status = EXIT_SUCCESS;

cleanup:
	if (pointer != NULL)
		wl_pointer_release(pointer);
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
