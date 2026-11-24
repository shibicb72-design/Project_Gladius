extends "res://tests/test_case.gd"
## A3 item 3: directional flinches (SoldierHitSide, data/anim_third_person.json gait.hit_dir, OQ-A3-HITDIR). Real pawns:
## a rifle shot shown on the SHOOTER's ShotFx (shot_shown) ending on the victim, then the victim's shield + health
## drop, picks the side the shot came from (front, back, left, right, in the victim's own frame); a melee swing of a
## simulated attacker (Pawn.shot) picks the attacker's side; no event plays front; a big drop still plays the head
## clip (gait.hit.head_drop). The graph layer facts are in tests/test_anim_layers.gd.

const RIFLE := "pilum_br"
const MELEE := "gladius_lux"


func _pawn(at: Vector3, yaw: float = 0.0) -> Pawn:
	var tree: SceneTree = Engine.get_main_loop()
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	tree.root.add_child(pawn)
	pawn.set_physics_process(false)
	pawn.global_position = at
	pawn.rotation.y = yaw
	(pawn.get_node("SoldierModel") as SoldierModel).set_process(false)
	return pawn


func _model(pawn: Pawn) -> SoldierModel:
	return pawn.get_node("SoldierModel") as SoldierModel


## The victim takes `amount` of damage and its model looks once (as its _process does every frame).
func _hurt(victim: Pawn, amount: float) -> String:
	var model := _model(victim)
	model._watch_hits()
	victim.bridge.state.health -= amount
	var before := model.hit_count
	model._watch_hits()
	assert_eq(model.hit_count, before + 1, "the drop asks for a flinch")
	model.animation_tree.advance(0.0)
	return model.hit_side


func _shoot(shooter: Pawn, victim: Pawn) -> void:
	shooter.show_shot_fx(shooter.get_muzzle_position(), victim.global_position + Vector3(0, 1.2, 0))


func test_rifle_hits_from_four_sides_pick_that_side() -> void:
	SoldierHitSide.clear()
	var cases := {"front": Vector3(0, 0, -6), "back": Vector3(0, 0, 6), "left": Vector3(-6, 0, 0), "right": Vector3(6, 0, 0)}
	for yaw: float in [0.0, PI * 0.5]:
		var victim := _pawn(Vector3(20, 0, 0), yaw)
		for side: String in cases:
			var shooter := _pawn(victim.global_position + Basis(Vector3.UP, yaw) * (cases[side] as Vector3))
			shooter.loadout.slots[shooter.loadout.active] = Weapon.new(DataRegistry.new().get_weapon_def(RIFLE))
			assert_true(shooter.shot_fx != null and shooter.shot_fx.tracer != null, "the shooter's ShotFx has a tracer (else shot_shown never fires)")
			var heard := [false]
			var probe := func(_o: Vector3, _e: Vector3) -> void: heard[0] = true
			shooter.shot_fx.shot_shown.connect(probe)
			_shoot(shooter, victim)
			assert_true(heard[0], "the real shot_shown fired")
			var got := _hurt(victim, 10.0)
			print("A3_HIT_SIDE rifle yaw=%.0f shooter=%s -> %s" % [rad_to_deg(yaw), side, got])
			assert_eq(got, side, "a rifle hit from the %s (victim yaw %.0f) picks %s" % [side, rad_to_deg(yaw), side])
			assert_eq(String(_model(victim).animation_tree.get("parameters/hit_which/current_state")), side, "the hit layer plays the %s flinch" % side)
			shooter.free()
		victim.free()


func test_a_shot_ending_elsewhere_or_from_the_victim_does_not_match() -> void:
	SoldierHitSide.clear()
	var victim := _pawn(Vector3(40, 0, 0))
	var shooter := _pawn(Vector3(40, 0, 6))
	shooter.show_shot_fx(shooter.get_muzzle_position(), victim.global_position + Vector3(5, 1.2, 0))
	victim.show_shot_fx(victim.get_muzzle_position(), victim.global_position + Vector3(0, 1.0, 0))
	assert_eq(_hurt(victim, 10.0), "front", "a miss beside the victim and its own shot leave the front fallback")
	shooter.free()
	victim.free()


func test_a_late_drop_inside_the_window_still_matches_and_a_stale_one_does_not() -> void:
	SoldierHitSide.clear()
	var tree: SceneTree = Engine.get_main_loop()
	var victim := _pawn(Vector3(60, 0, 0))
	var shooter := _pawn(Vector3(60, 0, 6))
	var window := float(SoldierHitSide.cfg()["window_s"])
	# A replica: the shot is shown at once, the damage arrives in a later snapshot.
	_shoot(shooter, victim)
	await tree.create_timer(window * 0.3).timeout
	assert_eq(_hurt(victim, 10.0), "back", "a drop seen %.2f s after its shot uses it" % (window * 0.3))
	_shoot(shooter, victim)
	await tree.create_timer(window + 0.15).timeout
	assert_eq(_hurt(victim, 10.0), "front", "a shot older than window_s is not used")
	shooter.free()
	victim.free()


func test_melee_from_a_simulated_attacker_picks_its_side() -> void:
	SoldierHitSide.clear()
	var victim := _pawn(Vector3(80, 0, 0))
	for side: String in ["right", "back"]:
		var at := Vector3(1.5, 0, 0) if side == "right" else Vector3(0, 0, 1.5)
		var attacker := _pawn(victim.global_position + at)
		attacker.loadout.slots[attacker.loadout.active] = Weapon.new(DataRegistry.new().get_weapon_def(MELEE))
		attacker.shot.emit(attacker.get_muzzle_position(), (victim.global_position - attacker.global_position).normalized(), MELEE)
		var got := _hurt(victim, 10.0)
		print("A3_HIT_SIDE melee attacker=%s -> %s" % [side, got])
		assert_eq(got, side, "a melee hit from the %s picks %s" % [side, side])
		attacker.free()
	victim.free()


## Every side's flinch moves only the flinch bones, the left-arm IK chain and the neck follower, the follower by at
## most head.limits.flinch_neck_max_deg (as tests/test_soldier_head_motion.gd checks for the default front flinch).
func test_every_side_stays_inside_the_head_motion_limits() -> void:
	SoldierRig.head_legacy = false
	var tree: SceneTree = Engine.get_main_loop()
	var allowed := ["Spine", "Chest", "LeftUpperArm", "RightUpperArm", "LeftForeArm", "LeftHand", "Neck", "Head"]
	var limit := float(SoldierRig.config()["head"]["limits"]["flinch_neck_max_deg"])
	var runs := {}
	for side: String in ["none", "front", "back", "left", "right"]:
		var pawn := _pawn(Vector3(120, 0, 0))
		var model := _model(pawn)
		model.animation_tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
		model.skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
		var frames: Array = []
		for f in 50:
			if f == 12 and side != "none":
				model.flinch(false, side)
			model._process(1.0 / 60.0)
			model.animation_tree.advance(1.0 / 60.0)
			model.skeleton.advance(1.0 / 60.0)
			await tree.process_frame
			var locals: Array[Transform3D] = []
			for i in model.skeleton.get_bone_count():
				var parent := model.skeleton.get_bone_parent(i)
				locals.append(model.pose_cache[i] if parent < 0 else model.pose_cache[parent].affine_inverse() * model.pose_cache[i])
			frames.append(locals)
		runs[side] = {"frames": frames, "names": range(model.skeleton.get_bone_count()).map(func(i: int) -> String: return String(model.skeleton.get_bone_name(i)))}
		pawn.free()
		await tree.process_frame
	var base: Array = runs["none"]["frames"]
	var names: Array = runs["none"]["names"]
	for side: String in ["front", "back", "left", "right"]:
		var moved := {}
		for f in base.size():
			for i in names.size():
				var turn := rad_to_deg((base[f][i] as Transform3D).basis.get_rotation_quaternion().angle_to((runs[side]["frames"][f][i] as Transform3D).basis.get_rotation_quaternion()))
				if turn > 0.1:
					moved[names[i]] = maxf(float(moved.get(names[i], 0.0)), turn)
		print("A3_HIT_FLINCH %s moved (max deg vs none): %s" % [side, moved])
		assert_true(moved.has("Chest") or moved.has("Spine"), "%s: nonvacuous, the torso moves" % side)
		for bone: String in moved:
			assert_true(allowed.has(bone), "%s: only the flinch bones, the left-arm IK and the neck follower move (%s)" % [side, bone])
		for bone in ["Neck", "Head"]:
			assert_true(float(moved.get(bone, 0.0)) <= limit, "%s: %s follows by at most %.0f deg (%.2f)" % [side, bone, limit, float(moved.get(bone, 0.0))])


func test_no_event_plays_front_and_a_big_drop_plays_head() -> void:
	SoldierHitSide.clear()
	var victim := _pawn(Vector3(100, 0, 0))
	var model := _model(victim)
	assert_eq(_hurt(victim, 10.0), "front", "no shot, no swing: the front flinch")
	assert_eq(String(model.animation_tree.get("parameters/hit_which/current_state")), "front", "the hit layer plays front")
	# A big drop plays the head clip, whatever side the shot came from.
	var shooter := _pawn(Vector3(106, 0, 0))
	_shoot(shooter, victim)
	model._watch_hits()
	victim.bridge.state.shield = 0.0
	victim.bridge.state.health -= float(SoldierRig.config()["gait"]["hit"]["head_drop"]) + 1.0
	model._watch_hits()
	model.animation_tree.advance(0.0)
	assert_eq(String(model.animation_tree.get("parameters/hit_which/current_state")), "head", "a drop of head_drop or more plays the head clip")
	assert_eq(model.hit_side, "right", "the side is still recorded")
	# The old one-argument call keeps working (front by default).
	model.flinch(false)
	model.animation_tree.advance(0.0)
	assert_eq(String(model.animation_tree.get("parameters/hit_which/current_state")), "front", "flinch(false) plays front")
	shooter.free()
	victim.free()
