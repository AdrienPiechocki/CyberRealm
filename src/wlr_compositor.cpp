#include "wlr_compositor.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <chrono>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <unistd.h>
#include <sys/wait.h>

extern "C" {
#include <wlr/types/wlr_buffer.h>
#include <wlr/render/dmabuf.h>
#include <libdrm/drm_fourcc.h>
#include <wlr/types/wlr_subcompositor.h>
#include <wlr/types/wlr_viewporter.h>
}

using namespace godot;

// ---------------------------------------------------------------------
// Table de correspondance Key (Godot, physical_keycode) -> evdev keycode
// (linux/input-event-codes.h). Couverture: lettres, chiffres, touches de
// contrôle et de navigation courantes. À COMPLÉTER si des touches
// manquent (pavé numérique détaillé, touches multimédia, etc.) et à
// VÉRIFIER contre la version de godot-cpp utilisée: les noms des
// constantes Key ont pu changer entre versions 4.x.
// ---------------------------------------------------------------------
static const std::unordered_map<int, uint32_t> GODOT_TO_EVDEV = {
    {(int)Key::KEY_ESCAPE, 1},
    {(int)Key::KEY_1, 2}, {(int)Key::KEY_2, 3}, {(int)Key::KEY_3, 4},
    {(int)Key::KEY_4, 5}, {(int)Key::KEY_5, 6}, {(int)Key::KEY_6, 7},
    {(int)Key::KEY_7, 8}, {(int)Key::KEY_8, 9}, {(int)Key::KEY_9, 10},
    {(int)Key::KEY_0, 11},
    {(int)Key::KEY_MINUS, 12}, {(int)Key::KEY_EQUAL, 13},
    {(int)Key::KEY_BACKSPACE, 14}, {(int)Key::KEY_TAB, 15},
    {(int)Key::KEY_Q, 16}, {(int)Key::KEY_W, 17}, {(int)Key::KEY_E, 18},
    {(int)Key::KEY_R, 19}, {(int)Key::KEY_T, 20}, {(int)Key::KEY_Y, 21},
    {(int)Key::KEY_U, 22}, {(int)Key::KEY_I, 23}, {(int)Key::KEY_O, 24},
    {(int)Key::KEY_P, 25},
    {(int)Key::KEY_BRACKETLEFT, 26}, {(int)Key::KEY_BRACKETRIGHT, 27},
    {(int)Key::KEY_ENTER, 28}, {(int)Key::KEY_CTRL, 29},
    {(int)Key::KEY_A, 30}, {(int)Key::KEY_S, 31}, {(int)Key::KEY_D, 32},
    {(int)Key::KEY_F, 33}, {(int)Key::KEY_G, 34}, {(int)Key::KEY_H, 35},
    {(int)Key::KEY_J, 36}, {(int)Key::KEY_K, 37}, {(int)Key::KEY_L, 38},
    {(int)Key::KEY_SEMICOLON, 39}, {(int)Key::KEY_APOSTROPHE, 40},
    {(int)Key::KEY_QUOTELEFT, 41},
    {(int)Key::KEY_SHIFT, 42},
    {(int)Key::KEY_BACKSLASH, 43},
    {(int)Key::KEY_Z, 44}, {(int)Key::KEY_X, 45}, {(int)Key::KEY_C, 46},
    {(int)Key::KEY_V, 47}, {(int)Key::KEY_B, 48}, {(int)Key::KEY_N, 49},
    {(int)Key::KEY_M, 50},
    {(int)Key::KEY_COMMA, 51}, {(int)Key::KEY_PERIOD, 52}, {(int)Key::KEY_SLASH, 53},
    {(int)Key::KEY_ALT, 56},
    {(int)Key::KEY_SPACE, 57},
    {(int)Key::KEY_CAPSLOCK, 58},
    {(int)Key::KEY_F1, 59}, {(int)Key::KEY_F2, 60}, {(int)Key::KEY_F3, 61},
    {(int)Key::KEY_F4, 62}, {(int)Key::KEY_F5, 63}, {(int)Key::KEY_F6, 64},
    {(int)Key::KEY_F7, 65}, {(int)Key::KEY_F8, 66}, {(int)Key::KEY_F9, 67},
    {(int)Key::KEY_F10, 68}, {(int)Key::KEY_F11, 87}, {(int)Key::KEY_F12, 88},
    {(int)Key::KEY_HOME, 102}, {(int)Key::KEY_UP, 103}, {(int)Key::KEY_PAGEUP, 104},
    {(int)Key::KEY_LEFT, 105}, {(int)Key::KEY_RIGHT, 106}, {(int)Key::KEY_END, 107},
    {(int)Key::KEY_DOWN, 108}, {(int)Key::KEY_PAGEDOWN, 109},
    {(int)Key::KEY_INSERT, 110}, {(int)Key::KEY_DELETE, 111},
    {(int)Key::KEY_META, 125},
    {(int)Key::KEY_MENU, 139},
};

// ---------------------------------------------------------------------

// ---------------------------------------------------------------------
// Impl minimal pour un wlr_keyboard non rattaché à un backend matériel.
// led_update en no-op: on ne pilote pas de LEDs physiques.
// ---------------------------------------------------------------------
static void waylandgodot_keyboard_led_update(wlr_keyboard *keyboard, uint32_t leds) {
    (void)keyboard;
    (void)leds;
}

static const wlr_keyboard_impl waylandgodot_KEYBOARD_IMPL = {
    .name = "waylandgodot-vkbd",
    .led_update = waylandgodot_keyboard_led_update,
};

void WlrCompositor::_bind_methods() {
    ClassDB::bind_method(D_METHOD("start_headless"), &WlrCompositor::start_headless);
    ClassDB::bind_method(D_METHOD("forward_pointer_motion", "window_id", "surface_x", "surface_y"),
        &WlrCompositor::forward_pointer_motion);
    ClassDB::bind_method(D_METHOD("forward_pointer_motion_popup", "popup_id", "surface_x", "surface_y"),
        &WlrCompositor::forward_pointer_motion_popup);
    ClassDB::bind_method(D_METHOD("forward_pointer_button", "window_id", "button", "pressed"),
        &WlrCompositor::forward_pointer_button);
    ClassDB::bind_method(D_METHOD("forward_pointer_button_popup", "popup_id", "button", "pressed"),
        &WlrCompositor::forward_pointer_button_popup);
    ClassDB::bind_method(D_METHOD("forward_pointer_axis", "window_id", "delta_x", "delta_y"),
        &WlrCompositor::forward_pointer_axis);
    ClassDB::bind_method(D_METHOD("forward_pointer_leave"), &WlrCompositor::forward_pointer_leave);
    ClassDB::bind_method(D_METHOD("forward_keyboard_key", "godot_physical_keycode", "key_location", "pressed"),
        &WlrCompositor::forward_keyboard_key);
    ClassDB::bind_method(D_METHOD("get_wayland_socket_name"), &WlrCompositor::get_wayland_socket_name);
    ClassDB::bind_method(D_METHOD("launch_app", "command"), &WlrCompositor::launch_app);
    ClassDB::bind_method(D_METHOD("set_window_size", "window_id", "width", "height"), &WlrCompositor::set_window_size);
    ClassDB::bind_method(D_METHOD("set_x11_display", "display_name"), &WlrCompositor::set_x11_display);

    ADD_SIGNAL(MethodInfo("window_mapped",
        PropertyInfo(Variant::INT, "id"),
        PropertyInfo(Variant::STRING, "title"),
        PropertyInfo(Variant::STRING, "app_id")));
    ADD_SIGNAL(MethodInfo("window_unmapped", PropertyInfo(Variant::INT, "id")));
    ADD_SIGNAL(MethodInfo("window_texture_updated",
        PropertyInfo(Variant::INT, "id"),
        PropertyInfo(Variant::OBJECT, "texture"),
        PropertyInfo(Variant::INT, "width"),
        PropertyInfo(Variant::INT, "height")));

    ADD_SIGNAL(MethodInfo("popup_mapped",
        PropertyInfo(Variant::INT, "id"),
        PropertyInfo(Variant::INT, "parent_window_id"),
        PropertyInfo(Variant::INT, "parent_popup_id"),
        PropertyInfo(Variant::INT, "x"),
        PropertyInfo(Variant::INT, "y"),
        PropertyInfo(Variant::INT, "width"),
        PropertyInfo(Variant::INT, "height")));
    ADD_SIGNAL(MethodInfo("popup_unmapped", PropertyInfo(Variant::INT, "id")));
    ADD_SIGNAL(MethodInfo("popup_texture_updated",
        PropertyInfo(Variant::INT, "id"),
        PropertyInfo(Variant::OBJECT, "texture"),
        PropertyInfo(Variant::INT, "width"),
        PropertyInfo(Variant::INT, "height")));
}

WlrCompositor::WlrCompositor() {}

WlrCompositor::~WlrCompositor() {
    if (display) {
        wl_display_destroy_clients(display);
        wl_display_destroy(display);
    }
}

uint32_t WlrCompositor::get_time_msec() {
    using namespace std::chrono;
    return (uint32_t)duration_cast<milliseconds>(
        steady_clock::now().time_since_epoch()).count();
}

WindowState *WlrCompositor::find_window(int id) {
    auto it = windows.find(id);
    return it == windows.end() ? nullptr : &it->second;
}

PopupState *WlrCompositor::find_popup(int id) {
    auto it = popups.find(id);
    return it == popups.end() ? nullptr : &it->second;
}

// --- Callbacks wlroots (C, appelés depuis wl_event_loop_dispatch) -----

void WlrCompositor::on_keyboard_key(wl_listener *listener, void *data) {
    WlrCompositor *self = wl_container_of(listener, self, keyboard_key_listener);
    auto *event = static_cast<wlr_keyboard_key_event *>(data);
    wlr_seat_set_keyboard(self->seat, &self->virtual_keyboard);
    wlr_seat_keyboard_notify_key(self->seat, event->time_msec, event->keycode, event->state);
}

void WlrCompositor::on_keyboard_modifiers(wl_listener *listener, void *data) {
    WlrCompositor *self = wl_container_of(listener, self, keyboard_modifiers_listener);
    wlr_seat_set_keyboard(self->seat, &self->virtual_keyboard);
    wlr_seat_keyboard_notify_modifiers(self->seat, &self->virtual_keyboard.modifiers);
}

void WlrCompositor::on_new_toplevel(wl_listener *listener, void *data) {
    // container_of manuel: new_toplevel_listener est un membre direct de
    // WlrCompositor, donc on retrouve l'instance par offset.
    WlrCompositor *self = wl_container_of(listener, self, new_toplevel_listener);
    auto *toplevel = static_cast<wlr_xdg_toplevel *>(data);

    int id = self->next_window_id++;
    WindowState &ws = self->windows[id];
    ws.id = id;
    ws.toplevel = toplevel;
    ws.owner = self;

    ws.map_listener.notify = WlrCompositor::on_toplevel_map;
    wl_signal_add(&toplevel->base->surface->events.map, &ws.map_listener);

    ws.unmap_listener.notify = WlrCompositor::on_toplevel_unmap;
    wl_signal_add(&toplevel->base->surface->events.unmap, &ws.unmap_listener);

    ws.destroy_listener.notify = WlrCompositor::on_toplevel_destroy;
    wl_signal_add(&toplevel->events.destroy, &ws.destroy_listener);

    ws.commit_listener.notify = WlrCompositor::on_surface_commit;
    wl_signal_add(&toplevel->base->surface->events.commit, &ws.commit_listener);

    // Menus/dropdowns créés par ce toplevel (rôle xdg_popup). Pas de
    // sous-menus imbriqués dans cette version: on n'écoute pas ce même
    // signal sur les popups eux-mêmes, seulement sur les toplevels.
    ws.new_popup_listener.notify = WlrCompositor::on_new_popup;
    wl_signal_add(&toplevel->base->events.new_popup, &ws.new_popup_listener);

    UtilityFunctions::print("waylandgodot: new_toplevel reçu, id=", id,
        " app_id=", toplevel->app_id ? toplevel->app_id : "(pas encore fixé)");

    (void)id;
}

void WlrCompositor::on_toplevel_map(wl_listener *listener, void *data) {
    WindowState *ws = wl_container_of(listener, ws, map_listener);
    WlrCompositor *self = ws->owner;

    String title = ws->toplevel->title ? String(ws->toplevel->title) : String("");
    String app_id = ws->toplevel->app_id ? String(ws->toplevel->app_id) : String("");
    self->emit_signal("window_mapped", ws->id, title, app_id);
}

void WlrCompositor::on_toplevel_unmap(wl_listener *listener, void *data) {
    WindowState *ws = wl_container_of(listener, ws, unmap_listener);
    WlrCompositor *self = ws->owner;
    self->emit_signal("window_unmapped", ws->id);
}

void WlrCompositor::on_toplevel_destroy(wl_listener *listener, void *data) {
    WindowState *ws = wl_container_of(listener, ws, destroy_listener);
    WlrCompositor *self = ws->owner;
    int id = ws->id;

    if (self->active_toplevel_id == id) {
        self->active_toplevel_id = -1;
    }

    wl_list_remove(&ws->map_listener.link);
    wl_list_remove(&ws->unmap_listener.link);
    wl_list_remove(&ws->destroy_listener.link);
    wl_list_remove(&ws->commit_listener.link);
    wl_list_remove(&ws->new_popup_listener.link);

    self->windows.erase(id);
}

void WlrCompositor::on_surface_commit(wl_listener *listener, void *data) {
    WindowState *ws = wl_container_of(listener, ws, commit_listener);
    WlrCompositor *self = ws->owner;

    // Depuis wlroots 0.18, un configure n'est plus envoyé automatiquement
    // en réponse au commit initial - c'est au compositeur de le détecter
    // (wlr_xdg_surface.initial_commit) et de le programmer lui-même, à
    // chaque commit tant que ce n'est pas fait (pas seulement à la
    // création du toplevel, sinon ça peut arriver trop tôt).
    if (ws->toplevel->base->initial_commit) {
        wlr_xdg_toplevel_set_size(ws->toplevel, 800, 600);
        wlr_xdg_surface_schedule_configure(ws->toplevel->base);
        return; // rien à capturer sur ce commit, juste la négociation initiale
    }

    if (!self->capture_surface_pixels(ws->toplevel->base->surface, ws->texture, ws->width, ws->height)) {
        return;
    }
    self->emit_signal("window_texture_updated", ws->id, ws->texture, ws->width, ws->height);
}

// --- Popups (menus, dropdowns, tooltips...) -------------------------------

void WlrCompositor::wire_popup(PopupState &ps, wlr_xdg_popup *popup) {
    ps.popup = popup;
    ps.owner = this;

    ps.map_listener.notify = WlrCompositor::on_popup_map;
    wl_signal_add(&popup->base->surface->events.map, &ps.map_listener);

    ps.unmap_listener.notify = WlrCompositor::on_popup_unmap;
    wl_signal_add(&popup->base->surface->events.unmap, &ps.unmap_listener);

    ps.destroy_listener.notify = WlrCompositor::on_popup_destroy;
    wl_signal_add(&popup->events.destroy, &ps.destroy_listener);

    ps.commit_listener.notify = WlrCompositor::on_popup_commit;
    wl_signal_add(&popup->base->surface->events.commit, &ps.commit_listener);

    ps.reposition_listener.notify = WlrCompositor::on_popup_reposition;
    wl_signal_add(&popup->events.reposition, &ps.reposition_listener);

    // Sous-menus créés depuis CE popup (menu qui ouvre un autre menu au survol).
    ps.new_popup_listener.notify = WlrCompositor::on_new_popup_from_popup;
    wl_signal_add(&popup->base->events.new_popup, &ps.new_popup_listener);
}

void WlrCompositor::on_new_popup(wl_listener *listener, void *data) {
    WindowState *ws = wl_container_of(listener, ws, new_popup_listener);
    WlrCompositor *self = ws->owner;
    auto *popup = static_cast<wlr_xdg_popup *>(data);

    int id = self->next_popup_id++;
    PopupState &ps = self->popups[id];
    ps.id = id;
    ps.parent_window_id = ws->id;
    ps.parent_popup_id = -1;
    self->wire_popup(ps, popup);

    UtilityFunctions::print("waylandgodot: new_popup reçu, id=", id, " parent_window_id=", ws->id);
}

void WlrCompositor::on_new_popup_from_popup(wl_listener *listener, void *data) {
    PopupState *parent_ps = wl_container_of(listener, parent_ps, new_popup_listener);
    WlrCompositor *self = parent_ps->owner;
    auto *popup = static_cast<wlr_xdg_popup *>(data);

    int id = self->next_popup_id++;
    PopupState &ps = self->popups[id];
    ps.id = id;
    ps.parent_window_id = parent_ps->parent_window_id; // propage la fenêtre racine
    ps.parent_popup_id = parent_ps->id;
    self->wire_popup(ps, popup);

    UtilityFunctions::print("waylandgodot: new_popup (sous-menu) reçu, id=", id,
        " parent_popup_id=", parent_ps->id);
}

void WlrCompositor::on_popup_map(wl_listener *listener, void *data) {
    PopupState *ps = wl_container_of(listener, ps, map_listener);
    WlrCompositor *self = ps->owner;

    // Position relative au coin haut-gauche de la géométrie du parent -
    // c'est au GDScript de la convertir en offset 3D par rapport au quad
    // parent, en pixels selon la résolution captée du parent.
    wlr_box geo = ps->popup->current.geometry;
    UtilityFunctions::print("waylandgodot: popup_mapped id=", ps->id,
        " parent=", ps->parent_window_id,
        " parent_popup=", ps->parent_popup_id,
        " x=", geo.x, " y=", geo.y, " w=", geo.width, " h=", geo.height);
    self->emit_signal("popup_mapped", ps->id, ps->parent_window_id, ps->parent_popup_id,
        geo.x, geo.y, geo.width, geo.height);
}

void WlrCompositor::on_popup_unmap(wl_listener *listener, void *data) {
    PopupState *ps = wl_container_of(listener, ps, unmap_listener);
    WlrCompositor *self = ps->owner;
    self->emit_signal("popup_unmapped", ps->id);
}

void WlrCompositor::on_popup_reposition(wl_listener *listener, void *data) {
    PopupState *ps = wl_container_of(listener, ps, reposition_listener);
    WlrCompositor *self = ps->owner;

    if (WindowState *parent = self->find_window(ps->parent_window_id)) {
        wlr_box constraint_box = {};
        constraint_box.x = 0;
        constraint_box.y = 0;
        constraint_box.width = parent->width > 0 ? parent->width : 800;
        constraint_box.height = parent->height > 0 ? parent->height : 600;
        wlr_xdg_popup_unconstrain_from_box(ps->popup, &constraint_box);
    }

    // Le client attend une réponse configure après reposition().
    wlr_xdg_surface_schedule_configure(ps->popup->base);
}

void WlrCompositor::on_popup_destroy(wl_listener *listener, void *data) {
    PopupState *ps = wl_container_of(listener, ps, destroy_listener);
    WlrCompositor *self = ps->owner;
    int id = ps->id;

    wl_list_remove(&ps->map_listener.link);
    wl_list_remove(&ps->unmap_listener.link);
    wl_list_remove(&ps->destroy_listener.link);
    wl_list_remove(&ps->commit_listener.link);
    wl_list_remove(&ps->reposition_listener.link);
    wl_list_remove(&ps->new_popup_listener.link);

    self->popups.erase(id);
}

void WlrCompositor::on_popup_commit(wl_listener *listener, void *data) {
    PopupState *ps = wl_container_of(listener, ps, commit_listener);
    WlrCompositor *self = ps->owner;

    // Même pattern que pour les toplevels (wlroots 0.18): pas de configure
    // automatique sur le commit initial, à détecter et programmer nous-mêmes.
    if (ps->popup->base->initial_commit) {
        wlr_box constraint_box = {};
        constraint_box.x = 0;
        constraint_box.y = 0;
        if (WindowState *parent = self->find_window(ps->parent_window_id)) {
            constraint_box.width = parent->width > 0 ? parent->width : 800;
            constraint_box.height = parent->height > 0 ? parent->height : 600;
        } else {
            constraint_box.width = 800;
            constraint_box.height = 600;
        }
        // La box doit être dans le repère du toplevel parent (0,0 = coin
        // haut-gauche de sa surface) - sans ça, le positioner du client
        // peut demander une géométrie absurde (observé: largeurs de
        // plusieurs milliers de pixels).
        wlr_xdg_popup_unconstrain_from_box(ps->popup, &constraint_box);
        wlr_xdg_surface_schedule_configure(ps->popup->base);
        return;
    }

    if (!self->capture_surface_pixels(ps->popup->base->surface, ps->texture, ps->width, ps->height)) {
        return;
    }
    self->emit_signal("popup_texture_updated", ps->id, ps->texture, ps->width, ps->height);
}

// --- Capture texture (partagée fenêtres/popups) ---------------------------

bool WlrCompositor::capture_surface_pixels(wlr_surface *surface, Ref<ImageTexture> &tex, int &out_w, int &out_h) {
    // On ne touche plus au wlr_client_buffer directement (échouait aussi
    // bien pour du shm importé côté GPU que pour du dmabuf pur - le wrapper
    // client_buffer n'expose pas d'accès CPU garanti). À la place: on
    // récupère la texture déjà importée par le renderer, on la dessine dans
    // un buffer offscreen qu'on alloue nous-mêmes en garantissant
    // WLR_BUFFER_CAP_DATA_PTR, puis on lit CE buffer-là. Marche pour shm et
    // dmabuf de la même façon.
    wlr_texture *texture = wlr_surface_get_texture(surface);
    if (!texture) {
        return false; // pas encore de texture importée pour ce commit
    }

    int w = (int)texture->width;
    int h = (int)texture->height;
    if (w <= 0 || h <= 0) {
        return false;
    }

    const wlr_drm_format_set *formats =
        wlr_renderer_get_texture_formats(renderer, WLR_BUFFER_CAP_DATA_PTR);
    const wlr_drm_format *fmt = formats ? wlr_drm_format_set_get(formats, DRM_FORMAT_ARGB8888) : nullptr;
    if (!fmt) {
        UtilityFunctions::printerr("waylandgodot: DRM_FORMAT_ARGB8888 non supporté en lecture CPU par ce renderer");
        return false;
    }

    wlr_buffer *offscreen = wlr_allocator_create_buffer(allocator, w, h, fmt);
    if (!offscreen) {
        UtilityFunctions::printerr("waylandgodot: échec allocation buffer offscreen");
        return false;
    }

    wlr_render_pass *pass = wlr_renderer_begin_buffer_pass(renderer, offscreen, nullptr);
    if (!pass) {
        wlr_buffer_drop(offscreen);
        UtilityFunctions::printerr("waylandgodot: échec begin_buffer_pass");
        return false;
    }

    wlr_render_texture_options opts = {};
    opts.texture = texture;
    opts.dst_box.x = 0;
    opts.dst_box.y = 0;
    opts.dst_box.width = w;
    opts.dst_box.height = h;
    wlr_render_pass_add_texture(pass, &opts);

    if (!wlr_render_pass_submit(pass)) {
        wlr_buffer_drop(offscreen);
        UtilityFunctions::printerr("waylandgodot: échec render_pass_submit");
        return false;
    }

    void *pixels = nullptr;
    uint32_t px_format = 0;
    size_t stride = 0;
    if (!wlr_buffer_begin_data_ptr_access(offscreen, WLR_BUFFER_DATA_PTR_ACCESS_READ,
            &pixels, &px_format, &stride)) {
        UtilityFunctions::printerr("waylandgodot: begin_data_ptr_access a échoué sur le buffer offscreen (pourtant alloué CPU-lisible)");
        wlr_buffer_drop(offscreen);
        return false;
    }

    PackedByteArray bytes;
    bytes.resize((int64_t)w * h * 4);
    uint8_t *dst = bytes.ptrw();
    const uint8_t *src = static_cast<const uint8_t *>(pixels);

    // On respecte le stride réel (peut inclure du padding de ligne).
    // DRM_FORMAT_ARGB8888 est BGRA en mémoire (little-endian) -> réordonné
    // en RGBA pour Godot.
    for (int y = 0; y < h; y++) {
        const uint8_t *row = src + (size_t)y * stride;
        for (int x = 0; x < w; x++) {
            dst[(y * w + x) * 4 + 0] = row[x * 4 + 2]; // R <- B
            dst[(y * w + x) * 4 + 1] = row[x * 4 + 1]; // G
            dst[(y * w + x) * 4 + 2] = row[x * 4 + 0]; // B <- R
            dst[(y * w + x) * 4 + 3] = row[x * 4 + 3]; // A
        }
    }

    wlr_buffer_end_data_ptr_access(offscreen);
    wlr_buffer_drop(offscreen);

    Ref<Image> img = Image::create_from_data(w, h, false, Image::FORMAT_RGBA8, bytes);

    if (tex.is_null() || out_w != w || out_h != h) {
        tex = ImageTexture::create_from_image(img);
    } else {
        tex->update(img);
    }
    out_w = w;
    out_h = h;
    return true;
}

// --- Cycle de vie -------------------------------------------------------

void WlrCompositor::start_headless() {
    display = wl_display_create();
    event_loop = wl_display_get_event_loop(display);

    backend = wlr_headless_backend_create(event_loop);
    if (!backend) {
        UtilityFunctions::printerr("waylandgodot: échec création backend headless");
        return;
    }

    // Force le renderer logiciel Pixman: garantit des buffers CPU-mappables
    // de bout en bout. L'allocateur GBM (choisi par défaut si un GPU est
    // détecté) ne garantit pas ça, ce qui faisait échouer la lecture du
    // buffer offscreen malgré un rendu réussi. Le pipeline actuel fait de
    // toute façon un readback CPU à chaque frame (pas de vrai zero-copy
    // GPU), donc Pixman ne coûte pas grand-chose de plus ici. À revoir si
    // le passage à un vrai chemin GPU zero-copy est fait un jour.
    setenv("WLR_RENDERER", "pixman", 0); // 0 = ne pas écraser si déjà positionné par l'utilisateur

    renderer = wlr_renderer_autocreate(backend);
    if (!renderer) {
        UtilityFunctions::printerr("waylandgodot: wlr_renderer_autocreate a échoué (pas d'EGL/GPU accessible ?) - essayez WLR_RENDERER=pixman en variable d'environnement");
        return;
    }
    wlr_renderer_init_wl_display(renderer, display);
    allocator = wlr_allocator_autocreate(backend, renderer);

    // Beaucoup de clients (Qt/KDE en tête, cf. "There are no outputs")
    // refusent de committer une surface tant qu'aucun wl_output n'existe.
    // Résolution plausible plutôt que 1x1: du code client (positionnement
    // des popups chez Qt en particulier) semble utiliser la géométrie de
    // cet output pour ses calculs de layout même s'il n'est jamais affiché
    // - 1x1 produisait des tailles de popup aberrantes (des milliers de
    // pixels), probablement un calcul qui déraille contre un écran nul.
    wlr_output *fake_output = wlr_headless_add_output(backend, 1920, 1080);
    if (fake_output) {
        wlr_output_state state;
        wlr_output_state_init(&state);
        wlr_output_state_set_enabled(&state, true);
        wlr_output_state_set_custom_mode(&state, 1920, 1080, 0);
        wlr_output_commit_state(fake_output, &state);
        wlr_output_state_finish(&state);

        // Sans ça, l'output existe côté backend mais n'est jamais annoncé
        // aux clients (aucun wl_registry.global "wl_output" reçu) - Qt en
        // particulier semble s'en servir pour calculer la géométrie
        // disponible lors du positionnement des popups, et échoue/abandonne
        // silencieusement sans cette info (observé: positioners avec des
        // tailles aberrantes, jamais vu avec un vrai compositeur qui expose
        // son output correctement).
        wlr_output_create_global(fake_output, display);
    } else {
        UtilityFunctions::printerr("waylandgodot: échec création output factice");
    }

    compositor = wlr_compositor_create(display, 6, renderer);
    xdg_shell = wlr_xdg_shell_create(display, 3);
    wlr_viewporter_create(display);
    wlr_subcompositor_create(display);
    seat = wlr_seat_create(display, "seat0");

    wlr_data_device_manager_create(display);
    wlr_primary_selection_v1_device_manager_create(display);

    // Clavier autonome, non rattaché à un wlr_input_device/backend -
    // uniquement utilisé pour porter la keymap et satisfaire l'API de
    // wlr_seat_set_keyboard(). wlr_keyboard_init/wlr_keyboard_impl viennent
    // de wlr/interfaces/wlr_keyboard.h (API "implémenteur", pas
    // wlr/types/wlr_keyboard.h) - impl fournit un led_update no-op puisqu'on
    // ne pilote pas de LEDs physiques.
    wlr_keyboard_init(&virtual_keyboard, &waylandgodot_KEYBOARD_IMPL, "waylandgodot-vkbd");

    xkb_context *ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    // Layout "fr" explicite: le layout par défaut ("us", utilisé si on
    // laissait les champs à nullptr sans variables d'env XKB_DEFAULT_*
    // positionnées) n'a pas de 3e niveau - AltGr n'y produit rien, même en
    // envoyant le bon code evdev. À changer ici si vous n'êtes pas en
    // AZERTY (ou remplacer par les variables XKB_DEFAULT_LAYOUT/VARIANT).
    xkb_rule_names rule_names = {
        .rules = nullptr,
        .model = nullptr,
        .layout = "fr",
        .variant = nullptr,
        .options = nullptr,
    };
    xkb_keymap *keymap = xkb_keymap_new_from_names(ctx, &rule_names, XKB_KEYMAP_COMPILE_NO_FLAGS);
    wlr_keyboard_set_keymap(&virtual_keyboard, keymap);
    xkb_keymap_unref(keymap);
    xkb_context_unref(ctx);

    wlr_seat_set_keyboard(seat, &virtual_keyboard);
    wlr_seat_set_capabilities(seat, WL_SEAT_CAPABILITY_POINTER | WL_SEAT_CAPABILITY_KEYBOARD);

    // wlr_keyboard_notify_key() (appelé depuis forward_keyboard_key) met à
    // jour l'état xkb interne de virtual_keyboard et émet ces deux signaux -
    // sans ce relais vers le seat, le client ne reçoit jamais wl_keyboard.
    // modifiers et ignore donc les combinaisons (Ctrl+C etc.), même si les
    // touches individuelles arrivent bien.
    keyboard_key_listener.notify = WlrCompositor::on_keyboard_key;
    wl_signal_add(&virtual_keyboard.events.key, &keyboard_key_listener);
    keyboard_modifiers_listener.notify = WlrCompositor::on_keyboard_modifiers;
    wl_signal_add(&virtual_keyboard.events.modifiers, &keyboard_modifiers_listener);

    new_toplevel_listener.notify = WlrCompositor::on_new_toplevel;
    wl_signal_add(&xdg_shell->events.new_toplevel, &new_toplevel_listener);

    const char *socket = wl_display_add_socket_auto(display);
    if (!socket) {
        UtilityFunctions::printerr("waylandgodot: impossible de créer le socket Wayland");
        return;
    }
    setenv("WAYLAND_DISPLAY", socket, 1);

    if (!wlr_backend_start(backend)) {
        UtilityFunctions::printerr("waylandgodot: échec démarrage backend");
        return;
    }

    UtilityFunctions::print("waylandgodot: compositeur headless prêt sur ", socket);
}

void WlrCompositor::_process(double delta) {
    if (!event_loop) return;
    wl_event_loop_dispatch(event_loop, 0);
    if (display) wl_display_flush_clients(display);

    // Sans ça, un client qui a demandé un frame callback
    // (wl_surface.frame(), ex. Qt/KDE) reste bloqué en attente
    // indéfiniment après sa première frame - il a bien traité les
    // événements entre-temps (input inclus) mais ne redessine jamais.
    // On débloque toutes les fenêtres mappées à chaque tick Godot.
    timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    for (auto &pair : windows) {
        WindowState &ws = pair.second;
        wlr_surface_send_frame_done(ws.toplevel->base->surface, &now);
    }
}

// --- Input ---------------------------------------------------------------

void WlrCompositor::notify_pointer_motion_on_surface(wlr_surface *surface, double surface_x, double surface_y) {
    if (!surface || !seat) return;
    uint32_t time = get_time_msec();

    if (seat->pointer_state.focused_surface != surface) {
        wlr_seat_pointer_notify_enter(seat, surface, surface_x, surface_y);
    }
    wlr_seat_pointer_notify_motion(seat, time, surface_x, surface_y);
    wlr_seat_pointer_notify_frame(seat);
}

void WlrCompositor::forward_pointer_motion(int window_id, double surface_x, double surface_y) {
    WindowState *ws = find_window(window_id);
    if (!ws) return;
    notify_pointer_motion_on_surface(ws->toplevel->base->surface, surface_x, surface_y);
}

void WlrCompositor::forward_pointer_motion_popup(int popup_id, double surface_x, double surface_y) {
    PopupState *ps = find_popup(popup_id);
    if (!ps) return;
    // Un popup (menu, dropdown) n'a besoin que du survol/hover pour ses
    // items - pas de vol de focus clavier ni d'activation xdg_toplevel,
    // contrairement à un clic sur une fenêtre.
    notify_pointer_motion_on_surface(ps->popup->base->surface, surface_x, surface_y);
}

void WlrCompositor::forward_pointer_button(int window_id, int button, bool pressed) {
    WindowState *ws = find_window(window_id);
    if (!ws || !seat) return;

    UtilityFunctions::print("waylandgodot: button id=", window_id,
        " pressed=", pressed,
        " focus_ok=", (seat->pointer_state.focused_surface == ws->toplevel->base->surface));

    wlr_seat_pointer_notify_button(seat, get_time_msec(), (uint32_t)button,
        pressed ? WL_POINTER_BUTTON_STATE_PRESSED : WL_POINTER_BUTTON_STATE_RELEASED);
    wlr_seat_pointer_notify_frame(seat);

    if (pressed) {
        // Le focus clavier wl_seat ne suffit pas pour la plupart des clients
        // (Konsole/KDE inclus): xdg_shell a sa propre notion de focus via
        // l'état ACTIVATED envoyé dans le configure du toplevel. Sans ça,
        // le client peut router les touches correctement en interne mais ne
        // pas afficher le curseur clignotant ni se comporter comme "actif".
        if (active_toplevel_id != window_id) {
            if (WindowState *prev = find_window(active_toplevel_id)) {
                wlr_xdg_toplevel_set_activated(prev->toplevel, false);
            }
            wlr_xdg_toplevel_set_activated(ws->toplevel, true);
            active_toplevel_id = window_id;
        }

        wlr_seat_keyboard_notify_enter(seat, ws->toplevel->base->surface,
            virtual_keyboard.keycodes,
            virtual_keyboard.num_keycodes,
            &virtual_keyboard.modifiers);
    }
}

void WlrCompositor::forward_pointer_button_popup(int popup_id, int button, bool pressed) {
    PopupState *ps = find_popup(popup_id);
    if (!ps || !seat) return;

    wlr_seat_pointer_notify_button(seat, get_time_msec(), (uint32_t)button,
        pressed ? WL_POINTER_BUTTON_STATE_PRESSED : WL_POINTER_BUTTON_STATE_RELEASED);
    wlr_seat_pointer_notify_frame(seat);
}

void WlrCompositor::forward_pointer_axis(int window_id, double delta_x, double delta_y) {
    WindowState *ws = find_window(window_id);
    if (!ws || !seat) return;
    uint32_t time = get_time_msec();
    if (delta_y != 0.0) {
        wlr_seat_pointer_notify_axis(seat, time, WL_POINTER_AXIS_VERTICAL_SCROLL,
            delta_y, (int32_t)delta_y, WL_POINTER_AXIS_SOURCE_WHEEL, WL_POINTER_AXIS_RELATIVE_DIRECTION_IDENTICAL);
    }
    if (delta_x != 0.0) {
        wlr_seat_pointer_notify_axis(seat, time, WL_POINTER_AXIS_HORIZONTAL_SCROLL,
            delta_x, (int32_t)delta_x, WL_POINTER_AXIS_SOURCE_WHEEL, WL_POINTER_AXIS_RELATIVE_DIRECTION_IDENTICAL);
    }
    wlr_seat_pointer_notify_frame(seat);
}

void WlrCompositor::forward_pointer_leave() {
    if (!seat) return;
    wlr_seat_pointer_notify_clear_focus(seat);
}

void WlrCompositor::forward_keyboard_key(int godot_physical_keycode, int key_location, bool pressed) {
    if (!seat) return;

    uint32_t evdev_code;
    // location 2 = KEY_LOCATION_RIGHT (Godot InputEventKey.location). Le
    // Alt droit physique partage le même Key::KEY_ALT que le gauche côté
    // Godot - sans ce cas spécial, AltGr est toujours envoyé comme
    // KEY_LEFTALT (56), qui n'active jamais le 3e niveau (ISO_Level3_Shift)
    // défini sur KEY_RIGHTALT (100) dans la keymap.
    if (godot_physical_keycode == (int)Key::KEY_ALT && key_location == 2) {
        evdev_code = 100; // KEY_RIGHTALT / AltGr
    } else {
        auto it = GODOT_TO_EVDEV.find(godot_physical_keycode);
        if (it == GODOT_TO_EVDEV.end()) {
            return; // touche non mappée - compléter GODOT_TO_EVDEV au besoin
        }
        evdev_code = it->second;
    }

    wlr_keyboard_key_event event = {};
    event.time_msec = get_time_msec();
    event.keycode = evdev_code;
    event.update_state = true; // met à jour l'xkb_state (et les modifiers) automatiquement
    event.state = pressed ? WL_KEYBOARD_KEY_STATE_PRESSED : WL_KEYBOARD_KEY_STATE_RELEASED;

    // Met à jour l'état interne de virtual_keyboard et émet events.key /
    // events.modifiers, relayés vers le seat par les listeners câblés dans
    // start_headless(). C'est ce qui manquait pour Ctrl+C et consorts.
    wlr_keyboard_notify_key(&virtual_keyboard, &event);
}

// --- Utilitaires -----------------------------------------------------------

String WlrCompositor::get_wayland_socket_name() const {
    const char *s = getenv("WAYLAND_DISPLAY");
    return s ? String(s) : String("");
}

void WlrCompositor::launch_app(const String &command) {
    // Fork/exec simple: le process enfant hérite de WAYLAND_DISPLAY (positionné
    // dans start_headless), donc le client s'y connecte automatiquement.
    // Pas de gestion de zombie process ici (pas de waitpid) - à ajouter si le
    // nombre de lancements devient significatif (SIGCHLD handler ou reap
    // périodique).
    pid_t pid = fork();
    if (pid == 0) {
        setsid();
        CharString cmd = command.utf8();
        execl("/bin/sh", "sh", "-c", cmd.get_data(), (char *)nullptr);
        _exit(127); // exec a échoué
    } else if (pid < 0) {
        UtilityFunctions::printerr("waylandgodot: fork() a échoué pour launch_app");
    }
}

void WlrCompositor::set_window_size(int window_id, int width, int height) {
    WindowState *ws = find_window(window_id);
    if (!ws || !ws->toplevel) return;

    // S'assure d'avoir des dimensions valides
    if (width < 50) width = 50;
    if (height < 50) height = 50;

    // Demande au client Wayland de s'adapter à cette nouvelle taille
    wlr_xdg_toplevel_set_size(ws->toplevel, width, height);
    wlr_xdg_surface_schedule_configure(ws->toplevel->base);
}

// Dans wlr_compositor.cpp (à déclarer aussi dans le .h et _bind_methods)
void WlrCompositor::set_x11_display(const String &display_name) {
    setenv("DISPLAY", display_name.utf8().get_data(), 1);
}