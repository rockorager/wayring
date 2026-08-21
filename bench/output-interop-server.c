#include "xdg-interop.h"

#include <stdint.h>
#include <stdlib.h>
#include <wayland-server.h>

struct output_server_state {
	struct wl_display *display;
	struct wl_listener client_destroy;
	int output_released;
};

static void
output_release(struct wl_client *client, struct wl_resource *resource)
{
	struct output_server_state *state = wl_resource_get_user_data(resource);

	(void) client;
	state->output_released = 1;
	wl_resource_destroy(resource);
}

static const struct wl_output_interface output_implementation = {
	.release = output_release,
};

static void
bind_output(struct wl_client *client, void *data, uint32_t version, uint32_t id)
{
	struct wl_resource *resource = wl_resource_create(
		client, &wl_output_interface, version < 4 ? (int) version : 4, id);

	if (resource == NULL) {
		wl_client_post_no_memory(client);
		return;
	}
	wl_resource_set_implementation(resource, &output_implementation, data, NULL);
	wl_output_send_geometry(resource, -10, 20, 600, 340,
	                        WL_OUTPUT_SUBPIXEL_HORIZONTAL_RGB,
	                        "Wayring", "Virtual-1", WL_OUTPUT_TRANSFORM_90);
	wl_output_send_mode(resource,
	                    WL_OUTPUT_MODE_CURRENT | WL_OUTPUT_MODE_PREFERRED,
	                    1920, 1080, 60000);
	if (wl_resource_get_version(resource) >= WL_OUTPUT_SCALE_SINCE_VERSION)
		wl_output_send_scale(resource, 2);
	if (wl_resource_get_version(resource) >= WL_OUTPUT_NAME_SINCE_VERSION) {
		wl_output_send_name(resource, "WL-1");
		wl_output_send_description(resource, "Wayring virtual output");
	}
	if (wl_resource_get_version(resource) >= WL_OUTPUT_DONE_SINCE_VERSION)
		wl_output_send_done(resource);
}

static void
handle_client_destroy(struct wl_listener *listener, void *data)
{
	struct output_server_state *state =
		wl_container_of(listener, state, client_destroy);

	(void) data;
	wl_display_terminate(state->display);
}

int
output_server_fd(int fd)
{
	struct output_server_state state = {0};
	struct wl_client *client;

	state.display = wl_display_create();
	if (state.display == NULL)
		return EXIT_FAILURE;
	if (wl_global_create(state.display, &wl_output_interface, 4,
	                     &state, bind_output) == NULL) {
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
	return state.output_released ? EXIT_SUCCESS : EXIT_FAILURE;
}
