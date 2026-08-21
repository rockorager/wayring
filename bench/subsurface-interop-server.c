#include "xdg-interop.h"

#include <stdint.h>
#include <stdlib.h>
#include <wayland-server.h>

struct subsurface_server_state {
	struct wl_display *display;
	struct wl_listener client_destroy;
	struct wl_resource *parent;
	struct wl_resource *child;
	int surfaces_created;
	int surfaces_destroyed;
	int subsurface_created;
	int positioned;
	int above;
	int below;
	int sync;
	int desync;
	int subsurface_destroyed;
	int subcompositor_destroyed;
};

static void
subsurface_destroy(struct wl_client *client, struct wl_resource *resource)
{
	struct subsurface_server_state *state = wl_resource_get_user_data(resource);
	(void) client;
	state->subsurface_destroyed = 1;
	wl_resource_destroy(resource);
}

static void
subsurface_set_position(struct wl_client *client, struct wl_resource *resource,
                        int32_t x, int32_t y)
{
	struct subsurface_server_state *state = wl_resource_get_user_data(resource);
	if (x != -7 || y != 11)
		wl_client_post_implementation_error(client, "invalid position");
	else
		state->positioned = 1;
}

static void
subsurface_place_above(struct wl_client *client, struct wl_resource *resource,
                       struct wl_resource *sibling)
{
	struct subsurface_server_state *state = wl_resource_get_user_data(resource);
	if (sibling != state->parent)
		wl_client_post_implementation_error(client, "invalid upper sibling");
	else
		state->above = 1;
}

static void
subsurface_place_below(struct wl_client *client, struct wl_resource *resource,
                       struct wl_resource *sibling)
{
	struct subsurface_server_state *state = wl_resource_get_user_data(resource);
	if (sibling != state->parent)
		wl_client_post_implementation_error(client, "invalid lower sibling");
	else
		state->below = 1;
}

static void
subsurface_set_sync(struct wl_client *client, struct wl_resource *resource)
{
	struct subsurface_server_state *state = wl_resource_get_user_data(resource);
	(void) client;
	state->sync = 1;
}

static void
subsurface_set_desync(struct wl_client *client, struct wl_resource *resource)
{
	struct subsurface_server_state *state = wl_resource_get_user_data(resource);
	(void) client;
	state->desync = 1;
}

static const struct wl_subsurface_interface subsurface_implementation = {
	.destroy = subsurface_destroy,
	.set_position = subsurface_set_position,
	.place_above = subsurface_place_above,
	.place_below = subsurface_place_below,
	.set_sync = subsurface_set_sync,
	.set_desync = subsurface_set_desync,
};

static void
subcompositor_destroy(struct wl_client *client, struct wl_resource *resource)
{
	struct subsurface_server_state *state = wl_resource_get_user_data(resource);
	(void) client;
	state->subcompositor_destroyed = 1;
	wl_resource_destroy(resource);
}

static void
subcompositor_get_subsurface(struct wl_client *client, struct wl_resource *resource,
                             uint32_t id, struct wl_resource *surface,
                             struct wl_resource *parent)
{
	struct subsurface_server_state *state = wl_resource_get_user_data(resource);
	struct wl_resource *subsurface;

	if (surface != state->child || parent != state->parent) {
		wl_client_post_implementation_error(client, "invalid subsurface pair");
		return;
	}
	subsurface = wl_resource_create(client, &wl_subsurface_interface, 1, id);
	if (subsurface == NULL) {
		wl_client_post_no_memory(client);
		return;
	}
	wl_resource_set_implementation(
		subsurface, &subsurface_implementation, state, NULL);
	state->subsurface_created = 1;
}

static const struct wl_subcompositor_interface subcompositor_implementation = {
	.destroy = subcompositor_destroy,
	.get_subsurface = subcompositor_get_subsurface,
};

static void
bind_subcompositor(struct wl_client *client, void *data, uint32_t version, uint32_t id)
{
	struct wl_resource *resource = wl_resource_create(
		client, &wl_subcompositor_interface, version < 1 ? (int) version : 1, id);
	if (resource == NULL) {
		wl_client_post_no_memory(client);
		return;
	}
	wl_resource_set_implementation(
		resource, &subcompositor_implementation, data, NULL);
}

static void
surface_destroy(struct wl_client *client, struct wl_resource *resource)
{
	struct subsurface_server_state *state = wl_resource_get_user_data(resource);
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
	struct subsurface_server_state *state = wl_resource_get_user_data(resource);
	struct wl_resource *surface = wl_resource_create(
		client, &wl_surface_interface, wl_resource_get_version(resource), id);
	if (surface == NULL) {
		wl_client_post_no_memory(client);
		return;
	}
	wl_resource_set_implementation(surface, &surface_implementation, state, NULL);
	if (state->surfaces_created++ == 0)
		state->parent = surface;
	else
		state->child = surface;
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
	struct subsurface_server_state *state =
		wl_container_of(listener, state, client_destroy);
	(void) data;
	wl_display_terminate(state->display);
}

int
subsurface_server_fd(int fd)
{
	struct subsurface_server_state state = {0};
	struct wl_client *client;

	state.display = wl_display_create();
	if (state.display == NULL)
		return EXIT_FAILURE;
	if (wl_global_create(state.display, &wl_compositor_interface, 4,
	                     &state, bind_compositor) == NULL ||
	    wl_global_create(state.display, &wl_subcompositor_interface, 1,
	                     &state, bind_subcompositor) == NULL) {
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
	return state.surfaces_created == 2 && state.surfaces_destroyed == 2 &&
	       state.subsurface_created && state.positioned && state.above && state.below &&
	       state.sync && state.desync && state.subsurface_destroyed &&
	       state.subcompositor_destroyed ? EXIT_SUCCESS : EXIT_FAILURE;
}
