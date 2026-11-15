extends "res://tests/test_case.gd"
## M2 L1b: a Breakable on its own (no map): the cover contract, health from data/props.json, melee_damage, one
## break only, the look hidden through real MapChunks (the batch's "transforms" meta zero-scaled), the deferred
## removal (the breaking frame still finds the body, the next one does not; on_removed runs once; the cover index
## sees one wall fewer on its next sample), the nearest box point for melee and the existing palette impact sound
## through Sfx. The shot and swing hooks: tests/test_props_hooks.gd; the 1 km build: tests/test_alesia_1km.gd.


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _crate_cfg() -> Dictionary:
	return WorldProps.config()["breakables"]["breakable_crate"]


func _entry(id: String = "Breakable_900", at: Array = [0.0, 0.6, 0.0]) -> Dictionary:
	return {"id": id, "type": "breakable_crate", "at": at, "size": [1.2, 1.2, 1.2]}


func test_make_keeps_the_cover_contract() -> void:
	var b := Breakable.make(_entry(), _crate_cfg())
	var shape := b.get_node_or_null("Shape") as CollisionShape3D
	assert_true(shape != null and shape.shape is BoxShape3D, "a Shape child holding a box")
	if shape != null:
		assert_eq((shape.shape as BoxShape3D).size, Vector3(1.2, 1.2, 1.2), "the box is the entry's size")
	assert_eq(b.collision_layer, 1, "layer 1")
	assert_eq(b.collision_mask, 0, "mask 0")
	assert_true(b.is_in_group(&"cover_wall") and b.is_in_group(Breakable.GROUP), "groups cover_wall and breakable")
	assert_eq(String(b.get_meta(&"cover_palette", "")), String(_crate_cfg()["palette"]), "cover_palette from props.json")
	assert_eq(b.health, float(_crate_cfg()["health"]), "health from props.json")
	assert_eq(String(b.name), "Breakable_900", "named by its id")
	assert_eq(b.position, Vector3(0, 0.6, 0), "at the file position (the builder lifts it)")
	b.free()


func test_gun_hits_lower_health_and_break_once() -> void:
	var b := Breakable.make(_entry(), _crate_cfg())
	var seen: Array = []
	b.broken.connect(func(id: String) -> void: seen.append(id))
	var full := b.health
	assert_true(b.take_hit(full * 0.25), "a hit counts")
	assert_true(is_equal_approx(b.health, full * 0.75) and not b.is_broken, "a quarter off, still standing")
	assert_true(not b.take_hit(0.0), "a hit of no damage does not count")
	b.take_hit(full)
	assert_true(b.is_broken and b.health == 0.0, "broken at 0")
	assert_eq(seen, ["Breakable_900"], "broken emitted once with the id")
	assert_true(not b.take_hit(full), "a broken body takes no more hits")
	b.break_now()
	assert_eq(seen.size(), 1, "break_now on a broken body does nothing")
	await _tree().process_frame  # the deferred removal frees it (never free a body with a pending _leave)


func test_melee_uses_melee_damage() -> void:
	var cfg := _crate_cfg().duplicate()
	cfg["melee_damage"] = 10.0
	var b := Breakable.make(_entry(), cfg)
	b.take_hit(999.0, true)
	assert_eq(b.health, float(cfg["health"]) - 10.0, "a swing does melee_damage, not the weapon damage")
	var one := Breakable.make(_entry("Breakable_901"), _crate_cfg())
	one.take_hit(0.0, true)
	assert_true(one.is_broken, "the shipped melee_damage breaks a crate in one swing")
	b.free()
	await _tree().process_frame  # `one` is freed by its deferred removal


func test_applied_break_emits_nothing() -> void:
	var b := Breakable.make(_entry(), _crate_cfg())
	var seen: Array = []
	b.broken.connect(func(id: String) -> void: seen.append(id))
	b.break_now(false)
	assert_true(b.is_broken and seen.is_empty(), "a state from the host breaks it without the broken signal")
	await _tree().process_frame  # freed by its deferred removal


func test_break_hides_the_look_and_leaves_the_world_next_frame() -> void:
	var holder := Node3D.new()
	_tree().root.add_child(holder)
	var b := Breakable.make(_entry("Breakable_903", [3.0, 0.6, 4.0]), _crate_cfg())
	var chunks := MapChunks.new()
	chunks.setup(0.0)  # one chunk
	chunks.add("cover", "breakable_crate", BoxMesh.new(), null, b.transform, true, b.prop_id)
	chunks.build()
	b.chunks = chunks
	holder.add_child(b)
	var bodies: Array[StaticBody3D] = [b]
	var removed: Array = []
	b.on_removed = func(body: StaticBody3D) -> void:
		removed.append(body)
		bodies.erase(body)
	await _tree().physics_frame
	var index := CoverIndex.of(_tree())
	index.refresh()
	var walls_before := index.size()
	assert_true(walls_before >= 1, "nonvacuous: the index holds the crate")
	b.take_hit(b.health)
	var batch := chunks.get_node("Chunk_0_0/Batch_cover_breakable_crate") as MultiMeshInstance3D
	var meta: Transform3D = batch.get_meta(&"transforms")[0]
	assert_true(chunks.is_piece_hidden("Breakable_903"), "the look is hidden at once")
	assert_true(meta.basis == Basis.from_scale(Vector3.ZERO) and meta.origin == Vector3(3, 0.6, 4), "the batch meta: zero scale at the same origin")
	assert_true(b.is_inside_tree(), "still in the tree in the breaking frame (the shot's impact probe finds it)")
	assert_true(removed.is_empty(), "on_removed waits for the deferred removal")
	await _tree().process_frame
	assert_eq(removed.size(), 1, "on_removed ran once")
	assert_true(bodies.is_empty(), "the builder's list shrinks")
	assert_eq(holder.get_child_count(), 0, "the body left its parent")
	index.refresh()
	assert_eq(index.size(), walls_before - 1, "the cover index sees one wall fewer on its next sample")
	holder.queue_free()
	chunks.free()


func test_closest_point_is_on_the_box() -> void:
	var b := Breakable.make(_entry("Breakable_902", [10.0, 0.6, 0.0]), _crate_cfg())
	assert_eq(b.closest_point(Vector3(0, 0.6, 0)), Vector3(9.4, 0.6, 0), "from the west: the west face")
	assert_eq(b.closest_point(Vector3(10, 0.6, 0.2)), Vector3(10, 0.6, 0.2), "inside: the point itself")
	assert_eq(b.ground_point(), Vector3(10, 0, 0), "the ground under the centre")
	b.free()


func test_break_plays_the_palette_impact() -> void:
	var sfx := _tree().root.get_node_or_null("Sfx")
	assert_true(sfx != null, "the Sfx autoload runs in tests")
	if sfx == null:
		return
	for i in sfx._pool_until.size():
		sfx._pool_until[i] = 0
	sfx._last_play.clear()
	sfx.clear_log()
	var b := Breakable.make(_entry(), _crate_cfg())
	_tree().root.add_child(b)
	b.take_hit(b.health)
	var impacts: Dictionary = sfx.cfg["impacts"]
	var want := String(impacts["by_material"].get(PawnAudio.material_of(b, impacts), sfx.cfg["hooks"]["impact_world"]))
	var ids: Array = []
	for entry: Dictionary in sfx.played:
		ids.append(String(entry["id"]))
	assert_true(want != "" and ids.has(want), "the break plays %s (played %s)" % [want, str(ids)])
	await _tree().process_frame
