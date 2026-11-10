extends "res://tests/test_case.gd"
## M2 A1b: a round that hits the world sounds like the material of the body under the shot's end point
## (data/audio.json "impacts"). Real StaticBody3Ds with the metas the world builders set are shot at through
## the pawn's own shot_resolved signal, so the probe, the rule and the fallback are all the real path.

const SETTLE_FRAMES := 2  # physics frames a new body gets before it is shot at (see test_a_new_body_is_found)


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _sfx() -> Node:
	return _tree().root.get_node_or_null("Sfx")


func _impacts() -> Dictionary:
	return _sfx().cfg["impacts"]


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


## A 2 m box on layer 1 centred at `at`, with the given metas and name, like the world builders make.
func _body(at: Vector3, metas: Dictionary = {}, body_name: String = "Piece") -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = body_name
	body.collision_layer = 1
	body.collision_mask = 0
	for key: String in metas:
		body.set_meta(StringName(key), metas[key])
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2, 2, 2)
	shape.shape = box
	body.add_child(shape)
	_tree().root.add_child(body)
	body.global_position = at
	return body


func _settle() -> void:
	for i in SETTLE_FRAMES:
		await _tree().physics_frame
	await _tree().process_frame


## Every id an impact can play: the impact_* sounds and the hook fallback (read so it holds while a test has
## the impacts block taken out).
func _impact_ids() -> Array:
	var ids: Array = [_sfx().cfg["hooks"]["impact_world"]]
	for id: String in _sfx().cfg["sounds"]:
		if id.begins_with("impact_"):
			ids.append(id)
	return ids


## Shoots from 10 m in front of `at` (the centre of a 2 m box) to its near face; returns the impact ids played.
func _shoot_at(pawn: Pawn, at: Vector3) -> Array:
	var sfx := _sfx()
	sfx.clear_log()
	_free_voices()
	var origin := at + Vector3(0, 0, 10)
	var end := at + Vector3(0, 0, 1)
	pawn.shot_resolved.emit(origin, end, {"position": end, "target": null, "is_headshot": false})
	var ids := _impact_ids()
	var out: Array = []
	for entry: Dictionary in sfx.played:
		if ids.has(entry["id"]):
			out.append(String(entry["id"]))
	return out


func _sound_of(material: String) -> String:
	return String(_impacts()["by_material"][material])


func _assert_plays(pawn: Pawn, at: Vector3, want: String, what: String) -> void:
	var got := _shoot_at(pawn, at)
	assert_eq(got, [want], "%s plays exactly %s" % [what, want])


func test_a_new_body_is_found() -> void:
	# How many physics frames a body added outside the step needs before a ray query finds it.
	var pawn := _pawn()
	var audio := pawn.get_node("Audio") as PawnAudio
	var at := Vector3(300, 50, 0)
	var body := _body(at, {"structure_type": "eagle_standard"})
	var origin := at + Vector3(0, 0, 10)
	var end := at + Vector3(0, 0, 1)
	var found_after := -1
	for frames in 4:
		if audio.impact_material_at(origin, end) == "metal":
			found_after = frames
			break
		await _tree().physics_frame
	print("AUDIO_IMPACT_FRAMES found_after=%d" % found_after)
	assert_true(found_after >= 0 and found_after <= SETTLE_FRAMES, "a new body is found within %d physics frames (%d)" % [SETTLE_FRAMES, found_after])
	body.free()
	pawn.free()


func test_a_structure_piece_sounds_by_its_type() -> void:
	var pawn := _pawn()
	var impacts := _impacts()
	var cases := [["barracks", "stone"], ["stake_row", "wood"], ["eagle_standard", "metal"], ["no_such_piece", String(impacts["default"])]]
	var bodies: Array[StaticBody3D] = []
	for i in cases.size():
		bodies.append(_body(Vector3(100 + 10 * i, 50, 0), {"structure_type": cases[i][0]}))
	await _settle()
	for i in cases.size():
		assert_eq(PawnAudio.material_of(bodies[i], impacts), cases[i][1], "%s is %s" % [cases[i][0], cases[i][1]])
		_assert_plays(pawn, bodies[i].global_position, _sound_of(cases[i][1]), "a %s piece" % cases[i][0])
	for body in bodies:
		body.free()
	pawn.free()


func test_a_cover_piece_sounds_by_its_palette() -> void:
	var pawn := _pawn()
	var impacts := _impacts()
	var cases := [["citadel", "stone"], ["camp", "metal"], ["inner_wall", "stone"], ["no_such_palette", String(impacts["by_palette"]["default"])]]
	assert_eq(String(impacts["by_palette"]["default"]), "wood", "an unlisted palette is wood today")
	var bodies: Array[StaticBody3D] = []
	for i in cases.size():
		bodies.append(_body(Vector3(100 + 10 * i, 60, 0), {"cover_palette": cases[i][0]}))
	await _settle()
	for i in cases.size():
		_assert_plays(pawn, bodies[i].global_position, _sound_of(cases[i][1]), "a %s cover piece" % cases[i][0])
	for body in bodies:
		body.free()
	pawn.free()


func test_decor_ground_bare_and_nothing() -> void:
	var pawn := _pawn()
	var impacts := _impacts()
	var decor := _body(Vector3(100, 70, 0), {"decor_id": "brazier_1"})
	var ground := _body(Vector3(110, 70, 0), {}, "Ground")
	var bare := _body(Vector3(120, 70, 0))
	var nothing := Vector3(130, 70, 0)
	await _settle()
	# With the data as shipped (all stone today).
	_assert_plays(pawn, decor.global_position, _sound_of(String(impacts["decor"])), "rim decor")
	_assert_plays(pawn, ground.global_position, _sound_of(String(impacts["ground"])), "the ground")
	_assert_plays(pawn, bare.global_position, _sound_of(String(impacts["default"])), "a bare body")
	_assert_plays(pawn, nothing, String(_sfx().cfg["hooks"]["impact_world"]), "nothing under the end point")
	# Distinct temporary values, so each branch is told apart; PawnAudio reads the same Dictionary.
	var saved := {"decor": impacts["decor"], "ground": impacts["ground"], "default": impacts["default"]}
	impacts["decor"] = "metal"
	impacts["ground"] = "wood"
	impacts["default"] = "metal"
	assert_true((pawn.get_node("Audio") as PawnAudio).impacts == impacts, "PawnAudio sees the temporary values")
	_assert_plays(pawn, decor.global_position, "impact_metal", "rim decor (decor = metal)")
	_assert_plays(pawn, ground.global_position, "impact_wood", "the ground (ground = wood)")
	_assert_plays(pawn, bare.global_position, "impact_metal", "a bare body (default = metal)")
	_assert_plays(pawn, nothing, "impact_metal", "nothing under the end point (default = metal)")
	impacts["default"] = "wood"
	_assert_plays(pawn, bare.global_position, "impact_wood", "a bare body (default = wood)")
	for key: String in saved:
		impacts[key] = saved[key]
	assert_eq(String(_impacts()["decor"]), String(saved["decor"]), "the data is restored")
	decor.free()
	ground.free()
	bare.free()
	pawn.free()


## Pawns in front of a stake row at its face: pawn i is pushed into the box so its front surface lies between
## the probe's start (5 cm before the face) and the face.
func _pawns_at_face(at: Vector3, count: int, layer: int) -> Array[Pawn]:
	var out: Array[Pawn] = []
	for i in count:
		var other := _pawn()
		other.collision_layer = layer
		# Capsule radius 0.4, centre 0.8 m above the origin: front at at.z + 1.02, inside the probe segment.
		other.global_position = at + Vector3(0, -0.8, 0.62)
		out.append(other)
	return out


func test_pawns_in_the_way_are_looked_past_up_to_the_cap() -> void:
	var pawn := _pawn()
	var impacts := _impacts()
	var saved_default: Variant = impacts["default"]
	impacts["default"] = "metal"  # so "gave up" is told apart from the stake row's wood
	var at_layer2 := Vector3(200, 50, 0)
	var at_one := Vector3(210, 50, 0)
	var at_two := Vector3(220, 50, 0)
	var at_cap := Vector3(230, 50, 0)
	var at_only := Vector3(240, 50, 0)
	var bodies: Array[StaticBody3D] = []
	for at in [at_layer2, at_one, at_two, at_cap]:
		bodies.append(_body(at, {"structure_type": "stake_row"}))
	var others: Array[Pawn] = []
	# A pawn as the scene makes it (layer 2): the probe's mask 1 never sees it.
	others.append_array(_pawns_at_face(at_layer2, 1, 2))
	# Pawns that are on layer 1 too (as Hitscan's comment describes): the probe must look past them.
	others.append_array(_pawns_at_face(at_one, 1, 3))
	others.append_array(_pawns_at_face(at_two, 2, 3))
	others.append_array(_pawns_at_face(at_cap, 3, 3))
	others.append_array(_pawns_at_face(at_only, 3, 3))
	await _settle()
	# Not vacuous: a plain mask-1 ray from the probe's start hits the layer-3 pawn before the stake row.
	var dir := Vector3(0, 0, -1)
	var end := at_one + Vector3(0, 0, 1)
	var q := PhysicsRayQueryParameters3D.create(end - dir * 0.05, end + dir * 0.1, 1)
	var first := pawn.get_world_3d().direct_space_state.intersect_ray(q)
	assert_true(not first.is_empty() and first["collider"] is CharacterBody3D, "the first thing on the probe is the pawn (%s)" % first.get("collider"))
	_assert_plays(pawn, at_layer2, "impact_wood", "a stake row behind a layer-2 pawn")
	_assert_plays(pawn, at_one, "impact_wood", "a stake row behind one pawn")
	_assert_plays(pawn, at_two, "impact_wood", "a stake row behind two pawns")
	_assert_plays(pawn, at_cap, "impact_metal", "a stake row behind three pawns (past the cap: default)")
	_assert_plays(pawn, at_only, "impact_metal", "only pawns there (default)")
	impacts["default"] = saved_default
	for other in others:
		other.free()
	for body in bodies:
		body.free()
	pawn.free()


func test_a_missing_block_or_unknown_sound_falls_back_to_the_hook() -> void:
	var sfx := _sfx()
	var fallback := String(sfx.cfg["hooks"]["impact_world"])
	var at := Vector3(100, 80, 0)
	var body := _body(at, {"structure_type": "stake_row"})
	await _settle()
	# No impacts block in the data: a pawn made then reads none.
	var saved: Dictionary = sfx.cfg["impacts"]
	sfx.cfg.erase("impacts")
	var pawn := _pawn()
	assert_true((pawn.get_node("Audio") as PawnAudio).impacts.is_empty(), "the pawn read no impacts block")
	_assert_plays(pawn, at, fallback, "no impacts block")
	sfx.cfg["impacts"] = saved
	pawn.free()
	# An unknown sound id for the material.
	pawn = _pawn()
	var by_material: Dictionary = saved["by_material"]
	var saved_wood: Variant = by_material["wood"]
	by_material["wood"] = "no_such_sound"
	_assert_plays(pawn, at, fallback, "an unknown sound id")
	by_material["wood"] = saved_wood
	# A material by_material does not list.
	assert_eq((pawn.get_node("Audio") as PawnAudio).impact_sound("glass"), fallback, "an unknown material")
	_assert_plays(pawn, at, "impact_wood", "the data restored")
	body.free()
	pawn.free()


func test_the_impact_data_is_complete() -> void:
	var sfx := _sfx()
	var impacts := _impacts()
	assert_true(not (sfx.cfg["hooks"] as Dictionary).has("impacts"), "impacts is not under hooks")
	var by_material: Dictionary = impacts["by_material"]
	for material: String in by_material:
		var id := String(by_material[material])
		assert_true(not (sfx.sound(id) as Dictionary).is_empty(), "%s: %s is a known sound" % [material, id])
		for path in sfx.paths(id):
			assert_true(ResourceLoader.exists(path) and load(path) is AudioStream, "%s: take %s loads" % [id, path])
	var used: Array = []
	used.append_array((impacts["by_structure"] as Dictionary).values())
	used.append_array((impacts["by_palette"] as Dictionary).values())
	used.append_array([impacts["decor"], impacts["ground"], impacts["default"]])
	for material: Variant in used:
		assert_true(by_material.has(String(material)), "material %s has a sound in by_material" % material)
	for type: String in WorldKit.config()["types"]:
		assert_true((impacts["by_structure"] as Dictionary).has(type), "structure type %s has a material" % type)
	var palettes := ["citadel", "default"]
	var cover: Dictionary = DataRegistry.new().load_file("res://data/maps/alesia_cover.json")
	for type: String in cover["types"]:
		var palette := String((cover["types"][type] as Dictionary).get("palette", ""))
		if palette != "" and not palettes.has(palette):
			palettes.append(palette)
	for palette: String in palettes:
		assert_true((impacts["by_palette"] as Dictionary).has(palette), "cover palette %s has a material" % palette)
	assert_true(float(impacts.get("probe_back_m", 0.0)) > 0.0 and float(impacts.get("probe_ahead_m", 0.0)) > 0.0, "the probe distances are set")


func test_material_of_reads_metas_in_order() -> void:
	var impacts := _impacts()
	var node := Node3D.new()
	assert_eq(PawnAudio.material_of(node, impacts), String(impacts["default"]), "a bare node is default")
	node.set_meta(&"decor_id", "x")
	assert_eq(PawnAudio.material_of(node, impacts), String(impacts["decor"]), "decor")
	node.set_meta(&"cover_palette", "camp")
	assert_eq(PawnAudio.material_of(node, impacts), "metal", "a cover palette beats decor")
	node.set_meta(&"structure_type", "tent")
	assert_eq(PawnAudio.material_of(node, impacts), "wood", "a structure type beats a cover palette")
	node.free()
	var ground := Node3D.new()
	ground.name = "Ground"
	assert_eq(PawnAudio.material_of(ground, impacts), String(impacts["ground"]), "the ground by name")
	ground.free()
	assert_eq(PawnAudio.material_of(null, impacts), String(impacts["default"]), "no body is default")
	assert_eq(PawnAudio.material_of(RefCounted.new(), impacts), String(impacts["default"]), "a non-node is default")
	var custom := {"default": "wood", "by_palette": {"default": "metal"}}
	var odd := Node3D.new()
	odd.set_meta(&"cover_palette", "nowhere")
	assert_eq(PawnAudio.material_of(odd, custom), "metal", "an unlisted palette is by_palette.default")
	odd.set_meta(&"structure_type", "nothing")
	assert_eq(PawnAudio.material_of(odd, custom), "wood", "an unlisted structure type is default")
	odd.free()
