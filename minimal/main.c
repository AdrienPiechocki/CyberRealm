#define _GNU_SOURCE
#include <errno.h>
#include <linux/input-event-codes.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <wayland-server-core.h>
#include <wlr/backend.h>
#include <wlr/render/allocator.h>
#include <wlr/render/wlr_renderer.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_cursor.h>
#include <wlr/types/wlr_data_device.h>
#include <wlr/types/wlr_input_device.h>
#include <wlr/types/wlr_keyboard.h>
#include <wlr/types/wlr_linux_dmabuf_v1.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_output_layout.h>
#include <wlr/types/wlr_pointer.h>
#include <wlr/types/wlr_pointer_constraints_v1.h>
#include <wlr/types/wlr_presentation_time.h>
#include <wlr/types/wlr_relative_pointer_v1.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/types/wlr_seat.h>
#include <wlr/types/wlr_subcompositor.h>
#include <wlr/types/wlr_xcursor_manager.h>
#include <wlr/types/wlr_xdg_shell.h>
#include <wlr/util/log.h>
#include <xkbcommon/xkbcommon.h>

struct server;
struct toplevel;

struct output {
	struct wl_list link;
	struct server *server;
	struct wlr_output *wlr_output;
	struct wl_listener frame;
	struct wl_listener request_state;
	struct wl_listener destroy;
};

struct toplevel {
	struct server *server;
	struct wlr_xdg_toplevel *xdg_toplevel;
	struct wlr_scene_tree *scene_tree;
	struct wl_listener map;
	struct wl_listener unmap;
	struct wl_listener commit;
	struct wl_listener destroy;
	struct wl_listener request_fullscreen;
	struct wl_listener request_maximize;
	bool is_fullscreen;
};

struct keyboard {
	struct wl_list link;
	struct server *server;
	struct wlr_keyboard *wlr_keyboard;
	struct wl_listener modifiers;
	struct wl_listener key;
	struct wl_listener destroy;
};

struct server {
	struct wl_display *display;
	struct wlr_backend *backend;
	struct wlr_renderer *renderer;
	struct wlr_allocator *allocator;
	struct wlr_scene *scene;
	struct wlr_output_layout *output_layout;
	struct wlr_scene_output_layout *scene_layout;
	struct wlr_xdg_shell *xdg_shell;
	struct wlr_cursor *cursor;
	struct wlr_xcursor_manager *cursor_mgr;
	struct wlr_seat *seat;
	struct wlr_relative_pointer_manager_v1 *relative_pointer;
	struct wlr_pointer_constraints_v1 *pointer_constraints;

	struct wl_list outputs;
	struct wl_list keyboards;

	struct wl_listener new_output;
	struct wl_listener new_xdg_toplevel;
	struct wl_listener new_input;
	struct wl_listener request_cursor;
	struct wl_listener request_set_selection;

	struct wl_listener cursor_motion;
	struct wl_listener cursor_motion_absolute;
	struct wl_listener cursor_button;
	struct wl_listener cursor_axis;
	struct wl_listener cursor_frame;

	struct toplevel *toplevel;
	pid_t game_pid;
};

static int handle_sigchld(int signal_number, void *data) {
	(void)signal_number;
	while (waitpid(-1, NULL, WNOHANG) > 0) {
	}
	struct server *server = data;
	wl_display_terminate(server->display);
	return 0;
}

static void focus_toplevel(struct toplevel *toplevel) {
	if (toplevel == NULL) {
		return;
	}
	struct server *server = toplevel->server;
	struct wlr_seat *seat = server->seat;
	struct wlr_surface *surface = toplevel->xdg_toplevel->base->surface;
	struct wlr_surface *prev = seat->keyboard_state.focused_surface;
	if (prev == surface) {
		return;
	}
	if (prev) {
		struct wlr_xdg_toplevel *prev_toplevel =
			wlr_xdg_toplevel_try_from_wlr_surface(prev);
		if (prev_toplevel) {
			wlr_xdg_toplevel_set_activated(prev_toplevel, false);
		}
	}
	wlr_xdg_toplevel_set_activated(toplevel->xdg_toplevel, true);
	struct wlr_keyboard *keyboard = wlr_seat_get_keyboard(seat);
	if (keyboard) {
		wlr_seat_keyboard_notify_enter(seat, surface,
			keyboard->keycodes, keyboard->num_keycodes,
			&keyboard->modifiers);
	} else {
		wlr_seat_keyboard_notify_enter(seat, surface, NULL, 0, NULL);
	}
}

static void fullscreen_toplevel(struct toplevel *toplevel) {
	if (toplevel->is_fullscreen) {
		return;
	}
	struct server *server = toplevel->server;
	wlr_xdg_toplevel_set_fullscreen(toplevel->xdg_toplevel, true);
	if (!wl_list_empty(&server->outputs)) {
		struct output *o = wl_container_of(server->outputs.next, o, link);
		int width, height;
		wlr_output_transformed_resolution(o->wlr_output, &width, &height);
		wlr_xdg_toplevel_set_size(toplevel->xdg_toplevel, width, height);
	}
	toplevel->is_fullscreen = true;
}

static void keyboard_handle_modifiers(struct wl_listener *listener, void *data) {
	(void)data;
	struct keyboard *keyboard = wl_container_of(listener, keyboard, modifiers);
	wlr_seat_set_keyboard(keyboard->server->seat, keyboard->wlr_keyboard);
	wlr_seat_keyboard_notify_modifiers(keyboard->server->seat,
		&keyboard->wlr_keyboard->modifiers);
}

static void keyboard_handle_key(struct wl_listener *listener, void *data) {
	struct keyboard *keyboard = wl_container_of(listener, keyboard, key);
	struct server *server = keyboard->server;
	struct wlr_keyboard_key_event *event = data;
	struct wlr_seat *seat = server->seat;

	xkb_keycode_t keycode = event->keycode + 8;
	const xkb_keysym_t *syms;
	int nsyms = xkb_state_key_get_syms(keyboard->wlr_keyboard->xkb_state,
		keycode, &syms);

	bool handled = false;
	uint32_t modifiers = wlr_keyboard_get_modifiers(keyboard->wlr_keyboard);
	if ((modifiers & WLR_MODIFIER_CTRL) && (modifiers & WLR_MODIFIER_ALT) &&
			event->state == WL_KEYBOARD_KEY_STATE_PRESSED) {
		for (int i = 0; i < nsyms; i++) {
			if (syms[i] == XKB_KEY_q) {
				wl_display_terminate(server->display);
				handled = true;
			}
		}
	}

	if (!handled) {
		wlr_seat_set_keyboard(seat, keyboard->wlr_keyboard);
		wlr_seat_keyboard_notify_key(seat, event->time_msec,
			event->keycode, event->state);
	}
}

static void keyboard_handle_destroy(struct wl_listener *listener, void *data) {
	(void)data;
	struct keyboard *keyboard = wl_container_of(listener, keyboard, destroy);
	wl_list_remove(&keyboard->modifiers.link);
	wl_list_remove(&keyboard->key.link);
	wl_list_remove(&keyboard->destroy.link);
	wl_list_remove(&keyboard->link);
	free(keyboard);
}

static void server_new_keyboard(struct server *server,
		struct wlr_input_device *device) {
	struct wlr_keyboard *wlr_keyboard = wlr_keyboard_from_input_device(device);

	struct keyboard *keyboard = calloc(1, sizeof(*keyboard));
	keyboard->server = server;
	keyboard->wlr_keyboard = wlr_keyboard;

	struct xkb_context *context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
	const char *layout = getenv("XKB_DEFAULT_LAYOUT");
	struct xkb_rule_names rules = {
		.rules = NULL,
		.model = NULL,
		.layout = layout != NULL ? layout : "fr",
		.variant = NULL,
		.options = NULL,
	};
	struct xkb_keymap *keymap = xkb_keymap_new_from_names(context, &rules,
		XKB_KEYMAP_COMPILE_NO_FLAGS);

	wlr_keyboard_set_keymap(wlr_keyboard, keymap);
	xkb_keymap_unref(keymap);
	xkb_context_unref(context);
	wlr_keyboard_set_repeat_info(wlr_keyboard, 25, 600);

	keyboard->modifiers.notify = keyboard_handle_modifiers;
	wl_signal_add(&wlr_keyboard->events.modifiers, &keyboard->modifiers);
	keyboard->key.notify = keyboard_handle_key;
	wl_signal_add(&wlr_keyboard->events.key, &keyboard->key);
	keyboard->destroy.notify = keyboard_handle_destroy;
	wl_signal_add(&device->events.destroy, &keyboard->destroy);

	wlr_seat_set_keyboard(server->seat, wlr_keyboard);
	wl_list_insert(&server->keyboards, &keyboard->link);
}

static void server_new_pointer(struct server *server,
		struct wlr_input_device *device) {
	wlr_cursor_attach_input_device(server->cursor, device);
}

static void server_new_input(struct wl_listener *listener, void *data) {
	struct server *server = wl_container_of(listener, server, new_input);
	struct wlr_input_device *device = data;
	switch (device->type) {
	case WLR_INPUT_DEVICE_KEYBOARD:
		server_new_keyboard(server, device);
		break;
	case WLR_INPUT_DEVICE_POINTER:
		server_new_pointer(server, device);
		break;
	default:
		break;
	}
	uint32_t caps = WL_SEAT_CAPABILITY_POINTER;
	if (!wl_list_empty(&server->keyboards)) {
		caps |= WL_SEAT_CAPABILITY_KEYBOARD;
	}
	wlr_seat_set_capabilities(server->seat, caps);
}

static void seat_request_cursor(struct wl_listener *listener, void *data) {
	struct server *server = wl_container_of(listener, server, request_cursor);
	struct wlr_seat_pointer_request_set_cursor_event *event = data;
	if (server->seat->pointer_state.focused_client == event->seat_client) {
		wlr_cursor_set_surface(server->cursor, event->surface,
			event->hotspot_x, event->hotspot_y);
	}
}

static void seat_request_set_selection(struct wl_listener *listener, void *data) {
	struct server *server = wl_container_of(listener, server, request_set_selection);
	struct wlr_seat_request_set_selection_event *event = data;
	wlr_seat_set_selection(server->seat, event->source, event->serial);
}

static void process_cursor_motion(struct server *server, uint32_t time,
		double dx, double dy, double dx_unaccel, double dy_unaccel) {
	double sx, sy;
	struct wlr_seat *seat = server->seat;
	struct wlr_surface *surface = NULL;

	struct wlr_scene_node *node = wlr_scene_node_at(
		&server->scene->tree.node, server->cursor->x, server->cursor->y,
		&sx, &sy);
	if (node == NULL || node->type != WLR_SCENE_NODE_BUFFER) {
		wlr_seat_pointer_clear_focus(seat);
	} else {
		struct wlr_scene_buffer *scene_buffer = wlr_scene_buffer_from_node(node);
		struct wlr_scene_surface *scene_surface =
			wlr_scene_surface_try_from_buffer(scene_buffer);
		if (scene_surface) {
			surface = scene_surface->surface;
			wlr_seat_pointer_notify_enter(seat, surface, sx, sy);
			wlr_seat_pointer_notify_motion(seat, time, sx, sy);
		}
	}

	if (dx != 0 || dy != 0) {
		wlr_relative_pointer_manager_v1_send_relative_motion(
			server->relative_pointer, seat, (uint64_t)time * 1000,
			dx, dy, dx_unaccel, dy_unaccel);
	}
}

static void pointer_enter_toplevel(struct server *server,
	struct wlr_xdg_toplevel *xdg_toplevel) {
	if (wl_list_empty(&server->outputs)) {
		return;
	}
	struct output *o = wl_container_of(server->outputs.next, o, link);
	struct wlr_box box;
	wlr_output_layout_get_box(server->output_layout, o->wlr_output, &box);
	double cx = box.x + box.width / 2.0;
	double cy = box.y + box.height / 2.0;
	wlr_cursor_warp(server->cursor, NULL, cx, cy);
	struct wlr_surface *surface = xdg_toplevel->base->surface;
	wlr_seat_pointer_notify_enter(server->seat, surface, cx - box.x, cy - box.y);
	wlr_log(WLR_INFO, "pointer enter toplevel surface %p", (void *)surface);
	struct timespec now;
	clock_gettime(CLOCK_MONOTONIC, &now);
	wlr_seat_pointer_notify_motion(server->seat,
		now.tv_sec * 1000 + now.tv_nsec / 1000000, cx - box.x, cy - box.y);
}

static void server_cursor_motion(struct wl_listener *listener, void *data) {
	struct server *server = wl_container_of(listener, server, cursor_motion);
	struct wlr_pointer_motion_event *event = data;
	wlr_cursor_move(server->cursor, &event->pointer->base,
		event->delta_x, event->delta_y);
	process_cursor_motion(server, event->time_msec,
		event->delta_x, event->delta_y,
		event->unaccel_dx, event->unaccel_dy);
}

static void server_cursor_motion_absolute(struct wl_listener *listener, void *data) {
	struct server *server = wl_container_of(listener, server, cursor_motion_absolute);
	struct wlr_pointer_motion_absolute_event *event = data;
	wlr_cursor_warp_absolute(server->cursor, &event->pointer->base,
		event->x, event->y);
	process_cursor_motion(server, event->time_msec,
		event->x, event->y, event->x, event->y);
}

static void server_cursor_button(struct wl_listener *listener, void *data) {
	struct server *server = wl_container_of(listener, server, cursor_button);
	struct wlr_pointer_button_event *event = data;
	wlr_seat_pointer_notify_button(server->seat, event->time_msec,
		event->button, event->state);
}

static void server_cursor_axis(struct wl_listener *listener, void *data) {
	struct server *server = wl_container_of(listener, server, cursor_axis);
	struct wlr_pointer_axis_event *event = data;
	wlr_seat_pointer_notify_axis(server->seat, event->time_msec,
		event->orientation, event->delta, event->delta_discrete,
		event->source, event->relative_direction);
}

static void server_cursor_frame(struct wl_listener *listener, void *data) {
	(void)data;
	struct server *server = wl_container_of(listener, server, cursor_frame);
	wlr_seat_pointer_notify_frame(server->seat);
}

static void output_frame(struct wl_listener *listener, void *data) {
	(void)data;
	struct output *output = wl_container_of(listener, output, frame);
	struct wlr_scene_output *scene_output = wlr_scene_get_scene_output(
		output->server->scene, output->wlr_output);
	wlr_scene_output_commit(scene_output, NULL);
	struct timespec now;
	clock_gettime(CLOCK_MONOTONIC, &now);
	wlr_scene_output_send_frame_done(scene_output, &now);
}

static void output_request_state(struct wl_listener *listener, void *data) {
	struct output *output = wl_container_of(listener, output, request_state);
	const struct wlr_output_event_request_state *event = data;
	wlr_output_commit_state(output->wlr_output, event->state);
}

static void output_destroy(struct wl_listener *listener, void *data) {
	(void)data;
	struct output *output = wl_container_of(listener, output, destroy);
	wl_list_remove(&output->frame.link);
	wl_list_remove(&output->request_state.link);
	wl_list_remove(&output->destroy.link);
	wl_list_remove(&output->link);
	free(output);
}

static void server_new_output(struct wl_listener *listener, void *data) {
	struct server *server = wl_container_of(listener, server, new_output);
	struct wlr_output *wlr_output = data;

	wlr_output_init_render(wlr_output, server->allocator, server->renderer);

	struct wlr_output_state state;
	wlr_output_state_init(&state);
	wlr_output_state_set_enabled(&state, true);
	struct wlr_output_mode *mode = wlr_output_preferred_mode(wlr_output);
	if (mode != NULL) {
		wlr_output_state_set_mode(&state, mode);
	}
	wlr_output_commit_state(wlr_output, &state);
	wlr_output_state_finish(&state);

	struct output *output = calloc(1, sizeof(*output));
	output->server = server;
	output->wlr_output = wlr_output;

	output->frame.notify = output_frame;
	wl_signal_add(&wlr_output->events.frame, &output->frame);
	output->request_state.notify = output_request_state;
	wl_signal_add(&wlr_output->events.request_state, &output->request_state);
	output->destroy.notify = output_destroy;
	wl_signal_add(&wlr_output->events.destroy, &output->destroy);

	wl_list_insert(&server->outputs, &output->link);

	struct wlr_output_layout_output *l_output = wlr_output_layout_add_auto(
		server->output_layout, wlr_output);
	struct wlr_scene_output *scene_output = wlr_scene_output_create(
		server->scene, wlr_output);
	wlr_scene_output_layout_add_output(server->scene_layout, l_output, scene_output);

	wlr_xcursor_manager_load(server->cursor_mgr, wlr_output->scale);
	wlr_cursor_set_xcursor(server->cursor, server->cursor_mgr, "default");
}

static void xdg_toplevel_map(struct wl_listener *listener, void *data) {
	(void)data;
	struct toplevel *toplevel = wl_container_of(listener, toplevel, map);
	struct server *server = toplevel->server;
	if (server->toplevel == NULL) {
		server->toplevel = toplevel;
		wlr_log(WLR_INFO, "toplevel mapped: %dx%d",
			toplevel->xdg_toplevel->base->surface->current.width,
			toplevel->xdg_toplevel->base->surface->current.height);
		fullscreen_toplevel(toplevel);
		focus_toplevel(toplevel);
		pointer_enter_toplevel(server, toplevel->xdg_toplevel);
	}
}

static void xdg_toplevel_unmap(struct wl_listener *listener, void *data) {
	(void)data;
	struct toplevel *toplevel = wl_container_of(listener, toplevel, unmap);
	if (toplevel->server->toplevel == toplevel) {
		wl_display_terminate(toplevel->server->display);
	}
}

static void xdg_toplevel_commit(struct wl_listener *listener, void *data) {
	(void)data;
	struct toplevel *toplevel = wl_container_of(listener, toplevel, commit);
	if (toplevel->xdg_toplevel->base->initial_commit) {
		wlr_xdg_toplevel_set_size(toplevel->xdg_toplevel, 0, 0);
	}
}

static void xdg_toplevel_request_fullscreen(struct wl_listener *listener, void *data) {
	(void)data;
	struct toplevel *toplevel = wl_container_of(listener, toplevel, request_fullscreen);
	if (toplevel->xdg_toplevel->base->initialized) {
		wlr_xdg_surface_schedule_configure(toplevel->xdg_toplevel->base);
	}
}

static void xdg_toplevel_request_maximize(struct wl_listener *listener, void *data) {
	(void)data;
	struct toplevel *toplevel = wl_container_of(listener, toplevel, request_maximize);
	if (toplevel->xdg_toplevel->base->initialized) {
		wlr_xdg_surface_schedule_configure(toplevel->xdg_toplevel->base);
	}
}

static void xdg_toplevel_destroy(struct wl_listener *listener, void *data) {
	(void)data;
	struct toplevel *toplevel = wl_container_of(listener, toplevel, destroy);
	if (toplevel->server->toplevel == toplevel) {
		wl_display_terminate(toplevel->server->display);
	}
	wl_list_remove(&toplevel->map.link);
	wl_list_remove(&toplevel->unmap.link);
	wl_list_remove(&toplevel->commit.link);
	wl_list_remove(&toplevel->destroy.link);
	wl_list_remove(&toplevel->request_fullscreen.link);
	wl_list_remove(&toplevel->request_maximize.link);
	free(toplevel);
}

static void server_new_xdg_toplevel(struct wl_listener *listener, void *data) {
	struct server *server = wl_container_of(listener, server, new_xdg_toplevel);
	struct wlr_xdg_toplevel *xdg_toplevel = data;

	struct toplevel *toplevel = calloc(1, sizeof(*toplevel));
	toplevel->server = server;
	toplevel->xdg_toplevel = xdg_toplevel;
	toplevel->scene_tree = wlr_scene_xdg_surface_create(
		&server->scene->tree, xdg_toplevel->base);
	toplevel->scene_tree->node.data = toplevel;
	xdg_toplevel->base->data = toplevel->scene_tree;

	toplevel->map.notify = xdg_toplevel_map;
	wl_signal_add(&xdg_toplevel->base->surface->events.map, &toplevel->map);
	toplevel->unmap.notify = xdg_toplevel_unmap;
	wl_signal_add(&xdg_toplevel->base->surface->events.unmap, &toplevel->unmap);
	toplevel->commit.notify = xdg_toplevel_commit;
	wl_signal_add(&xdg_toplevel->base->surface->events.commit, &toplevel->commit);
	toplevel->destroy.notify = xdg_toplevel_destroy;
	wl_signal_add(&xdg_toplevel->events.destroy, &toplevel->destroy);
	toplevel->request_fullscreen.notify = xdg_toplevel_request_fullscreen;
	wl_signal_add(&xdg_toplevel->events.request_fullscreen, &toplevel->request_fullscreen);
	toplevel->request_maximize.notify = xdg_toplevel_request_maximize;
	wl_signal_add(&xdg_toplevel->events.request_maximize, &toplevel->request_maximize);

	pointer_enter_toplevel(server, xdg_toplevel);
}

static char *get_game_path(void) {
	static char path[4096];
	ssize_t len = readlink("/proc/self/exe", path, sizeof(path) - 1);
	if (len <= 0) {
		return NULL;
	}
	path[len] = '\0';
	char *slash = strrchr(path, '/');
	if (slash == NULL) {
		return NULL;
	}
	*slash = '\0';
	if (strlen(path) + strlen("/../CyberRealm/build/CyberRealm.x86_64") >= sizeof(path)) {
		return NULL;
	}
	strcat(path, "/../CyberRealm/build/CyberRealm.x86_64");
	return path;
}

static void launch_game(struct server *server, const char *cmd) {
	server->game_pid = fork();
	if (server->game_pid < 0) {
		wlr_log(WLR_ERROR, "fork failed: %s", strerror(errno));
		return;
	}
	if (server->game_pid == 0) {
		setsid();
		unsetenv("DISPLAY");
		if (cmd != NULL) {
			execl("/bin/sh", "/bin/sh", "-c", cmd, (void *)NULL);
		} else {
			char *path = get_game_path();
			if (path != NULL) {
				execl(path, path, (void *)NULL);
			}
		}
		wlr_log(WLR_ERROR, "failed to launch game: %s", strerror(errno));
		_exit(127);
	}
	wlr_log(WLR_INFO, "game launched (pid %d)", server->game_pid);
}

static void usage(const char *name) {
	printf("Usage: %s [-c command] [-h]\n", name);
	printf("\nMinimal Wayland kiosk compositor for CyberRealm.\n");
	printf("\nOptions:\n");
	printf("  -c command   Launch command instead of the CyberRealm build\n");
	printf("  -h           Show this help\n");
	printf("\nEnv: WLR_BACKEND=headless WLR_RENDERER=pixman for headless testing.\n");
}

int main(int argc, char *argv[]) {
	const char *cmd = NULL;
	int opt;
	while ((opt = getopt(argc, argv, "c:h")) != -1) {
		switch (opt) {
		case 'c':
			cmd = optarg;
			break;
		case 'h':
			usage(argv[0]);
			return 0;
		default:
			usage(argv[0]);
			return 1;
		}
	}

	wlr_log_init(WLR_INFO, NULL);

	if (getenv("XDG_RUNTIME_DIR") == NULL) {
		wlr_log(WLR_ERROR, "XDG_RUNTIME_DIR is not set");
		return 1;
	}

	struct server server = {0};
	wl_list_init(&server.outputs);
	wl_list_init(&server.keyboards);

	server.display = wl_display_create();
	server.backend = wlr_backend_autocreate(
		wl_display_get_event_loop(server.display), NULL);
	if (server.backend == NULL) {
		wlr_log(WLR_ERROR, "failed to create wlr_backend");
		return 1;
	}

	server.renderer = wlr_renderer_autocreate(server.backend);
	if (server.renderer == NULL) {
		wlr_log(WLR_ERROR, "failed to create wlr_renderer");
		return 1;
	}
	wlr_renderer_init_wl_display(server.renderer, server.display);

	server.allocator = wlr_allocator_autocreate(server.backend, server.renderer);
	if (server.allocator == NULL) {
		wlr_log(WLR_ERROR, "failed to create wlr_allocator");
		return 1;
	}

	wlr_compositor_create(server.display, 5, server.renderer);
	wlr_subcompositor_create(server.display);
	wlr_data_device_manager_create(server.display);
	wlr_linux_dmabuf_v1_create_with_renderer(server.display, 4, server.renderer);
	wlr_presentation_create(server.display, server.backend);

	server.pointer_constraints = wlr_pointer_constraints_v1_create(server.display);
	server.relative_pointer = wlr_relative_pointer_manager_v1_create(server.display);

	server.output_layout = wlr_output_layout_create(server.display);
	server.new_output.notify = server_new_output;
	wl_signal_add(&server.backend->events.new_output, &server.new_output);

	server.scene = wlr_scene_create();
	server.scene_layout = wlr_scene_attach_output_layout(
		server.scene, server.output_layout);

	server.xdg_shell = wlr_xdg_shell_create(server.display, 3);
	server.new_xdg_toplevel.notify = server_new_xdg_toplevel;
	wl_signal_add(&server.xdg_shell->events.new_toplevel, &server.new_xdg_toplevel);

	server.cursor = wlr_cursor_create();
	wlr_cursor_attach_output_layout(server.cursor, server.output_layout);
	server.cursor_mgr = wlr_xcursor_manager_create(NULL, 24);

	server.cursor_motion.notify = server_cursor_motion;
	wl_signal_add(&server.cursor->events.motion, &server.cursor_motion);
	server.cursor_motion_absolute.notify = server_cursor_motion_absolute;
	wl_signal_add(&server.cursor->events.motion_absolute, &server.cursor_motion_absolute);
	server.cursor_button.notify = server_cursor_button;
	wl_signal_add(&server.cursor->events.button, &server.cursor_button);
	server.cursor_axis.notify = server_cursor_axis;
	wl_signal_add(&server.cursor->events.axis, &server.cursor_axis);
	server.cursor_frame.notify = server_cursor_frame;
	wl_signal_add(&server.cursor->events.frame, &server.cursor_frame);

	server.new_input.notify = server_new_input;
	wl_signal_add(&server.backend->events.new_input, &server.new_input);
	server.seat = wlr_seat_create(server.display, "seat0");
	server.request_cursor.notify = seat_request_cursor;
	wl_signal_add(&server.seat->events.request_set_cursor, &server.request_cursor);
	server.request_set_selection.notify = seat_request_set_selection;
	wl_signal_add(&server.seat->events.request_set_selection, &server.request_set_selection);

	struct wl_event_loop *loop = wl_display_get_event_loop(server.display);
	wl_event_loop_add_signal(loop, SIGCHLD, handle_sigchld, &server);

	unsetenv("WAYLAND_DISPLAY");
	const char *socket = wl_display_add_socket_auto(server.display);
	if (socket == NULL) {
		wlr_log(WLR_ERROR, "failed to add Wayland socket: %s", strerror(errno));
		return 1;
	}

	if (!wlr_backend_start(server.backend)) {
		wlr_log(WLR_ERROR, "failed to start backend");
		return 1;
	}

	setenv("WAYLAND_DISPLAY", socket, true);
	launch_game(&server, cmd);

	wlr_log(WLR_INFO, "Running kiosk compositor on WAYLAND_DISPLAY=%s", socket);
	wl_display_run(server.display);
	wlr_log(WLR_INFO, "display run returned");

	if (server.game_pid > 0) {
		kill(server.game_pid, SIGTERM);
		waitpid(server.game_pid, NULL, 0);
	}

	wl_display_destroy_clients(server.display);
	wlr_scene_node_destroy(&server.scene->tree.node);
	wlr_xcursor_manager_destroy(server.cursor_mgr);
	wlr_cursor_destroy(server.cursor);
	wlr_allocator_destroy(server.allocator);
	wlr_renderer_destroy(server.renderer);
	wlr_backend_destroy(server.backend);
	wl_display_destroy(server.display);
	return 0;
}
