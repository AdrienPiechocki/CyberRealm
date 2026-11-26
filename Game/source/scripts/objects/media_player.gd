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
	_refresh()
	connect_bridge()

func _on_bridge(b: Node) -> void:
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

## Pochette : fichier local (file://, y compris celles qu'a extraites le pont depuis une image intégrée data:, ex.
## mpv) ou adresse web (http(s)://, téléchargée une fois, taille limitée, gardée en cache pour tous les lecteurs du
## niveau). Le format est reconnu d'après le contenu (PNG, JPEG, WebP, BMP).
const WEB_TIMEOUT_SEC := 10.0
const WEB_CACHE_MAX := 32
static var _web_art: Dictionary = {}     # url -> Texture2D (null : échec, pas de nouvel essai)
var _http: HTTPRequest = null
var _pending_url := ""

func _set_art(url: String) -> void:
	if url == _art_url:
		return
	_art_url = url
	_cover.texture = null
	if url.begins_with("file://"):
		var path := url.substr(7).uri_decode()
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null or f.get_length() > ART_MAX_BYTES:
			return
		var bytes := f.get_buffer(f.get_length())
		f.close()
		_cover.texture = texture_from_bytes(bytes)
	elif url.begins_with("https://") or url.begins_with("http://"):
		_fetch(url)

func _fetch(url: String) -> void:
	if _web_art.has(url):
		_cover.texture = _web_art[url]
		return
	if _http == null:
		_http = HTTPRequest.new()
		_http.timeout = WEB_TIMEOUT_SEC
		_http.body_size_limit = ART_MAX_BYTES
		_http.max_redirects = 3
		add_child(_http)
		_http.request_completed.connect(_on_art_downloaded)
	_http.cancel_request()
	_pending_url = url
	if _http.request(url) != OK:
		_remember(url, null)

func _on_art_downloaded(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var tex: Texture2D = null
	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		tex = texture_from_bytes(body)
	_remember(_pending_url, tex)
	if _pending_url == _art_url:
		_cover.texture = tex

static func _remember(url: String, tex: Texture2D) -> void:
	if _web_art.size() >= WEB_CACHE_MAX:
		_web_art.erase(_web_art.keys()[0])
	_web_art[url] = tex

## Image (PNG, JPEG, WebP, BMP) reconnue par ses premiers octets, réduite pour la pochette ; null sinon.
static func texture_from_bytes(b: PackedByteArray) -> Texture2D:
	if b.size() < 12 or b.size() > ART_MAX_BYTES:
		return null
	var img := Image.new()
	var err := ERR_FILE_UNRECOGNIZED
	if b[0] == 0x89 and b[1] == 0x50 and b[2] == 0x4E and b[3] == 0x47:
		err = img.load_png_from_buffer(b)
	elif b[0] == 0xFF and b[1] == 0xD8:
		err = img.load_jpg_from_buffer(b)
	elif b.slice(0, 4).get_string_from_ascii() == "RIFF" and b.slice(8, 12).get_string_from_ascii() == "WEBP":
		err = img.load_webp_from_buffer(b)
	elif b[0] == 0x42 and b[1] == 0x4D:
		err = img.load_bmp_from_buffer(b)
	if err != OK or img.is_empty():
		return null
	img.resize(220, 220)
	return ImageTexture.create_from_image(img)
