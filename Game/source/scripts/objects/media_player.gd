extends "res://scripts/objects/desktop_object.gd"
## Lecteur multimédia (lot L) : pochette, titre, artiste, progression du lecteur MPRIS courant (apps du jeu ou du
## bureau). Clic : lecture / pause ; boutons : précédent / suivant. Chaque joueur voit SON lecteur.

const SIZE := Vector2(0.7, 0.36)
const ART_MAX_BYTES := 8 * 1024 * 1024

var _cover: Sprite3D
var _title: Label3D
var _artist: Label3D
var _status: Label3D
var _bar: MeshInstance3D
var _time: Label3D
var _play: Node3D
var _art_url := ""
var _tick := 0.0

func _ready() -> void:
	make_panel(SIZE)
	make_body(SIZE)
	_cover = Sprite3D.new()
	_cover.pixel_size = 0.001
	_cover.position = Vector3(-SIZE.x / 2.0 + 0.13, 0.03, 0.012)
	add_child(_cover)
	var x := -SIZE.x / 2.0 + 0.27
	_title = make_label("No media", Vector2(x, 0.15), 44, Color(1, 1, 1), 0.4)
	_artist = make_label("", Vector2(x, 0.08), 32, Color(0.7, 0.75, 0.85), 0.4)
	_status = make_label("", Vector2(x, 0.02), 26, Color(0.55, 0.6, 0.7))
	_bar = make_bar(Vector2(x, -0.06), Vector2(0.4, 0.012), Color(0.3, 0.7, 1.0))
	_time = make_label("", Vector2(x, -0.075), 24, Color(0.6, 0.65, 0.75))
	make_button("⏮", Vector2(x + 0.06, -0.135), Vector2(0.08, 0.05), _cmd.bind("previous"), "Left click: previous")
	_play = make_button("⏯", Vector2(x + 0.2, -0.135), Vector2(0.08, 0.05), _cmd.bind("play_pause"), "Left click: play / pause")
	make_button("⏭", Vector2(x + 0.34, -0.135), Vector2(0.08, 0.05), _cmd.bind("next"), "Left click: next")
	var b := bridge()
	if b != null:
		b.media_changed.connect(func(_p): _refresh())
		b.media_removed.connect(func(_id): _refresh())
	_refresh()

func interact(player_id: int) -> void:
	_cmd(player_id, "play_pause")

func get_interact_prompt() -> String:
	return "Left click: play / pause"

func _cmd(player_id: int, cmd: String) -> void:
	if not is_local_player(player_id):
		return                          # chaque joueur commande SON lecteur
	var b := bridge()
	if b == null:
		return
	var p: Dictionary = b.current_player()
	if not p.is_empty():
		b.media_command(String(p["id"]), cmd)

static func fmt_time(us: int) -> String:
	var s := maxi(0, us / 1000000)
	return "%d:%02d" % [s / 60, s % 60]

func _refresh() -> void:
	var b := bridge()
	var p: Dictionary = b.current_player() if b != null else {}
	if p.is_empty():
		_title.text = "No media" if b != null else "Desktop bridge unavailable"
		_artist.text = ""
		_status.text = ""
		_time.text = ""
		set_bar(_bar, 0.0)
		_set_art("")
		return
	_title.text = String(p.get("title", "")) if String(p.get("title", "")) != "" else String(p.get("identity", ""))
	_artist.text = String(p.get("artist", ""))
	_status.text = "%s · %s" % [String(p.get("identity", "")), String(p.get("status", ""))]
	_play.set_text("⏸" if p.get("status") == "Playing" else "▶")
	_set_art(String(p.get("art", "")))
	_update_progress(p)

func _update_progress(p: Dictionary) -> void:
	var length := int(p.get("length", 0))
	var pos: int = b_pos(p)
	set_bar(_bar, float(pos) / float(length) if length > 0 else 0.0)
	_time.text = "%s / %s" % [fmt_time(pos), fmt_time(length)] if length > 0 else ""

func b_pos(p: Dictionary) -> int:
	return preload("res://scripts/main/desktop_bridge.gd").estimated_position(p)

func _process(delta: float) -> void:
	_tick -= delta
	if _tick > 0.0:
		return
	_tick = 0.25
	var b := bridge()
	if b != null:
		var p: Dictionary = b.current_player()
		if not p.is_empty() and p.get("status") == "Playing":
			_update_progress(p)

## Pochette : fichier local seulement (file://), image de taille raisonnable.
func _set_art(url: String) -> void:
	if url == _art_url:
		return
	_art_url = url
	_cover.texture = null
	if not url.begins_with("file://"):
		return
	var path := url.substr(7).uri_decode()
	if not path.get_extension().to_lower() in ["png", "jpg", "jpeg", "webp", "bmp"]:
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null or f.get_length() > ART_MAX_BYTES:
		return
	f.close()
	var img := Image.load_from_file(path)
	if img == null or img.is_empty():
		return
	img.resize(220, 220)
	_cover.texture = ImageTexture.create_from_image(img)
