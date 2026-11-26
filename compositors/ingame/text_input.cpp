// Saisie de texte (lot I) : text_input_v3 + input_method_v2 + virtual_keyboard_v1.
//
// Relais standard (même schéma que sway) :
//   - les apps (GTK 4, Qt 6, Firefox, kitty…) ouvrent un text_input_v3 ; il suit le focus CLAVIER du seat
//     (enter / leave sur la surface focalisée) ;
//   - quand un text_input est activé (enable / commit), son état (texte autour du curseur, type de contenu) est
//     relayé à l'input method (fcitx5, ibus… lancé DANS le jeu) : activate / surrounding_text / content_type / done ;
//   - les commit de l'input method deviennent preedit / commit_string / delete_surrounding vers le text_input ;
//   - grab clavier : tant que l'input method le tient, les touches du jeu (forward_keyboard_key) lui vont à elle
//     (input.cpp) ; elle renvoie celles qu'elle ne consomme pas par son clavier virtuel (virtual_keyboard_v1) ;
//   - popups de l'input method (liste des candidats) : émis au jeu comme des popups xdg de la fenêtre, placés sous
//     le rectangle du curseur du text_input.
// Sans input method, le compositeur joue lui-même une input method minimale : ime_commit_string() insère un texte
// (emoji, caractère absent de la disposition) dans le champ actif.
// Le jeu est prévenu par le signal text_input_changed(window_id, active, hint, purpose, cursor_rect) — clavier
// virtuel ouvert automatiquement sur un champ de texte (scripts/main/text_input_osk.gd).
//
// Coordonnées vers le jeu : pixels de capture (logique × échelle de la fenêtre), comme le reste (window.cpp).

#include "wlr_compositor.h"

#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/rect2i.hpp>
#include <algorithm>
#include <cmath>
#include <vector>

// wlr_input_method_v2.h nomme un champ `delete` (mot-clé C++) : renommé le temps de l'inclusion, accessible
// sous le nom delete_field (même astuce que `namespace` pour wlr_layer_shell_v1.h dans wlr_compositor.h).
extern "C" {
#include <wlr/types/wlr_text_input_v3.h>
#define delete delete_field
#include <wlr/types/wlr_input_method_v2.h>
#undef delete
#include <wlr/types/wlr_virtual_keyboard_v1.h>
}

namespace godot {

struct TextInputRelay;

struct TiEntry {
    TextInputRelay *relay = nullptr;
    wlr_text_input_v3 *input = nullptr;
    wl_listener enable{}, commit{}, disable{}, destroy{};
};

struct ImPopup {
    TextInputRelay *relay = nullptr;
    wlr_input_popup_surface_v2 *popup = nullptr;
    int id = -1;
    int window_id = -1;
    bool mapped = false;
    int x = 0, y = 0;                 // position émise (pixels de capture, relative à la fenêtre)
    Ref<Texture2D> texture;
    int width = 0, height = 0;
    CaptureCache cache;
    wl_listener map{}, unmap{}, commit{}, destroy{};
};

struct VKbd {
    TextInputRelay *relay = nullptr;
    wlr_virtual_keyboard_v1 *vk = nullptr;
    wl_listener key{}, modifiers{}, destroy{};
};

struct TextInputRelay {
    WlrCompositor *comp = nullptr;
    std::vector<TiEntry *> inputs;
    std::vector<ImPopup *> popups;
    std::vector<VKbd *> vkbds;
    wlr_input_method_v2 *im = nullptr;
    wlr_input_method_keyboard_grab_v2 *grab = nullptr;

    wl_listener new_ti{}, new_im{}, new_vk{};
    bool managers_listening = false;
    wl_listener im_commit{}, im_grab{}, im_destroy{}, im_new_popup{}, grab_destroy{};

    // Dernier état émis au jeu (text_input_changed n'est émis qu'au changement).
    int last_wid = -2;
    bool last_active = false;
    uint32_t last_hint = 0, last_purpose = 0;
    Rect2i last_rect;

    bool alive() const { return comp && comp->alive_guard && comp->alive_guard->load(); }

    // Text input actif : focalisé ET activé par son client.
    TiEntry *focused_enabled() {
        for (TiEntry *e : inputs) {
            if (e->input->focused_surface && e->input->current_enabled) return e;
        }
        return nullptr;
    }

    float window_scale(int wid) {
        WindowState *ws = comp->find_window(wid);
        return ws ? ws->scale : 1.0f;
    }

    void send_im_state(TiEntry *e) {
        if (!im || !e) return;
        wlr_text_input_v3 *ti = e->input;
        if (ti->active_features & WLR_TEXT_INPUT_V3_FEATURE_SURROUNDING_TEXT) {
            wlr_input_method_v2_send_surrounding_text(im,
                ti->current.surrounding.text ? ti->current.surrounding.text : "",
                ti->current.surrounding.cursor, ti->current.surrounding.anchor);
        }
        wlr_input_method_v2_send_text_change_cause(im, ti->current.text_change_cause);
        if (ti->active_features & WLR_TEXT_INPUT_V3_FEATURE_CONTENT_TYPE) {
            wlr_input_method_v2_send_content_type(im, ti->current.content_type.hint, ti->current.content_type.purpose);
        }
        wlr_input_method_v2_send_done(im);
    }

    // Position d'un popup de candidats : sous le rectangle du curseur, relative à la géométrie de la fenêtre.
    bool popup_position(TiEntry *e, int &wid, int &x, int &y, wlr_box &rect) {
        wid = comp->window_id_for_surface(e->input->focused_surface);
        if (wid < 0) return false;
        rect = e->input->current.cursor_rectangle;
        if (!(e->input->active_features & WLR_TEXT_INPUT_V3_FEATURE_CURSOR_RECTANGLE)) {
            rect = wlr_box{0, 0, 1, 1};
        }
        WindowState *ws = comp->find_window(wid);
        wlr_box geo{};
        if (ws && ws->toplevel && ws->toplevel->base) geo = ws->toplevel->base->current.geometry;
        const float sc = window_scale(wid);
        x = (int)std::lround((rect.x - geo.x) * sc);
        y = (int)std::lround((rect.y + rect.height - geo.y) * sc);
        return true;
    }

    void emit_popup_mapped(ImPopup *p) {
        TiEntry *e = focused_enabled();
        int wid, x, y;
        wlr_box rect;
        if (!e || !popup_position(e, wid, x, y, rect)) return;
        wlr_surface *s = p->popup->surface;
        const float sc = window_scale(wid);
        p->window_id = wid;
        p->x = x;
        p->y = y;
        p->cache.scale = sc;
        WlrCompositor::apply_surface_scale(s, sc);
        // Rectangle du texte relatif au popup (placé juste dessous).
        wlr_box rel{0, -rect.height, rect.width, rect.height};
        wlr_input_popup_surface_v2_send_text_input_rectangle(p->popup, &rel);
        p->mapped = true;
        if (alive()) {
            comp->emit_signal("popup_mapped", p->id, wid, -1, x, y,
                (int)std::lround(s->current.width * sc), (int)std::lround(s->current.height * sc));
        }
    }

    void emit_popup_unmapped(ImPopup *p) {
        if (!p->mapped) return;
        p->mapped = false;
        if (alive()) comp->emit_signal("popup_unmapped", p->id);
    }

    // Curseur déplacé : les popups suivent (re-émis à la nouvelle position).
    void reposition_popups() {
        TiEntry *e = focused_enabled();
        if (!e) return;
        for (ImPopup *p : popups) {
            if (!p->mapped) continue;
            int wid, x, y;
            wlr_box rect;
            if (!popup_position(e, wid, x, y, rect)) continue;
            if (wid == p->window_id && x == p->x && y == p->y) continue;
            emit_popup_unmapped(p);
            emit_popup_mapped(p);
            capture_popup(p);
        }
    }

    void capture_popup(ImPopup *p) {
        if (!p->mapped || !alive()) return;
        if (comp->capture_surface(p->popup->surface, p->texture, p->width, p->height, p->cache)) {
            comp->emit_signal("popup_texture_updated", p->id, p->texture, p->width, p->height);
        }
    }

    // Signal au jeu : champ de texte actif ou non, type de contenu, rectangle du curseur (pixels de capture).
    void emit_state() {
        if (!alive()) return;
        TiEntry *e = focused_enabled();
        int wid = -1;
        bool active = false;
        uint32_t hint = 0, purpose = 0;
        Rect2i rect;
        if (e) {
            wid = comp->window_id_for_surface(e->input->focused_surface);
            active = true;
            hint = e->input->current.content_type.hint;
            purpose = e->input->current.content_type.purpose;
            const float sc = window_scale(wid);
            const wlr_box &b = e->input->current.cursor_rectangle;
            rect = Rect2i((int)std::lround(b.x * sc), (int)std::lround(b.y * sc),
                (int)std::lround(b.width * sc), (int)std::lround(b.height * sc));
        }
        if (wid == last_wid && active == last_active && hint == last_hint && purpose == last_purpose && rect == last_rect) {
            return;
        }
        last_wid = wid;
        last_active = active;
        last_hint = hint;
        last_purpose = purpose;
        last_rect = rect;
        comp->emit_signal("text_input_changed", wid, active, (int)hint, (int)purpose, rect);
    }

    // ── text_input_v3 ──────────────────────────────────────────────────
    static void on_ti_enable(wl_listener *l, void *) {
        TiEntry *e = wl_container_of(l, e, enable);
        TextInputRelay *r = e->relay;
        if (r->im) {
            wlr_input_method_v2_send_activate(r->im);
            r->send_im_state(e);
        }
        r->emit_state();
    }
    static void on_ti_commit(wl_listener *l, void *) {
        TiEntry *e = wl_container_of(l, e, commit);
        TextInputRelay *r = e->relay;
        if (!e->input->current_enabled) return;
        r->send_im_state(e);
        r->reposition_popups();
        r->emit_state();
    }
    static void on_ti_disable(wl_listener *l, void *) {
        TiEntry *e = wl_container_of(l, e, disable);
        TextInputRelay *r = e->relay;
        if (r->im) {
            wlr_input_method_v2_send_deactivate(r->im);
            r->send_im_state(e);
        }
        r->emit_state();
    }
    static void on_ti_destroy(wl_listener *l, void *) {
        TiEntry *e = wl_container_of(l, e, destroy);
        TextInputRelay *r = e->relay;
        if (e->input->current_enabled && r->im) {
            wlr_input_method_v2_send_deactivate(r->im);
            wlr_input_method_v2_send_done(r->im);
        }
        wl_list_remove(&e->enable.link);
        wl_list_remove(&e->commit.link);
        wl_list_remove(&e->disable.link);
        wl_list_remove(&e->destroy.link);
        r->inputs.erase(std::remove(r->inputs.begin(), r->inputs.end(), e), r->inputs.end());
        delete e;
        r->emit_state();
    }
    static void on_new_ti(wl_listener *l, void *data) {
        TextInputRelay *r = wl_container_of(l, r, new_ti);
        auto *ti = static_cast<wlr_text_input_v3 *>(data);
        TiEntry *e = new TiEntry();
        e->relay = r;
        e->input = ti;
        e->enable.notify = on_ti_enable;
        wl_signal_add(&ti->events.enable, &e->enable);
        e->commit.notify = on_ti_commit;
        wl_signal_add(&ti->events.commit, &e->commit);
        e->disable.notify = on_ti_disable;
        wl_signal_add(&ti->events.disable, &e->disable);
        e->destroy.notify = on_ti_destroy;
        wl_signal_add(&ti->events.destroy, &e->destroy);
        r->inputs.push_back(e);
        // La surface qui a déjà le focus clavier appartient peut-être à ce client.
        wlr_surface *focused = r->comp->seat ? r->comp->seat->keyboard_state.focused_surface : nullptr;
        if (focused && wl_resource_get_client(focused->resource) == wl_resource_get_client(ti->resource)) {
            wlr_text_input_v3_send_enter(ti, focused);
        }
    }

    void set_focus(wlr_surface *surface) {
        for (TiEntry *e : inputs) {
            if (e->input->focused_surface && e->input->focused_surface != surface) {
                wlr_text_input_v3_send_leave(e->input);
            }
        }
        if (surface) {
            wl_client *client = wl_resource_get_client(surface->resource);
            for (TiEntry *e : inputs) {
                if (!e->input->focused_surface && wl_resource_get_client(e->input->resource) == client) {
                    wlr_text_input_v3_send_enter(e->input, surface);
                }
            }
        }
        emit_state();
    }

    // ── input_method_v2 ────────────────────────────────────────────────
    static void on_im_commit(wl_listener *l, void *) {
        TextInputRelay *r = wl_container_of(l, r, im_commit);
        TiEntry *e = r->focused_enabled();
        if (!e || !r->im) return;
        wlr_input_method_v2_state &st = r->im->current;
        // Champ mot de passe : jamais de preedit (le texte en cours de composition serait affiché en clair).
        // (content_purpose text-input-v3 : 8 = password, 9 = pin)
        const uint32_t purpose = e->input->current.content_type.purpose;
        bool password = purpose == 8 || purpose == 9;
        if (st.preedit.text && !password) {
            wlr_text_input_v3_send_preedit_string(e->input, st.preedit.text, st.preedit.cursor_begin, st.preedit.cursor_end);
        }
        if (st.commit_text) {
            wlr_text_input_v3_send_commit_string(e->input, st.commit_text);
        }
        if (st.delete_field.before_length || st.delete_field.after_length) {
            wlr_text_input_v3_send_delete_surrounding_text(e->input, st.delete_field.before_length, st.delete_field.after_length);
        }
        wlr_text_input_v3_send_done(e->input);
    }
    static void on_grab_destroy(wl_listener *l, void *) {
        TextInputRelay *r = wl_container_of(l, r, grab_destroy);
        wl_list_remove(&r->grab_destroy.link);
        r->grab = nullptr;
        // Le client focalisé retrouve l'état réel des modificateurs.
        if (r->comp->seat && r->comp->seat->keyboard_state.focused_surface) {
            wlr_seat_keyboard_notify_modifiers(r->comp->seat, &r->comp->virtual_keyboard.modifiers);
        }
    }
    static void on_im_grab(wl_listener *l, void *data) {
        TextInputRelay *r = wl_container_of(l, r, im_grab);
        auto *grab = static_cast<wlr_input_method_keyboard_grab_v2 *>(data);
        if (r->grab) wl_list_remove(&r->grab_destroy.link);
        r->grab = grab;
        wlr_input_method_keyboard_grab_v2_set_keyboard(grab, &r->comp->virtual_keyboard);
        r->grab_destroy.notify = on_grab_destroy;
        wl_signal_add(&grab->events.destroy, &r->grab_destroy);
    }

    // Popups de candidats.
    static void on_popup_map(wl_listener *l, void *) {
        ImPopup *p = wl_container_of(l, p, map);
        p->relay->emit_popup_mapped(p);
    }
    static void on_popup_unmap(wl_listener *l, void *) {
        ImPopup *p = wl_container_of(l, p, unmap);
        p->relay->emit_popup_unmapped(p);
    }
    static void on_popup_commit(wl_listener *l, void *) {
        ImPopup *p = wl_container_of(l, p, commit);
        p->relay->capture_popup(p);
    }
    static void on_popup_destroy(wl_listener *l, void *) {
        ImPopup *p = wl_container_of(l, p, destroy);
        TextInputRelay *r = p->relay;
        r->emit_popup_unmapped(p);
        wl_list_remove(&p->map.link);
        wl_list_remove(&p->unmap.link);
        wl_list_remove(&p->commit.link);
        wl_list_remove(&p->destroy.link);
        r->popups.erase(std::remove(r->popups.begin(), r->popups.end(), p), r->popups.end());
        delete p;
    }
    static void on_im_new_popup(wl_listener *l, void *data) {
        TextInputRelay *r = wl_container_of(l, r, im_new_popup);
        auto *popup = static_cast<wlr_input_popup_surface_v2 *>(data);
        ImPopup *p = new ImPopup();
        p->relay = r;
        p->popup = popup;
        p->id = r->comp->next_popup_id++;
        p->map.notify = on_popup_map;
        wl_signal_add(&popup->surface->events.map, &p->map);
        p->unmap.notify = on_popup_unmap;
        wl_signal_add(&popup->surface->events.unmap, &p->unmap);
        p->commit.notify = on_popup_commit;
        wl_signal_add(&popup->surface->events.commit, &p->commit);
        p->destroy.notify = on_popup_destroy;
        wl_signal_add(&popup->events.destroy, &p->destroy);
        r->popups.push_back(p);
        if (popup->surface->mapped) r->emit_popup_mapped(p);
    }

    static void on_im_destroy(wl_listener *l, void *) {
        TextInputRelay *r = wl_container_of(l, r, im_destroy);
        wl_list_remove(&r->im_commit.link);
        wl_list_remove(&r->im_grab.link);
        wl_list_remove(&r->im_destroy.link);
        wl_list_remove(&r->im_new_popup.link);
        if (r->grab) {
            wl_list_remove(&r->grab_destroy.link);
            r->grab = nullptr;
        }
        r->im = nullptr;
        // Preedit en cours effacé dans le champ actif.
        if (TiEntry *e = r->focused_enabled()) {
            wlr_text_input_v3_send_preedit_string(e->input, "", 0, 0);
            wlr_text_input_v3_send_done(e->input);
        }
        UtilityFunctions::print("waylandgodot: input method gone");
    }
    static void on_new_im(wl_listener *l, void *data) {
        TextInputRelay *r = wl_container_of(l, r, new_im);
        auto *im = static_cast<wlr_input_method_v2 *>(data);
        if (r->im) {
            wlr_input_method_v2_send_unavailable(im);   // une seule input method à la fois
            return;
        }
        r->im = im;
        r->im_commit.notify = on_im_commit;
        wl_signal_add(&im->events.commit, &r->im_commit);
        r->im_grab.notify = on_im_grab;
        wl_signal_add(&im->events.grab_keyboard, &r->im_grab);
        r->im_destroy.notify = on_im_destroy;
        wl_signal_add(&im->events.destroy, &r->im_destroy);
        r->im_new_popup.notify = on_im_new_popup;
        wl_signal_add(&im->events.new_popup_surface, &r->im_new_popup);
        UtilityFunctions::print("waylandgodot: input method bound");
        if (TiEntry *e = r->focused_enabled()) {
            wlr_input_method_v2_send_activate(im);
            r->send_im_state(e);
        }
    }

    // ── virtual_keyboard_v1 ────────────────────────────────────────────
    // Réservé à l'input method (fcitx5 y renvoie les touches qu'elle ne consomme pas) : un clavier virtuel d'un
    // autre client permettrait à n'importe quelle app du jeu de taper dans une autre fenêtre.
    bool vk_allowed(VKbd *v) {
        return im && v->vk && wl_resource_get_client(v->vk->resource) == wl_resource_get_client(im->resource);
    }
    static void on_vk_key(wl_listener *l, void *data) {
        VKbd *v = wl_container_of(l, v, key);
        TextInputRelay *r = v->relay;
        if (!r->vk_allowed(v) || !r->comp->seat) return;
        auto *ev = static_cast<wlr_keyboard_key_event *>(data);
        wlr_seat_set_keyboard(r->comp->seat, &v->vk->keyboard);
        wlr_seat_keyboard_notify_key(r->comp->seat, ev->time_msec, ev->keycode, ev->state);
    }
    static void on_vk_modifiers(wl_listener *l, void *) {
        VKbd *v = wl_container_of(l, v, modifiers);
        TextInputRelay *r = v->relay;
        if (!r->vk_allowed(v) || !r->comp->seat) return;
        wlr_seat_set_keyboard(r->comp->seat, &v->vk->keyboard);
        wlr_seat_keyboard_notify_modifiers(r->comp->seat, &v->vk->keyboard.modifiers);
    }
    static void on_vk_destroy(wl_listener *l, void *) {
        VKbd *v = wl_container_of(l, v, destroy);
        TextInputRelay *r = v->relay;
        wl_list_remove(&v->key.link);
        wl_list_remove(&v->modifiers.link);
        wl_list_remove(&v->destroy.link);
        // Le seat ne doit pas garder un clavier détruit : retour au clavier du jeu.
        if (r->comp->seat && r->comp->seat->keyboard_state.keyboard == &v->vk->keyboard) {
            wlr_seat_set_keyboard(r->comp->seat, &r->comp->virtual_keyboard);
        }
        r->vkbds.erase(std::remove(r->vkbds.begin(), r->vkbds.end(), v), r->vkbds.end());
        delete v;
    }
    static void on_new_vk(wl_listener *l, void *data) {
        TextInputRelay *r = wl_container_of(l, r, new_vk);
        auto *vk = static_cast<wlr_virtual_keyboard_v1 *>(data);
        VKbd *v = new VKbd();
        v->relay = r;
        v->vk = vk;
        v->key.notify = on_vk_key;
        wl_signal_add(&vk->keyboard.events.key, &v->key);
        v->modifiers.notify = on_vk_modifiers;
        wl_signal_add(&vk->keyboard.events.modifiers, &v->modifiers);
        v->destroy.notify = on_vk_destroy;
        wl_signal_add(&vk->keyboard.base.events.destroy, &v->destroy);
        r->vkbds.push_back(v);
    }
};

void WlrCompositor::setup_text_input() {
    ti_relay = new TextInputRelay();
    ti_relay->comp = this;
    wlr_text_input_manager_v3 *ti_mgr = wlr_text_input_manager_v3_create(display);
    wlr_input_method_manager_v2 *im_mgr = wlr_input_method_manager_v2_create(display);
    wlr_virtual_keyboard_manager_v1 *vk_mgr = wlr_virtual_keyboard_manager_v1_create(display);
    if (!ti_mgr || !im_mgr || !vk_mgr) {
        UtilityFunctions::printerr("waylandgodot: failed to create text-input / input-method / virtual-keyboard globals");
        return;
    }
    ti_relay->new_ti.notify = TextInputRelay::on_new_ti;
    wl_signal_add(&ti_mgr->events.text_input, &ti_relay->new_ti);
    ti_relay->new_im.notify = TextInputRelay::on_new_im;
    wl_signal_add(&im_mgr->events.input_method, &ti_relay->new_im);
    ti_relay->new_vk.notify = TextInputRelay::on_new_vk;
    wl_signal_add(&vk_mgr->events.new_virtual_keyboard, &ti_relay->new_vk);
    ti_relay->managers_listening = true;
}

void WlrCompositor::teardown_text_input_listeners() {
    if (ti_relay && ti_relay->managers_listening) {
        wl_list_remove(&ti_relay->new_ti.link);
        wl_list_remove(&ti_relay->new_im.link);
        wl_list_remove(&ti_relay->new_vk.link);
        ti_relay->managers_listening = false;
    }
}

// Après wl_display_destroy : les objets ont été détruits (leurs handlers de destruction ont vidé les listes).
void WlrCompositor::destroy_text_input_relay() {
    delete ti_relay;
    ti_relay = nullptr;
}

void WlrCompositor::text_input_focus_changed(wlr_surface *surface) {
    if (ti_relay) ti_relay->set_focus(surface);
}

bool WlrCompositor::text_input_grab_key(uint32_t time_msec, uint32_t keycode, uint32_t state) {
    if (!ti_relay || !ti_relay->grab) return false;
    wlr_input_method_keyboard_grab_v2_send_key(ti_relay->grab, time_msec, keycode, state);
    return true;
}

bool WlrCompositor::text_input_grab_modifiers() {
    if (!ti_relay || !ti_relay->grab) return false;
    wlr_input_method_keyboard_grab_v2_send_modifiers(ti_relay->grab, &virtual_keyboard.modifiers);
    return true;
}

// Input method minimale du compositeur : insère `text` dans le champ actif. Refusé si une vraie input method est
// liée (elle gère le champ) ou si aucun champ n'est actif.
bool WlrCompositor::ime_commit_string(const String &text) {
    if (!ti_relay || ti_relay->im || text.is_empty()) return false;
    TiEntry *e = ti_relay->focused_enabled();
    if (!e) return false;
    CharString utf8 = text.utf8();
    wlr_text_input_v3_send_commit_string(e->input, utf8.get_data());
    wlr_text_input_v3_send_done(e->input);
    return true;
}

bool WlrCompositor::has_input_method() const {
    return ti_relay && ti_relay->im;
}

Dictionary WlrCompositor::get_text_input_state() {
    Dictionary d;
    d["active"] = false;
    d["window_id"] = -1;
    d["input_method"] = has_input_method();
    if (!ti_relay) return d;
    if (TiEntry *e = ti_relay->focused_enabled()) {
        d["active"] = true;
        d["window_id"] = window_id_for_surface(e->input->focused_surface);
        d["hint"] = (int)e->input->current.content_type.hint;
        d["purpose"] = (int)e->input->current.content_type.purpose;
    }
    return d;
}

} // namespace godot
