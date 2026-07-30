// SPDX-License-Identifier: MIT
//
// CyberRealm Session Launcher
// Minimal kiosk Wayland compositor — takes over DRM, runs Godot fullscreen.
// When Godot exits, the session ends (= logout).

#define _GNU_SOURCE
#include <assert.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/wait.h>
#include <time.h>
#include <math.h>

#include <wayland-server-core.h>
#include <wlr/backend.h>
#include <wlr/render/allocator.h>
#include <wlr/render/pass.h>
#include <wlr/render/wlr_renderer.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_cursor.h>
#include <wlr/types/wlr_data_device.h>
#include <wlr/types/wlr_input_device.h>
#include <wlr/types/wlr_keyboard.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_output_layout.h>
#include <wlr/types/wlr_pointer.h>
#include <wlr/types/wlr_seat.h>
#include <wlr/types/wlr_xdg_shell.h>
#include <wlr/types/wlr_subcompositor.h>
#include <wlr/types/wlr_viewporter.h>
#include <wlr/util/log.h>
#include <xkbcommon/xkbcommon.h>

struct session_state;

struct session_keyboard {
    struct wl_listener key;
    struct wl_listener modifiers;
    struct session_state *state;
};

struct session_pointer {
    struct wl_listener motion;
    struct wl_listener button;
    struct wl_listener axis;
    struct session_state *state;
};

struct session_state {
    struct wl_display *display;
    struct wl_event_loop *loop;
    struct wlr_backend *backend;
    struct wlr_renderer *renderer;
    struct wlr_allocator *allocator;
    struct wlr_compositor *compositor;
    struct wlr_xdg_shell *xdg_shell;
    struct wlr_seat *seat;
    struct wlr_cursor *cursor;
    struct wlr_output_layout *output_layout;

    struct wlr_output *output;

    struct wl_listener new_output;
    struct wl_listener output_frame;
    struct wl_listener output_destroy;

    struct wlr_surface *focused;
    struct wl_listener surface_destroy;

    struct wl_listener new_toplevel;
    struct wl_listener new_input;

    pid_t child_pid;
    bool running;
};

// ---- Output ----

static void output_frame_notify(struct wl_listener *listener, void *data) {
    struct session_state *state = wl_container_of(listener, state, output_frame);
    struct wlr_output *output = data;

    struct wlr_output_state out_state;
    wlr_output_state_init(&out_state);

    int buf_age = -1;
    struct wlr_render_pass *pass = wlr_output_begin_render_pass(output,
        &out_state, &buf_age, NULL);
    if (!pass) {
        wlr_output_state_finish(&out_state);
        return;
    }

    // Background
    wlr_render_pass_add_rect(pass, &(struct wlr_render_rect_options){
        .box = {0, 0, output->width, output->height},
        .color = {0.06, 0.06, 0.08, 1.0},
    });

    // Focused surface (Godot) centered and scaled
    if (state->focused) {
        struct wlr_texture *tex = wlr_surface_get_texture(state->focused);
        if (tex) {
            int pw = state->focused->current.width;
            int ph = state->focused->current.height;
            if (pw > 0 && ph > 0) {
                double scale = fmin(
                    (double)output->width / pw,
                    (double)output->height / ph);
                int dw = (int)(pw * scale);
                int dh = (int)(ph * scale);
                wlr_render_pass_add_texture(pass, &(struct wlr_render_texture_options){
                    .texture = tex,
                    .src_box = {0, 0, (double)pw, (double)ph},
                    .dst_box = {(output->width - dw) / 2, (output->height - dh) / 2, dw, dh},
                });
            }
        }
    }

    wlr_render_pass_submit(pass);
    wlr_output_commit_state(output, &out_state);
    wlr_output_state_finish(&out_state);

    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    if (state->focused)
        wlr_surface_send_frame_done(state->focused, &now);
}

static void new_output_notify(struct wl_listener *listener, void *data) {
    struct session_state *state = wl_container_of(listener, state, new_output);
    struct wlr_output *output = data;

    if (state->output) return;

    struct wlr_output_state out_state;
    wlr_output_state_init(&out_state);
    wlr_output_state_set_enabled(&out_state, true);

    struct wlr_output_mode *preferred = NULL;
    struct wlr_output_mode *mode;
    wl_list_for_each(mode, &output->modes, link) {
        if (mode->preferred) { preferred = mode; break; }
        if (!preferred) preferred = mode;
    }
    if (preferred)
        wlr_output_state_set_mode(&out_state, preferred);

    wlr_output_commit_state(output, &out_state);
    wlr_output_state_finish(&out_state);

    state->output = output;
    wl_signal_add(&output->events.frame, &state->output_frame);
    wl_signal_add(&output->events.destroy, &state->output_destroy);

    wlr_output_layout_add_auto(state->output_layout, output);
    wlr_cursor_map_to_output(state->cursor, output);
}

static void output_destroy_notify(struct wl_listener *listener, void *data) {
    struct session_state *state = wl_container_of(listener, state, output_destroy);
    state->output = NULL;
}

// ---- Surface ----

static void surface_destroy_notify(struct wl_listener *listener, void *data) {
    struct session_state *state = wl_container_of(listener, state, surface_destroy);
    state->focused = NULL;
}

static void new_toplevel_notify(struct wl_listener *listener, void *data) {
    struct session_state *state = wl_container_of(listener, state, new_toplevel);
    struct wlr_xdg_toplevel *toplevel = data;
    if (!toplevel->base->surface) return;

    wlr_xdg_toplevel_set_fullscreen(toplevel, true);
    wlr_xdg_toplevel_set_activated(toplevel, true);

    if (!state->focused) {
        state->focused = toplevel->base->surface;
        wl_signal_add(&toplevel->base->surface->events.destroy, &state->surface_destroy);
    }
}

// ---- Input ----

static void keyboard_key_notify(struct wl_listener *listener, void *data) {
    struct session_keyboard *sk = wl_container_of(listener, sk, key);
    struct session_state *state = sk->state;
    struct wlr_keyboard_key_event *ev = data;
    if (state->focused)
        wlr_seat_keyboard_notify_key(state->seat, ev->time_msec, ev->keycode, ev->state);
}

static void keyboard_modifiers_notify(struct wl_listener *listener, void *data) {
    struct session_keyboard *sk = wl_container_of(listener, sk, modifiers);
    (void)data;
    struct wlr_keyboard *kb = wlr_seat_get_keyboard(sk->state->seat);
    if (kb) wlr_seat_keyboard_notify_modifiers(sk->state->seat, &kb->modifiers);
}

static void pointer_motion_notify(struct wl_listener *listener, void *data) {
    struct session_pointer *sp = wl_container_of(listener, sp, motion);
    struct wlr_pointer_motion_event *ev = data;
    wlr_cursor_move(sp->state->cursor, &ev->pointer->base, ev->delta_x, ev->delta_y);
    if (sp->state->focused) {
        wlr_seat_pointer_notify_motion(sp->state->seat, ev->time_msec,
            sp->state->cursor->x, sp->state->cursor->y);
        wlr_seat_pointer_notify_frame(sp->state->seat);
    }
}

static void pointer_button_notify(struct wl_listener *listener, void *data) {
    struct session_pointer *sp = wl_container_of(listener, sp, button);
    struct wlr_pointer_button_event *ev = data;
    if (sp->state->focused) {
        wlr_seat_pointer_notify_button(sp->state->seat, ev->time_msec,
            ev->button, ev->state);
        wlr_seat_pointer_notify_frame(sp->state->seat);
    }
}

static void pointer_axis_notify(struct wl_listener *listener, void *data) {
    struct session_pointer *sp = wl_container_of(listener, sp, axis);
    struct wlr_pointer_axis_event *ev = data;
    wlr_seat_pointer_notify_axis(sp->state->seat, ev->time_msec,
        ev->orientation, ev->delta, ev->delta_discrete, ev->source,
        ev->relative_direction);
    wlr_seat_pointer_notify_frame(sp->state->seat);
}

static void new_input_notify(struct wl_listener *listener, void *data) {
    struct session_state *state = wl_container_of(listener, state, new_input);
    struct wlr_input_device *dev = data;

    switch (dev->type) {
    case WLR_INPUT_DEVICE_KEYBOARD: {
        struct wlr_keyboard *kb = wlr_keyboard_from_input_device(dev);
        struct xkb_context *ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
        struct xkb_keymap *keymap = xkb_keymap_new_from_names(ctx, NULL,
            XKB_KEYMAP_COMPILE_NO_FLAGS);
        wlr_keyboard_set_keymap(kb, keymap);
        xkb_keymap_unref(keymap);
        xkb_context_unref(ctx);
        wlr_keyboard_set_repeat_info(kb, 25, 600);
        wlr_seat_set_keyboard(state->seat, kb);

        struct session_keyboard *sk = calloc(1, sizeof(*sk));
        sk->state = state;
        sk->key.notify = keyboard_key_notify;
        sk->modifiers.notify = keyboard_modifiers_notify;
        wl_signal_add(&kb->events.key, &sk->key);
        wl_signal_add(&kb->events.modifiers, &sk->modifiers);
        break;
    }
    case WLR_INPUT_DEVICE_POINTER: {
        struct wlr_pointer *ptr = wlr_pointer_from_input_device(dev);
        wlr_cursor_attach_input_device(state->cursor, dev);

        struct session_pointer *sp = calloc(1, sizeof(*sp));
        sp->state = state;
        sp->motion.notify = pointer_motion_notify;
        sp->button.notify = pointer_button_notify;
        sp->axis.notify = pointer_axis_notify;
        wl_signal_add(&ptr->events.motion, &sp->motion);
        wl_signal_add(&ptr->events.button, &sp->button);
        wl_signal_add(&ptr->events.axis, &sp->axis);
        break;
    }
    default:
        break;
    }
}

// ---- Child process ----

static void launch_child(struct session_state *state) {
    state->child_pid = fork();
    if (state->child_pid < 0) {
        wlr_log(WLR_ERROR, "fork failed");
        return;
    }
    if (state->child_pid == 0) {
        setsid();
        unsetenv("DISPLAY");

        const char *socket = getenv("WAYLAND_DISPLAY");
        if (!socket) socket = "wayland-0";

        const char *proj_dir = getenv("CYBERREALM_PROJECT_DIR");
        if (!proj_dir) proj_dir = "/usr/local/share/cyberrealm/demo";

        static const char *bin_paths[] = {
            "/usr/local/CyberRealm/CyberRealm.x86_64",
            "/usr/share/cyberrealm/CyberRealm.x86_64",
            NULL,
        };
        for (const char **p = bin_paths; *p; p++) {
            if (access(*p, X_OK) == 0) {
                execl(*p, *p, NULL);
                _exit(127);
            }
        }

        static const char *godot_bins[] = {"godot", "godot4", NULL};
        for (const char **g = godot_bins; *g; g++) {
            char path[512];
            snprintf(path, sizeof(path), "/usr/bin/%s", *g);
            if (access(path, X_OK) == 0) {
                execl(path, path, "--path", proj_dir,
                    "--display-driver", "wayland", "--fullscreen", NULL);
                _exit(127);
            }
        }

        fprintf(stderr, "CyberRealm: no game binary or Godot engine found.\n");
        _exit(1);
    }
    wlr_log(WLR_INFO, "launched child pid %d", state->child_pid);
}

// ---- Signal ----

static int on_signal(int signo, void *data) {
    struct session_state *state = data;
    wlr_log(WLR_INFO, "caught signal %d, shutting down", signo);
    state->running = false;
    wl_display_terminate(state->display);
    return 0;
}

// ---- Entry point ----

int main(int argc, char *argv[]) {
    wlr_log_init(WLR_DEBUG, NULL);

    struct session_state state = {0};
    state.running = true;

    state.display = wl_display_create();
    state.loop = wl_display_get_event_loop(state.display);

    state.backend = wlr_backend_autocreate(state.loop, NULL);
    if (!state.backend) {
        wlr_log(WLR_ERROR, "failed to create backend");
        return 1;
    }

    state.renderer = wlr_renderer_autocreate(state.backend);
    assert(state.renderer);
    wlr_renderer_init_wl_display(state.renderer, state.display);

    state.allocator = wlr_allocator_autocreate(state.backend, state.renderer);
    assert(state.allocator);

    state.compositor = wlr_compositor_create(state.display, 6, state.renderer);
    state.xdg_shell = wlr_xdg_shell_create(state.display, 3);
    wlr_subcompositor_create(state.display);
    wlr_viewporter_create(state.display);
    wlr_data_device_manager_create(state.display);

    state.seat = wlr_seat_create(state.display, "seat0");
    wlr_seat_set_capabilities(state.seat,
        WL_SEAT_CAPABILITY_KEYBOARD | WL_SEAT_CAPABILITY_POINTER);

    state.cursor = wlr_cursor_create();
    state.output_layout = wlr_output_layout_create(state.display);
    wlr_cursor_attach_output_layout(state.cursor, state.output_layout);

    // Wire signals
    state.new_output.notify = new_output_notify;
    wl_signal_add(&state.backend->events.new_output, &state.new_output);
    state.new_toplevel.notify = new_toplevel_notify;
    wl_signal_add(&state.xdg_shell->events.new_toplevel, &state.new_toplevel);
    state.new_input.notify = new_input_notify;
    wl_signal_add(&state.backend->events.new_input, &state.new_input);

    state.output_frame.notify = output_frame_notify;
    state.output_destroy.notify = output_destroy_notify;
    state.surface_destroy.notify = surface_destroy_notify;

    // Wayland socket
    const char *socket = wl_display_add_socket_auto(state.display);
    if (!socket) {
        wlr_log(WLR_ERROR, "failed to create Wayland socket");
        return 1;
    }
    setenv("WAYLAND_DISPLAY", socket, 1);

    // Start backend
    if (!wlr_backend_start(state.backend)) {
        wlr_log(WLR_ERROR, "failed to start backend");
        return 1;
    }

    wl_event_loop_add_signal(state.loop, SIGTERM, on_signal, &state);
    wl_event_loop_add_signal(state.loop, SIGINT, on_signal, &state);

    // Launch game
    launch_child(&state);

    wlr_log(WLR_INFO, "CyberRealm session ready on %s", socket);

    // Main loop
    while (state.running) {
        wl_display_flush_clients(state.display);
        if (wl_event_loop_dispatch(state.loop, -1) < 0)
            break;
    }

    // Cleanup
    if (state.child_pid > 0) {
        killpg(state.child_pid, SIGTERM);
        int status;
        waitpid(state.child_pid, &status, 0);
    }
    wl_display_destroy_clients(state.display);
    wl_display_destroy(state.display);

    wlr_log(WLR_INFO, "CyberRealm session ended");
    return 0;
}
