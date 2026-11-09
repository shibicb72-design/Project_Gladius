extends "res://tests/test_case.gd"
## C2 and D1 (Shibi, Nov 9 2026): the helmet is built around the head hitbox ("what you see is what you can
## headshot") and the yellow head sphere is a debug overlay, off by default. The hitbox itself is unchanged.
const Checks := preload("res://tests/soldier_checks.gd")
const TOLERANCE := 0.00001  # float comparison slack in metres, not a tunable


func _pawn() -> Pawn:
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	(Engine.get_main_loop() as SceneTree).root.add_child(pawn)
	pawn.set_physics_process(false)
	(pawn.get_node("SoldierModel") as SoldierModel).set_process(false)
	return pawn


func test_helmet_shell_encloses_the_head_hitbox_sphere() -> void:
	var pawn := _pawn()
	var centre := (pawn.get_node("Head") as Node3D).position
	var radius := Checks.head_radius(pawn)
	var shell := {}
	for part: Dictionary in LowpolyKit.config()["soldier"]["parts"]:
		if part["name"] == Checks.helmet_cfg()["shell_part"]:
			shell = part
	assert_true(not shell.is_empty(), "the shell part named in data exists")
	var points := LowpolyShapes.triangles(shell, LowpolyKit.config()["kit"]["shapes"])
	var xf := LowpolyShapes.transform_of(shell)
	# The shell is a closed solid (tests/test_kit_shapes.gd). If the hitbox centre is at least one radius inside
	# every face plane, the whole sphere is inside the shell: no part of the hitbox can be hit through thin air.
	var nearest := INF
	for i in range(0, points.size(), 3):
		var a := xf * points[i]
		var normal := (xf * points[i + 1] - a).cross(xf * points[i + 2] - a).normalized()
		nearest = minf(nearest, normal.dot(a - centre))
	assert_true(points.size() >= 12 and nearest >= radius, "every face of the helmet shell is outside the hitbox sphere: nearest %s, radius %s" % [nearest, radius])
	print("ASTRA_HELMET shell_faces=", points.size() / 3, " nearest_face_m=", nearest, " hitbox_radius_m=", radius, " margin_m=", Checks.helmet_margin())
	pawn.free()


func test_helmet_contains_the_hitbox_within_the_margin_and_the_body_keeps_clear() -> void:
	var cfg := Checks.helmet_cfg()
	assert_true(bool(cfg["_placeholder"]) and String(cfg["_todo"]).contains("OQ-3D-HELMET"), "helmet margins are placeholders with an OQ id")
	var pawn := _pawn()
	var model := pawn.get_node("SoldierModel") as SoldierModel
	var names: Array = model.get_meta("parts")
	var hitbox := Checks.head_box(pawn)
	var helmet := AABB()
	var helmet_parts := 0
	var crests := 0
	for i in model.part_bounds.size():
		var bounds := model.part_bounds[i]
		if Checks.is_helmet(model, i):
			helmet = bounds if helmet_parts == 0 else helmet.merge(bounds)
			helmet_parts += 1
			if Checks.is_crest(model, i):
				crests += 1
			else:
				assert_true(hitbox.grow(Checks.helmet_margin() + TOLERANCE).encloses(bounds), "helmet part %s reaches at most the margin past the hitbox: %s" % [names[i], bounds])
		else:
			assert_true(not hitbox.grow(Checks.body_clearance()).intersects(bounds), "body part %s keeps clear of the head hitbox: %s" % [names[i], bounds])
	assert_true(helmet_parts >= 2 and helmet.encloses(hitbox), "the helmet contains the head hitbox: %s around %s" % [helmet, hitbox])
	assert_eq(crests, (cfg["crest_parts"] as Array).size(), "every crest part named in data is a helmet part")
	assert_true(helmet_parts < model.part_bounds.size(), "nonvacuous: there are body parts too")
	pawn.free()


func test_yellow_head_sphere_is_a_debug_overlay_off_by_default() -> void:
	var flag: Dictionary = LowpolyKit.config()["soldier"]["debug_head_sphere"]
	assert_true(bool(flag["_placeholder"]) and String(flag["_todo"]).contains("OQ-ART-ASTRA"), "the flag is placeholder data with its OQ id")
	assert_eq(bool(flag["visible"]), false, "off by default (D1)")
	var pawn := _pawn()
	var head := pawn.get_node("Head") as Area3D
	var sphere := head.get_node("HeadMesh") as MeshInstance3D
	assert_true(not sphere.visible, "no yellow sphere on a pawn by default")
	assert_true(head.is_in_group(&"head_hitbox") and head.collision_layer == 4 and head.position == Vector3(0, 1.75, 0)
			and is_equal_approx(Checks.head_radius(pawn), 0.22), "the head hitbox is unchanged")
	var corpse := (pawn.get_node("SoldierModel") as SoldierModel).make_corpse()
	assert_true(corpse.get_node_or_null("Skeleton3D/HeadAttachment/Shell") == null, "no yellow sphere on a corpse by default")
	corpse.free()
	pawn.free()
	flag["visible"] = true  # the registry caches this dictionary: flip it for one pawn, then restore it
	var shown := _pawn()
	var shown_sphere := shown.get_node("Head/HeadMesh") as MeshInstance3D
	assert_true(shown_sphere.visible, "flag on: the sphere shows on the pawn")
	assert_eq((shown_sphere.material_override as StandardMaterial3D).albedo_color, Color(1, 0.9, 0.2, 1), "the overlay keeps the exact yellow the Fold detector looks for")
	var shown_corpse := (shown.get_node("SoldierModel") as SoldierModel).make_corpse()
	var shell := shown_corpse.get_node_or_null("Skeleton3D/HeadAttachment/Shell") as MeshInstance3D
	assert_true(shell != null and shell.mesh == shown_sphere.mesh and shell.material_override == shown_sphere.material_override, "flag on: the corpse carries the same sphere")
	if shell != null:
		assert_eq((shell.get_parent() as BoneAttachment3D).bone_name, &"Head", "the corpse sphere follows the Head bone")
	flag["visible"] = false
	shown_corpse.free()
	shown.free()
