extends Node
## S5 audio layer, autoload "Sfx". Plays generated sound effects and ambience (data/audio.json; placeholders,
## OQ-AUDIO-MIX / OQ-AUDIO-VOICES). It only listens: gameplay never calls it, and it adds nothing to gameplay
## nodes. Buses Master / SFX / Ambience / Music are created here when the project has none of that name; Music
## and the announcer are empty named slots (data "music_slots", "announcer_slots").
## Positional one-shots come from a fixed pool (voices.max_3d): when every voice is busy, a new sound that is
## nearer to the listener replaces the farthest one, otherwise it is dropped. Headless runs use the dummy
## audio driver: the players exist and "play", nothing is heard.

const PATH := "res://data/audio.json"

var cfg: Dictionary = {}
var enabled := true
## Every sound started since the last clear_log(): [{id, bus, positional, at, stream}] (for the tests).
var played: Array[Dictionary] = []
var music: AudioStreamPlayer
var announcer: AudioStreamPlayer

var _streams := {}
## True under the dummy audio driver (headless runs): voices are assigned and timed as usual but never
## started, so nothing is left playing when the process exits. Tests may set it to compare.
var silent := false
var _pool: Array[AudioStreamPlayer3D] = []
var _pool_id: Array[String] = []
var _pool_until := PackedInt64Array()  # ms tick at which each positional voice's sound ends
var _ui: Array[AudioStreamPlayer] = []
var _ui_until := PackedInt64Array()
var _last_play := {}  # id -> time in ms
var _rng := RandomNumberGenerator.new()
var _loops: Array = []  # looping sources handed out by make_loop (freed ones are pruned there)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	cfg = DataRegistry.new().load_file(PATH)
	silent = AudioServer.get_driver_name() == "Dummy"
	_ensure_buses()
	for i in int(cfg["voices"]["max_3d"]):
		var voice := AudioStreamPlayer3D.new()
		voice.name = "Voice3D_%d" % i
		add_child(voice)
		_pool.append(voice)
		_pool_id.append("")
		_pool_until.append(0)
	for i in int(cfg["voices"]["max_ui"]):
		var voice := AudioStreamPlayer.new()
		voice.name = "VoiceUi_%d" % i
		add_child(voice)
		_ui.append(voice)
		_ui_until.append(0)
	music = AudioStreamPlayer.new()
	music.name = "MusicSlot"
	music.bus = &"Music"
	add_child(music)
	announcer = AudioStreamPlayer.new()
	announcer.name = "AnnouncerSlot"
	announcer.bus = &"SFX"
	add_child(announcer)
	_rng.seed = 1
	get_tree().node_added.connect(_on_node_added)


func _ensure_buses() -> void:
	var buses: Dictionary = cfg["buses"]
	for bus_name: String in buses:
		if bus_name.begins_with("_"):
			continue
		if AudioServer.get_bus_index(bus_name) < 0:
			AudioServer.add_bus()
			var index := AudioServer.bus_count - 1
			AudioServer.set_bus_name(index, bus_name)
			AudioServer.set_bus_send(index, &"Master")
			AudioServer.set_bus_volume_db(index, float(buses[bus_name]["volume_db"]))


## A sound's settings: data "defaults" with the sound's own keys on top. {} for an unknown id.
func sound(id: String) -> Dictionary:
	var sounds: Dictionary = cfg["sounds"]
	if not sounds.has(id):
		return {}
	return (cfg["defaults"] as Dictionary).merged(sounds[id], true)


## The stream of a sound id (cached; a looping sound loops over its whole length). null for an unknown id.
func stream(id: String) -> AudioStream:
	if _streams.has(id):
		return _streams[id]
	var s := sound(id)
	var loaded: AudioStream = null
	if not s.is_empty():
		var path := String(cfg["dir"]) + String(s.get("file", id + ".wav"))
		if ResourceLoader.exists(path):
			loaded = load(path) as AudioStream
			if loaded is AudioStreamWAV and bool(s["loop"]):
				var wav := (loaded as AudioStreamWAV).duplicate() as AudioStreamWAV
				wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
				wav.loop_begin = 0
				wav.loop_end = int(wav.get_length() * wav.mix_rate)
				loaded = wav
	_streams[id] = loaded
	return loaded


## The stream path of a music or announcer slot ("" = the slot is empty, as shipped).
func slot(kind: String, slot_name: String) -> String:
	return String((cfg.get(kind + "_slots", {}) as Dictionary).get(slot_name, ""))


## Plays an announcer slot if a stream has been put into it; does nothing for an empty slot.
func announce(slot_name: String) -> bool:
	var path := slot("announcer", slot_name)
	if path == "" or not ResourceLoader.exists(path):
		return false
	announcer.stream = load(path)
	announcer.play()
	return true


func clear_log() -> void:
	played.clear()


## Ids of the sounds the positional voices are busy with right now (one entry per busy voice).
func busy_voices() -> Array[String]:
	var out: Array[String] = []
	var now := Time.get_ticks_msec()
	for i in _pool.size():
		if now < _pool_until[i]:
			out.append(_pool_id[i])
	return out


func _allowed(id: String, s: Dictionary) -> bool:
	if not enabled or s.is_empty():
		return false
	var now := Time.get_ticks_msec()
	if _last_play.has(id) and now - int(_last_play[id]) < int(float(s["min_interval_s"]) * 1000.0):
		return false
	_last_play[id] = now
	return true


func _listener_position() -> Vector3:
	var viewport := get_viewport()
	var camera := viewport.get_camera_3d() if viewport != null else null
	return camera.global_position if camera != null else Vector3.ZERO


func _pitch(s: Dictionary) -> float:
	var jitter := float(s["pitch_jitter"])
	return 1.0 + _rng.randf_range(-jitter, jitter)


## Plays a positional one-shot at a world position. Returns the voice, or null when it was not played
## (unknown id, retriggered too soon, polyphony cap reached, or every voice busy with nearer sounds).
func play_at(id: String, at: Vector3, volume_offset_db: float = 0.0) -> AudioStreamPlayer3D:
	var s := sound(id)
	if not _allowed(id, s):
		return null
	var audio := stream(id)
	if audio == null:
		return null
	var listener := _listener_position()
	var free_voice := -1
	var same := 0
	var farthest := -1
	var farthest_d := at.distance_squared_to(listener)
	var now := Time.get_ticks_msec()
	for i in _pool.size():
		if now >= _pool_until[i]:
			if free_voice < 0:
				free_voice = i
			continue
		if _pool_id[i] == id:
			same += 1
		var d := _pool[i].global_position.distance_squared_to(listener)
		if d > farthest_d:
			farthest_d = d
			farthest = i
	if same >= int(s["max_polyphony"]):
		return null
	var pick := free_voice if free_voice >= 0 else farthest
	if pick < 0:
		return null
	var voice := _pool[pick]
	voice.stop()
	voice.stream = audio
	voice.bus = StringName(String(s["bus"]))
	voice.volume_db = float(s["volume_db"]) + volume_offset_db
	voice.unit_size = float(s["unit_size"])
	voice.max_distance = float(s["max_distance_m"])
	voice.pitch_scale = _pitch(s)
	voice.global_position = at
	if not silent:
		voice.play()
	_pool_id[pick] = id
	_pool_until[pick] = now + int(audio.get_length() / voice.pitch_scale * 1000.0)
	played.append({"id": id, "bus": String(voice.bus), "positional": true, "at": at, "stream": audio})
	return voice


## Plays a non-positional one-shot (UI, hit markers, horns).
func play_ui(id: String, volume_offset_db: float = 0.0) -> AudioStreamPlayer:
	var s := sound(id)
	if not _allowed(id, s):
		return null
	var audio := stream(id)
	if audio == null:
		return null
	var now := Time.get_ticks_msec()
	var index := 0  # every voice busy: the one that ends first is replaced
	for i in _ui.size():
		if _ui_until[i] < _ui_until[index]:
			index = i
	var pick := _ui[index]
	pick.stop()
	pick.stream = audio
	pick.bus = StringName(String(s["bus"]))
	pick.volume_db = float(s["volume_db"]) + volume_offset_db
	pick.pitch_scale = _pitch(s)
	if not silent:
		pick.play()
	_ui_until[index] = now + int(audio.get_length() / pick.pitch_scale * 1000.0)
	played.append({"id": id, "bus": String(pick.bus), "positional": false, "at": Vector3.ZERO, "stream": audio})
	return pick


## A looping source owned by `parent` (freed with it). Positional when `positional`; null past voices.max_loops
## or for an unknown id. The caller starts and stops it (play() / stop()) or just leaves it running.
func make_loop(id: String, parent: Node, positional: bool = true, autoplay: bool = true) -> Node:
	var s := sound(id)
	var audio := stream(id)
	if s.is_empty() or audio == null or parent == null:
		return null
	var alive: Array = []
	for candidate: Variant in _loops:
		if is_instance_valid(candidate):
			alive.append(candidate)
	_loops = alive
	if _loops.size() >= int(cfg["voices"]["max_loops"]):
		return null
	var node: Node
	if positional:
		var p := AudioStreamPlayer3D.new()
		p.stream = audio
		p.bus = StringName(String(s["bus"]))
		p.volume_db = float(s["volume_db"])
		p.unit_size = float(s["unit_size"])
		p.max_distance = float(s["max_distance_m"])
		node = p
	else:
		var p := AudioStreamPlayer.new()
		p.stream = audio
		p.bus = StringName(String(s["bus"]))
		p.volume_db = float(s["volume_db"])
		node = p
	node.name = "Loop_" + id
	node.set_meta(&"sound_id", id)
	parent.add_child(node)
	_loops.append(node)
	if autoplay and enabled and not silent:
		node.call("play")
	played.append({"id": id, "bus": String(s["bus"]), "positional": positional, "at": Vector3.ZERO, "stream": audio})
	return node


# ---------- UI clicks: every button in every scene, without touching the UI scripts ----------

func _on_node_added(node: Node) -> void:
	if node is BaseButton:
		var button := node as BaseButton
		# The touch HUD's fire, aim and stick buttons are game controls, not menu buttons: no click for them.
		var skip: Array = cfg["hooks"]["ui_skip_under"]
		var up := node.get_parent()
		while up != null:
			if skip.has(String(up.name)):
				return
			up = up.get_parent()
		if not button.pressed.is_connected(_on_button_pressed):
			button.pressed.connect(_on_button_pressed.bind(button))


func _on_button_pressed(button: BaseButton) -> void:
	var hooks: Dictionary = cfg["hooks"]
	if not is_instance_valid(button):
		return
	if button.toggle_mode:
		play_ui(String(hooks["ui_toggled"]))
		return
	var label := String(button.get("text")) if "text" in button else ""
	for word: String in hooks["ui_back_names"]:
		if label.containsn(word):
			play_ui(String(hooks["ui_back"]))
			return
	play_ui(String(hooks["ui_pressed"]))
