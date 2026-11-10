extends "res://tests/test_case.gd"
## S5: the audio layer (scripts/audio/, data/audio.json). Headless runs use the dummy audio driver, so these
## check wiring, not what is heard: every hooked signal starts a player with a non-empty stream on the right
## bus, the caps hold, footstep surfaces come from the visual side, and music and the announcer stay empty.


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _sfx() -> Node:
	return _tree().root.get_node_or_null("Sfx")


func _played(id: String) -> Array:
	return _sfx().played.filter(func(entry: Dictionary) -> bool: return entry["id"] == id)


func _stream_ok(entry: Dictionary) -> bool:
	var stream := entry["stream"] as AudioStreamWAV
	return stream != null and stream.data.size() > 64 and stream.get_length() > 0.03


func _pawn() -> Pawn:
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	_tree().root.add_child(pawn)
	pawn.set_physics_process(false)
	return pawn


func test_data_is_placeholder_and_every_sound_has_a_generated_file() -> void:
	var cfg: Dictionary = DataRegistry.new().load_file("res://data/audio.json")
	assert_true(bool(cfg["_placeholder"]) and String(cfg["_todo"]).contains("OQ-AUDIO-MIX") and String(cfg["_todo"]).contains("OQ-AUDIO-VOICE"), "audio numbers are placeholders with OQ ids")
	var sfx := _sfx()
	assert_true(sfx != null, "the Sfx autoload exists")
	for id: String in cfg["sounds"]:
		var stream := sfx.stream(id) as AudioStreamWAV
		# The import may compress the samples, so "non-empty" is some data and a real length.
		assert_true(stream != null and stream.data.size() > 64 and stream.get_length() > 0.03, "sound %s has a non-empty generated stream" % id)
		assert_true(String(cfg["dir"]).begins_with("res://assets/generated/audio"), "sounds are generated assets")
		var settings: Dictionary = sfx.sound(id)
		assert_true(AudioServer.get_bus_index(String(settings["bus"])) >= 0, "sound %s names an existing bus" % id)
		if stream != null:
			assert_eq(stream.loop_mode != AudioStreamWAV.LOOP_DISABLED, bool(settings["loop"]), "loop flag of " + id)
	# Every hook names a known sound.
	for key: String in cfg["hooks"]:
		var value: Variant = cfg["hooks"][key]
		var ids: Array = []
		if value is String and not key.begins_with("_"):
			ids = [value]
		elif value is Dictionary:
			ids = (value as Dictionary).values()
		for id in ids:
			assert_true((cfg["sounds"] as Dictionary).has(id), "hook %s names a known sound (%s)" % [key, id])
	for surface: String in cfg["footsteps"]["surfaces"]:
		for id: String in cfg["footsteps"]["surfaces"][surface]:
			assert_true((cfg["sounds"] as Dictionary).has(id), "footstep sound %s exists" % id)


func test_buses_and_empty_music_and_announcer_slots() -> void:
	var sfx := _sfx()
	for bus in ["Master", "SFX", "Ambience", "Music"]:
		assert_true(AudioServer.get_bus_index(bus) >= 0, "bus " + bus)
	assert_eq(String(sfx.music.bus), "Music", "the music slot sits on the Music bus")
	assert_true(sfx.music.stream == null and not sfx.music.playing, "no music plays")
	assert_true(sfx.announcer.stream == null, "no announcer line is loaded")
	var cfg: Dictionary = sfx.cfg
	var slots := 0
	for kind in ["music_slots", "announcer_slots"]:
		for slot_name: String in cfg[kind]:
			if slot_name.begins_with("_"):
				continue
			slots += 1
			assert_eq(String(cfg[kind][slot_name]), "", "%s.%s is an empty named slot" % [kind, slot_name])
	assert_true(slots >= 8, "named slots exist for the announcer and the music")
	assert_true(not sfx.announce("match_start"), "an empty announcer slot plays nothing")
	# No player anywhere under Sfx sits on the Music bus with a stream.
	for child in sfx.get_children():
		if child != sfx.music and child.get("bus") != null:
			assert_true(String(child.bus) != "Music", "only the music slot uses the Music bus")


func test_each_hooked_pawn_signal_starts_a_player_on_the_sfx_bus() -> void:
	var sfx := _sfx()
	var pawn := _pawn()
	var audio := pawn.get_node_or_null("Audio") as PawnAudio
	assert_true(audio != null, "the pawn scene carries its audio child")
	await _tree().process_frame  # the shot visual is bound deferred
	var hooks: Dictionary = sfx.cfg["hooks"]
	var cases := {
		"reload_started": func() -> void: pawn.reload_started.emit(),
		"weapon_switched": func() -> void: pawn.weapon_switched.emit(0),
		"fire_empty": func() -> void: pawn.fire_empty.emit(),
		"landed": func() -> void: pawn.landed.emit(),
		"melee_landed": func() -> void: pawn.melee_landed.emit(),
	}
	for hook: String in cases:
		sfx.clear_log()
		sfx._last_play.clear()
		(cases[hook] as Callable).call()
		var plays := _played(String(hooks[hook]))
		assert_eq(plays.size(), 1, "signal %s starts one %s" % [hook, hooks[hook]])
		if plays.size() == 1:
			assert_true(_stream_ok(plays[0]), "its stream is not empty")
			assert_eq(String(plays[0]["bus"]), "SFX", "it plays on the SFX bus")
			assert_true(bool(plays[0]["positional"]), "it is positional")
	# damaged: shield, health and shield break pick different sounds.
	for case: Array in [["damaged_shield", 10.0, 0.0, false], ["damaged_health", 0.0, 10.0, false], ["shield_broken", 10.0, 5.0, true]]:
		sfx.clear_log()
		sfx._last_play.clear()
		var result := DamageRules.HitResult.new()
		result.shield_damage = float(case[1])
		result.health_damage = float(case[2])
		result.damage_dealt = result.shield_damage + result.health_damage
		result.shield_broken = bool(case[3])
		pawn.damaged.emit(result)
		assert_eq(_played(String(hooks[case[0]])).size(), 1, "damaged plays " + String(case[0]))
	# The shot: the report at the muzzle (by weapon), and for a miss into the world the impact at the end.
	sfx.clear_log()
	sfx._last_play.clear()
	pawn.shot_fx.show_shot(Vector3(0, 1.4, 0), Vector3(0, 1.4, -20))
	var weapon_id := pawn.loadout.get_active().def.id
	var shot_id := String((hooks["shot_by_weapon"] as Dictionary).get(weapon_id, hooks["shot_default"]))
	assert_eq(_played(shot_id).size(), 1, "a shown shot plays the weapon's report (%s)" % shot_id)
	pawn.shot_resolved.emit(Vector3(0, 1.4, 0), Vector3(0, 1.4, -20), {"position": Vector3(0, 1.4, -20), "target": null, "is_headshot": false})
	assert_eq(_played(String(hooks["impact_world"])).size(), 1, "a round that hits the world plays an impact")
	# A melee swing has no shot visual: the shot signal with the blade's id plays the swing.
	sfx.clear_log()
	sfx._last_play.clear()
	var blade := pawn.loadout.get_active()
	for slot in 3:
		if pawn.loadout.get_active() != null and pawn.loadout.get_active().def.is_melee():
			break
		pawn.loadout.swap()
	blade = pawn.loadout.get_active()
	if blade != null and blade.def.is_melee():
		pawn.shot.emit(Vector3.ZERO, Vector3.FORWARD, blade.def.id)
		assert_eq(_played(String(hooks["melee_swing"])).size(), 1, "a blade swing plays the swing sound")
	pawn.free()


func test_voice_caps_hold_when_eighteen_pawns_fire_at_once() -> void:
	var sfx := _sfx()
	var cap := int(sfx.cfg["voices"]["max_3d"])
	assert_true(bool(sfx.cfg["voices"].has("_note")) and cap > 0, "voice caps are data")
	sfx.clear_log()
	sfx._last_play.clear()
	var shot := sfx.sound("shot_pilum_br") as Dictionary
	for round in 3:
		for i in 18:
			sfx._last_play.clear()  # eighteen different pawns: the retrigger guard is per sound, lift it for the burst
			sfx.play_at("shot_pilum_br", Vector3(i * 3.0, 1.0, round))
	var pool := 0
	for child in sfx.get_children():
		if child is AudioStreamPlayer3D and String(child.name).begins_with("Voice3D"):
			pool += 1
	var voices: Array[String] = sfx.busy_voices()
	var busy := voices.size()
	var same := voices.count("shot_pilum_br")
	assert_true(same > 0, "the burst is playing")
	assert_eq(pool, cap, "the positional pool is exactly the cap")
	assert_true(_played("shot_pilum_br").size() <= 54 and same <= int(shot["max_polyphony"]), "one sound never exceeds its own polyphony (%d playing, cap %d)" % [same, int(shot["max_polyphony"])])
	assert_true(busy <= cap, "never more voices than the cap")
	# The retrigger guard: the same sound twice in the same instant plays once.
	sfx.clear_log()
	sfx._last_play.clear()
	sfx.play_at("reload", Vector3.ZERO)
	sfx.play_at("reload", Vector3.ZERO)
	assert_eq(_played("reload").size(), 1, "min_interval_s drops an immediate retrigger")
	print("AUDIO_VOICES pool=%d busy_after_54_shots=%d same_sound=%d" % [pool, busy, same])


func test_footstep_surface_comes_from_the_ground_paint_and_the_piece_stood_on() -> void:
	var map: Node3D = load("res://scenes/maps/alesia_section.tscn").instantiate()
	_tree().root.add_child(map)
	var builder := map.get_node("ArtBuilder")
	assert_true(builder.is_in_group(&"ground_paint") and builder.ground_paint != null, "the map builder publishes its ground paint")
	var g: Dictionary = WorldSurface.config()["ground"]
	assert_eq(GroundPaint.surface_at(builder.ground_paint, builder.ground_size_m, Vector3(1.0, 0, 1.0)), "paving", "the citadel floor is paved")
	var far := float(g["grass_full_m"]) + 14.0
	var names := {}
	for step in 72:
		var angle := TAU * step / 72.0
		names[GroundPaint.surface_at(builder.ground_paint, builder.ground_size_m, Vector3(cos(angle) * far, 0, sin(angle) * far))] = true
	assert_true(names.has("grass"), "the outer ring has grass")
	var mid := (float(g["citadel_paving_m"]) + float(g["grass_from_m"])) * 0.5
	var earth := 0
	for step in 72:
		var angle := TAU * step / 72.0
		if GroundPaint.surface_at(builder.ground_paint, builder.ground_size_m, Vector3(cos(angle) * mid, 0, sin(angle) * mid)) == "earth":
			earth += 1
	assert_true(earth > 36, "between the citadel and the grass the ground is mostly earth (%d of 72)" % earth)
	var sounds: Dictionary = _sfx().cfg["footsteps"]["surfaces"]
	for surface in ["earth", "grass", "paving", "stone", "wood"]:
		assert_true(sounds.has(surface) and (sounds[surface] as Array).size() >= 2, "footstep variants for " + surface)
	map.free()
