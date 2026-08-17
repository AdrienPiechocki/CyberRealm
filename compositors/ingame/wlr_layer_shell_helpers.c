#include "wlr_layer_shell_helpers.h"

const char *waylandgodot_layer_surface_get_namespace(const struct wlr_layer_surface_v1 *surface) {
	if (surface == NULL) {
		return NULL;
	}
	return surface->namespace;
}
