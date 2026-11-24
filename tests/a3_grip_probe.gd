extends SceneTree
## A3 fix pass 1 (B3) diagnosis, NOT a test (no test_ prefix). Headless:
##   godot.cmd --headless --path . --script res://tests/a3_grip_probe.gd --log-file <log>
## Per armour set and long gun, after 1 s of the default aim (pawn physics off, model ticked at 60 Hz as the A3 tests
## do), in the shown gun's own frame (RifleModel local: the mesh's units): the foregrip marker (left-hand IK target),
## the LeftHand bone, the glove (Hand + Fingers vertices, skinned on the CPU by the drawn pose) and the gun mesh's
## cross-section at the glove (vertices within SLAB of the glove's centre z): where the palm sits against the
## handguard. Then the forearm (LeftForeArm vertices): how many lie inside the gun's cross-section at their own z
## (sunk into the receiver / handguard), and the elbow. Presentation measurement only.

const DT := 1.0 / 60.0
const SLAB := 0.03
const GUNS: Array[String] = ["pilum_br", "sagittarii_rifle"]


func _initialize() -> void:
	_run.call_deferred()


func _verts(mesh: Mesh, skin: Skin, skeleton: Skeleton3D, globals: Array[Transform3D], suffixes: Array, to_local: Transform3D) -> PackedVector3Array:
	var out := PackedVector3Array()
	var sets := SoldierCorpse._limb_verts(mesh, skin, skeleton, suffixes)
	for v: Array in sets["Left"]:
		var p := Vector3.ZERO
		for j in (v[1] as Array).size():
			var bind: int = v[1][j]
			p += float(v[2][j]) * (globals[skin.get_bind_bone(bind)] * skin.get_bind_pose(bind) * (v[0] as Vector3))
		out.append(to_local * p)
	return out


## The gun's triangle edges as point pairs (the section at a z is where they cross it).
func _gun_points(mesh: Mesh) -> PackedVector3Array:
	var out := PackedVector3Array()
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		if idx.is_empty():
			for i in v.size():
				idx.append(i)
		for t in range(0, idx.size() - 2, 3):
			for e in 3:
				out.append(v[idx[t + e]])
				out.append(v[idx[t + (e + 1) % 3]])
	return out


func _section(gun: PackedVector3Array, z: float) -> AABB:
	var box := AABB()
	var first := true
	for i in range(0, gun.size(), 2):
		var a := gun[i]
		var b := gun[i + 1]
		if (a.z - z) * (b.z - z) > 0.0 or is_equal_approx(a.z, b.z):
			continue
		var p := a.lerp(b, (z - a.z) / (b.z - a.z))
		if first:
			box = AABB(p, Vector3.ZERO)
			first = false
		else:
			box = box.expand(p)
	return box


func _range(points: PackedVector3Array) -> AABB:
	var box := AABB(points[0], Vector3.ZERO)
	for p in points:
		box = box.expand(p)
	return box


func _v(p: Vector3) -> String:
	return "(%.3f,%.3f,%.3f)" % [p.x, p.y, p.z]


func _run() -> void:
	for set_id in ["legionary", "murmillo"]:
		for gun_id in GUNS:
			var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
			pawn.set_meta("armour_set", set_id)
			root.add_child(pawn)
			pawn.set_physics_process(false)
			pawn.loadout.slots[pawn.loadout.active] = Weapon.new(DataRegistry.new().get_weapon_def(gun_id))
			var model := pawn.get_node("SoldierModel") as SoldierModel
			model.set_process(false)
			model.animation_tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
			model.skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
			for i in 60:
				model._process(DT)
				model.animation_tree.advance(DT)
				model.skeleton.advance(DT)
				await process_frame
			var sk := model.skeleton
			var rifle := model.rifle
			# Skeleton space -> rifle local.
			var to_local := (sk.global_transform.affine_inverse() * rifle.global_transform).affine_inverse()
			var hand := to_local * model.pose_cache[sk.find_bone("LeftHand")].origin
			var fore := to_local * model.pose_cache[sk.find_bone("LeftForeArm")].origin
			var upper := to_local * model.pose_cache[sk.find_bone("LeftUpperArm")].origin
			var grip := model.foregrip.position
			var glove := _verts(model.armor.mesh, model.armor.skin, sk, model.pose_cache, ["Hand", "Fingers"], to_local)
			var arm := _verts(model.armor.mesh, model.armor.skin, sk, model.pose_cache, ["ForeArm"], to_local)
			var gun := _gun_points(rifle.mesh)
			var g := _range(glove)
			var centre := g.get_center()
			var sec := _section(gun, centre.z)
			var inside := 0
			for p in arm:
				var s := _section(gun, p.z)
				if s.size != Vector3.ZERO and s.grow(0.0).has_point(p):
					inside += 1
			var a := _range(arm)
			print("GRIP set=%s gun=%s foregrip=%s hand_bone=%s err_m=%.3f elbow=%s shoulder=%s rifle_scale=%s" % [set_id, gun_id, _v(grip), _v(hand), hand.distance_to(grip), _v(fore), _v(upper), _v(rifle.transform.basis.get_scale())])
			print("GRIP   glove x=%.3f..%.3f y=%.3f..%.3f z=%.3f..%.3f centre=%s | gun section at z=%.3f: x=%.3f..%.3f y=%.3f..%.3f" % [g.position.x, g.end.x, g.position.y, g.end.y, g.position.z, g.end.z, _v(centre), centre.z, sec.position.x, sec.end.x, sec.position.y, sec.end.y])
			print("GRIP   forearm verts=%d inside_gun=%d x=%.3f..%.3f y=%.3f..%.3f z=%.3f..%.3f | gun x=%.3f..%.3f y=%.3f..%.3f z=%.3f..%.3f" % [arm.size(), inside, a.position.x, a.end.x, a.position.y, a.end.y, a.position.z, a.end.z,
					_range(gun).position.x, _range(gun).end.x, _range(gun).position.y, _range(gun).end.y, _range(gun).position.z, _range(gun).end.z])
			pawn.free()
			await process_frame
	quit(0)
