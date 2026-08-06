#pragma once

#include <wlr/types/wlr_layer_shell_v1.h>

#ifdef __cplusplus
extern "C" {
#endif

// 'namespace' est un mot-clé C++: impossible d'accéder directement au
// membre `struct wlr_layer_surface_v1::namespace` depuis du C++. Ce
// shim C expose le champ sans conflit de mot-clé.
const char *waylandgodot_layer_surface_get_namespace(const struct wlr_layer_surface_v1 *surface);

#ifdef __cplusplus
}
#endif
