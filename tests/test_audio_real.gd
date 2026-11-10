extends "res://tests/test_case.gd"
## M2 audio loader: sounds may carry several recorded takes ("files", any AudioStream type), loops loop per stream
## type, ambience layers are lists per look, far shots per weapon and the listener's sprint foley. Every
## expectation is read from data/audio.json, so these hold on the generated WAVs today and on the real files later.


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _sfx() -> Node:
	return _tree().root.get_node_or_null("Sfx")


func _played(id: String) -> Array:
	return _sfx().played.filter(func(entry: Dictionary) -> bool: return entry["id"] == id)


func _pawn() -> Pawn:
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	_tree().root.add_child(pawn)
	pawn.set_physics_process(false)
	return pawn


func _free_voices() -> void:
	var sfx := _sfx()
	for i in sfx._pool_until.size():
		sfx._pool_until[i] = 0
	sfx._last_play.clear()


## Whether a stream loops, per stream type: a WAV by its loop_mode, Ogg Vorbis / MP3 by their loop property.
static func _loops(stream: AudioStream) -> bool:
	if stream is AudioStreamWAV:
		return (stream as AudioStreamWAV).loop_mode != AudioStreamWAV.LOOP_DISABLED
	return "loop" in stream and bool(stream.get("loop"))


## A data layer as a list of ids (a plain String is a one-item list).
static func _ids(layer: Variant) -> Array:
	if layer is String:
		return [layer] if String(layer) != "" else []
	return (layer as Array).duplicate() if layer is Array else []


func test_every_sound_resolves_to_existing_loadable_takes() -> void:
	var sfx := _sfx()
	var checked := 0
	for id: String in sfx.cfg["sounds"]:
		var paths: PackedStringArray = sfx.paths(id)
		assert_true(not paths.is_empty(), "sound %s resolves to at least one file" % id)
		for path in paths:
			checked += 1
			assert_true(ResourceLoader.exists(path), "sound %s: %s exists" % [id, path])
			var stream: AudioStream = load(path) as AudioStream if ResourceLoader.exists(path) else null
			assert_true(stream != null and stream.get_length() > 0.03, "sound %s: %s loads as a real AudioStream" % [id, path])
	assert_eq(sfx.paths("no_such_sound").size(), 0, "an unknown id has no files")
	assert_true(sfx.stream("no_such_sound") == null, "an unknown id has no stream")
	print("AUDIO_TAKES files=%d" % checked)


func test_recorded_takes_are_third_party_oggs_and_some_sound_has_several() -> void:
	var sfx := _sfx()
	var several := 0
	for id: String in sfx.cfg["sounds"]:
		var files: Array = (sfx.cfg["sounds"][id] as Dictionary).get("files", [])
		if files.size() > 1:
			several += 1
		for path: Variant in files:
			assert_true(String(path).begins_with("res://assets/third_party/audio/") and String(path).ends_with(".ogg"), "sound %s: take %s is a third-party .ogg" % [id, path])
	assert_true(several > 0, "at least one sound has several recorded takes (%d)" % several)


func _files_under(dir_path: String, out: Array[String]) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for f in dir.get_files():
		if not (f.ends_with(".import") or f.ends_with(".uid")):
			out.append(dir_path.path_join(f))
	for sub in dir.get_directories():
		_files_under(dir_path.path_join(sub), out)


func test_every_third_party_audio_file_is_catalogued_cc0() -> void:
	var files: Array[String] = []
	if DirAccess.dir_exists_absolute("res://assets/third_party/audio"):
		_files_under("res://assets/third_party/audio", files)
	var catalog: Dictionary = DataRegistry.new().load_file("res://data/asset_catalog.json")
	var licence_of := {}
	for row: Dictionary in catalog["assets"]:
		licence_of[String(row.get("path", ""))] = String(row.get("licence", ""))
	for path in files:
		assert_true(licence_of.has(path), "%s has a row in data/asset_catalog.json" % path)
		assert_eq(licence_of.get(path, ""), "CC0-1.0", "%s is CC0-1.0" % path)
	print("AUDIO_THIRD_PARTY files_checked=%d" % files.size())


func test_loops_loop_on_every_take_and_one_shots_never_do() -> void:
	var sfx := _sfx()
	for id: String in sfx.cfg["sounds"]:
		var loop := bool(sfx.sound(id)["loop"])
		for path in sfx.paths(id):
			var take: AudioStream = sfx._take(path, loop)
			if take == null:
				continue  # a missing file is the first test's failure
			assert_eq(_loops(take), loop, "%s: the take %s loops = %s" % [id, path, loop])
			if loop and not (take is AudioStreamWAV):
				assert_true(not _loops(load(path) as AudioStream), "%s: the cached resource of %s is left a one-shot" % [id, path])
		for take: AudioStream in sfx.streams(id):
			assert_eq(_loops(take), loop, "%s: every take from streams() loops = %s" % [id, loop])


func test_every_surface_the_game_reports_has_known_step_sounds() -> void:
	var sfx := _sfx()
	var steps: Dictionary = sfx.cfg["footsteps"]
	var surfaces: Array = ["paving", "grass", "earth"]  # what GroundPaint.surface_at returns
	surfaces.append_array((steps["piece_surface"] as Dictionary).values())
	surfaces.append(steps["cover_surface"])
	for surface: Variant in surfaces:
		var list: Variant = (steps["surfaces"] as Dictionary).get(String(surface))
		assert_true(list is Array and not (list as Array).is_empty(), "surface %s has footstep sounds" % surface)
		if list is Array:
			for id: Variant in list:
				assert_true(not sfx.sound(String(id)).is_empty(), "surface %s: %s is a known sound" % [surface, id])


## A MatchAudio under a plain Node3D pair: _match() finds no Director, so only show_look works.
func _match_audio() -> Array:
	var root := Node3D.new()
	var env := Node3D.new()
	root.add_child(env)
	var audio := MatchAudio.new()
	env.add_child(audio)
	_tree().root.add_child(root)
	return [root, audio]


func _expected_layers(look: Dictionary) -> Array[String]:
	var amb: Dictionary = _sfx().cfg["ambience"]
	var out: Array[String] = []
	var lists := [_ids(amb["base_loop"]), _ids((amb["by_weather"] as Dictionary).get(look["weather"], [])), _ids((amb["by_variant"] as Dictionary).get(look["id"], []))]
	for list: Array in lists:
		for id: Variant in list:
			if not out.has(String(id)):
				out.append(String(id))
	return out


func test_each_look_starts_exactly_its_data_layers() -> void:
	var sfx := _sfx()
	var pair := _match_audio()
	var audio := pair[1] as MatchAudio
	var amb: Dictionary = sfx.cfg["ambience"]
	var started := {}
	for look_id in ["dusk", "night", "storm"]:
		var look := MatchLook.resolved(look_id)
		assert_eq(String(look["id"]), look_id, "the resolver builds the %s look" % look_id)
		var want := _expected_layers(look)
		assert_true(not want.is_empty(), "%s has an ambience bed" % look_id)
		sfx.clear_log()
		audio.show_look(look, null)
		var got: Array[String] = []
		for entry: Dictionary in sfx.played:
			got.append(String(entry["id"]))
			assert_true(not bool(entry["positional"]), "%s: %s is non-positional" % [look_id, entry["id"]])
			assert_eq(String(entry["bus"]), String(sfx.sound(String(entry["id"]))["bus"]), "%s: %s on its data bus" % [look_id, entry["id"]])
			assert_true(entry["stream"] != null and _loops(entry["stream"]), "%s: %s has a looping stream" % [look_id, entry["id"]])
		assert_eq(got, want, "%s starts exactly its data layers, once each" % look_id)
		assert_eq(audio._ambient_loops.size(), want.size(), "%s holds one loop per layer" % look_id)
		started[look_id] = got
	# Night carries every night layer and no dusk-only layer (vacuous while dusk lists none of its own).
	for id: Variant in _ids((amb["by_variant"] as Dictionary).get("night", [])):
		assert_true((started["night"] as Array).has(String(id)), "night starts its layer %s" % id)
	var night_wants := _expected_layers(MatchLook.resolved("night"))
	for id: Variant in _ids((amb["by_variant"] as Dictionary).get("dusk", [])):
		if not night_wants.has(String(id)):
			assert_true(not (started["night"] as Array).has(String(id)), "night does not start the dusk layer %s" % id)
	(pair[0] as Node).queue_free()
	await _tree().process_frame


func _valid_loops() -> int:
	var n := 0
	for loop: Variant in _sfx()._loops:
		if is_instance_valid(loop):
			n += 1
	return n


func test_the_loop_budget_holds_through_a_look_switch() -> void:
	var sfx := _sfx()
	await _tree().process_frame  # loops freed by earlier tests are gone
	var before := _valid_loops()
	var pair := _match_audio()
	var root := pair[0] as Node3D
	var audio := pair[1] as MatchAudio
	var hooks: Dictionary = sfx.cfg["hooks"]
	var amb: Dictionary = sfx.cfg["ambience"]
	var cap := int(sfx.cfg["voices"]["max_loops"])
	var most := "dusk"
	for look_id in ["dusk", "night", "storm"]:
		if audio.look_layers(MatchLook.resolved(look_id)).size() > audio.look_layers(MatchLook.resolved(most)).size():
			most = look_id
	# One frame, no await: the first look's loops are queue_freed by the switch but still count.
	audio.show_look(MatchLook.resolved(most), null)
	var look_switch := _valid_loops() - before
	audio.show_look(MatchLook.resolved("storm"), null)
	var storm := _valid_loops() - before - look_switch
	var holder := Node3D.new()
	root.add_child(holder)
	var braziers: int = (DataRegistry.new().load_file("res://data/art_world.json")["braziers"]["positions"] as Array).size()
	var made := 0
	for i in braziers:
		made += 1 if sfx.make_loop(String(amb["brazier_loop"]), holder, true) != null else 0
	assert_eq(made, braziers, "every brazier gets its loop")
	var others: Array = [["zone_wall_loop", true], ["zone_outside_loop", false], ["carrier_loop", true], ["falling_loop", false]]
	for i in 4:
		others.append(["reviving_loop", true])
	for other: Array in others:
		var loop: Node = sfx.make_loop(String(hooks[other[0]]), holder, bool(other[1]))
		assert_true(loop != null, "the %s loop is made inside the budget" % other[0])
	var total := _valid_loops()
	assert_true(total <= cap, "valid loops stay within voices.max_loops (%d of %d)" % [total, cap])
	print("AUDIO_LOOPS look_switch=%d storm=%d braziers=%d other=%d total=%d cap=%d" % [look_switch, storm, braziers, others.size(), total, cap])
	root.queue_free()
	await _tree().process_frame
	assert_eq(_valid_loops(), before, "every loop made here is freed")


func test_a_far_shot_plays_the_weapons_far_report_or_the_shared_one() -> void:
	var sfx := _sfx()
	var hooks: Dictionary = sfx.cfg["hooks"]
	var had_key := hooks.has("shot_far_by_weapon")
	var original: Variant = hooks.get("shot_far_by_weapon")
	var far_by: Dictionary = hooks.get("shot_far_by_weapon", {})
	for id: Variant in far_by.values():
		assert_true(not sfx.sound(String(id)).is_empty(), "shot_far_by_weapon names a known sound (%s)" % id)
	# Every weapon with its own report also has its own far report, a different sound.
	for weapon: String in hooks["shot_by_weapon"]:
		assert_true(far_by.has(weapon), "weapon %s has a far report in shot_far_by_weapon" % weapon)
		var own_far := String(far_by.get(weapon, ""))
		assert_true(not sfx.sound(own_far).is_empty(), "weapon %s: its far report %s is a known sound" % [weapon, own_far])
		assert_true(own_far != String(hooks["shot_by_weapon"][weapon]), "weapon %s: the far report differs from the near one" % weapon)
	var pawn := _pawn()
	await _tree().process_frame  # the shot visual is bound deferred
	var weapon_id := pawn.loadout.get_active().def.id
	var near_id := String((hooks["shot_by_weapon"] as Dictionary).get(weapon_id, hooks["shot_default"]))
	var far_id := String(hooks["shot_far"])
	var stand_in := ""
	for id: String in sfx.cfg["sounds"]:
		if id != far_id and id != near_id and not bool(sfx.sound(id)["loop"]):
			stand_in = id
			break
	var range_m := float(hooks["shot_far_from_m"])
	var far_from := Vector3(0, 1.4, -(range_m + 30.0))
	var far_to := far_from + Vector3(0, 0, -20)
	# (a) a listed weapon plays its own far report.
	hooks["shot_far_by_weapon"] = {weapon_id: stand_in}
	sfx.clear_log()
	_free_voices()
	pawn.shot_fx.show_shot(far_from, far_to)
	assert_eq(_played(stand_in).size(), 1, "a listed weapon far away plays its far report (%s)" % stand_in)
	assert_eq(_played(far_id).size(), 0, "and not the shared far shot")
	# (b) an unlisted weapon falls back to the shared far shot.
	var others := ((original as Dictionary).duplicate() if original is Dictionary else {}) as Dictionary
	others.erase(weapon_id)
	hooks["shot_far_by_weapon"] = others
	sfx.clear_log()
	_free_voices()
	pawn.shot_fx.show_shot(far_from, far_to)
	assert_eq(_played(far_id).size(), 1, "an unlisted weapon far away plays the shared far shot")
	# A missing key works as an empty one.
	hooks.erase("shot_far_by_weapon")
	sfx.clear_log()
	_free_voices()
	pawn.shot_fx.show_shot(far_from, far_to)
	assert_eq(_played(far_id).size(), 1, "without shot_far_by_weapon the shared far shot plays")
	# (d) the same shot nearer than the distance plays the weapon's near report.
	hooks["shot_far_by_weapon"] = {weapon_id: stand_in}
	sfx.clear_log()
	_free_voices()
	pawn.shot_fx.show_shot(Vector3(0, 1.4, -10), Vector3(0, 1.4, -30))
	assert_eq(_played(near_id).size(), 1, "a near shot plays the weapon's report (%s)" % near_id)
	assert_eq(_played(stand_in).size() + _played(far_id).size(), 0, "and no far report")
	if had_key:
		hooks["shot_far_by_weapon"] = original
	else:
		hooks.erase("shot_far_by_weapon")
	assert_true(hooks.get("shot_far_by_weapon") == original, "the data is restored")
	sfx.clear_log()
	_free_voices()
	pawn.free()


func _steps(audio: PawnAudio, foley_id: String, count: int) -> int:
	var sfx := _sfx()
	sfx.clear_log()
	for i in count:
		_free_voices()
		audio.play_step(Vector3(i * 3.0, 0.0, 5.0))
	return _played(foley_id).size()


func test_the_listeners_sprint_adds_one_foley_per_step() -> void:
	var sfx := _sfx()
	var steps: Dictionary = sfx.cfg["footsteps"]
	var had_foley := steps.has("foley")
	var foley: Dictionary = steps.get("foley", {"sprint_factor_above": 1.17, "sound": ""})
	var old_sound: Variant = foley.get("sound")
	var threshold := float(foley["sprint_factor_above"])
	var step_ids: Array = []
	for surface: String in steps["surfaces"]:
		step_ids.append_array(steps["surfaces"][surface])
	var foley_id := ""
	for id: String in sfx.cfg["sounds"]:
		if not step_ids.has(id) and not bool(sfx.sound(id)["loop"]):
			foley_id = id
			break
	foley["sound"] = foley_id
	steps["foley"] = foley
	var pawn := _pawn()
	var audio := pawn.get_node("Audio") as PawnAudio
	var rig := Node3D.new()  # what _is_listener() looks for; no camera, so the listener stays at the origin
	rig.name = "CameraRig"
	pawn.add_child(rig)
	pawn.sprint_factor = threshold + 0.1
	assert_eq(_steps(audio, foley_id, 5), 5, "the listener's sprinting steps play one foley each")
	pawn.sprint_factor = maxf(1.0, threshold - 0.1)
	assert_eq(_steps(audio, foley_id, 5), 0, "below the threshold no foley")
	rig.free()
	pawn.sprint_factor = threshold + 0.1
	assert_eq(_steps(audio, foley_id, 5), 0, "a pawn without a CameraRig never plays the foley")
	foley["sound"] = ""
	var listener := Node3D.new()
	listener.name = "CameraRig"
	pawn.add_child(listener)
	assert_eq(audio.step_foley(), "", "an empty foley sound plays nothing")
	foley["sound"] = "no_such_sound"
	assert_eq(audio.step_foley(), "", "an unknown foley sound plays nothing")
	if had_foley:
		foley["sound"] = old_sound
	else:
		steps.erase("foley")
	sfx.clear_log()
	_free_voices()
	pawn.free()


func test_a_sound_with_two_takes_plays_both() -> void:
	var sfx := _sfx()
	var id := "step_earth_1"
	var own: Dictionary = sfx.cfg["sounds"][id]
	var had_files := own.has("files")
	var old_files: Variant = own.get("files")
	var dir := String(sfx.cfg["dir"])
	var a := dir + "step_earth_1.wav"
	var b := dir + "step_earth_2.wav"
	own["files"] = [a, b]
	assert_eq(sfx.paths(id), PackedStringArray([a, b]), "paths() returns the listed takes")
	assert_eq(sfx.streams(id).size(), 2, "streams() returns both takes")
	sfx.clear_log()
	for i in 40:
		_free_voices()
		sfx.play_at(id, Vector3(i * 2.0, 0.0, -7.0))
	var seen := {}
	for entry: Dictionary in _played(id):
		seen[entry["stream"]] = true
	assert_eq(_played(id).size(), 40, "every play started")
	assert_true(seen.has(load(a)) and seen.has(load(b)), "both takes are heard (%d distinct streams)" % seen.size())
	if had_files:
		own["files"] = old_files
	else:
		own.erase("files")
	assert_eq(sfx.paths(id), PackedStringArray([dir + id + ".wav"]), "the data is restored")
	sfx.clear_log()
	_free_voices()
