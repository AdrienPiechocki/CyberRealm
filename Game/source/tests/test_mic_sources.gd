extends Node
## Sources micro du chat vocal (scripts/main/mic_sources.gd) : lecture de pw-dump, cible du micro.

const Runner = preload("res://tests/runner.gd")
const MicSources := preload("res://scripts/main/mic_sources.gd")

const DUMP := """[
 {"id": 30, "type": "PipeWire:Interface:Metadata", "props": {"metadata.name": "default"},
  "metadata": [{"subject": 0, "key": "default.audio.source", "type": "Spa:String:JSON",
                "value": {"name": "alsa_input.mic2"}}]},
 {"id": 51, "type": "PipeWire:Interface:Node", "info": {"props": {"media.class": "Audio/Source",
  "node.name": "alsa_input.mic1", "node.description": "Digital Microphone"}}},
 {"id": 70, "type": "PipeWire:Interface:Node", "info": {"props": {"media.class": "Audio/Source",
  "node.name": "alsa_input.mic2", "node.description": "Stereo Microphone"}}},
 {"id": 71, "type": "PipeWire:Interface:Node", "info": {"props": {"media.class": "Stream/Input/Audio",
  "node.name": "cyberrealm-voice"}}},
 {"id": 105, "type": "PipeWire:Interface:Node", "info": {"props": {"media.class": "Audio/Sink",
  "node.name": "alsa_output.headphones"}}}
]"""

func test_sources_listed_default_first():
	var l := MicSources.parse_pw_dump(DUMP)
	var names := l.map(func(s): return s["name"])
	var r: Variant = Runner.assert_eq(names, ["alsa_input.mic2", "alsa_input.mic1"], "sources seulement, défaut en tête")
	if r is String: return r
	return Runner.assert_true(bool(l[0]["default"]) and String(l[0]["description"]) == "Stereo Microphone", "défaut marqué")

func test_echo_cancel_missing_falls_back_to_chosen_mic():
	var l := MicSources.parse_pw_dump(DUMP)
	var r: Variant = Runner.assert_eq(MicSources.voice_target(true, "alsa_input.mic1", l), "alsa_input.mic1",
			"écho demandé, module absent : micro choisi")
	if r is String: return r
	r = Runner.assert_eq(MicSources.voice_target(true, "", l), "", "écho absent, pas de choix : source par défaut")
	if r is String: return r
	return Runner.assert_eq(MicSources.voice_target(false, "unplugged", l), "", "micro débranché : source par défaut")

func test_echo_cancel_used_when_present():
	var l := MicSources.parse_pw_dump(DUMP)
	l.append({"name": MicSources.ECHO_CANCEL_SOURCE, "description": "Echo-Cancel Source", "default": false})
	return Runner.assert_eq(MicSources.voice_target(true, "alsa_input.mic1", l), MicSources.ECHO_CANCEL_SOURCE,
			"module présent : source echo-cancel")

func test_bad_dump_gives_no_source():
	return Runner.assert_eq(MicSources.parse_pw_dump("not json"), [], "sortie illisible : aucune source")
