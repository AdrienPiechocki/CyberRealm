extends RefCounted
## Sources micro de PipeWire (chat vocal) : liste pour le menu Multiplayer, présence du module echo-cancel.
##
## Lecture seule : `pw-dump` (paquet pipewire), jamais de modification de l'état audio. Appel bloquant de quelques
## dizaines de ms : fait à l'ouverture de la page ou du micro, jamais à chaque frame. Résultat gardé CACHE_MSEC.

const ECHO_CANCEL_SOURCE := "echo-cancel-source"   # nœud du module echo-cancel de PipeWire (nom par défaut)
const CACHE_MSEC := 5000

static var _cache: Array = []
static var _cache_msec := -100000

## [{name, description, default}] des sources audio (micros, sources virtuelles), la source par défaut en tête.
static func list_sources(force := false) -> Array:
	var now := Time.get_ticks_msec()
	if not force and now - _cache_msec < CACHE_MSEC:
		return _cache
	var out: Array = []
	var code := OS.execute("pw-dump", [], out)
	_cache = parse_pw_dump(String(out[0]) if code == 0 and not out.is_empty() else "")
	_cache_msec = now
	return _cache

static func has_source(node_name: String, sources: Array) -> bool:
	for s in sources:
		if String(s["name"]) == node_name:
			return true
	return false

static func echo_cancel_available(sources: Array) -> bool:
	return has_source(ECHO_CANCEL_SOURCE, sources)

## Cible du micro : la source echo-cancel si demandée ET présente, sinon le micro choisi s'il existe encore, sinon
## "" (source par défaut de PipeWire).
static func voice_target(echo_cancel: bool, chosen: String, sources: Array) -> String:
	if echo_cancel and echo_cancel_available(sources):
		return ECHO_CANCEL_SOURCE
	if chosen != "" and has_source(chosen, sources):
		return chosen
	return ""

## Logique pure (testée) : sources de la sortie JSON de pw-dump.
static func parse_pw_dump(text: String) -> Array:
	var json := JSON.new()
	if text == "" or json.parse(text) != OK:      # (pas JSON.parse_string : il journalise une erreur)
		return []
	var v: Variant = json.data
	if not (v is Array):
		return []
	var default_name := ""
	var sources: Array = []
	for o in v:
		if not (o is Dictionary):
			continue
		var type := String(o.get("type", ""))
		if type.ends_with("Metadata"):
			var props: Dictionary = (o.get("props", {}) as Dictionary) if o.get("props") is Dictionary else {}
			if String(props.get("metadata.name", "")) != "default":
				continue
			for e in o.get("metadata", []):
				if e is Dictionary and String(e.get("key", "")) == "default.audio.source" and e.get("value") is Dictionary:
					default_name = String((e["value"] as Dictionary).get("name", ""))
		elif type.ends_with("Node"):
			var info: Variant = o.get("info")
			var props: Variant = (info as Dictionary).get("props") if info is Dictionary else null
			if not (props is Dictionary):
				continue
			var mc := String(props.get("media.class", ""))
			if mc != "Audio/Source" and mc != "Audio/Source/Virtual":
				continue
			var nm := String(props.get("node.name", ""))
			if nm == "":
				continue
			var desc := String(props.get("node.description", props.get("node.nick", nm)))
			sources.append({"name": nm, "description": desc, "default": false})
	for s in sources:
		s["default"] = String(s["name"]) == default_name
	sources.sort_custom(func(a, b): return bool(a["default"]) and not bool(b["default"]))
	return sources
