extends Node
## Barres de titre du mode focus et plein écran sur demande du client.
##
## Module de FocusMode (nœud enfant « Titlebar »), créé par la façade : l'état partagé vit dans la façade
## (`fm`), l'état propre au module vit ici.

const FocusMode := preload("res://scripts/windows/focus_mode.gd")
var fm: FocusMode = null

const Decorations := preload("res://scripts/ui/window_decorations.gd")

# Barre de titre des fenêtres du mode focus (décoration 2D, miroir de la SSD
# de windows_3d.gd : mêmes couleurs). Posée juste au-dessus du contenu
# AFFICHÉ (zone KEEP_ASPECT_CENTERED), largeur = celle du contenu. Un
# clic-glisser dessus déplace la fenêtre sans modificateur ; les couleurs
# reprennent TITLEBAR_BG/TITLEBAR_FG de windows_3d.gd.
# FOCUS_TITLEBAR_BG/FG ne servent plus que de REPLI, quand l'asset SVG est
# absent : voir `titlebar_style`.
const FOCUS_TITLEBAR_BG := Color(0.13, 0.15, 0.22)

## Hauteur de la barre en px, lue dans le JSON des décorations. La bande « top »
## du SVG mesure `titlebar_height` px de haut : c'est donc cette métrique qui
## donne un affichage 1:1, identique à la barre 3D. Une constante codée en dur
## (32) étirait la bande de 20 px, ou la rognait.
static func titlebar_h() -> float:
	return float(Decorations.metrics().get("titlebar_height", 32.0))

## Style de la barre. La bande « top » vient du MÊME loader que la décoration
## 3D, tuilée en largeur comme les bords 3D : étirer 292 px sur 1000 px
## déformerait le motif d'un facteur 3.4.
## `atlas == null` = asset absent, on garde l'aplat historique : sinon la
## fenêtre se retrouverait sans barre alors que le client n'a rien demandé.
static func titlebar_style(atlas: Texture2D) -> StyleBox:
	if atlas != null:
		var sb := StyleBoxTexture.new()
		sb.texture = atlas
		sb.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
		return sb
	var flat := StyleBoxFlat.new()
	flat.bg_color = FOCUS_TITLEBAR_BG
	flat.corner_radius_top_left = 4
	flat.corner_radius_top_right = 4
	return flat

## Couleur du titre : la métrique `label_color` du JSON, lue comme la 3D en
## `_sync_bar`, pour que les deux rasters parlent du même gris.
static func titlebar_fg() -> Color:
	return Decorations.metrics().get("label_color", Color.WHITE) as Color

# Règle unique du plein écran du mode focus : une fenêtre n'est traitée en
# plein écran QUE si son client l'a demandé (xdg_toplevel.request_fullscreen).
# Le mode focus n'impose plus rien — un terminal ou un éditeur garde sa taille
# naturelle et sa barre de titre.
#
# `requested` est l'état demandé par le client, pas l'état courant : le getter
# natif lit toplevel->requested.fullscreen. On n'appelle le setter que sur
# TRANSITION (sinon on renvoie un configure au client à chaque frame).
func _apply_fullscreen_request(id: int, requested: bool) -> void:
	if not fm.focus_mode or id < 0:
		return
	var current := fm.focus_fullscreen_id == id
	if requested == current:
		# Déjà dans l'état voulu : ne rien envoyer au compositeur.
		return
	if requested:
		fm.compositor.set_window_fullscreen(id, true)
		fm.focus_fullscreen_id = id
		fm.focus_maximized.erase(id)
		# Cadence de capture prioritaire (60/s) : c'est l'image affichée plein
		# écran, sa fluidité est bornée par la recapture de sa texture. Sans
		# ça, un jeu plein écran resterait bridé à la cadence "quads 3D".
		fm.compositor.set_focus_capture_priority_window(id)
		# La fenêtre en plein écran n'est pas déplaçable : pas de barre de titre.
		_remove_title_bar(id)
	else:
		fm.compositor.set_window_fullscreen(id, false)
		fm.focus_fullscreen_id = -1
		_remove_title_bar(id)
		# Retour à l'état « maximisé » du mode focus (et non à original_size).
		fm._maximize_window(id)
		# Fenêtre ACTIVE : pas de barre (invariant _activate_window). Fenêtre
		# de pile : elle redevient une fenêtre de titre normale.
		if id == fm._active_id() and not fm.focus_opened_during.has(id):
			_remove_title_bar(id)
		else:
			_ensure_title_bar(id)
	# Recalcule la géométrie de TOUTE la pile : une bascule plein écran change
	# la taille de l'overlay concerné et le cadrage des fenêtres au premier plan.
	for wid in fm.focus_stack:
		fm._refresh_rect_layout(wid)

# Réaction en direct : la fenêtre ACTIVE peut demander (ou annuler) le plein
# écran en cours de session. On n'agit que sur transition — c'est ce qui
# garantit zéro appel au compositeur sur une frame stable.
func _sync_active_fullscreen() -> void:
	var id := fm._active_id()
	if id < 0:
		return
	_apply_fullscreen_request(id, fm.compositor.is_window_fullscreen_requested(id))

# Crée la barre de titre d'une fenêtre de la pile (sauf plein écran).
# Panel + Label centré : même palette que les SSD 3D (windows_3d.gd) pour une
# cohérence visuelle entre les deux modes.
func _ensure_title_bar(id: int) -> void:
	if id == fm.focus_fullscreen_id or id < 0:
		return
	if fm.focus_title_bars.has(id) and is_instance_valid(fm.focus_title_bars[id]):
		_sync_title_bar(id)
		return
	var bar := Panel.new()
	bar.add_theme_stylebox_override("panel", titlebar_style(Decorations.border_piece("top")))
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.z_index = _rect_z_index(id)
	var lbl := Label.new()
	lbl.name = "Title"
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.clip_text = true
	lbl.add_theme_color_override("font_color", titlebar_fg())
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(lbl)
	fm.ui.add_child(bar)
	fm.focus_title_bars[id] = bar
	_sync_title_bar(id)

func _sync_title_bar(id: int) -> void:
	var bar: Panel = fm.focus_title_bars.get(id)
	if bar == null or not is_instance_valid(bar):
		return
	if id == fm.focus_fullscreen_id or not fm.focus_stack.has(id):
		bar.visible = false
		return
	# Clients CSD (Firefox, GTK, Qt) : la window_geometry xdg ne couvre que
	# la zone de contenu client, PAS la barre d'onglets/decoration dessinée
	# par le client. Utiliser le haut du displayed_rect (buffer entier rendu)
	# pour placer la titlebar au-dessus de TOUT le contenu rendu, y compris
	# les onglets du client.
	var is_csd: bool = not fm.windows.window_server_side.get(id, true)
	var bar_rect: Rect2
	if is_csd:
		bar_rect = fm._displayed_rect(id)
		if bar_rect.size.x <= 0.0:
			bar.visible = false
			return
	else:
		bar_rect = fm._displayed_content_rect(id)
		if bar_rect.size.x <= 0.0:
			bar.visible = false
			return
	bar.visible = true
	var bar_h := titlebar_h()
	bar.size = Vector2(bar_rect.size.x, bar_h)
	bar.position = Vector2(bar_rect.position.x, bar_rect.position.y - bar_h)
	# Rechargement a chaud : le stylebox est reapplique a chaque sync, donc un
	# SVG edite, remplace ou supprime est pris en compte au prochain
	# deplacement, redimensionnement ou remontee, sans quitter le mode focus.
	# On ne reconstruit que si l'asset a change, pour ne pas allouer un
	# StyleBox a chaque frame de drag.
	var atlas := Decorations.border_piece("top")
	var current := bar.get_theme_stylebox("panel")
	var unchanged := (atlas != null and current is StyleBoxTexture \
		and (current as StyleBoxTexture).texture == atlas) \
		or (atlas == null and current is StyleBoxFlat)
	if not unchanged:
		bar.add_theme_stylebox_override("panel", titlebar_style(atlas))
	var lbl: Label = bar.get_node_or_null("Title")
	if lbl != null:
		lbl.text = fm.windows.bar_title(id)
		lbl.size = bar.size

# z_index que porte l'overlay d'une fenêtre selon son rang dans la pile
# (FOCUS_Z_BASE + rang + 1, cf. enter_focus / _raise_window). La barre porte
# le MÊME z que son rect : ajoutée après dans l'arbre, elle se dessine
# au-dessus ; le rect d'une fenêtre plus haute dans la pile (z supérieur) la
# recouvre, comme en 3D.
func _rect_z_index(id: int) -> int:
	var idx := fm.focus_stack.find(id)
	if idx == -1 or not fm.focus_rects.has(id) or not is_instance_valid(fm.focus_rects[id]):
		return FocusMode.FOCUS_Z_BASE + 1
	return int(fm.focus_rects[id].z_index)

# Fenêtre dont la BARRE DE TITRE affichée contient pos, -1 sinon. Itération
# du sommet vers le fond (une barre peut être recouverte par le contenu d'une
# fenêtre plus haute, mais jamais par une autre barre : elles sont hors des
# zones de contenu).
func _titlebar_at(pos: Vector2) -> int:
	for i in range(fm.focus_stack.size() - 1, -1, -1):
		var id: int = fm.focus_stack[i]
		var bar: Panel = fm.focus_title_bars.get(id)
		if bar == null or not is_instance_valid(bar) or not bar.visible:
			continue
		if bar.get_global_rect().has_point(pos):
			return id
	return -1

# Retire la barre de titre d'une fenêtre (démap, sortie de pile, sortie du
# mode focus).
func _remove_title_bar(id: int) -> void:
	if not fm.focus_title_bars.has(id):
		return
	var bar: Panel = fm.focus_title_bars[id]
	fm.focus_title_bars.erase(id)
	if is_instance_valid(bar):
		bar.queue_free()
