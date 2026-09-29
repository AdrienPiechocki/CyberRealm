extends Node
## Tests de la garde du raccourci toggle_ui (wayland_room.gd) : le bind qui
## masque/affiche le HUD (ui.visible) doit être ignoré pendant le mode focus —
## ce CanvasLayer héberge aussi les overlays focus, le cacher ferait disparaître
## la fenêtre focalisée.

const WaylandRoomScript := preload("res://scripts/main/wayland_room.gd")

func test_toggle_ui_blocked_while_focus_active() -> Variant:
	if WaylandRoomScript._ui_toggle_allowed(true, false):
		return "toggle_ui devrait être bloqué quand le focus est actif"
	return true

func test_toggle_ui_allowed_outside_focus() -> Variant:
	if not WaylandRoomScript._ui_toggle_allowed(false, false):
		return "toggle_ui devrait rester permis hors focus"
	return true

func test_toggle_ui_blocked_while_keyboard_busy() -> Variant:
	if WaylandRoomScript._ui_toggle_allowed(false, true):
		return "toggle_ui reste bloqué quand le clavier virtuel est occupé"
	return true