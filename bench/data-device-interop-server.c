#include "xdg-interop.h"

#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <wayland-server.h>

static const char source_data[] = "wayring-selection";
static const char offer_data[] = "libwayland-offer";

struct data_device_server_state {
	struct wl_display *display;
	struct wl_listener client_destroy;
	struct wl_resource *source;
	struct wl_resource *origin;
	struct wl_resource *icon;
	int source_read_fd;
	int source_created;
	int device_created;
	int source_offered;
	int selection_set;
	int source_sent;
	int offer_received;
	int offer_destroyed;
	int source_destroyed;
	int device_released;
	int seat_released;
	int source_actions;
	int drag_started;
	int drag_events;
	int surfaces_destroyed;
};

static void
offer_accept(struct wl_client *client, struct wl_resource *resource,
             uint32_t serial, const char *mime_type)
{
	(void) client;
	(void) resource;
	(void) serial;
	(void) mime_type;
}

static void
offer_receive(struct wl_client *client, struct wl_resource *resource,
              const char *mime_type, int32_t fd)
{
	struct data_device_server_state *state = wl_resource_get_user_data(resource);
	ssize_t written;

	(void) client;
	if (strcmp(mime_type, "text/plain") != 0 ||
	    (fcntl(fd, F_GETFD) & FD_CLOEXEC) == 0) {
		close(fd);
		return;
	}
	written = write(fd, offer_data, sizeof(offer_data));
	close(fd);
	if (written == (ssize_t) sizeof(offer_data))
		state->offer_received = 1;
}

static void
offer_destroy(struct wl_client *client, struct wl_resource *resource)
{
	struct data_device_server_state *state = wl_resource_get_user_data(resource);

	(void) client;
	state->offer_destroyed = 1;
	wl_resource_destroy(resource);
}

static void
offer_finish(struct wl_client *client, struct wl_resource *resource)
{
	(void) resource;
	wl_client_post_implementation_error(client, "unexpected data offer finish");
}

static void
offer_set_actions(struct wl_client *client, struct wl_resource *resource,
                  uint32_t actions, uint32_t preferred_action)
{
	(void) resource;
	(void) actions;
	(void) preferred_action;
	wl_client_post_implementation_error(client, "unexpected data offer actions");
}

static const struct wl_data_offer_interface offer_implementation = {
	.accept = offer_accept,
	.receive = offer_receive,
	.destroy = offer_destroy,
	.finish = offer_finish,
	.set_actions = offer_set_actions,
};

static void
source_offer(struct wl_client *client, struct wl_resource *resource,
             const char *mime_type)
{
	struct data_device_server_state *state = wl_resource_get_user_data(resource);

	(void) client;
	if (strcmp(mime_type, "text/plain") == 0)
		state->source_offered = 1;
}

static void
source_destroy(struct wl_client *client, struct wl_resource *resource)
{
	struct data_device_server_state *state = wl_resource_get_user_data(resource);
	char received[sizeof(source_data)];
	ssize_t count;

	(void) client;
	count = read(state->source_read_fd, received, sizeof(received));
	close(state->source_read_fd);
	state->source_read_fd = -1;
	if (count == (ssize_t) sizeof(received) &&
	    memcmp(received, source_data, sizeof(received)) == 0)
		state->source_destroyed = 1;
	wl_resource_destroy(resource);
}

static void
source_set_actions(struct wl_client *client, struct wl_resource *resource,
                   uint32_t actions)
{
	struct data_device_server_state *state = wl_resource_get_user_data(resource);
	if (actions != (WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY |
	                WL_DATA_DEVICE_MANAGER_DND_ACTION_MOVE))
		wl_client_post_implementation_error(client, "invalid data source actions");
	else
		state->source_actions = 1;
}

static const struct wl_data_source_interface source_implementation = {
	.offer = source_offer,
	.destroy = source_destroy,
	.set_actions = source_set_actions,
};

static void
device_start_drag(struct wl_client *client, struct wl_resource *resource,
                  struct wl_resource *source, struct wl_resource *origin,
                  struct wl_resource *icon, uint32_t serial)
{
	struct data_device_server_state *state = wl_resource_get_user_data(resource);
	if (!state->source_actions || source != state->source || origin != state->origin ||
	    icon != state->icon || serial != 88) {
		wl_client_post_implementation_error(client, "invalid start drag");
		return;
	}
	wl_data_source_send_target(source, "text/plain");
	wl_data_source_send_action(source, WL_DATA_DEVICE_MANAGER_DND_ACTION_MOVE);
	wl_data_source_send_dnd_drop_performed(source);
	wl_data_source_send_dnd_finished(source);
	state->drag_started = 1;
	state->drag_events = 1;
}

static void
device_set_selection(struct wl_client *client, struct wl_resource *resource,
                     struct wl_resource *source, uint32_t serial)
{
	struct data_device_server_state *state = wl_resource_get_user_data(resource);
	int pipe_fds[2];

	if (source == NULL || serial != 77 || !state->source_offered ||
	    pipe2(pipe_fds, O_CLOEXEC) != 0) {
		wl_client_post_implementation_error(client, "invalid selection");
		return;
	}
	state->source_read_fd = pipe_fds[0];
	wl_data_source_send_send(source, "text/plain", pipe_fds[1]);
	close(pipe_fds[1]);
	state->selection_set = 1;
	state->source_sent = 1;
}

static void
device_release(struct wl_client *client, struct wl_resource *resource)
{
	struct data_device_server_state *state = wl_resource_get_user_data(resource);

	(void) client;
	state->device_released = 1;
	wl_resource_destroy(resource);
}

static const struct wl_data_device_interface device_implementation = {
	.start_drag = device_start_drag,
	.set_selection = device_set_selection,
	.release = device_release,
};

static void
manager_create_source(struct wl_client *client, struct wl_resource *resource,
                      uint32_t id)
{
	struct data_device_server_state *state = wl_resource_get_user_data(resource);
	struct wl_resource *source = wl_resource_create(
		client, &wl_data_source_interface, wl_resource_get_version(resource), id);

	if (source == NULL) {
		wl_client_post_no_memory(client);
		return;
	}
	wl_resource_set_implementation(source, &source_implementation, state, NULL);
	state->source = source;
	state->source_created = 1;
}

static void
manager_get_device(struct wl_client *client, struct wl_resource *resource,
                   uint32_t id, struct wl_resource *seat)
{
	struct data_device_server_state *state = wl_resource_get_user_data(resource);
	struct wl_resource *device;
	struct wl_resource *offer;

	(void) seat;
	device = wl_resource_create(
		client, &wl_data_device_interface, wl_resource_get_version(resource), id);
	if (device == NULL) {
		wl_client_post_no_memory(client);
		return;
	}
	offer = wl_resource_create(
		client, &wl_data_offer_interface, wl_resource_get_version(resource), 0);
	if (offer == NULL) {
		wl_resource_destroy(device);
		wl_client_post_no_memory(client);
		return;
	}
	wl_resource_set_implementation(device, &device_implementation, state, NULL);
	wl_resource_set_implementation(offer, &offer_implementation, state, NULL);
	wl_data_device_send_data_offer(device, offer);
	wl_data_offer_send_offer(offer, "text/plain");
	wl_data_device_send_selection(device, offer);
	state->device_created = 1;
}

static const struct wl_data_device_manager_interface manager_implementation = {
	.create_data_source = manager_create_source,
	.get_data_device = manager_get_device,
};

static void
bind_manager(struct wl_client *client, void *data, uint32_t version, uint32_t id)
{
	struct wl_resource *resource = wl_resource_create(
		client, &wl_data_device_manager_interface,
		version < 3 ? (int) version : 3, id);

	if (resource == NULL) {
		wl_client_post_no_memory(client);
		return;
	}
	wl_resource_set_implementation(resource, &manager_implementation, data, NULL);
}

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
	(void) resource;
	(void) id;
	wl_client_post_implementation_error(client, "unexpected touch");
}

static void
seat_release(struct wl_client *client, struct wl_resource *resource)
{
	struct data_device_server_state *state = wl_resource_get_user_data(resource);

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
		client, &wl_seat_interface, version < 7 ? (int) version : 7, id);

	if (resource == NULL) {
		wl_client_post_no_memory(client);
		return;
	}
	wl_resource_set_implementation(resource, &seat_implementation, data, NULL);
}

static void
surface_destroy(struct wl_client *client, struct wl_resource *resource)
{
	struct data_device_server_state *state = wl_resource_get_user_data(resource);
	(void) client;
	state->surfaces_destroyed++;
	wl_resource_destroy(resource);
}

static const struct wl_surface_interface surface_implementation = {
	.destroy = surface_destroy,
};

static void
compositor_create_surface(struct wl_client *client, struct wl_resource *resource,
                          uint32_t id)
{
	struct data_device_server_state *state = wl_resource_get_user_data(resource);
	struct wl_resource *surface = wl_resource_create(
		client, &wl_surface_interface, wl_resource_get_version(resource), id);
	if (surface == NULL) {
		wl_client_post_no_memory(client);
		return;
	}
	wl_resource_set_implementation(surface, &surface_implementation, state, NULL);
	if (state->origin == NULL)
		state->origin = surface;
	else
		state->icon = surface;
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
	struct data_device_server_state *state =
		wl_container_of(listener, state, client_destroy);

	(void) data;
	wl_display_terminate(state->display);
}

int
data_device_server_fd(int fd)
{
	struct data_device_server_state state = {.source_read_fd = -1};
	struct wl_client *client;

	state.display = wl_display_create();
	if (state.display == NULL)
		return EXIT_FAILURE;
	if (wl_global_create(state.display, &wl_seat_interface, 7,
	                     &state, bind_seat) == NULL ||
	    wl_global_create(state.display, &wl_data_device_manager_interface, 3,
	                     &state, bind_manager) == NULL ||
	    wl_global_create(state.display, &wl_compositor_interface, 4,
	                     &state, bind_compositor) == NULL) {
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
	if (state.source_read_fd >= 0)
		close(state.source_read_fd);
	wl_display_destroy(state.display);
	return state.source_created && state.device_created && state.source_offered &&
	       state.selection_set && state.source_sent && state.offer_received &&
	       state.offer_destroyed && state.source_destroyed &&
	       state.device_released && state.seat_released && state.source_actions &&
	       state.drag_started && state.drag_events && state.surfaces_destroyed == 2 ?
	       EXIT_SUCCESS : EXIT_FAILURE;
}
