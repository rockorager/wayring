#include "xdg-interop.h"

#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <wayland-client.h>

static const char expected_keymap[] = "xkb_keymap {}";

struct keyboard_client_state {
	struct wl_compositor *compositor;
	struct wl_seat *seat;
	int capabilities;
	int name;
	int keymap;
	int enter;
	int modifiers;
	int key;
	int repeat_info;
	int leave;
};

static void
seat_capabilities(void *data, struct wl_seat *seat, uint32_t capabilities)
{
	struct keyboard_client_state *state = data;

	(void) seat;
	if (capabilities == WL_SEAT_CAPABILITY_KEYBOARD)
		state->capabilities = 1;
}

static void
seat_name(void *data, struct wl_seat *seat, const char *name)
{
	struct keyboard_client_state *state = data;

	(void) seat;
	if (strcmp(name, "wayring-seat") == 0)
		state->name = 1;
}

static const struct wl_seat_listener seat_listener = {
	.capabilities = seat_capabilities,
	.name = seat_name,
};

static void
keyboard_keymap(void *data, struct wl_keyboard *keyboard, uint32_t format,
                int32_t fd, uint32_t size)
{
	struct keyboard_client_state *state = data;
	char keymap[sizeof(expected_keymap)];
	ssize_t count;

	(void) keyboard;
	count = read(fd, keymap, sizeof(keymap));
	if (format == WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1 &&
	    size == sizeof(expected_keymap) && count == (ssize_t) sizeof(keymap) &&
	    memcmp(keymap, expected_keymap, sizeof(keymap)) == 0 &&
	    (fcntl(fd, F_GETFD) & FD_CLOEXEC) != 0)
		state->keymap = 1;
	close(fd);
}

static void
keyboard_enter(void *data, struct wl_keyboard *keyboard, uint32_t serial,
               struct wl_surface *surface, struct wl_array *keys)
{
	struct keyboard_client_state *state = data;
	const uint32_t expected_keys[] = {30, 31};

	(void) keyboard;
	if (state->keymap && serial == 41 && surface != NULL &&
	    keys->size == sizeof(expected_keys) &&
	    memcmp(keys->data, expected_keys, sizeof(expected_keys)) == 0)
		state->enter = 1;
}

static void
keyboard_leave(void *data, struct wl_keyboard *keyboard, uint32_t serial,
               struct wl_surface *surface)
{
	struct keyboard_client_state *state = data;

	(void) keyboard;
	if (state->key && serial == 44 && surface != NULL)
		state->leave = 1;
}

static void
keyboard_key(void *data, struct wl_keyboard *keyboard, uint32_t serial,
             uint32_t time, uint32_t key, uint32_t key_state)
{
	struct keyboard_client_state *state = data;

	(void) keyboard;
	if (state->repeat_info && state->modifiers && serial == 43 && time == 100 &&
	    key == 30 && key_state == WL_KEYBOARD_KEY_STATE_PRESSED)
		state->key = 1;
}

static void
keyboard_modifiers(void *data, struct wl_keyboard *keyboard, uint32_t serial,
                   uint32_t depressed, uint32_t latched, uint32_t locked,
                   uint32_t group)
{
	struct keyboard_client_state *state = data;

	(void) keyboard;
	if (state->enter && serial == 42 && depressed == 1 && latched == 2 &&
	    locked == 4 && group == 3)
		state->modifiers = 1;
}

static void
keyboard_repeat_info(void *data, struct wl_keyboard *keyboard, int32_t rate,
                     int32_t delay)
{
	struct keyboard_client_state *state = data;

	(void) keyboard;
	if (rate == 25 && delay == 600)
		state->repeat_info = 1;
}

static const struct wl_keyboard_listener keyboard_listener = {
	.keymap = keyboard_keymap,
	.enter = keyboard_enter,
	.leave = keyboard_leave,
	.key = keyboard_key,
	.modifiers = keyboard_modifiers,
	.repeat_info = keyboard_repeat_info,
};

static void
registry_global(void *data, struct wl_registry *registry, uint32_t name,
                const char *interface, uint32_t version)
{
	struct keyboard_client_state *state = data;

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
keyboard_client_fd(int fd)
{
	struct keyboard_client_state state = {0};
	struct wl_display *display = wl_display_connect_to_fd(fd);
	struct wl_registry *registry;
	struct wl_surface *surface = NULL;
	struct wl_keyboard *keyboard = NULL;
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
	keyboard = wl_seat_get_keyboard(state.seat);
	if (surface == NULL || keyboard == NULL)
		goto cleanup;
	wl_keyboard_add_listener(keyboard, &keyboard_listener, &state);
	if (wl_display_roundtrip(display) < 0 || !state.keymap || !state.enter ||
	    !state.modifiers || !state.key || !state.repeat_info || !state.leave)
		goto cleanup;
	status = EXIT_SUCCESS;

cleanup:
	if (keyboard != NULL)
		wl_keyboard_release(keyboard);
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
