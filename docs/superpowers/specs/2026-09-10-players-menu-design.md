# Players Menu — Design

**Date**: 2026-09-10
**Statut**: validé en brainstorming, en attente de review

## Objectif

Ajouter un menu « joueurs » ouvrable à la manette et au clavier (SUPER+SHIFT+P par
défaut), avec la même disposition que `window_menu` : onglets par joueur distant,
préview 3D de l'avatar du joueur sélectionné, et panneau d'actions (send file,
send message, kick, ban).

## Contexte

- Le roster LAN ne contient que `{id, name, color}` (`get_players_roster()`).
- Aucune action par joueur n'existe : pas de chat/message, pas de kick, pas de
  ban, pas d'envoi de fichier programmatique.
- L'envoi de fichier n'existe que par drag&drop sur un avatar (`file_share_manager.gd`).
- L'IP d'un peer est déjà récupérable côté hôte (`_remote_ip(peer_id)`).
- Le projet n'utilise aucun `SubViewport` aujourd'hui.

## Décisions validées

| Décision | Choix |
|---|---|
| Hotkey d'ouverture | Action `players_menu` = **SUPER+SHIFT+P** (libre). `pin_window` reste SUPER+P. |
| Send Message | `notify-send` sur la machine cible via RPC + gestionnaire dans `wayland_room`. |
| Send File | **`zenity --file-selection`** lancé comme fenêtre du compositor ; sortie redirigée vers un fichier tampon + polling. |
| Ban | **IP persistante** (fichier), kick + blocage au `peer_connected`, gérable depuis le pause menu. |
| Kick/Ban | Hôte uniquement ; local player exclu des onglets. |

## Architecture

### 1. `players_menu.gd` (nouveau, `extends GameMenu`, `class_name PlayersMenu`)

Layer `PlayersMenuLayer` (CanvasLayer) ajoutée dans `player.tscn`, avec
`PlayersMenu` (PanelContainer).

```
PlayersMenuLayer
└── PlayersMenu
    └── VBox
        ├── TopBar (ScrollContainer)
        │   └── Tabs (HBoxContainer)          # 1 onglet par joueur distant
        └── Content (HBoxContainer)
            ├── Preview (SubViewportContainer) # avatar 3D du joueur sélectionné
            ├── VSeparator
            └── Actions (VBoxContainer)        # boutons Send File / Send Message / Kick / Ban
```

Geométrie/thème repris de `window_menu` (900×600, centré, StyleBoxFlat identique).

Comportement :
- **Tabs** : un bouton par joueur **distant** (id croissant), texte = nom.
  Si aucun joueur distant → label « No players joined » au centre.
- **Preview** : `SubViewport` + `Camera3D` qui instancie la scène d'avatar du
  joueur sélectionné : recharger `remote.scene_file_path` (depuis
  `lan.get_remote_players()`), `setup(peer_id, name, false)`, teinte avec la
  couleur du roster, rotation lente de l'avatar. Libérer l'ancien héritage à
  chaque changement d'onglet / fermeture.
- **Actions** (selon joueur sélectionné) :
  - `Send Message` : révèle un `LineEdit` + bouton Send dans le panneau Action.
  - `Send File` : lance le sélecteur zenity en jeu, puis offre le fichier au joueur.
  - `Kick` / `Ban` : **hôte uniquement** (cachés sinon). Prompt inline
    « Confirm / Cancel » avant l'action.
- **Mise à jour live** : `lan.players_changed` → `_refresh_tabs()` (pattern
  `window_menu._refresh_tabs`).
- **Fermeture** : Échap, START (JOY_BUTTON_START), B (JOY_BUTTON_B) — même
  traitement que `window_menu`.
- `_ready` : `visible = false` ; `show_menu()` / `hide_menu()` / `toggle_menu()`.
- Lors de l'ouverture, focus sur le premier onglet (`_focus_first_deferred`, comme
  `capture_selector`).

API publique :
```gdscript
func setup(lan_ref: Node, compositor_ref: WlrCompositor, file_share_ref: Node) -> void
func show_menu() / hide_menu() / toggle_menu()
```

### 2. `player.tscn`

Nouvelle branche `PlayersMenuLayer` (CanvasLayer) en miroir de
`WindowMenuLayer`, node `PlayersMenu` avec script `players_menu.gd`.

### 3. `project.godot`

Nouvelle action `players_menu` (InputEventKey `physical_keycode=77` KEY_P,
`meta_pressed=true`, `shift_pressed=true`). Aucun conflit avec les existants.

### 4. `wayland_room.gd`

- `@onready var players_menu = $Level/Player/PlayersMenuLayer/PlayersMenu`.
- Setup : `players_menu.setup(lan, compositor, file_share)`,
  `players_menu.visibility_changed.connect(_on_menu_visibility_changed)`.
- Hotkey dans `_process` : à côté du toggle `window_menu` (mêmes gardes : pas de
  focus actif, pas de `layers.keyboard_busy()`, gating pause/ui). Ouverture via
  helper `_open_players_menu()` = `layers.deactivate_layer_interact()` +
  `compositor.release_all_keys()` + `players_menu.show_menu()`.
- Ajouter `players_menu.visible` aux retours anticipés du `_process` (blocage
  des inputs jeu quand il est ouvert) et à la mise à jour `_menu_just_closed`.

### 5. `player.gd`

- Ajouter `$PlayersMenuLayer/PlayersMenu.visible` au gating de `_input`
  (retour anticipé + politique souris « visible si mouvement » comme PauseMenu).
- Ajouter PlayersMenu à `_on_menu_visibility_changed()`.

### 6. `lan_manager.gd` — réseau

Nouvelles méthodes (hôte/API) :
```gdscript
signal message_received(sender_name: String, text: String)
signal kicked()
signal banned()
# RPC vers un peer :
func send_message_to(peer_id: int, text: String) -> void       # uid rpc
func kick_player(peer_id: int) -> void                         # hôte seulement
func ban_player(peer_id: int) -> void                          # hôte : kick + IP persistée
func get_banned_ips() -> Array[String]
func unban_ip(ip: String) -> void
# interne
func _rpc_recv_message(sender_name: String, text: String) -> void  # uid remote, target cible
func _rpc_you_were_kicked() -> void                                # target cible
func _ban_list_path / _load_ban_list / _save_ban_list               # pattern _settings
```

Détails réseau :
- `send_message_to` → `_rpc_recv_message.rpc_id(peer_id, my_name, text)`.
  Target : `message_received.emit(sender_name, text)`.
- `kick_player` : vérifier `is_host`, `multiplayer.multiplayer_peer.disconnect_peer(peer_id)`,
  `_players.erase(peer_id)` + `_emit_players()`. Avant de disconnecter, envoyer
  `_rpc_you_were_kicked.rpc_id(peer_id)` (best-effort).
- `ban_player` : `kick_player(peer_id)` puis `_remote_ip(peer_id)` → ajout à la
  liste persistée.
- Blocage au join : en tête de `_on_peer_connected(id)` (lan_manager.gd:1045),
  si `is_host and _remote_ip(id)` est dans la ban list →
  `disconnect_peer(id)` + `_set_status("Banned IP rejected: <ip>")` + `return`
  (avant le timeout/`_pending_auth`).
- Le peer kické reçoit `kicked.emit()` → UI « Kicked by host » ; le serveur ayant
  coupé, couvrir aussi le cas où le client voit `peer_disconnected` sans flag.

### 7. `file_share_manager.gd`

```gdscript
func send_file_to_peer(peer_id: int, path: String) -> bool
```
Réutilise le flux offer existant : valide le fichier (lisible) puis appelle
`_offer_files.rpc_id(peer_id, offer_id, [basename], total)` (mêmes constantes /
prompt d'acceptation que le drag&drop). Retourne `false` si fichier invalide.

### 8. Sélecteur de fichier (zenity + polling)

- `zenity --file-selection` lancé via `compositor.launch_app("sh -c '...'")` :
  fenêtre en jeu ; la sélection est écrite dans `$XDG_RUNTIME_DIR/cyberrealm-filepick` ;
  un flag `cyberrealm-filepick.done` est écrit après (commande `;` enchaînée).
- `players_menu.gd` poll les fichiers chaque frame tant que le sélecteur est
  ouvert. Fin de polling : flag `.done` présent (chemin lu) **ou** timeout 60 s
  (state polling fermé, message d'état). Si le flag apparaît sans contenu → échec
  (sélection annulée).
- Chemin choisi → `file_share.send_file_to_peer(peer_id, path)`.

### 9. Page admin « Banned IPs » dans `pause_menu.gd`

- Nouvelle vue `_current_view == "banned"` (entry depuis un sous-menu LAN ou
  directement dans la liste LAN).
- Affiche la liste `lan.get_banned_ips()` avec un bouton « Unban » par entrée
  → `lan.unban_ip(ip)` ; bouton retour.
- Signaux/vars : `advance` via `lan.is_session_active()` pour la visibilité.

## Erreurs / cas limites

- Pas de session LAN active → menu vide (« No players ») ; actions désactivées.
- Joueur sélectionné se déconnecte pendant l'affichage → `_refresh_tabs()`
  resegmente le roster ; fallback au premier onglet ou désactivation.
- Fichier à envoyer inexistant/illisible → `send_file_to_peer` retourne false →
  message d'état dans le menu (label temporaire).
- zenity lancé par un non-hôte → rien à vérifier (tout le monde peut envoyer).
- Hôte forcé : kick/ban sur soi-même impossible (local player exclu).
- Ban d'un peer déjà déconnecté : `_remote_ip` peut être vide → refuser le ban
  avec message d'état.
- `notify-send` absent sur la cible → échec silencieux (OS.execute loggé, pas de
  crash).

## Tests

- Tests unitaires Godot existants (`tests/runner.gd`) : ajouter des cas si le framework
  le permet pour la ban list (load/save/check) et `send_file_to_peer`
  (validation fichier).
- Vérification manuelle en session LAN 2 machines : ouverture par
  SUPER+SHIFT+P, onglets, preview avatar, envoi message (notify-send), envoi
  fichier (zenity → offer → rsync), kick, ban + rejoin refusé + unban.

## Fichiers touchés

| Fichier | Changements |
|---|---|
| `scripts/ui/players_menu.gd` | **Nouveau** — menu complet |
| `scenes/player.tscn` | Layer + node PlayersMenu |
| `project.godot` | Action `players_menu` (SUPER+SHIFT+P) |
| `scripts/main/wayland_room.gd` | Réf, setup, hotkey, gating |
| `scripts/player/player.gd` | Gating `_input` |
| `scripts/network/lan_manager.gd` | RPC message/kick/ban, ban list persistée, check join |
| `scripts/network/file_share_manager.gd` | `send_file_to_peer` |
| `scripts/ui/pause_menu.gd` | Page admin « Banned IPs » |