extends Label


func _process(_delta: float) -> void:
	text = "FPS: %s" % [Engine.get_frames_per_second()]
