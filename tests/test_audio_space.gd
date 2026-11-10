extends "res://tests/test_case.gd"
## M2 audio space: distance filters and reverb zones. Every positional player takes its distance low-pass
## (attenuation_filter_cutoff_hz / attenuation_filter_db) from data/audio.json, a reused pool voice never keeps the
## previous sound's values, and the shipped data keeps far reports duller than footsteps. Reverb zones: the Reverb
## bus, every positional player's area_mask, the zone boxes from the open volumes, and a real match's zones (the
## engine's own point lookup finds them, gameplay casts never do). The reverb itself cannot be heard headless.

const ZONE_TYPES_LEFT_OUT := ["watchtower", "aqueduct_span", "pediment_front"]


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _sfx() -> Node:
	return _tree().root.get_node_or_null("Sfx")


func _free_voices() -> void:
	var sfx := _sfx()
	for i in sfx._pool_until.size():
		sfx._pool_until[i] = 0
	sfx._last_play.clear()


func _valid_loops() -> int:
	var n := 0
	for loop: Variant in _sfx()._loops:
		if is_instance_valid(loop):
			n += 1
	return n


## Every footstep id listed under footsteps.surfaces.
func _step_ids() -> Array[String]:
	var out: Array[String] = []
	var surfaces: Dictionary = _sfx().cfg["footsteps"]["surfaces"]
	for surface: String in surfaces:
		for id: Variant in surfaces[surface]:
			out.append(String(id))
	return out


## The far report ids: hooks.shot_far and each value of hooks.shot_far_by_weapon.
func _far_ids() -> Array[String]:
	var hooks: Dictionary = _sfx().cfg["hooks"]
	var out: Array[String] = [String(hooks["shot_far"])]
	for weapon: String in hooks["shot_far_by_weapon"]:
		out.append(String(hooks["shot_far_by_weapon"][weapon]))
	return out


func _assert_filter(player: AudioStreamPlayer3D, id: String, what: String) -> void:
	var s: Dictionary = _sfx().sound(id)
	assert_eq(player.attenuation_filter_cutoff_hz, float(s["attenuation_filter_cutoff_hz"]), "%s: %s cutoff from data" % [what, id])
	assert_eq(player.attenuation_filter_db, float(s["attenuation_filter_db"]), "%s: %s filter db from data" % [what, id])


## Plays an id on the first pool voice (every voice made free first, so index 0 is picked).
func _play_on_first_voice(id: String) -> AudioStreamPlayer3D:
	_free_voices()
	return _sfx().play_at(id, Vector3(2.0, 0.0, 0.0))


func test_play_at_sets_each_sounds_filter_on_a_reused_voice() -> void:
	var sfx := _sfx()
	var far := _far_ids()[0]
	var step := _step_ids()[0]
	var plain := "shield_break"  # no filter keys of its own: the defaults
	assert_true(not (sfx.cfg["sounds"][plain] as Dictionary).has("attenuation_filter_cutoff_hz"), "%s uses the default filter" % plain)
	assert_true(sfx.sound(far)["attenuation_filter_cutoff_hz"] != sfx.sound(step)["attenuation_filter_cutoff_hz"], "far and step cutoffs differ in data")
	var first := _play_on_first_voice(far)
	assert_true(first != null, "%s plays" % far)
	if first == null:
		return
	assert_true(first == sfx._pool[0], "the first free voice is picked")
	_assert_filter(first, far, "far report")
	var second := _play_on_first_voice(step)
	assert_true(second == first, "%s reuses the same voice" % step)
	_assert_filter(second, step, "footstep after a far report")
	var third := _play_on_first_voice(plain)
	assert_true(third == first, "%s reuses the same voice" % plain)
	_assert_filter(third, plain, "default after a footstep")
	assert_eq(third.attenuation_filter_cutoff_hz, float(sfx.cfg["defaults"]["attenuation_filter_cutoff_hz"]), "%s gets the default cutoff" % plain)
	assert_eq(third.attenuation_filter_db, float(sfx.cfg["defaults"]["attenuation_filter_db"]), "%s gets the default filter db" % plain)
	# Synthetic values, so this does not hang on today's numbers.
	var entry: Dictionary = sfx.cfg["sounds"][plain]
	var saved := entry.duplicate(true)
	entry["attenuation_filter_cutoff_hz"] = 1234.0
	entry["attenuation_filter_db"] = -7.0
	var fourth := _play_on_first_voice(plain)
	sfx.cfg["sounds"][plain] = saved
	assert_true(fourth == first, "the synthetic play reuses the same voice")
	if fourth != null:
		assert_eq(fourth.attenuation_filter_cutoff_hz, 1234.0, "a synthetic cutoff reaches the voice")
		assert_eq(fourth.attenuation_filter_db, -7.0, "a synthetic filter db reaches the voice")
	assert_true(not (sfx.cfg["sounds"][plain] as Dictionary).has("attenuation_filter_cutoff_hz"), "the synthetic values are restored away")
	var fifth := _play_on_first_voice(far)
	if fifth != null:
		_assert_filter(fifth, far, "far report after the synthetic values")
	_free_voices()


func test_make_loop_sets_each_sounds_filter() -> void:
	var sfx := _sfx()
	var fire := String(sfx.cfg["ambience"]["brazier_loop"])
	var hum := "zone_hum_loop"
	var before := _valid_loops()
	var saved := {fire: (sfx.cfg["sounds"][fire] as Dictionary).duplicate(true), hum: (sfx.cfg["sounds"][hum] as Dictionary).duplicate(true)}
	sfx.cfg["sounds"][fire]["attenuation_filter_cutoff_hz"] = 2345.0
	sfx.cfg["sounds"][fire]["attenuation_filter_db"] = -9.0
	sfx.cfg["sounds"][hum]["attenuation_filter_cutoff_hz"] = 6789.0
	sfx.cfg["sounds"][hum]["attenuation_filter_db"] = -3.0
	var holder := Node3D.new()
	_tree().root.add_child(holder)
	var a: Node = sfx.make_loop(fire, holder, true)
	var b: Node = sfx.make_loop(hum, holder, true)
	for id: String in saved:
		sfx.cfg["sounds"][id] = saved[id]
	assert_true(a is AudioStreamPlayer3D, "%s positional loop is an AudioStreamPlayer3D" % fire)
	assert_true(b is AudioStreamPlayer3D, "%s positional loop is an AudioStreamPlayer3D" % hum)
	if a is AudioStreamPlayer3D:
		assert_eq((a as AudioStreamPlayer3D).attenuation_filter_cutoff_hz, 2345.0, "%s loop carries its cutoff" % fire)
		assert_eq((a as AudioStreamPlayer3D).attenuation_filter_db, -9.0, "%s loop carries its filter db" % fire)
	if b is AudioStreamPlayer3D:
		assert_eq((b as AudioStreamPlayer3D).attenuation_filter_cutoff_hz, 6789.0, "%s loop carries its own cutoff" % hum)
		assert_eq((b as AudioStreamPlayer3D).attenuation_filter_db, -3.0, "%s loop carries its own filter db" % hum)
	assert_eq(_valid_loops(), before + 2, "both loops count against max_loops")
	holder.free()
	assert_eq(_valid_loops(), before, "freeing the holder leaves no loop behind")
	for id: String in saved:
		assert_true(not (sfx.cfg["sounds"][id] as Dictionary).has("attenuation_filter_cutoff_hz"), "%s data is restored" % id)


func test_far_reports_are_filtered_harder_than_footsteps() -> void:
	var sfx := _sfx()
	var steps := _step_ids()
	assert_true(not steps.is_empty(), "footsteps list ids")
	for far in _far_ids():
		var f: Dictionary = sfx.sound(far)
		assert_true(not f.is_empty(), "%s is a sound" % far)
		for step in steps:
			var s: Dictionary = sfx.sound(step)
			assert_true(float(f["attenuation_filter_cutoff_hz"]) < float(s["attenuation_filter_cutoff_hz"]), "%s cutoff below %s" % [far, step])
			assert_true(float(f["attenuation_filter_db"]) <= float(s["attenuation_filter_db"]), "%s filter db at least as deep as %s" % [far, step])


func test_every_sound_resolves_a_sane_filter() -> void:
	var sfx := _sfx()
	for id: String in sfx.cfg["sounds"]:
		if id.begins_with("_"):
			continue
		var s: Dictionary = sfx.sound(id)
		var cutoff := float(s["attenuation_filter_cutoff_hz"])
		var db := float(s["attenuation_filter_db"])
		assert_true(cutoff >= 20.0 and cutoff <= 20500.0, "%s cutoff %s within 20..20500 Hz" % [id, cutoff])
		assert_true(db <= 0.0, "%s filter db %s is a cut" % [id, db])


func test_defaults_carry_both_filter_keys() -> void:
	var defaults: Dictionary = _sfx().cfg["defaults"]
	assert_true(defaults.has("attenuation_filter_cutoff_hz"), "defaults carry attenuation_filter_cutoff_hz")
	assert_true(defaults.has("attenuation_filter_db"), "defaults carry attenuation_filter_db")


# ---------- reverb zones ----------

func _zones_cfg() -> Dictionary:
	return _sfx().cfg["reverb_zones"]


func _zone_bit() -> int:
	return 1 << (int(_zones_cfg()["physics_layer"]) - 1)


func test_the_reverb_bus_is_built_from_data() -> void:
	var buses: Dictionary = _sfx().cfg["buses"]
	var entry: Dictionary = buses["Reverb"]
	var index := AudioServer.get_bus_index("Reverb")
	assert_true(index >= 0, "the Reverb bus exists")
	if index < 0:
		return
	var effect := AudioServer.get_bus_effect(index, 0) if AudioServer.get_bus_effect_count(index) > 0 else null
	assert_true(effect is AudioEffectReverb, "the Reverb bus's effect 0 is an AudioEffectReverb")
	if effect is AudioEffectReverb:
		var props: Dictionary = entry["reverb"]
		for key in ["room_size", "damping", "wet", "dry"]:
			assert_true(props.has(key), "data reverb lists %s" % key)
			assert_true(is_equal_approx(float(effect.get(key)), float(props.get(key, -1.0))), "reverb %s = %s from data" % [key, props.get(key)])
		assert_eq(float((effect as AudioEffectReverb).dry), 0.0, "the reverb bus carries no dry sound")
	assert_eq(String(AudioServer.get_bus_send(index)), String(entry["send"]), "the Reverb bus sends to its data target")
	var order: Array = buses.keys()
	assert_true(order.has(String(entry["send"])) and order.find(String(entry["send"])) < order.find("Reverb"), "the send target is listed before Reverb")
	assert_eq(String(_zones_cfg()["bus"]), "Reverb", "the zones send to the Reverb bus")


func test_every_positional_player_has_the_zone_area_mask() -> void:
	var sfx := _sfx()
	assert_eq(sfx.zone_mask(), _zone_bit(), "zone_mask is the data layer's bit")
	assert_eq(_zone_bit(), 512, "layer 10 is bit 512")
	assert_eq(_zone_bit() & 7, 0, "the zone bit shares no bit with the gameplay mask 1|2|4")
	for voice: AudioStreamPlayer3D in sfx._pool:
		assert_eq(voice.area_mask, 512, "%s has the zone area_mask" % voice.name)
	var played := _play_on_first_voice("shield_break")
	assert_true(played != null, "a one-shot plays")
	if played != null:
		assert_eq(played.area_mask, 512, "the voice keeps its area_mask after a play_at")
	_free_voices()
	var before := _valid_loops()
	var holder := Node3D.new()
	_tree().root.add_child(holder)
	var loop: Node = sfx.make_loop("zone_hum_loop", holder, true)
	assert_true(loop is AudioStreamPlayer3D, "a positional loop is an AudioStreamPlayer3D")
	if loop is AudioStreamPlayer3D:
		assert_eq((loop as AudioStreamPlayer3D).area_mask, 512, "a positional loop has the zone area_mask")
	holder.free()
	assert_eq(_valid_loops(), before, "no loop is left behind")


## The test's own union of a type's open volumes (min, max corners), without AABB.merge.
func _union(open: Array) -> Array[Vector3]:
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for entry: Dictionary in open:
		var at := LowpolyKit.vec(entry["at"])
		var half := LowpolyKit.vec(entry["size"]) * 0.5
		lo = lo.min(at - half)
		hi = hi.max(at + half)
	return [lo, hi]


func _assert_box(box: AABB, lo: Vector3, hi: Vector3, what: String) -> void:
	assert_true(box.position.is_equal_approx(lo), "%s min corner %s (got %s)" % [what, lo, box.position])
	assert_true(box.end.is_equal_approx(hi), "%s max corner %s (got %s)" % [what, hi, box.end])


func test_zone_box_is_the_padded_union_of_the_open_volumes() -> void:
	var types: Dictionary = WorldKit.config()["types"]
	var pad := float(_zones_cfg()["padding_m"])
	var drop := float(_zones_cfg()["floor_drop_m"])
	var barracks := MatchAudio.zone_box(types["barracks"]["open"], pad, drop)
	_assert_box(barracks, Vector3(-4.1 - pad, -drop, -3.0 - pad), Vector3(4.1 + pad, 3.0, 3.0 + pad), "barracks")
	for type in ["gate", "colonnade", "barracks"]:
		var open: Array = types[type]["open"]
		var u := _union(open)
		var lo: Vector3 = u[0] - Vector3(pad, drop, pad)
		var hi: Vector3 = u[1] + Vector3(pad, 0.0, pad)
		_assert_box(MatchAudio.zone_box(open, pad, drop), lo, hi, type)
		var wide := MatchAudio.zone_box(open, 2.0, drop)
		assert_true(is_equal_approx(wide.end.y, u[1].y), "%s: padding never changes the top" % type)
		assert_true(is_equal_approx(MatchAudio.zone_box(open, 0.0, 0.0).end.y, u[1].y), "%s: the top is the roof underside" % type)
	assert_eq(MatchAudio.zone_box([], pad, drop), AABB(), "no open volumes, no box")


## Every zone the engine's own lookup finds at a world point (the AudioStreamPlayer3D query: areas only, its mask).
func _zones_at(space: PhysicsDirectSpaceState3D, point: Vector3) -> Array:
	var q := PhysicsPointQueryParameters3D.new()
	q.position = point
	q.collide_with_areas = true
	q.collide_with_bodies = false
	q.collision_mask = _zone_bit()
	var out: Array = []
	for hit: Dictionary in space.intersect_point(q, 32):
		out.append(hit["collider"])
	return out


func _zone_centre(zone: Area3D) -> Vector3:
	return zone.global_transform * (zone.get_node("Box") as Node3D).position


## RIDs of every collision object of every pawn, so the casts below see only the world.
func _pawn_rids(m: MatchRoot) -> Array[RID]:
	var out: Array[RID] = []
	var players: Dictionary = m.director.all_players()
	for id: int in players:
		var pawn: Node = players[id]
		if pawn is CollisionObject3D:
			out.append((pawn as CollisionObject3D).get_rid())
		for child: Node in pawn.find_children("*", "CollisionObject3D", true, false):
			out.append((child as CollisionObject3D).get_rid())
	return out


func _is_zone(collider: Variant) -> bool:
	return collider is Area3D and ((collider as Area3D).collision_layer & _zone_bit()) != 0


## The three gameplay casts along origin -> origin + dir: Hitscan.cast, AimMath.camera_aim_point and a RayCast3D
## set up as CameraRig sets up its aim ray. Also asserts none of them reports a zone.
func _casts(m: MatchRoot, origin: Vector3, dir: Vector3, def: WeaponDef, exclude: Array[RID], what: String) -> Dictionary:
	var space := m.get_world_3d().direct_space_state
	var out := {"hitscan": Hitscan.cast(space, origin, dir, def, exclude)}
	var raw_q := PhysicsRayQueryParameters3D.create(origin, origin + dir.normalized() * def.range_m, Hitscan.MASK_WORLD | Hitscan.MASK_BODY | Hitscan.MASK_HEAD)
	raw_q.collide_with_areas = true
	raw_q.exclude = exclude
	var raw := space.intersect_ray(raw_q)
	assert_true(raw.is_empty() or not _is_zone(raw["collider"]), "%s: the Hitscan query never meets a zone" % what)
	var cam := Camera3D.new()
	_tree().root.add_child(cam)
	cam.look_at_from_position(origin, origin + dir)
	out["aim"] = AimMath.camera_aim_point(cam, exclude, def.range_m)
	cam.free()
	var ray := RayCast3D.new()
	ray.enabled = true
	ray.collide_with_areas = true
	ray.collision_mask = Hitscan.MASK_WORLD | Hitscan.MASK_BODY | Hitscan.MASK_HEAD
	_tree().root.add_child(ray)
	ray.look_at_from_position(origin, origin + dir)
	ray.target_position = Vector3(0.0, 0.0, -def.range_m)
	for rid in exclude:
		ray.add_exception_rid(rid)
	ray.force_raycast_update()
	out["ray"] = ray.get_collision_point() if ray.is_colliding() else null
	assert_true(not _is_zone(ray.get_collider()), "%s: the camera ray never reports a zone" % what)
	ray.free()
	return out


## A clear point 4.5 m from one of the body's collider centres from which a plain world ray hits that body:
## [origin, target], or [] when none is found.
func _shot_at(space: PhysicsDirectSpaceState3D, body: CollisionObject3D, exclude: Array[RID]) -> Array:
	for shape: Node in body.get_children():
		if not (shape is CollisionShape3D):
			continue
		var target := (shape as Node3D).global_position
		for i in 8:
			var d := Vector3.FORWARD.rotated(Vector3.UP, TAU * i / 8.0)
			var origin := target + d * 4.5
			var p := PhysicsPointQueryParameters3D.new()
			p.position = origin
			p.collision_mask = 1
			if not space.intersect_point(p, 1).is_empty():
				continue  # starts inside something
			var q := PhysicsRayQueryParameters3D.create(origin, target + (target - origin) * 0.5, 1)
			q.exclude = exclude
			var hit := space.intersect_ray(q)
			if not hit.is_empty() and hit["collider"] == body:
				return [origin, target]
	return []


## The material of a real hit: a Hitscan.cast from origin at target, checked against a plain mask-1 ray.
func _real_impact(m: MatchRoot, body: Node, origin: Vector3, target: Vector3, def: WeaponDef, exclude: Array[RID], expected: String, report: Array) -> void:
	var space := m.get_world_3d().direct_space_state
	var dir := (target - origin).normalized()
	var hit := Hitscan.cast(space, origin, dir, def, exclude)
	var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * def.range_m, 1)
	q.exclude = exclude
	var plain := space.intersect_ray(q)
	var what := String(body.name)
	assert_true(not hit.is_empty() and not plain.is_empty(), "%s: the shot hits" % what)
	if hit.is_empty() or plain.is_empty():
		return
	assert_true(plain["collider"] == body, "%s: the plain ray's collider is the body" % what)
	assert_true((hit["position"] as Vector3).is_equal_approx(plain["position"]), "%s: Hitscan hit the same point" % what)
	var got: String = (m.local_player.get_node("Audio") as PawnAudio).impact_material_at(origin, hit["position"])
	assert_eq(got, expected, "%s: the real end point sounds %s" % [what, expected])
	report.append("%s=%s/%s" % [what, expected, got])


func test_reverb_zones_in_a_real_match() -> void:
	var sfx := _sfx()
	var data := _zones_cfg()
	var amounts: Dictionary = data["types"]
	var bit := _zone_bit()
	var m: MatchRoot = load("res://scenes/match/match.tscn").instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.seed_override = 4245
	_tree().root.add_child(m)
	await _tree().process_frame
	assert_true(m.begin(), "match begins")
	for b in m.bots:
		var brain := b.get_node_or_null("Brain")
		if brain != null:
			brain.set_physics_process(false)
	for i in 3:
		await _tree().physics_frame
		await _tree().process_frame
	var audio := m.find_child("MatchAudio", true, false) as MatchAudio
	assert_true(audio != null and is_instance_valid(audio.reverb_zones), "MatchAudio built its zones once the map existed")
	if audio == null or not is_instance_valid(audio.reverb_zones):
		m.free()
		return
	var map := m.map as Node
	var nav := map.find_child("Nav", true, false)
	assert_true(nav != null, "the map has its Nav")
	# The structure bodies whose type the data lists, and the left-out types.
	var wanted := {}  # body name -> body
	var per_type := {}
	var left_out := 0
	for node: Node in _tree().get_nodes_in_group(WorldKit.GROUP):
		if not map.is_ancestor_of(node) or not node.has_meta(&"structure_type"):
			continue
		for child: Node in node.get_children():
			assert_true(not (child is Area3D), "%s gained no area child" % node.name)
		var type := String(node.get_meta(&"structure_type"))
		if amounts.has(type):
			wanted[String(node.name)] = node
			per_type[type] = int(per_type.get(type, 0)) + 1
		elif ZONE_TYPES_LEFT_OUT.has(type):
			left_out += 1
	for type in ["barracks", "gate", "colonnade"]:
		assert_true(int(per_type.get(type, 0)) >= 1, "this map has a %s" % type)
	assert_true(left_out >= 1, "this map has a left-out type")
	var zones_node := audio.reverb_zones
	assert_true(zones_node.get_parent() == audio, "the zones node is MatchAudio's own child")
	var zones: Array[Area3D] = []
	for child: Node in zones_node.get_children():
		assert_true(child is Area3D, "%s is an Area3D" % child.name)
		if child is Area3D:
			zones.append(child as Area3D)
	assert_eq(zones.size(), wanted.size(), "one zone per listed structure body")
	var names: Array[String] = []
	var tol := 0.0001
	for zone in zones:
		names.append(String(zone.name))
		var zb := zone.get_node("Box") as CollisionShape3D
		var half := (zb.shape as BoxShape3D).size * 0.5
		print("AUDIO_REVERB_ZONE %s type=%s box=%s..%s at=%s yaw=%.1f amount=%.2f" % [zone.name, zone.get_meta(&"structure_type", ""), zb.position - half, zb.position + half, zone.global_position, rad_to_deg(zone.global_rotation.y), zone.reverb_bus_amount])
		var id := String(zone.get_meta(&"structure_id", ""))
		var type := String(zone.get_meta(&"structure_type", ""))
		assert_true(wanted.has(id), "%s belongs to a listed body" % zone.name)
		assert_true(not ZONE_TYPES_LEFT_OUT.has(type), "%s is not a left-out type" % zone.name)
		assert_eq(String(zone.name), "Zone_" + id, "%s is named after its body" % zone.name)
		assert_eq(zone.collision_layer, bit, "%s is on the zone layer only" % zone.name)
		assert_eq(zone.collision_mask, 0, "%s masks nothing" % zone.name)
		assert_true(not zone.monitoring and not zone.monitorable, "%s neither monitors nor is monitorable" % zone.name)
		assert_true(zone.reverb_bus_enabled, "%s sends reverb" % zone.name)
		assert_eq(String(zone.reverb_bus_name), "Reverb", "%s sends to Reverb" % zone.name)
		assert_true(absf(zone.reverb_bus_amount - float(amounts.get(type, -1.0))) < tol, "%s amount from data" % zone.name)
		assert_true(absf(zone.reverb_bus_uniformity - float(data["uniformity"])) < tol, "%s uniformity from data" % zone.name)
		assert_true(not zone.is_overriding_audio_bus(), "%s does not override the bus" % zone.name)
		if wanted.has(id):
			var body := wanted[id] as Node3D
			assert_true(zone.global_transform.is_equal_approx(body.global_transform), "%s has its body's global transform" % zone.name)
		assert_true(zone.find_children("*", "AudioStreamPlayer3D", true, false).is_empty() and zone.find_children("*", "AudioStreamPlayer", true, false).is_empty(), "%s holds no player" % zone.name)
	var colonnade := zones_node.get_node_or_null("Zone_ForumColonnade") as Area3D
	assert_true(colonnade != null, "ForumColonnade has a zone")
	if colonnade != null:
		assert_true(absf(rad_to_deg(colonnade.global_rotation.y) - 90.0) < 0.01, "ForumColonnade's zone is turned 90 degrees (%s)" % rad_to_deg(colonnade.global_rotation.y))
	for area: Node in nav.find_children("*", "Area3D", true, false):
		assert_true(((area as Area3D).collision_layer & bit) == 0, "no zone-layer area under Nav (%s)" % area.name)
	# The engine's own lookup (AudioStreamPlayer3D's point query), on the zones built a few frames ago.
	var space := m.get_world_3d().direct_space_state
	for zone in zones:
		assert_true(_zones_at(space, _zone_centre(zone)).has(zone), "the point query finds %s at its centre" % zone.name)
	var barracks := zones_node.get_node_or_null("Zone_Barracks_NE") as Area3D
	assert_true(barracks != null, "Barracks_NE has a zone")
	var t := (wanted["Barracks_NE"] as Node3D).global_transform if wanted.has("Barracks_NE") else Transform3D()
	if barracks != null:
		assert_true(_zones_at(space, t * Vector3(0, 1.4, 0)).has(barracks), "a muzzle-height point in the room is inside")
		assert_true(_zones_at(space, t * Vector3(1.0, 0.0, 1.0)).has(barracks), "a foot-level point in the room is inside")
		assert_true(_zones_at(space, t * Vector3(0, 3.3 + 1.0, 0)).is_empty(), "1 m above the roof is outside")
		assert_true(_zones_at(space, t * Vector3(4.5 + 2.0, 1.4, 0)).is_empty(), "2 m outside the wall is outside")
	# Gameplay casts through the zones.
	var def: WeaponDef = DataRegistry.new().get_weapon_def("pilum_br")
	var exclude := _pawn_rids(m)
	var lines: Array = []  # [name, origin, dir]
	if wanted.has("Gate_NW"):
		var g := (wanted["Gate_NW"] as Node3D).global_transform
		lines.append(["gate passage", g * Vector3(0, 1.4, -6.0), g.basis * Vector3(0, 0, 1)])
	if wanted.has("Barracks_NE"):
		lines.append(["barracks doorway", t * Vector3(-2.5, 1.2, -7.0), t.basis * Vector3(0, 0, 1)])
	if wanted.has("ForumColonnade"):
		var c := (wanted["ForumColonnade"] as Node3D).global_transform
		lines.append(["colonnade", c * Vector3(-3.0, 1.4, -5.0), c.basis * Vector3(0, 0, 1)])
	assert_eq(lines.size(), 3, "three cast lines")
	# The test's RayCast3D copies the real rig's aim ray setup; check that setup is still what it copies.
	var rig_ray := m.local_player.find_child("AimRayCast", true, false) as RayCast3D
	assert_true(rig_ray != null, "the local player's CameraRig has its aim ray")
	if rig_ray != null:
		assert_true(rig_ray.collision_mask == 7 and rig_ray.collide_with_areas and rig_ray.collide_with_bodies, "the rig's aim ray: mask 7, areas and bodies")
		rig_ray.force_raycast_update()
		assert_true(not _is_zone(rig_ray.get_collider()), "the rig's own aim ray reports no zone")
	var with_zones: Array = []
	for line: Array in lines:
		var through := false
		for zone in zones:
			var zb := (zone.get_node("Box") as CollisionShape3D)
			var box := AABB(zb.position - (zb.shape as BoxShape3D).size * 0.5, (zb.shape as BoxShape3D).size)
			for step in 48:  # the first 12 m of the line
				var local: Vector3 = zone.global_transform.affine_inverse() * ((line[1] as Vector3) + (line[2] as Vector3) * step * 0.25)
				through = through or box.has_point(local)
		assert_true(through, "the %s line passes through a zone" % line[0])
		with_zones.append(_casts(m, line[1], line[2], def, exclude, String(line[0])))
		print("AUDIO_REVERB_CAST %s hitscan=%s aim=%s ray=%s" % [line[0], with_zones[-1]["hitscan"].get("position"), with_zones[-1]["aim"], with_zones[-1]["ray"]])
	# Zones are not loops: a rebuild leaves the loop count alone; the fresh areas' first query frame is measured.
	var loops_before := _valid_loops()
	var rebuilt := audio.build_reverb_zones(map)
	assert_eq(rebuilt, wanted.size(), "a rebuild makes the same zones")
	assert_eq(_valid_loops(), loops_before, "building zones makes no loop")
	assert_true(not is_instance_valid(zones_node), "a rebuild frees the old zones")
	zones_node = audio.reverb_zones
	assert_eq(String(zones_node.name), "ReverbZones", "the rebuilt node keeps its name")
	barracks = zones_node.get_node_or_null("Zone_Barracks_NE") as Area3D
	var frames_to_query := -1
	for frame in 6:
		if barracks != null and _zones_at(space, _zone_centre(barracks)).has(barracks):
			frames_to_query = frame
			break
		await _tree().physics_frame
	assert_true(frames_to_query >= 0, "a new zone is found within 5 physics frames (%d)" % frames_to_query)
	# Real-map impact materials: one real piece each, a real Hitscan end point, the PawnAudio probe.
	var impacts: Dictionary = sfx.cfg["impacts"]
	var report: Array = []
	var pick := {"stone": ["barracks", "wall_walk", "wall_stair"], "wood": ["stake_row", "tent"], "metal": ["eagle_standard"]}
	for material: String in pick:
		var done := false
		for type: String in pick[material]:  # in order of preference
			for node: Node in _tree().get_nodes_in_group(WorldKit.GROUP):
				if done or not map.is_ancestor_of(node) or String(node.get_meta(&"structure_type", "")) != type:
					continue
				var shot := _shot_at(space, node as CollisionObject3D, exclude)
				if shot.is_empty():
					continue
				assert_eq(String(impacts["by_structure"][type]), material, "%s is %s in data" % [node.name, material])
				_real_impact(m, node, shot[0], shot[1], def, exclude, material, report)
				done = true
		assert_true(done, "a reachable %s structure piece" % material)
	var cover_done := false
	for node: Node in map.find_children("*", "StaticBody3D", true, false):
		if cover_done or not node.has_meta(&"cover_palette"):
			continue
		var shot := _shot_at(space, node as CollisionObject3D, exclude)
		if shot.is_empty():
			continue
		var by_palette: Dictionary = impacts["by_palette"]
		var palette := String(node.get_meta(&"cover_palette"))
		_real_impact(m, node, shot[0], shot[1], def, exclude, String(by_palette.get(palette, by_palette["default"])), report)
		report[-1] = "%s(%s)" % [report[-1], palette]
		cover_done = true
	assert_true(cover_done, "a reachable cover piece")
	var ground_done := false
	var base := m.local_player.global_position
	for i in 9:
		var above := base + Vector3((i % 3 - 1) * 3.0, 6.0, (i / 3 - 1) * 3.0)
		var q := PhysicsRayQueryParameters3D.create(above, above + Vector3.DOWN * 40.0, 1)
		q.exclude = exclude
		var plain := space.intersect_ray(q)
		if plain.is_empty() or (plain["collider"] as Node).name != &"Ground":
			continue
		_real_impact(m, plain["collider"], above, above + Vector3.DOWN, def, exclude, String(impacts["ground"]), report)
		ground_done = true
		break
	assert_true(ground_done, "open ground is reachable")
	# The same casts with the zones gone.
	var gone := audio.reverb_zones
	gone.free()
	await _tree().physics_frame
	await _tree().physics_frame
	for i in lines.size():
		var line: Array = lines[i]
		var without := _casts(m, line[1], line[2], def, exclude, String(line[0]) + " (no zones)")
		for key in ["hitscan", "aim", "ray"]:
			assert_eq(without[key], with_zones[i][key], "%s: %s is the same with and without zones" % [line[0], key])
	# Freeing the match frees the zones.
	audio.build_reverb_zones(map)
	var last := audio.reverb_zones
	assert_true(is_instance_valid(last), "zones rebuilt for the free check")
	print("AUDIO_REVERB_ZONES zones=%d ids=%s monitorable=%s frames_to_query=%d" % [names.size(), ",".join(names), last.get_child(0).get("monitorable") if last.get_child_count() > 0 else "none", frames_to_query])
	print("AUDIO_REAL_IMPACTS ", " ".join(report))
	m.free()
	assert_true(not is_instance_valid(last), "freeing the match frees the zones")
