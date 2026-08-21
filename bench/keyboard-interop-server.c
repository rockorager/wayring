#include "xdg-interop.h"

#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-server.h>

static const char keymap_text[] = "xkb_keymap {}";

struct keyboard_server_state {
	struct wl_display *display;
	struct wl_listener client_destroy;
	struct wl_resource *surface;
	int keyboard_released;
	int surface_destroyed;
	int seat_released;
};

static void
keyboard_release(struct wl_client *client, struct wl_resource *resource)
{
	struct keyboard_server_state *state = wl_resource_get_user_data(resource);

	(void) client;
	state->keyboard_released = 1;
	wl_resource_destroy(resource);
}

static const struct wl_keyboard_interface keyboard_implementation = {
	.release = keyboard_release,
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
	struct keyboard_server_state *state = wl_resource_get_user_data(resource);
	struct wl_resource *keyboard;
	const uint32_t pressed_keys[] = {30, 31};
	struct wl_array keys = {
		.size = sizeof(pressed_keys),
		.alloc = sizeof(pressed_keys),
		.data = (void *) pressed_keys,
	};
	int keymap_fd;

	if (state->surface == NULL) {
		wl_client_post_implementation_error(client, "keyboard without surface");
		return;
	}
	keyboard = wl_resource_create(
		client, &wl_keyboard_interface, wl_resource_get_version(resource), id);
	if (keyboard == NULL) {
		wl_client_post_no_memory(client);
		return;
	}
	wl_resource_set_implementation(keyboard, &keyboard_implementation, state, NULL);
	keymap_fd = memfd_create("libwayland-keymap", MFD_CLOEXEC);
	if (keymap_fd < 0 || write(keymap_fd, keymap_text, sizeof(keymap_text)) !=
	    (ssize_t) sizeof(keymap_text) || lseek(keymap_fd, 0, SEEK_SET) < 0) {
		if (keymap_fd >= 0)
			close(keymap_fd);
		wl_client_post_no_memory(client);
		return;
	}
	wl_keyboard_send_repeat_info(keyboard, 25, 600);
	wl_keyboard_send_keymap(
		keyboard, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, keymap_fd, sizeof(keymap_text));
	close(keymap_fd);
	wl_keyboard_send_enter(keyboard, 41, state->surface, &keys);
	wl_keyboard_send_modifiers(keyboard, 42, 1, 2, 4, 3);
	wl_keyboard_send_key(
		keyboard, 43, 100, 30, WL_KEYBOARD_KEY_STATE_PRESSED);
	wl_keyboard_send_leave(keyboard, 44, state->surface);
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
	struct keyboard_server_state *state = wl_resource_get_user_data(resource);

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
	wl_seat_send_capabilities(resource, WL_SEAT_CAPABILITY_KEYBOARD);
	wl_seat_send_name(resource, "wayring-seat");
}

static void
surface_destroy(struct wl_client *client, struct wl_resource *resource)
{
	struct keyboard_server_state *state = wl_resource_get_user_data(resource);

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
	struct keyboard_server_state *state = wl_resource_get_user_data(resource);
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
	struct keyboard_server_state *state =
		wl_container_of(listener, state, client_destroy);

	(void) data;
	wl_display_terminate(state->display);
}

int
keyboard_server_fd(int fd)
{
	struct keyboard_server_state state = {0};
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
	return state.keyboard_released && state.surface_destroyed && state.seat_released ?
	       EXIT_SUCCESS : EXIT_FAILURE;
}
