# Hyprland — CyberRealm

[`cyberrealm.lua`](cyberrealm.lua) est une règle de fenêtre Hyprland (config
Lua, wikis [Core](https://wiki.hypr.land/configuring/core/) /
[Rules](https://wiki.hypr.land/configuring/core/rules/window-rules/)) qui
reproduit le comportement de l'[extension GNOME Shell](../gnome/) et du
[script KWin](../kwin/) : détecter la fenêtre du jeu, la passer en plein écran
à l'ouverture et conserver son focus tant qu'elle est visible.

## Ce que fait la configuration

| Comportement KWin / GNOME | Équivalent Hyprland (Lua) |
| --- | --- |
| Détection `/cyberrealm/i` (wm_class / resourceClass) | `match = { initial_title = ".*[Cc]yber[Rr]ealm.*" }` (+ secours `initial_class`) |
| `make_fullscreen` / `fullScreen` à l'ouverture | effet statique `fullscreen = true` |
| Ré-focus / activate répété (balayage) | effet dynamique `stay_focused = true` |
| – | `content = "game"`, `idle_inhibit = "focus"` |

Les raccourcis globaux de l'hôte ne sont pas bloqués : c'est le même compromis
que GNOME / KWin — le jeu gère sa propre inhibition des raccourcis à
l'intérieur de son compositor embarqué (`zwp_keyboard_shortcuts_inhibit_v1`,
voir `compositors/gnome/godot-4.7-shortcuts-inhibit.patch`).

## Installation

`install.sh` fait tout automatiquement (si `~/.config/hypr/hyprland.lua`
existe) : il copie `cyberrealm.lua` dans `~/.config/hypr/` et ajoute
`require("cyberrealm")` à la config **si elle n'y est pas déjà** (idempotent),
puis recharge la configuration si une session Hyprland tourne.

À la main (`install.sh` non (re)lancé) :

1. Copier la règle vers la config utilisateur :

   ```sh
   cp compositors/hyprland/cyberrealm.lua ~/.config/hypr/
   ```

2. L'inclure depuis `~/.config/hypr/hyprland.lua` :

   ```lua
   require("cyberrealm")
   ```

3. Recharger la configuration :

   ```sh
   hyprctl reload
   ```

Si `hyprland.lua` n'existe pas encore (config générée au premier démarrage de
Hyprland), le script l'ignore : relancer `./install.sh` après la première
session pour activer la règle.

## Vérifier

```sh
hyprctl clients | grep -iA3 cyberrealm
```

La fenêtre du jeu doit apparaître avec `fullscreen: true` dès son ouverture, et
conserver le focus pendant toute la partie.

> Note : la configuration Lua est en place dans Hyprland depuis ses versions
> récentes (la règle cible la branche « Latest git » du wiki). Sur une
> installation antérieure utilisant l'ancien format `hyprland.conf`
> (`~/.config/hypr/hyprland.conf`), l'équivalent est :
>
> ```conf
> windowrulev2 = fullscreen,class:.*[Cc]yber[Rr]ealm.*
> ```