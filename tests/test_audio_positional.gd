extends "res://tests/test_case.gd"
## Positional playback wants mono takes. The positional ids are not listed by hand: the real audio scripts are
## driven (PawnAudio on a lone pawn, MatchAudio and PawnAudio in a squads match) and every id Sfx logs with
## positional = true is collected; only what no cheap real path reaches is started through the same Sfx call the
## audio script makes, with the id read from the same data key. Then every take of every collected id is checked.

const _AudioReal := preload("res://tests/test_audio_real.gd")
const REVIVE_S := 0.5  # test-only fast revive (data value: br.json downed.revive_s)
const REAL := "real"
const DIRECT := "direct"


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _sfx() -> Node:
	return _tree().root.get_node_or_null("Sfx")


func _free_voices() -> void:
	var sfx := _sfx()
	for i in sfx._pool_until.size():
		sfx._pool_until[i] = 0
	sfx._last_play.clear()


## Moves the ids Sfx started positionally since the last call into `found` (id -> how it was driven) and clears
## the log, which keeps only the newest MAX_LOG entries; also frees the voices and the retrigger guard.
func _harvest(found: Dictionary, how: String) -> void:
	var sfx := _sfx()
	for entry: Dictionary in sfx.played:
		var id := String(entry["id"])
		if bool(entry["positional"]) and not found.has(id):
			found[id] = how
	sfx.clear_log()
	_free_voices()


func _frames(n: int, found: Dictionary) -> void:
	for i in n:
		await _tree().physics_frame
		await _tree().process_frame
		_harvest(found, REAL)


## A lone pawn, no camera (the listener is the origin): every Pawn-signal hook, shots near and far per weapon,
## the near miss, the impact, the swing, one real step plus the sprint foley.
func _drive_pawn(found: Dictionary) -> void:
	var sfx := _sfx()
	var hooks: Dictionary = sfx.cfg["hooks"]
	var steps: Dictionary = sfx.cfg["footsteps"]
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	_tree().root.add_child(pawn)
	pawn.set_physics_process(false)
	await _tree().process_frame  # the shot visual is bound deferred
	var audio := pawn.get_node("Audio") as PawnAudio
	_harvest(found, REAL)
	pawn.reload_started.emit()
	pawn.weapon_switched.emit(0)
	pawn.fire_empty.emit()
	pawn.landed.emit()
	pawn.melee_landed.emit()
	_harvest(found, REAL)
	for case: Array in [[10.0, 0.0, false], [0.0, 10.0, false], [10.0, 5.0, true]]:
		var result := DamageRules.HitResult.new()
		result.shield_damage = float(case[0])
		result.health_damage = float(case[1])
		result.damage_dealt = result.shield_damage + result.health_damage
		result.shield_broken = bool(case[2])
		pawn.damaged.emit(result)
		_harvest(found, REAL)
	# Each weapon the data names, then no weapon in hand (shot_default near, the shared shot_far far away).
	var slot := pawn.loadout.active
	var held := pawn.loadout.slots[slot]
	var weapons: Array = (hooks["shot_by_weapon"] as Dictionary).keys()
	weapons.append("")
	for weapon_id: String in weapons:
		var def := pawn.registry.get_weapon_def(weapon_id) if weapon_id != "" else null
		assert_true(weapon_id == "" or def != null, "weapon %s exists" % weapon_id)
		pawn.loadout.slots[slot] = Weapon.new(def) if def != null else null
		pawn.shot_fx.show_shot(Vector3(0, 1.4, -10), Vector3(0, 1.4, -30))
		_harvest(found, REAL)
		pawn.shot_fx.show_shot(Vector3(0, 1.4, -100), Vector3(0, 1.4, -120))
		_harvest(found, REAL)
	pawn.loadout.slots[slot] = held
	# A round that passes 1.4 m over the listener, 20 m from its muzzle: the whiz.
	pawn.shot_fx.show_shot(Vector3(0, 1.4, -20), Vector3(0, 1.4, 20))
	pawn.shot_resolved.emit(Vector3(0, 1.4, 0), Vector3(0, 1.4, -20), {"position": Vector3(0, 1.4, -20), "target": null, "is_headshot": false})
	_harvest(found, REAL)
	for i in pawn.loadout.slots.size():
		if pawn.loadout.get_active() != null and pawn.loadout.get_active().def.is_melee():
			break
		pawn.loadout.swap()
	var blade := pawn.loadout.get_active()
	assert_true(blade != null and blade.def.is_melee(), "the loadout holds a blade for the swing")
	if blade != null:
		pawn.shot.emit(Vector3.ZERO, Vector3.FORWARD, blade.def.id)
	_harvest(found, REAL)
	# One real step (no paint, no piece under the lone pawn) by the sprinting listener: a step and the foley.
	var rig := Node3D.new()
	rig.name = "CameraRig"
	pawn.add_child(rig)
	pawn.sprint_factor = float((steps["foley"] as Dictionary).get("sprint_factor_above", 1.17)) + 0.1
	audio.play_step(Vector3(0, 0, 5))
	_harvest(found, REAL)
	rig.free()
	pawn.free()
	# Every step id of every surface (the surface under the feet needs the ground paint or a piece, which a lone
	# pawn has not): the call PawnAudio.play_step makes, id from footsteps.surfaces.
	for surface: String in steps["surfaces"]:
		for id: Variant in steps["surfaces"][surface]:
			sfx.play_at(String(id), Vector3(0, 0, 5))
			_harvest(found, DIRECT)
	# The carrier only flies with drop_from_sky, a second match: the call MatchAudio._set_loop makes for it.
	var holder := Node3D.new()
	_tree().root.add_child(holder)
	sfx.make_loop(String(hooks["carrier_loop"]), holder, true)
	_harvest(found, DIRECT)
	holder.free()


## A squads match: the zone wall loop, braziers, a downed mate (PawnAudio), its revive loop and revived
## (MatchAudio), an elimination, one pickup of each kind on the ground and a banner by the listener.
func _drive_match(found: Dictionary) -> void:
	var m: MatchRoot = load("res://scenes/match/match.tscn").instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.seed_override = 4244
	m.ground_loot = true
	_tree().root.add_child(m)
	await _tree().process_frame
	m.director.load_config()
	m.director.mode_cfg["zone"] = {"start_center": [0, 0], "start_radius_m": 5000.0, "damage_skips_shield": false,
			"phases": [{"wait_s": 1000.0, "shrink_s": 10.0, "radius_m": 2500.0, "damage_per_s": 0.0}]}
	m.director.mode_cfg["teams"]["mode"]["value"] = "squads"
	m.director.mode_cfg["downed"]["revive_s"] = REVIVE_S
	assert_true(m.begin(), "match begins")
	for b in m.bots:
		var brain := b.get_node_or_null("Brain")
		if brain != null:
			brain.set_physics_process(false)
	await _frames(3, found)
	var audio := m.find_child("MatchAudio", true, false) as MatchAudio
	assert_true(audio != null, "the match carries its MatchAudio")
	var local := m.local_player
	var mate: Pawn = null
	var enemy: Pawn = null
	for id in m.director.all_players():
		var p: Pawn = m.director.player(id)
		if p == local:
			continue
		if p.squad_id == local.squad_id and mate == null:
			mate = p
		elif p.squad_id != local.squad_id and enemy == null:
			enemy = p
	assert_true(mate != null and enemy != null, "a squad mate and an enemy")
	if audio == null or mate == null or enemy == null:
		m.free()
		return
	# Down the mate beside the local pawn and hold a revive until it is up.
	mate.global_position = local.global_position + local.global_transform.basis.x
	mate.bridge.state.shield = 0.0
	mate.bridge.state.health = 1.0
	mate.receive_hit(DataRegistry.new().get_weapon_def("sagittarii_rifle"), false, enemy.squad_id, enemy.player_id)
	await _frames(2, found)
	assert_true(mate.is_downed(), "the mate is downed")
	assert_true(m.director.begin_revive(local.player_id), "the local pawn starts a revive")
	for i in 200:
		if not mate.is_downed():
			break
		await _frames(1, found)
	assert_true(not mate.is_downed(), "the revive finishes")
	await _frames(2, found)
	m.director.player_eliminated.emit(enemy.player_id, enemy.player_id, "zone")
	_harvest(found, REAL)
	# One loot item of each kind leaves the field the pickup way (LootField.take frees its node).
	var field := m.director.loot
	var taken := {}
	for loot_id: int in field.items.keys():
		var kind := String(field.def(String(field.items[loot_id]["item_id"])).get("kind", ""))
		if not taken.has(kind):
			taken[kind] = true
			field.take(loot_id)
	await _frames(1, found)
	assert_true(not taken.is_empty(), "there is ground loot")
	# A banner within reach of the listener (a camera beside it) when the banner timer is due.
	var ambient := m.map.get_node_or_null("ArtBuilder/Ambient")
	var banner: Node3D = null
	if ambient != null:
		for child in ambient.get_children():
			if String(child.name).begins_with("Banner"):
				banner = child as Node3D
				break
	assert_true(banner != null, "the map has a banner")
	if banner != null:
		var camera := Camera3D.new()
		m.add_child(camera)
		camera.global_position = banner.global_position + Vector3(0, 2, 4)
		camera.make_current()
		audio._banner_in = 0.0
		await _frames(1, found)
		camera.free()
	m.free()
	await _tree().process_frame
	_sfx().clear_log()
	_free_voices()


func test_every_positionally_played_sound_has_only_mono_takes() -> void:
	var sfx := _sfx()
	var hooks: Dictionary = sfx.cfg["hooks"]
	var amb: Dictionary = sfx.cfg["ambience"]
	var found := {}
	sfx.clear_log()
	_free_voices()
	await _drive_pawn(found)
	await _drive_match(found)
	var ids: Array = found.keys()
	ids.sort()
	var takes := 0
	for id: String in ids:
		var paths: PackedStringArray = sfx.paths(id)
		assert_true(not paths.is_empty(), "%s has takes" % id)
		for path in paths:
			takes += 1
			var take := load(path) as AudioStream
			if take is AudioStreamOggVorbis:
				assert_eq(_AudioReal._ogg_channels(take as AudioStreamOggVorbis), 1, "positional %s: the Ogg take %s is mono" % [id, path])
			elif take is AudioStreamWAV:
				assert_true(not (take as AudioStreamWAV).stereo, "positional %s: the WAV take %s is mono" % [id, path])
			else:
				assert_true(false, "positional %s: the take %s is neither Ogg Vorbis nor WAV (%s)" % [id, path, take])
	# Not vacuous: the sounds every phase must have reached.
	var want: Array = [hooks["reload_started"], hooks["landed"], hooks["impact_world"], hooks["damaged_health"],
			hooks["near_miss"], hooks["zone_wall_loop"], hooks["carrier_loop"], hooks["reviving_loop"],
			amb["brazier_loop"], amb["banner"]]
	want.append_array((hooks["shot_far_by_weapon"] as Dictionary).values())
	for id: Variant in want:
		assert_true(found.has(String(id)), "%s was played positionally" % id)
	for surface: String in sfx.cfg["footsteps"]["surfaces"]:
		var any := false
		for id: Variant in sfx.cfg["footsteps"]["surfaces"][surface]:
			any = any or found.has(String(id))
		assert_true(any, "a %s step was played positionally" % surface)
	for how in [REAL, DIRECT]:
		var list: Array[String] = []
		for id: String in ids:
			if found[id] == how:
				list.append(id)
		print("AUDIO_POSITIONAL_%s %s" % [how.to_upper(), " ".join(list)])
	print("AUDIO_POSITIONAL_MONO ids=%d takes=%d" % [ids.size(), takes])
