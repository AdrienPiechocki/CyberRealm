extends Node
## Tests du clavier virtuel ouvert sur un champ de texte (scripts/main/text_input_osk.gd).

const Runner = preload("res://tests/runner.gd")
const Osk = preload("res://scripts/main/text_input_osk.gd")

func test_should_open():
	var r: Variant = Runner.assert_eq([Osk.should_open("pad", true, true), Osk.should_open("pad", false, true),
		Osk.should_open("never", true, true), Osk.should_open("pad", true, false)],
		[true, false, false, false], "manette seulement / jamais / clavier non routé")
	return r

class FakeKeyboard extends Node:
	var visible := false
	var closed_notify: Array = []
	var refreshed := 0
	func show_menu(_t = null, _f := true) -> void: visible = true
	func hide_menu(notify := true) -> void: visible = false; closed_notify.append(notify)
	func _refresh_extra_row() -> void: refreshed += 1

class FakeSettings extends Node:
	var mode := "pad"
	func get_osk_on_text_input() -> String: return mode

func test_auto_open_and_close_without_cutting_interact():
	var kb := FakeKeyboard.new()
	var st := FakeSettings.new()
	var o: Node = Osk.new()
	o.setup(null, kb, st, func() -> bool: return true)
	o._last_was_pad = true
	o.on_text_input_changed(3, true, 0, 0, Rect2i())
	var r: Variant = Runner.assert_true(kb.visible, "champ actif + manette : clavier ouvert")
	if r is String: kb.free(); st.free(); o.free(); return r
	o.on_text_input_changed(3, false, 0, 0, Rect2i())
	r = Runner.assert_eq([kb.visible, kb.closed_notify], [false, [false]], "champ quitté : refermé sans keyboard_closed")
	if r is String: kb.free(); st.free(); o.free(); return r
	kb.visible = true                         # ouvert à la main
	o.on_text_input_changed(3, false, 0, 0, Rect2i())
	r = Runner.assert_true(kb.visible and kb.refreshed == 3, "clavier ouvert à la main : jamais refermé par le script")
	kb.free(); st.free(); o.free()
	return r

func test_extra_row_labels_survive_layout_refresh():

	var vk: Node = preload("res://scripts/ui/virtual_keyboard.gd").new()
	add_child(vk)
	vk._update_all_labels(vk._get_current_layout())
	var labels: Array = []
	for b in vk._key_buttons:
		if is_instance_valid(b) and b.get_meta("keycode", 0) == -1:
			labels.append(b.text)
	var r: Variant = Runner.assert_eq(labels, vk.EXTRA_CHARS, "emoji gardés après mise à jour des étiquettes")
	vk.free()
	return r
