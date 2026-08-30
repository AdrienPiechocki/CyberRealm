-- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --
-- CyberRealm — Intégration Hyprland (config Lua).
--
-- Reproduit le comportement de l'extension GNOME Shell / du script KWin :
--   * détection de la fenêtre du jeu,
--   * plein écran à l'ouverture,
--   * focus conservé tant que la fenêtre est visible.
--
-- Les raccourcis globaux ne sont PAS bloqués côté hôte (même compromis qu'avec
-- GNOME/KWin) : le jeu gère déjà sa propre inhibition de raccourcis à
-- l'intérieur de son compositor embarqué (zwp_keyboard_shortcuts_inhibit_v1,
-- voir compositors/gnome/).
--
-- Installation :
--   cp compositors/hyprland/cyberrealm.lua ~/.config/hypr/
-- puis ajouter  require("cyberrealm")  à ~/.config/hypr/hyprland.lua,
-- enfin  hyprctl reload .
-- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --

-- Règle principale : le titre de la fenêtre (xdg-shell title) vaut "CyberRealm"
-- (config/name du projet). Les règles statiques sont évaluées à l'ouverture sur
-- initial_title/initial_class ; stay_focused est ré-évalué en dynamique.
hl.window_rule({
    name = "cyberrealm",
    match = {
        initial_title = ".*[Cc]yber[Rr]ealm.*",
    },
    fullscreen = true,        -- équivalent de make_fullscreen (GNOME) / fullScreen (KWin)
    stay_focused = true,      -- force le focus tant que la fenêtre est visible
    focus_on_activate = true, -- reprend l'activation si le jeu le demande
    content = "game",         -- type de contenu (gestion moniteur/VRR)
    idle_inhibit = "focus",   -- évite la mise en veille DPMS pendant le jeu
})

-- Secours : certains clients Wayland exposent une app_id (class) différente du
-- titre ; on re-matche alors sur la classe si elle contient "cyberrealm".
hl.window_rule({
    name = "cyberrealm-class",
    match = {
        initial_class = ".*[Cc]yber[Rr]ealm.*",
    },
    fullscreen = true,
    stay_focused = true,
    focus_on_activate = true,
    content = "game",
    idle_inhibit = "focus",
})