extends Label

func _process(delta: float) -> void:
	set_text("FPS %d" % Engine.get_frames_per_second())
