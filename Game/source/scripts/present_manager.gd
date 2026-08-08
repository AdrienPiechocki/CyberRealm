extends Node3D
## Présente la vue du viewport (readback GPU→CPU) vers l'output headless du
## compositeur : c'est ce buffer qu'alimente la source ext_image_capture
## "output" capturée par OBS (xdg-desktop-portal-wlr).
##
## PROCESS_MODE_ALWAYS : le menu pause met l'arbre en pause (get_tree().paused
## = true) et fige _process des nodes normaux — or la capture OBS doit
## continuer de tourner pour montrer le menu pause. Ce node tourne donc même
## en pause. Il synchronise aussi le curseur Wayland, composité dans le
## buffer présenté pour qu'il apparaisse dans la capture.

var compositor: WlrCompositor

var _present_idle_counter := 0 # frames consécutives sans capture active
const PRESENT_IDLE_INTERVAL := 60 # filet de sécurité : 1 présentation/s au repos
var _capture_grace := 0 # frames de grâce après une capture active
const CAPTURE_GRACE_FRAMES := 30 # ~0.5 s à 60 FPS : lisse les trous screencopy
var _cursor_hidden := false # curseur composité masqué (mode caméra)

func setup(compositor_ref: WlrCompositor) -> void:
	compositor = compositor_ref

func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS

func _process(_delta: float) -> void:
	# Synchroniser le curseur Wayland (wlr_cursor) avec la position de la
	# souris Godot. Le curseur est composité dans le frame screencopy par
	# le compositeur, donc il apparaîtra dans la capture OBS. En mode caméra
	# (MOUSE_MODE_CAPTURED), le curseur est masqué côté compositeur pour ne
	# pas apparaître dans la capture OBS.
	var mouse_pos := get_viewport().get_mouse_position()
	compositor.set_cursor_position(mouse_pos.x, mouse_pos.y)
	if _cursor_hidden != (Input.mouse_mode == Input.MOUSE_MODE_CAPTURED):
		_cursor_hidden = (Input.mouse_mode == Input.MOUSE_MODE_CAPTURED)
		compositor.set_cursor_visible(not _cursor_hidden)

	# Capture écran pour OBS (xdg-desktop-portal-wlr) : présente la vue du
	# viewport (ce que le joueur voit, menu pause compris) à l'output
	# headless. Le readback GPU→CPU coûte cher : on ne le fait que si un
	# client capture réellement (has_active_capture = verrou attach_render
	# posé par la session de capture), à chaque frame (60 FPS). La grâce
	# (CAPTURE_GRACE_FRAMES) couvre les trous entre deux frames d'un client
	# screencopy (verrou péri-frame). Sans capture active, un simple filet
	# de sécurité à ~1 Hz garantit un buffer frais si une session démarre
	# entre deux présentations.
	if compositor.has_active_capture():
		_capture_grace = CAPTURE_GRACE_FRAMES
	elif _capture_grace > 0:
		_capture_grace -= 1

	if _capture_grace > 0:
		_present_idle_counter = 0
		_present_viewport_frame()
	else:
		_present_idle_counter += 1
		if _present_idle_counter >= PRESENT_IDLE_INTERVAL:
			_present_idle_counter = 0
			_present_viewport_frame()

func _present_viewport_frame() -> void:
	var vp := get_viewport()
	var img := vp.get_texture().get_image()
	if img == null or img.is_empty():
		return
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	compositor.present_viewport_frame(img.get_data(), img.get_width(), img.get_height())
