extends Node
## Coque du menu pause : en-tête, fil d'Ariane, sidebar des catégories, panneau de contenu, cartes et
## mise en page des pages.
##
## Module de PauseMenu (nœud enfant « Shell »), créé par la façade : l'état partagé vit dans la façade
## (`menu`), l'état propre au module vit ici.

const PauseMenu := preload("res://scripts/ui/pause_menu.gd")
var menu: PauseMenu = null

# ── Coque : en-tête + sidebar + panneau de contenu ───────────────────
# Le menu est un panneau large : catégories toujours visibles à gauche, page
# courante à droite. Toutes les pages (_show_*) construisent toujours leur
# contenu dans `container`, désormais le panneau de droite ; les pages ajoutées
# par un niveau (add_menu_page) aussi.

const SIDEBAR_WIDTH := 230
const CONTENT_MAX_WIDTH := 820

## Catégories de la sidebar : [vue, libellé]. Les pages de niveau
## (add_menu_page) sont des sous-pages de « World ».
const _CATEGORIES := [
	["general", "General"],
	["graphics", "Graphics"],
	["controls", "Controls"],
	["lan", "Multiplayer"],
	["levels", "World"],
]

var _header_status: Label = null
var _crumb: Label = null
var _content_margin: MarginContainer = null

func _build_shell() -> void:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 0)
	menu.add_child(root)

	# En-tête : marque + état (monde, session).
	var header := PanelContainer.new()
	header.set_meta("ui_class", "pm-header")
	root.add_child(header)
	var hrow := HBoxContainer.new()
	hrow.add_theme_constant_override("separation", 16)
	header.add_child(hrow)
	var brand := Label.new()
	brand.text = "CYBERREALM"
	brand.set_meta("ui_class", "pm-brand")
	hrow.add_child(brand)
	_header_status = Label.new()
	_header_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_header_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_header_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_header_status.set_meta("ui_class", "pm-status")
	hrow.add_child(_header_status)

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 0)
	root.add_child(body)

	# Sidebar (persistante : seuls ses états changent d'une page à l'autre).
	var side_panel := PanelContainer.new()
	side_panel.custom_minimum_size = Vector2(SIDEBAR_WIDTH, 0)
	side_panel.set_meta("ui_class", "pm-sidebar")
	body.add_child(side_panel)
	menu._sidebar = VBoxContainer.new()
	menu._sidebar.add_theme_constant_override("separation", 2)
	side_panel.add_child(menu._sidebar)
	_rebuild_sidebar()

	# Contenu : fil d'Ariane + page défilante, largeur bornée et centrée.
	menu._content_root = VBoxContainer.new()
	menu._content_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	menu._content_root.add_theme_constant_override("separation", 0)
	body.add_child(menu._content_root)
	_content_margin = MarginContainer.new()
	_content_margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	menu._content_root.add_child(_content_margin)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	_content_margin.add_child(col)
	_crumb = Label.new()
	_crumb.set_meta("ui_class", "pm-crumb")
	_crumb.custom_minimum_size = Vector2(0, 18)
	col.add_child(_crumb)
	menu._scroll = ScrollContainer.new()
	menu._scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	menu._scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	menu._scroll.follow_focus = true
	col.add_child(menu._scroll)
	menu.container = VBoxContainer.new()
	menu.container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	menu.container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	menu.container.add_theme_constant_override("separation", 8)
	menu._scroll.add_child(menu.container)
	menu._content_root.resized.connect(_layout_content)

## Marges du panneau de contenu : la page garde une largeur lisible
## (CONTENT_MAX_WIDTH) même sur un très grand écran.
func _layout_content() -> void:
	if _content_margin == null:
		return
	var side := maxi(28, int((menu._content_root.size.x - CONTENT_MAX_WIDTH) * 0.5))
	_content_margin.add_theme_constant_override("margin_left", side)
	_content_margin.add_theme_constant_override("margin_right", side)
	_content_margin.add_theme_constant_override("margin_top", 18)
	_content_margin.add_theme_constant_override("margin_bottom", 18)

func _rebuild_sidebar() -> void:
	if menu._sidebar == null:
		return
	for c in menu._sidebar.get_children():
		menu._sidebar.remove_child(c)
		c.queue_free()
	menu._nav_buttons.clear()

	menu._resume_btn = _make_side_btn("▶  Resume", "nav-item nav-resume")
	menu._resume_btn.pressed.connect(menu.hide_menu)
	menu._sidebar.add_child(menu._resume_btn)

	menu._sidebar.add_child(_make_side_section("Settings"))
	for cat in _CATEGORIES:
		_add_category_btn(String(cat[0]), String(cat[1]), _show_category.bind(String(cat[0])))
		if String(cat[0]) == "controls":
			menu._sidebar.add_child(_make_side_section("Session"))

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	menu._sidebar.add_child(spacer)

	var tutorial_btn := _make_side_btn("Tutorial", "nav-item")
	tutorial_btn.pressed.connect(func():
		menu.hide_menu()
		menu.tutorial_requested.emit()
	)
	menu._sidebar.add_child(tutorial_btn)
	var respawn_btn := _make_side_btn("Respawn", "nav-item")
	respawn_btn.pressed.connect(func():
		menu.hide_menu()
		menu.respawn_requested.emit()
	)
	menu._sidebar.add_child(respawn_btn)
	menu._quit_btn = _make_side_btn("Quit", "nav-item nav-quit")
	menu._quit_btn.pressed.connect(menu._quit_game)
	menu._quit_btn.disabled = menu._play_time < PauseMenu.QUIT_GAMEPLAY_DELAY
	menu._sidebar.add_child(menu._quit_btn)
	_refresh_sidebar()

func _add_category_btn(view: String, label: String, show: Callable) -> void:
	var btn := _make_side_btn(label, "nav-item")
	btn.pressed.connect(func(): show.call())
	menu._sidebar.add_child(btn)
	menu._nav_buttons[view] = btn

func _make_side_btn(text: String, klass: String) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.custom_minimum_size = Vector2(0, 40)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.set_meta("ui_class", klass)
	UITheme.apply_class(btn, klass)
	btn.add_theme_stylebox_override("disabled", btn.get_theme_stylebox("normal"))
	return btn

func _make_side_section(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text.to_upper()
	lbl.custom_minimum_size = Vector2(0, 30)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	lbl.set_meta("ui_class", "nav-section")
	UITheme.apply_class(lbl, "nav-section")
	return lbl

func _show_category(view: String) -> void:
	match view:
		"general": menu.page_general._show_general()
		"graphics": menu.page_general._show_graphics()
		"controls": menu.page_general._show_controls()
		"lan": menu.page_multiplayer._show_lan()
		"levels": menu.page_world._show_levels()
		_:
			for page in menu._extra_pages:
				if String(page["id"]) == view:
					(page["show"] as Callable).call()
					return
			menu._show_main()

## Catégorie de premier niveau d'une vue (remonte _PARENT_VIEW jusqu'à
## l'accueil). Une page de niveau (add_menu_page) relève de World.
func _category_of(view: String) -> String:
	if _is_extra_page(view):
		return "levels"
	var v := view
	for _i in 8:
		var parent := String(PauseMenu._PARENT_VIEW.get(v, "main"))
		if parent == "main":
			return v
		v = parent
	return v

func _is_extra_page(view: String) -> bool:
	for page in menu._extra_pages:
		if String(page["id"]) == view:
			return true
	return false

func _category_label(view: String) -> String:
	for cat in _CATEGORIES:
		if String(cat[0]) == view:
			return String(cat[1])
	for page in menu._extra_pages:
		if String(page["id"]) == view:
			return String(page["label"])
	return ""


func _refresh_sidebar() -> void:
	var active := _category_of(menu._current_view)
	for view in menu._nav_buttons:
		var btn: Button = menu._nav_buttons[view]
		if not is_instance_valid(btn):
			continue
		var klass := "nav-item-selected" if view == active and menu._current_view != "main" else "nav-item"
		btn.set_meta("ui_class", klass)
		UITheme.apply_class(btn, klass)

## Fil d'Ariane au-dessus du titre de page : « GRAPHICS › » sur une sous-page.
func _refresh_crumb() -> void:
	if _crumb == null:
		return
	var parent := String(PauseMenu._PARENT_VIEW.get(menu._current_view, "main"))
	if menu._current_view == "main":
		_crumb.text = ""
	elif parent == "main":
		_crumb.text = ""
	else:
		var lbl := _category_label(_category_of(menu._current_view))
		_crumb.text = (lbl.to_upper() + "  ›") if lbl != "" else ""

func _world_label() -> String:
	if menu._level_room != null and menu._level_room.has_method("get_current_level_label"):
		return String(menu._level_room.call("get_current_level_label"))
	return "—"

func _refresh_header() -> void:
	if _header_status == null:
		return
	var parts: PackedStringArray = ["World: " + _world_label()]
	if menu._lan_connected:
		var n := menu._lan_roster.size()
		parts.append("Multiplayer: %d player%s" % [n, "" if n == 1 else "s"])
	else:
		parts.append("Offline")
	_header_status.text = "   ·   ".join(parts)

func _make_card(caption: String, value: String, detail: String) -> PanelContainer:
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.set_meta("ui_class", "pm-card")
	UITheme.apply_class(card, "pm-card")
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	card.add_child(v)
	for pair in [[caption, "card-caption"], [value, "card-value"], [detail, "hint"]]:
		var l := Label.new()
		l.text = String(pair[0])
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.set_meta("ui_class", String(pair[1]))
		UITheme.apply_class(l, String(pair[1]))
		v.add_child(l)
	return card

## Après construction d'une page : état de la sidebar, fil d'Ariane, en-tête,
## et mode de défilement. Une page qui gère son propre ScrollContainer (listes
## de raccourcis, d'apps…) remplit le panneau sans défilement externe, sinon
## le panneau défile.
func _after_page_built() -> void:
	_normalize_page_layout()
	menu._focus_first_deferred()
	_refresh_sidebar()
	_refresh_crumb()
	_refresh_header()
	if menu._scroll == null:
		return
	var inner := _find_live_scroll(menu.container)
	menu._scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED if inner != null \
			else ScrollContainer.SCROLL_MODE_AUTO
	menu._scroll.scroll_vertical = 0
	_layout_content()

const ROW_LABEL_WIDTH := 230

## Mise en forme commune des pages, appliquée après leur construction (y
## compris les pages ajoutées par un niveau) : les pages empilent souvent
## « libellé / curseur / valeur » ou « libellé / champ » sur plusieurs lignes ;
## ils sont regroupés sur UNE ligne (libellé à gauche, contrôle à droite).
## Les libellés courts centrés sont réalignés à gauche, comme les lignes
## centrées commençant par un libellé.
func _normalize_page_layout() -> void:
	var kids: Array = []
	for c in menu.container.get_children():
		if not c.is_queued_for_deletion():
			kids.append(c)
	var i := 0
	while i < kids.size():
		var n: Node = kids[i]
		var next: Node = kids[i + 1] if i + 1 < kids.size() else null
		if n is Label and _is_short_label(n as Label) and next != null \
				and (next is HSlider or next is LineEdit or next is OptionButton):
			var value: Label = null
			if next is HSlider and i + 2 < kids.size() and kids[i + 2] is Label \
					and (kids[i + 2] as Label).text.length() <= 12:
				value = kids[i + 2]
			_make_row_from(n as Label, next as Control, value)
			i += 3 if value != null else 2
			continue
		if n is Label and (n as Label).horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER \
				and not (n as Label).has_meta("ui_keep_center"):
			(n as Label).horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		elif n is HBoxContainer and n.get_child_count() > 1 and n.get_child(0) is Label \
				and _is_short_label(n.get_child(0) as Label):
			# Ligne « libellé + contrôle » déjà construite par la page : même
			# colonne de libellés que les lignes regroupées ci-dessus.
			if (n as HBoxContainer).alignment == BoxContainer.ALIGNMENT_CENTER:
				(n as HBoxContainer).alignment = BoxContainer.ALIGNMENT_BEGIN
			var lbl := n.get_child(0) as Label
			lbl.custom_minimum_size.x = ROW_LABEL_WIDTH
			lbl.add_theme_font_size_override("font_size", 14)
		i += 1

func _is_short_label(l: Label) -> bool:
	return not l.text.contains("\n") and l.text.length() <= 40 \
			and l.autowrap_mode == TextServer.AUTOWRAP_OFF

func _make_row_from(label: Label, ctrl: Control, value: Label) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	menu.container.add_child(row)
	menu.container.move_child(row, label.get_index())
	for n: Node in [label, ctrl, value]:
		if n != null:
			n.reparent(row, false)
	label.custom_minimum_size.x = ROW_LABEL_WIDTH
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	ctrl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ctrl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if value != null:
		value.custom_minimum_size.x = 56
		value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		value.size_flags_vertical = Control.SIZE_SHRINK_CENTER

func _find_live_scroll(node: Node) -> ScrollContainer:
	for c in node.get_children():
		if c.is_queued_for_deletion():
			continue
		if c is ScrollContainer:
			return c
		var found := _find_live_scroll(c)
		if found != null:
			return found
	return null

## Pages ajoutées par le niveau courant (ex. options Morrowind) : ligne dans la
## page World, construite par `show` dans `container` comme les autres pages.
## `id` doit être la valeur que `show` donne à _current_view.
func add_menu_page(id: String, label: String, show: Callable) -> void:
	remove_menu_page(id, false)
	menu._extra_pages.append({"id": id, "label": label, "show": show})
	_rebuild_sidebar()
	if menu.visible and menu._current_view == "levels":
		menu.page_world._show_levels()

func remove_menu_page(id: String, rebuild := true) -> void:
	for i in range(menu._extra_pages.size() - 1, -1, -1):
		if String(menu._extra_pages[i]["id"]) == id:
			menu._extra_pages.remove_at(i)
	if rebuild:
		_rebuild_sidebar()
		if menu.visible and (menu._current_view == id or menu._current_view == "levels"):
			menu.page_world._show_levels()
