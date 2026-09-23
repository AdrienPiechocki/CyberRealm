extends Node
## Tests du menu fenêtres (window_menu.gd).
## Régression : la preview doit être ancrée plein-rect dans son conteneur
## borné (_preview_box). Un Control simple ne trie pas ses enfants : sans
## ancrage, le TextureRect garde une taille (0,0) et la preview n'affiche
## rien.

const WindowMenuScript := preload("res://scripts/ui/window_menu.gd")

func test_preview_rect_fills_bounded_box() -> Variant:
	var menu := PanelContainer.new()
	menu.name = "WindowMenu"

	var vbox := VBoxContainer.new()
	vbox.name = "VBox"
	menu.add_child(vbox)

	var topbar := ScrollContainer.new()
	topbar.name = "TopBar"
	vbox.add_child(topbar)
	var tabs := HBoxContainer.new()
	tabs.name = "Tabs"
	topbar.add_child(tabs)

	var content := HBoxContainer.new()
	content.name = "Content"
	vbox.add_child(content)
	var preview := TextureRect.new()
	preview.name = "Preview"
	content.add_child(preview)
	content.add_child(VSeparator.new())
	var actions := VBoxContainer.new()
	actions.name = "Actions"
	content.add_child(actions)

	menu.set_script(WindowMenuScript)
	get_tree().root.add_child(menu)

	var box: Control = menu.get_node_or_null("VBox/Content/PreviewBox")
	if box == null:
		return "PreviewBox manquant (le build a échoué)"

	var rect: TextureRect = menu.preview_rect
	if rect.anchor_left != 0.0:
		return "anchor_left n'est pas 0"
	if rect.anchor_top != 0.0:
		return "anchor_top n'est pas 0"
	if rect.anchor_right != 1.0:
		return "anchor_right n'est pas 1.0 (preview non ancrée plein-rect)"
	if rect.anchor_bottom != 1.0:
		return "anchor_bottom n'est pas 1.0 (preview non ancrée plein-rect)"
	menu.free()
	return true