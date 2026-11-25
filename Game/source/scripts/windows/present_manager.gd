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

## Readback ASYNCHRONE (RenderingDevice.texture_get_data_async) : la copie
## GPU→CPU est mise en file dans la frame courante et rendue 1-2 frames plus
## tard par callback, sans bloquer le thread principal ni vider la file GPU.
## Le get_image() synchrone coûte un stall complet par frame (1080p ≈ 8 Mo) :
## c'était la cause du lag du screenshare. Au plus MAX_READBACKS_IN_FLIGHT
## lectures en vol ; au-delà la frame est sautée (le flux ralentit au lieu
## de faire ramer le jeu).
const MAX_READBACKS_IN_FLIGHT := 2
var _readbacks_in_flight := 0
var _async_readback_ok := true # false → repli définitif sur get_image()

func _present_viewport_frame() -> void:
	if _async_readback_ok and _present_viewport_frame_async():
		return
	_present_viewport_frame_sync()

func _present_viewport_frame_async() -> bool:
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		_async_readback_ok = false
		return false
	var vp_tex := RenderingServer.viewport_get_texture(get_viewport().get_viewport_rid())
	var tex := RenderingServer.texture_get_rd_texture(vp_tex)
	if not tex.is_valid():
		_async_readback_ok = false
		return false
	var fmt := rd.texture_get_format(tex)
	if fmt.format != RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM \
			and fmt.format != RenderingDevice.DATA_FORMAT_R8G8B8A8_SRGB:
		_async_readback_ok = false
		return false
	if _readbacks_in_flight >= MAX_READBACKS_IN_FLIGHT:
		return true # trop de lectures en vol : on saute cette frame
	if rd.texture_get_data_async(tex, 0, _on_readback.bind(fmt.width, fmt.height)) != OK:
		_async_readback_ok = false
		return false
	_readbacks_in_flight += 1
	return true

func _on_readback(data: PackedByteArray, w: int, h: int) -> void:
	_readbacks_in_flight = maxi(_readbacks_in_flight - 1, 0)
	if compositor == null or data.size() < w * h * 4:
		return
	compositor.present_viewport_frame(data, w, h)

func _present_viewport_frame_sync() -> void:
	var vp := get_viewport()
	var img := vp.get_texture().get_image()
	if img == null or img.is_empty():
		return
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	compositor.present_viewport_frame(img.get_data(), img.get_width(), img.get_height())
