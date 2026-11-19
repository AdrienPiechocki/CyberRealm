extends Node
## Sous une session kiosque (cage), force la fenêtre à occuper tout l'écran
## principal. Cage envoie un configure plein écran, mais Godot peut garder sa
## taille initiale (1920x1080) tant qu'on ne lui redemande pas explicitement.

func _ready() -> void:
	if Engine.is_editor_hint() or DisplayServer.get_name() != "Wayland":
		return
	var win := get_window()
	# Mode observé sous cage : MAXIMIZED (cage n'honore pas le fullscreen) et
	# fenêtre de 1032 px au lieu de 1080 => les 48 px manquants sont la barre
	# de titre client-side (libdecor). On la supprime.
	win.borderless = true
	win.size_changed.connect(_fit)
	_fit()
	# Le compositeur peut annoncer la taille de l'écran après le 1er frame.
	get_tree().create_timer(0.5).timeout.connect(_fit)

func _fit() -> void:
	var screen := DisplayServer.get_primary_screen()
	var target := DisplayServer.screen_get_size(screen)
	var win := get_window()
	if not win.borderless:
		win.borderless = true
	if target.x > 0 and win.size != target:
		win.size = target
