#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#include "logger.h"
#include "screencast.h"
#include "string_util.h"
#include "wlr_screencast.h"
#include "xdpw.h"

static struct xdpw_wlr_output *xdpw_wlr_output_first(struct wl_list *output_list) {
	struct xdpw_wlr_output *output, *tmp;
	wl_list_for_each_safe(output, tmp, output_list, link) {
		return output;
	}
	return NULL;
}

static bool is_screen_designation(const char *designation) {
	return strcmp(designation, "screen") == 0
		|| strcmp(designation, "monitor") == 0
		|| strcmp(designation, "desktop") == 0;
}

// --- Sélection interactive de la cible de capture (OBS) --------------------
// Handshake par fichiers entre portal-wlr et le jeu (compositeur) :
//   1. portal-wlr écrit $XDG_RUNTIME_DIR/cyberrealm-capture-pending puis
//      attend la réponse du joueur.
//   2. Le jeu détecte le fichier, ouvre le sélecteur (choix écran/fenêtres)
//      et écrit le choix dans $XDG_RUNTIME_DIR/cyberrealm-capture-choice :
//      "screen", un app_id ou un titre de fenêtre, ou "cancel" pour annuler.
//   3. portal-wlr consomme le choix (fichier supprimé) et configure la cible.
//      En cas de timeout ou d'annulation, on retombe sur la première fenêtre
//      puis sur l'écran.

static const char *capture_rt(void) {
	const char *rt = getenv("XDG_RUNTIME_DIR");
	return rt && rt[0] ? rt : NULL;
}

// Purge un éventuel choix périmé avant d'ouvrir une nouvelle demande.
static void capture_clear_choice(void) {
	const char *rt = capture_rt();
	if (!rt) {
		return;
	}
	char path[4096];
	if (snprintf(path, sizeof(path), "%s/cyberrealm-capture-choice", rt) < (int)sizeof(path)) {
		remove(path);
	}
}

// Signale au jeu qu'une source OBS demande une cible de capture.
static void capture_write_pending(void) {
	const char *rt = capture_rt();
	if (!rt) {
		return;
	}
	char path[4096];
	if (snprintf(path, sizeof(path), "%s/cyberrealm-capture-pending", rt) >= (int)sizeof(path)) {
		return;
	}
	FILE *f = fopen(path, "w");
	if (f) {
		fprintf(f, "1\n");
		fclose(f);
	}
}

static void capture_remove_pending(void) {
	const char *rt = capture_rt();
	if (!rt) {
		return;
	}
	char path[4096];
	if (snprintf(path, sizeof(path), "%s/cyberrealm-capture-pending", rt) < (int)sizeof(path)) {
		remove(path);
	}
}

// Attend que le jeu écrive le choix du joueur. Consomme le fichier choice.
// Renvoie une copie du choix (à libérer avec free), "cancel" si le jeu a
// annulé, ou NULL si le timeout expire (60 s).
static char *capture_wait_choice(void) {
	const char *rt = capture_rt();
	if (!rt) {
		return NULL;
	}
	char path[4096];
	if (snprintf(path, sizeof(path), "%s/cyberrealm-capture-choice", rt) >= (int)sizeof(path)) {
		return NULL;
	}

	const int timeout_ms = 60000;
	const int step_ms = 100;
	for (int waited = 0; waited < timeout_ms; waited += step_ms) {
		FILE *f = fopen(path, "r");
		if (f) {
			char *line = NULL;
			size_t cap = 0;
			ssize_t n = getline(&line, &cap, f);
			fclose(f);
			remove(path);
			if (n < 0) {
				free(line);
				return strdup("cancel");
			}
			char *nl = strchr(line, '\n');
			if (nl) {
				*nl = '\0';
			}
			nl = strchr(line, '\r');
			if (nl) {
				*nl = '\0';
			}
			if (line[0] == '\0') {
				free(line);
				return strdup("cancel");
			}
			logprint(INFO, "wlroots: capture choice received: %s", line);
			return line;
		}
		struct timespec ts = {0, step_ms * 1000 * 1000};
		nanosleep(&ts, NULL);
	}
	logprint(INFO, "wlroots: capture choice timeout");
	return NULL;
}

static pid_t spawn_chooser(const char *cmd, FILE **chooser_in_ptr, FILE **chooser_out_ptr) {
	int chooser_in[2]; // p -> c
	int chooser_out[2]; // c -> p

	if (pipe(chooser_in) == -1) {
		perror("pipe chooser_in");
		logprint(ERROR, "Failed to open pipe chooser_in");
		return -1;
	}
	if (pipe(chooser_out) == -1) {
		perror("pipe chooser_out");
		logprint(ERROR, "Failed to open pipe chooser_out");
		goto error_chooser_in;
	}

	logprint(TRACE,
		"exec chooser called: cmd %s, pipe chooser_in (%d,%d), pipe chooser_out (%d,%d)",
		cmd, chooser_in[0], chooser_in[1], chooser_out[0], chooser_out[1]);

	pid_t pid = fork();
	if (pid < 0) {
		perror("fork");
		goto error_chooser_out;
	} else if (pid == 0) {
		close(chooser_in[1]);
		close(chooser_out[0]);

		dup2(chooser_in[0], STDIN_FILENO);
		dup2(chooser_out[1], STDOUT_FILENO);
		close(chooser_in[0]);
		close(chooser_out[1]);

		execl("/bin/sh", "/bin/sh", "-c", cmd, NULL);

		perror("execl");
		_exit(127);
	}

	close(chooser_in[0]);
	close(chooser_out[1]);

	FILE *chooser_in_f = fdopen(chooser_in[1], "w");
	if (chooser_in_f == NULL) {
		close(chooser_in[1]);
		close(chooser_out[0]);
		return -1;
	}
	FILE *chooser_out_f = fdopen(chooser_out[0], "r");
	if (chooser_out_f == NULL) {
		fclose(chooser_in_f);
		close(chooser_out[0]);
		return -1;
	}

	*chooser_in_ptr = chooser_in_f;
	*chooser_out_ptr = chooser_out_f;

	return pid;

error_chooser_out:
	close(chooser_out[0]);
	close(chooser_out[1]);
error_chooser_in:
	close(chooser_in[0]);
	close(chooser_in[1]);
	return -1;
}

static bool wait_chooser(pid_t pid) {
	int status;
	if (waitpid(pid ,&status, 0) != -1 && WIFEXITED(status)) {
		return WEXITSTATUS(status) != 127;
	}
	return false;
}

static char *read_chooser_out(FILE *f) {
	char *name = NULL;
	size_t name_size = 0;
	ssize_t nread = getline(&name, &name_size, f);
	if (nread < 0) {
		if (!feof(f)) {
			perror("getline failed");
		}
		return NULL;
	}

	// Strip newline
	char *p = strchr(name, '\n');
	if (p != NULL) {
		*p = '\0';
	}

	return name;
}

static char *get_output_label(struct xdpw_wlr_output *output, enum xdpw_chooser_types chooser_type) {
	if (chooser_type == XDPW_CHOOSER_DMENU) {
		return format_str("Monitor: %s %s", output->name, output->description);
	} else {
		return format_str("Monitor: %s", output->name);
	}
}

static char *get_toplevel_label(struct xdpw_toplevel *toplevel, enum xdpw_chooser_types chooser_type) {
	if (chooser_type == XDPW_CHOOSER_DMENU) {
		return format_str("Window: %s (%s)", toplevel->title, toplevel->identifier);
	} else {
		return format_str("Window: %s", toplevel->identifier);
	}
}

static bool wlr_chooser(const struct xdpw_chooser *chooser,
		struct xdpw_screencast_context *ctx, struct xdpw_screencast_target *target,
		uint32_t type_mask) {
	logprint(DEBUG, "wlroots: chooser called");

	FILE *chooser_in = NULL, *chooser_out = NULL;
	pid_t pid = spawn_chooser(chooser->cmd, &chooser_in, &chooser_out);
	if (pid < 0) {
		logprint(ERROR, "Failed to fork chooser");
		return false;
	}

	switch (chooser->type) {
	case XDPW_CHOOSER_DMENU:
		if (type_mask & MONITOR) {
			struct xdpw_wlr_output *out;
			wl_list_for_each(out, &ctx->output_list, link) {
				char *label = get_output_label(out, chooser->type);
				fprintf(chooser_in, "%s\n", label);
				free(label);
			}
		}
		if (type_mask & WINDOW) {
			struct xdpw_toplevel *toplevel;
			wl_list_for_each(toplevel, &ctx->toplevels, link) {
				char *label = get_toplevel_label(toplevel, chooser->type);
				fprintf(chooser_in, "%s\n", label);
				free(label);
			}
		}
		fclose(chooser_in);
		break;
	default:
		fclose(chooser_in);
	}

	if (!wait_chooser(pid)) {
		fclose(chooser_out);
		return false;
	}

	char *selected_label = read_chooser_out(chooser_out);
	fclose(chooser_out);
	if (selected_label == NULL) {
		return true;
	}

	logprint(TRACE, "wlroots: chooser %s selects %s", chooser->cmd, selected_label);

	bool found = false;
	struct xdpw_wlr_output *out;
	wl_list_for_each(out, &ctx->output_list, link) {
		char *label = get_output_label(out, chooser->type);
		found = strcmp(selected_label, label) == 0;
		free(label);
		if (!found && chooser->type == XDPW_CHOOSER_SIMPLE) {
			// Compatibility with xdg-desktop-portal-wlr < v0.8.0
			found = strcmp(selected_label, out->name) == 0;
		}
		if (found) {
			target->type = MONITOR;
			target->output = out;
			break;
		}
	}

	struct xdpw_toplevel *toplevel;
	wl_list_for_each(toplevel, &ctx->toplevels, link) {
		if (found) {
			break;
		}
		char *label = get_toplevel_label(toplevel, chooser->type);
		found = strcmp(selected_label, label) == 0;
		free(label);
		if (found) {
			target->type = WINDOW;
			target->toplevel = toplevel;
			break;
		}
	}

	if (!found) {
		logprint(ERROR, "wlroots: chooser %s selected unknown target: %s", chooser->cmd, selected_label);
	}

	free(selected_label);

	return true;
}

static bool wlr_chooser_default(struct xdpw_screencast_context *ctx, struct xdpw_screencast_target *target, uint32_t type_mask) {
	logprint(DEBUG, "wlroots: chooser called");

	const struct xdpw_chooser default_chooser[] = {
		{XDPW_CHOOSER_SIMPLE, "slurp -f 'Monitor: %o' -or"},
		{XDPW_CHOOSER_DMENU, "wmenu -p 'Select a source to share:' -l 10"},
		{XDPW_CHOOSER_DMENU, "wofi -d -n --prompt='Select a source to share:'"},
		{XDPW_CHOOSER_DMENU, "rofi -dmenu -p 'Select a source to share:'"},
		{XDPW_CHOOSER_DMENU, "bemenu --prompt='Select a source to share:'"},
		{XDPW_CHOOSER_DMENU, "mew -l 10 -p 'Select a source to share:'"},
		{XDPW_CHOOSER_DMENU, "fuzzel -d -l 10 -p 'Select a source to share:'"},
	};

	size_t N = sizeof(default_chooser)/sizeof(default_chooser[0]);
	bool ret;
	for (size_t i = 0; i<N; i++) {
		const struct xdpw_chooser *chooser = &default_chooser[i];
		if (chooser->type == XDPW_CHOOSER_SIMPLE && type_mask != MONITOR) {
			continue;
		}
		ret = wlr_chooser(chooser, ctx, target, type_mask);
		if (!ret) {
			logprint(DEBUG, "wlroots: chooser %s failed. Trying next one.",
					default_chooser[i].cmd);
			continue;
		}
		return target->output || target->toplevel;
	}
	return false;
}

bool xdpw_wlr_target_chooser(struct xdpw_screencast_context *ctx, struct xdpw_session *sess, struct xdpw_screencast_target *target, uint32_t type_mask) {
	switch (ctx->state->config->screencast_conf.chooser_type) {
	case XDPW_CHOOSER_DEFAULT:
		return wlr_chooser_default(ctx, target, type_mask);
	case XDPW_CHOOSER_NONE: {
		// Capture sans chooser externe (slurp/wmenu...). Quand une source
		// « Screen Capture (PipeWire) » est ajoutée dans OBS, on demande au
		// joueur de choisir la cible via l'interface du jeu : portal-wlr
		// écrit cyberrealm-capture-pending, le jeu ouvre le sélecteur et
		// écrit le choix dans cyberrealm-capture-choice.
		if (type_mask & WINDOW) {
			capture_clear_choice();
			capture_write_pending();
			char *choice = capture_wait_choice();
			capture_remove_pending();

			if (choice && strcmp(choice, "cancel") != 0) {
				if (is_screen_designation(choice) && (type_mask & MONITOR)) {
					// Le joueur a choisi l'écran.
					sess->screencast_data.capture_claim = strdup(choice);
					logprint(INFO, "wlroots: window capture target: screen (chosen)");
					target->type = MONITOR;
					if (ctx->state->config->screencast_conf.output_name) {
						target->output = xdpw_wlr_output_find_by_name(&ctx->output_list,
							ctx->state->config->screencast_conf.output_name);
					} else {
						target->output = xdpw_wlr_output_first(&ctx->output_list);
					}
					free(choice);
					if (target->output) {
						return true;
					}
				} else {
					// Le joueur a choisi une fenêtre : correspondance app_id
					// puis titre.
					struct xdpw_toplevel *toplevel, *chosen = NULL;
					wl_list_for_each(toplevel, &ctx->toplevels, link) {
						if (chosen == NULL) {
							chosen = toplevel;
						}
						if ((toplevel->app_id && strcmp(toplevel->app_id, choice) == 0)
								|| (toplevel->title && strcmp(toplevel->title, choice) == 0)) {
							chosen = toplevel;
							break;
						}
					}
					if (chosen) {
						sess->screencast_data.capture_claim = strdup(choice);
						logprint(INFO, "wlroots: window capture target: app_id=%s title=%s",
							chosen->app_id ? chosen->app_id : "(null)",
							chosen->title ? chosen->title : "(null)");
						target->type = WINDOW;
						target->toplevel = chosen;
						free(choice);
						return true;
					}
					logprint(INFO, "wlroots: chosen capture target not found: %s", choice);
					free(choice);
				}
			} else {
				if (choice) {
					logprint(INFO, "wlroots: capture cancelled by player, falling back");
				}
				free(choice);
			}
			logprint(INFO, "wlroots: no designated target available, falling back to first window");
			struct xdpw_toplevel *first = NULL;
			struct xdpw_toplevel *toplevel;
			wl_list_for_each(toplevel, &ctx->toplevels, link) {
				if (!first) {
					first = toplevel;
					break;
				}
			}
			if (first) {
				logprint(INFO, "wlroots: window capture target: app_id=%s title=%s",
					first->app_id ? first->app_id : "(null)",
					first->title ? first->title : "(null)");
				target->type = WINDOW;
				target->toplevel = first;
				return true;
			}
			logprint(INFO, "wlroots: no capturable window, falling back to monitor");
		}
		target->type = MONITOR;
		if (ctx->state->config->screencast_conf.output_name) {
			target->output = xdpw_wlr_output_find_by_name(&ctx->output_list, ctx->state->config->screencast_conf.output_name);
		} else {
			target->output = xdpw_wlr_output_first(&ctx->output_list);
		}
		return target->output != NULL;
	}
	case XDPW_CHOOSER_DMENU:
	case XDPW_CHOOSER_SIMPLE:;
		if (!ctx->state->config->screencast_conf.chooser_cmd) {
			logprint(ERROR, "wlroots: no chooser given");
			goto end;
		}
		struct xdpw_chooser chooser = {
			ctx->state->config->screencast_conf.chooser_type,
			ctx->state->config->screencast_conf.chooser_cmd
		};
		logprint(DEBUG, "wlroots: chooser %s (%d)", chooser.cmd, chooser.type);
		bool ret = wlr_chooser(&chooser, ctx, target, type_mask);
		if (!ret) {
			logprint(ERROR, "wlroots: chooser %s failed", chooser.cmd);
			goto end;
		}
		return target->output || target->toplevel;
	}
end:
	return false;
}
