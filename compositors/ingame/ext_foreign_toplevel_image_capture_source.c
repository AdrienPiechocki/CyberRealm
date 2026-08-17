// Interface wire de ext_foreign_toplevel_image_capture_source_manager_v1.
//
// wlroots 0.19 fournit wlr_ext_image_copy_capture_manager_v1 (sessions et
// frames) et wlr_ext_output_image_capture_source_manager_v1 (capture des
// outputs), mais pas encore le manager "foreign toplevel" — le fichier
// ext-image-capture-source-v1.xml déclare pourtant l'interface. On définit
// donc ici la seule chose qu'il manque : le struct wl_interface du manager,
// câblé sur les interfaces fournies par libwlroots (ext_image_capture_source_v1
// et ext_foreign_toplevel_handle_v1). Le reste (bind, create_source, cycle de
// vie des sources) est implémenté côté compositeur dans wlr_compositor.cpp.
//
// Le header généré (server-header) par le SConstruct déclare ce symbole en
// extern ; il est défini ici pour éviter d'avoir à générer le private-code de
// tout le fichier XML (qui définirait aussi les interfaces output/source déjà
// exportées par libwlroots → conflits de symboles).

#include <wayland-server-core.h>

// Interfaces référencées par le types array du manager. libwlroots ne les
// exporte pas (wayland-scanner private-code → statiques en interne) : on les
// définit ici, avec exactement les mêmes noms et signatures que le XML, pour
// que libwayland valide les arguments objets par nom.

static const struct wl_message ext_image_capture_source_v1_requests[] = {
	{ "destroy", "", NULL },
};

const struct wl_interface ext_image_capture_source_v1_interface = {
	"ext_image_capture_source_v1", 1, 1,
	ext_image_capture_source_v1_requests, 0, NULL,
};

static const struct wl_message ext_foreign_toplevel_handle_v1_requests[] = {
	{ "destroy", "", NULL },
};

static const struct wl_message ext_foreign_toplevel_handle_v1_events[] = {
	{ "closed", "", NULL },
	{ "done", "", NULL },
	{ "title", "s", NULL },
	{ "app_id", "s", NULL },
	{ "identifier", "s", NULL },
};

const struct wl_interface ext_foreign_toplevel_handle_v1_interface = {
	"ext_foreign_toplevel_handle_v1", 1, 1,
	ext_foreign_toplevel_handle_v1_requests, 5,
	ext_foreign_toplevel_handle_v1_events,
};

static const struct wl_interface *foreign_toplevel_image_capture_source_manager_v1_types[] = {
	&ext_image_capture_source_v1_interface,
	&ext_foreign_toplevel_handle_v1_interface,
};

static const struct wl_message foreign_toplevel_image_capture_source_manager_v1_requests[] = {
	{ "create_source", "no", foreign_toplevel_image_capture_source_manager_v1_types },
	{ "destroy", "", NULL },
};

const struct wl_interface ext_foreign_toplevel_image_capture_source_manager_v1_interface = {
	"ext_foreign_toplevel_image_capture_source_manager_v1", 1, 2,
	foreign_toplevel_image_capture_source_manager_v1_requests, 0, NULL,
};
