#include "xdg-interop.h"

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <wayland-client.h>

static const char selection_data[] = "libwayland-selection";

struct data_device_client_state {
	struct wl_seat *seat;
	struct wl_data_device_manager *manager;
	int sent;
};

static void
source_target(void *data, struct wl_data_source *source, const char *mime_type)
{
	(void) data;
	(void) source;
	(void) mime_type;
}

static void
source_send(void *data, struct wl_data_source *source, const char *mime_type,
            int32_t fd)
{
	struct data_device_client_state *state = data;
	ssize_t written;

	(void) source;
	if (strcmp(mime_type, "text/plain") != 0 ||
	    (fcntl(fd, F_GETFD) & FD_CLOEXEC) == 0) {
		close(fd);
		return;
	}
	written = write(fd, selection_data, sizeof(selection_data));
	close(fd);
	if (written == (ssize_t) sizeof(selection_data))
		state->sent = 1;
}

static void
source_cancelled(void *data, struct wl_data_source *source)
{
	(void) data;
	(void) source;
}

static void
source_dnd_drop_performed(void *data, struct wl_data_source *source)
{
	(void) data;
	(void) source;
}

static void
source_dnd_finished(void *data, struct wl_data_source *source)
{
	(void) data;
	(void) source;
}

static void
source_action(void *data, struct wl_data_source *source, uint32_t action)
{
	(void) data;
	(void) source;
	(void) action;
}

static const struct wl_data_source_listener source_listener = {
	.target = source_target,
	.send = source_send,
	.cancelled = source_cancelled,
	.dnd_drop_performed = source_dnd_drop_performed,
	.dnd_finished = source_dnd_finished,
	.action = source_action,
};

static void
device_data_offer(void *data, struct wl_data_device *device,
                  struct wl_data_offer *offer)
{
	(void) data;
	(void) device;
	(void) offer;
}

static void
device_enter(void *data, struct wl_data_device *device, uint32_t serial,
             struct wl_surface *surface, wl_fixed_t x, wl_fixed_t y,
             struct wl_data_offer *offer)
{
	(void) data;
	(void) device;
	(void) serial;
	(void) surface;
	(void) x;
	(void) y;
	(void) offer;
}

static void
device_leave(void *data, struct wl_data_device *device)
{
	(void) data;
	(void) device;
}

static void
device_motion(void *data, struct wl_data_device *device, uint32_t time,
              wl_fixed_t x, wl_fixed_t y)
{
	(void) data;
	(void) device;
	(void) time;
	(void) x;
	(void) y;
}

static void
device_drop(void *data, struct wl_data_device *device)
{
	(void) data;
	(void) device;
}

static void
device_selection(void *data, struct wl_data_device *device,
                 struct wl_data_offer *offer)
{
	(void) data;
	(void) device;
	(void) offer;
}

static const struct wl_data_device_listener device_listener = {
	.data_offer = device_data_offer,
	.enter = device_enter,
	.leave = device_leave,
	.motion = device_motion,
	.drop = device_drop,
	.selection = device_selection,
};

static void
registry_global(void *data, struct wl_registry *registry, uint32_t name,
                const char *interface, uint32_t version)
{
	struct data_device_client_state *state = data;

	if (strcmp(interface, wl_seat_interface.name) == 0) {
		state->seat = wl_registry_bind(
			registry, name, &wl_seat_interface, version < 7 ? version : 7);
	} else if (strcmp(interface, wl_data_device_manager_interface.name) == 0) {
		state->manager = wl_registry_bind(
			registry, name, &wl_data_device_manager_interface,
			version < 3 ? version : 3);
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
data_device_client_fd(int fd)
{
	struct data_device_client_state state = {0};
	struct wl_display *display = wl_display_connect_to_fd(fd);
	struct wl_registry *registry;
	struct wl_data_source *source = NULL;
	struct wl_data_device *device = NULL;
	int status = EXIT_FAILURE;

	if (display == NULL)
		return EXIT_FAILURE;
	registry = wl_display_get_registry(display);
	wl_registry_add_listener(registry, &registry_listener, &state);
	if (wl_display_roundtrip(display) < 0 || state.seat == NULL ||
	    state.manager == NULL)
		goto cleanup;

	source = wl_data_device_manager_create_data_source(state.manager);
	device = wl_data_device_manager_get_data_device(state.manager, state.seat);
	if (source == NULL || device == NULL)
		goto cleanup;
	wl_data_source_add_listener(source, &source_listener, &state);
	wl_data_device_add_listener(device, &device_listener, &state);
	wl_data_source_offer(source, "text/plain");
	wl_data_device_set_selection(device, source, 77);
	if (wl_display_roundtrip(display) < 0 || !state.sent)
		goto cleanup;
	status = EXIT_SUCCESS;

cleanup:
	if (source != NULL)
		wl_data_source_destroy(source);
	if (device != NULL)
		wl_data_device_release(device);
	if (state.manager != NULL)
		wl_data_device_manager_destroy(state.manager);
	if (state.seat != NULL)
		wl_seat_release(state.seat);
	wl_registry_destroy(registry);
	wl_display_flush(display);
	wl_display_disconnect(display);
	return status;
}
