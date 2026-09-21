extends Label

func _ready() -> void:
	UITheme.stylesheet_reloaded.connect(_on_stylesheet_reloaded)
	_apply_css()

func _apply_css() -> void:
	if label_settings == null:
		label_settings = LabelSettings.new()
	label_settings.font_size = int(UITheme.get_number("hud", "fps-size", 32.0))
	label_settings.font_color = UITheme.get_color("hud", "fps-color", Color(1, 1, 1))

func _on_stylesheet_reloaded() -> void:
	_apply_css()

func _process(delta: float) -> void:
	set_text("FPS %d" % Engine.get_frames_per_second())
