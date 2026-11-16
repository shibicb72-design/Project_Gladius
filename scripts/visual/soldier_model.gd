class_name SoldierModel
extends Node3D
## One shared vertex-colour surface, no hitboxes. Only reads pawn velocity.
static var _mesh: ArrayMesh
var skeleton: Skeleton3D
var armor: MeshInstance3D
var armor_far: MeshInstance3D  # M2 AN2 item 1: the body's far LOD (null with the code-built mesh)
var local_part_bounds: Array[AABB] = []
var part_bones := PackedInt32Array()
var animation_tree: AnimationTree
var _animation_cfg: Dictionary
var _previous_position := Vector3.ZERO
var _replica_velocity := Vector3.ZERO
var _upper_cfg: Dictionary
var reload_duration_s := 0.0
var rifle: MeshInstance3D
var rifle_far: MeshInstance3D  # M2 AN1 commit 6: the gun's far detail level (child of rifle)
var shown_gun := ""  # the weapon art id of the gun in the hands
var stock_point := Vector3.ZERO  # the butt of the shown gun, in the rifle mesh's frame
var hand_attachment: BoneAttachment3D
var foregrip: Marker3D
var barrel_tip: Marker3D
var left_ik: TwoBoneIK3D
var right_hand_bone := -1
var pose_cache: Array[Transform3D] = []
var hand_error_m := 0.0
var recoil_left_s := 0.0
var _recoil_recover_s := 0.0
var _recoil_power := 0.0
var _recoil_pitch := 0.0
var _recoil_kick := Vector3.ZERO
var _rifle_rest := Transform3D.IDENTITY
var sway_enabled := true
var _clock := 0.0
var _pawn: CharacterBody3D
var _cfg: Dictionary
var part_bounds: Array[AABB] = []
var shown_squad := 0  # the squad id whose colour the armor shows (C3)
var shown_tier := 0  # the armor tier whose trim the armor shows (S4)
var _cape_lift := 0.0
var pose: SoldierPose
var blade: MeshInstance3D
static var _blade: ArrayMesh
## M2 AN1 commit 4: library gait (data/anim.json "gait").
var gait: SoldierGait
var crawl: SoldierCrawl
var gait_rate := 1.0  # gait cycles per second shown (ground speed / cycle_m)
var airborne := false
var hit_count := 0  # flinches requested so far (tests, captures)
var _gait_cfg: Dictionary
var _cycles: Dictionary = {}
var _sprint := 1.0
var _air_s := 0.0
var _replica_vy := 0.0
var _last_hp := -1.0
## M2 AN2 items 3/5: keyed whole-body clips (assets/generated/characters/soldier_keyed.glb) played through SoldierPose.
## Climbing (pawn.climbing, read-only): ladder_up / ladder_down at the time the feet's height on the ladder gives, the
## model turned to face the ladder, the gun slung; ladder_top once after the top step. One-shots: play_action.
const ACTIONS: Array[String] = ["door_open", "chest_open", "pickup_ground"]
var climb_weight := 0.0  # 0..1 shown
var climb_clip := ""  # "ladder_up" / "ladder_down" while climbing
var action_name := ""  # the one-shot playing ("" none): an ACTIONS entry or "ladder_top"
var action_s := 0.0
var action_count := 0  # one-shots started so far (tests, captures)
var _keyed: Dictionary = {}
var _action_clips: Dictionary = {}  # slot -> Animation (only the slots that resolved)
var _climb_up := true
var _was_climbing := false
var _climb_last_pos := Vector3.ZERO
var _ladder_foot_y := 0.0
var _ladder_yaw := 0.0  # world yaw that faces into the ladder
var _yaw_owned := false
var _top_offset := Vector3.ZERO

func _ready() -> void:
	# M2 AN1 commit 6: the parts are art_astra.json's (read-only) with data/art_soldier.json soldier's overrides on top.
	_cfg = (LowpolyKit.config()["soldier"] as Dictionary).duplicate(false)
	_cfg["parts"] = SoldierLook.parts()
	_pawn = get_parent() as CharacterBody3D
	var parts: Array = _cfg["parts"]
	skeleton = SoldierRig.build(parts, (_pawn.get_node("Head") as Node3D).position)
	add_child(skeleton)
	_mesh = SoldierRig.mesh
	armor = MeshInstance3D.new()
	armor.name = "Armor"
	armor.mesh = _mesh
	armor.skin = SoldierRig.skin
	armor.skeleton = NodePath("..")
	skeleton.add_child(armor)
	# M2 AN2 item 1: the Blender-built body has a far LOD; it takes over from the near one at the gun's far
	# distance (the same hand-over as the gun). Both instances share the skeleton, the skin and the one material,
	# and one culling box, so the hand-over distance is measured from the same centre.
	if SoldierRig.mesh_far != null:
		armor_far = MeshInstance3D.new()
		armor_far.name = "ArmorFar"
		armor_far.mesh = SoldierRig.mesh_far
		armor_far.skin = SoldierRig.skin
		armor_far.skeleton = NodePath("..")
		var far_m := float(SoldierLook.config()["gun"]["far_m"])
		var box := _mesh.get_aabb().grow(float(SoldierLook.config().get("lod_aabb_grow_m", 0.6)))
		armor.custom_aabb = box
		armor_far.custom_aabb = box
		armor.visibility_range_end = far_m
		armor_far.visibility_range_begin = far_m
		skeleton.add_child(armor_far)
	local_part_bounds = SoldierRig.part_local_bounds(parts, skeleton)
	pose_cache.resize(skeleton.get_bone_count())
	_cache_pose()
	skeleton.skeleton_updated.connect(_cache_pose)
	var mapping: Dictionary = SoldierRig.config()["part_bones"]
	var names: Array[String] = []
	for part: Dictionary in parts:
		names.append(part["name"])
		part_bones.append(skeleton.find_bone(mapping[part["name"]]))
	part_bounds.assign(SoldierRig.rest_bounds(parts))
	set_meta("parts", names)
	if _pawn != null:
		(_pawn.get_node("Body") as MeshInstance3D).visible = false
		# D1: the helmet replaces the yellow head sphere, which stays as a debug overlay behind a data flag.
		(_pawn.get_node("Head/HeadMesh") as MeshInstance3D).visible = bool(_cfg["debug_head_sphere"]["visible"])
	_animation_cfg = SoldierRig.config()["locomotion"]
	var registry := DataRegistry.new()
	var movement := registry.get_movement_cfg()
	var initial_weapon := registry.get_weapon_def(String(registry.get_loadout_ids((_pawn as Pawn).class_id).get("primary", "")))
	var initial_reload := initial_weapon.reload_s if initial_weapon != null and initial_weapon.reload_s > 0.0 else float(_animation_cfg["idle_s"])
	_sprint = float(movement["sprint_speed_multiplier"]["value"])
	animation_tree = SoldierAnimation.build(skeleton, _sprint, initial_reload)
	add_child(animation_tree)
	_gait_cfg = SoldierRig.config()["gait"]
	_cycles = animation_tree.get_meta(&"gait_cycles", {})
	# M2 AN1: the gait modifier runs first after the tree (hip turn for strafes, library spine and neck carry).
	gait = SoldierGait.new()
	gait.name = "Gait"
	skeleton.add_child(gait)
	gait.setup()
	_previous_position = _pawn.global_position
	_upper_cfg = SoldierRig.config()["upper_body"]
	var shot_cfg: Dictionary = registry.load_file("res://data/ui.json")["shot_fx"]
	_recoil_recover_s = float(shot_cfg["viewmodel_recoil_recover_s"])
	_recoil_kick = LowpolyKit.vec(shot_cfg["viewmodel_recoil_m"])
	_recoil_pitch = deg_to_rad(float(SoldierRig.config()["recoil"]["rifle_pitch_deg"]))
	_recoil_power = float(SoldierRig.config()["recoil"]["recover_power"])
	var pawn := _pawn as Pawn
	_show_squad()
	# S4: poses from read-only pawn state (falling, landing, downed, reviving, blade), over the graph's result.
	pose = SoldierPose.new()
	pose.name = "Pose"
	skeleton.add_child(pose)
	pose.setup(pawn)
	# M2 AN1: the downed knee-crawl takes the hips, legs and neck over from the downed pose.
	crawl = SoldierCrawl.new()
	crawl.name = "Crawl"
	skeleton.add_child(crawl)
	crawl.setup()
	_keyed = SoldierRig.config().get("keyed", {})
	for slot: String in ["ladder_up", "ladder_down", "ladder_top"] + ACTIONS:
		var clip := SoldierAnimation.shared(slot, skeleton)
		if clip != null:
			_action_clips[slot] = clip
	pawn.reload_started.connect(_on_reload_started)
	pawn.weapon_switched.connect(_on_weapon_switched)
	pawn.visibility_changed.connect(_on_visibility_changed)

func _show_squad() -> void:
	shown_squad = (_pawn as Pawn).squad_id
	SoldierSquadColour.apply(armor, shown_squad)
	if armor_far != null:
		SoldierSquadColour.apply(armor_far, shown_squad)


## Fill a caller-owned array; no allocation in the animation path.
func posed_bounds(out: Array[AABB]) -> void:
	for i in local_part_bounds.size():
		out[i] = skeleton.global_transform * pose_cache[part_bones[i]] * local_part_bounds[i]


func _cache_pose() -> void:
	for i in pose_cache.size():
		pose_cache[i] = skeleton.get_bone_global_pose(i)
	if foregrip != null:
		var hand := skeleton.global_transform * pose_cache[skeleton.find_bone("LeftHand")]
		hand_error_m = hand.origin.distance_to(foregrip.global_position)

static func add_rifle(parent: MeshInstance3D) -> MeshInstance3D:
	var rifle := MeshInstance3D.new()
	rifle.name = "RifleModel"
	rifle.mesh = SoldierLook.gun_mesh("", "near")
	parent.add_child(rifle)
	parent.layers = 0
	var model := parent.get_parent().get_parent().get_node_or_null("SoldierModel") as SoldierModel
	if model != null:
		model.mount_rifle(rifle)
	return rifle


func mount_rifle(mesh: MeshInstance3D) -> void:
	rifle = mesh
	right_hand_bone = skeleton.find_bone("RightHand")
	hand_attachment = BoneAttachment3D.new()
	hand_attachment.name = "RightHandAttachment"
	hand_attachment.bone_name = &"RightHand"
	skeleton.add_child(hand_attachment)
	rifle.reparent(hand_attachment, false)
	foregrip = Marker3D.new()
	foregrip.name = "Foregrip"
	rifle.add_child(foregrip)
	barrel_tip = Marker3D.new()
	barrel_tip.name = "BarrelTip"
	rifle.add_child(barrel_tip)
	# M2 AN1 commit 6: a far copy of the gun (silhouette parts only) takes over past gun.far_m (visibility ranges).
	rifle_far = MeshInstance3D.new()
	rifle_far.name = "RifleFar"
	rifle.add_child(rifle_far)
	var far_m := float(SoldierLook.config()["gun"]["far_m"])
	rifle.visibility_range_end = far_m
	rifle_far.visibility_range_begin = far_m
	var weapon := (_pawn as Pawn).loadout.get_active() if _pawn != null and (_pawn as Pawn).loadout != null else null
	var first := weapon.def.id if weapon != null and not weapon.def.is_melee() else ""
	if first == "" and _pawn != null:
		first = String(DataRegistry.new().get_loadout_ids((_pawn as Pawn).class_id).get("primary", ""))
	show_gun(first)
	# S4: the blade shares the hand with the rifle; only the active weapon's model is shown (_process).
	var blade_cfg: Dictionary = _cfg["blade"]
	if _blade == null:
		_blade = LowpolyKit.merge(blade_cfg["parts"])
	blade = MeshInstance3D.new()
	blade.name = "BladeModel"
	blade.mesh = _blade
	var turn := LowpolyKit.vec(blade_cfg["hand_rot_deg"])
	blade.transform = Transform3D(Basis.from_euler(Vector3(deg_to_rad(turn.x), deg_to_rad(turn.y), deg_to_rad(turn.z))), LowpolyKit.vec(blade_cfg["hand_offset_m"]))
	blade.visible = false
	hand_attachment.add_child(blade)
	var sync := SoldierHandSync.new()
	sync.name = "HandTargetSync"
	sync.model = self
	skeleton.add_child(sync)
	# ClassDB probe verifies the native 4.7 solver before instantiation.
	assert(ClassDB.class_exists("TwoBoneIK3D"))
	left_ik = ClassDB.instantiate("TwoBoneIK3D") as TwoBoneIK3D
	left_ik.name = "LeftArmIK"
	left_ik.set_setting_count(1)
	skeleton.add_child(left_ik)
	left_ik.set_root_bone_name(0, "LeftUpperArm")
	left_ik.set_middle_bone_name(0, "LeftForeArm")
	left_ik.set_end_bone_name(0, "LeftHand")
	left_ik.set_target_node(0, left_ik.get_path_to(foregrip))
	var pole := Marker3D.new()
	pole.name = "LeftElbowPole"
	pole.position = skeleton.get_bone_global_rest(skeleton.find_bone("LeftUpperArm")).origin + LowpolyKit.vec(_upper_cfg["left_pole"])
	skeleton.add_child(pole)
	left_ik.set_pole_node(0, left_ik.get_path_to(pole))


## M2 AN1 commit 6: the gun in the hands is the active gun's own model (data/art_soldier.json soldier.gun): the
## Pilum BR, the Sagittarii rifle with its scope, ... Only the visible mesh and its hand markers move; the gameplay
## muzzle and the shot effects' origin do not.
func show_gun(id: String) -> void:
	var key := SoldierLook.gun_id(id)
	if key == shown_gun or rifle == null:
		return
	shown_gun = key
	rifle.mesh = SoldierLook.gun_mesh(key, "near")
	rifle_far.mesh = SoldierLook.gun_mesh(key, "far")
	_rifle_rest = Transform3D(Basis.IDENTITY, -SoldierLook.gun_point(key, "grip_m"))
	rifle.transform = _rifle_rest
	foregrip.position = SoldierLook.gun_point(key, "foregrip_m")
	barrel_tip.position = SoldierLook.gun_point(key, "muzzle_m")
	stock_point = SoldierLook.gun_point(key, "stock_m")
	_update_recoil(0.0)

func _process(delta: float) -> void:
	if _pawn == null:
		return
	# D2: squad ids change without a signal (MatchDirector.start), so the model polls its own pawn.
	if (_pawn as Pawn).squad_id != shown_squad:
		_show_squad()
	# S4: the armor tier is read the same way (it changes on pickup, without a signal).
	if (_pawn as Pawn).armor_tier != shown_tier:
		shown_tier = (_pawn as Pawn).armor_tier
		SoldierSquadColour.apply_tier(armor, shown_tier)
		if armor_far != null:
			SoldierSquadColour.apply_tier(armor_far, shown_tier)
	if not is_visible_in_tree():
		return
	_show_weapon()
	_clock += delta
	_update_recoil(delta)
	var pawn := _pawn as Pawn
	var observed := (_pawn.global_position - _previous_position) / delta if delta > 0.0 else Vector3.ZERO
	_previous_position = _pawn.global_position
	_replica_vy = observed.y
	observed.y = 0.0
	if observed.length() > pawn.get_max_move_speed() * float(_animation_cfg["teleport_speed_multiplier"]):
		observed = Vector3.ZERO
	var smooth_s := float(_animation_cfg["replica_smoothing_s"])
	_replica_velocity = _replica_velocity.lerp(observed, 1.0 - exp(-delta / smooth_s) if smooth_s > 0.0 else 1.0)
	var velocity := _pawn.velocity
	velocity.y = 0.0
	if velocity.is_zero_approx():
		velocity = _replica_velocity
	var local := _pawn.global_transform.basis.inverse() * velocity
	var blend := Vector2(local.x, local.z) / pawn.get_move_speed()
	animation_tree.set("parameters/locomotion/blend_position", blend)
	_drive_gait(blend, velocity.length())
	crawl.move_local = local
	crawl.weight = float(pose.weights["downed"])
	_drive_air(delta)
	drive_actions(delta)
	_watch_hits()
	# S4: the cape swings back with forward speed (and streams up in a fall); a per-instance shader value.
	var cape: Dictionary = _cfg["material"]["cape"]
	var lift := clampf(-local.z / maxf(pawn.get_max_move_speed(), 0.01), 0.0, 1.0)
	if pawn.drop_state == Pawn.Drop.FALLING:
		lift = 1.0
	# M2 AN2 item 1: downed (body pitched forward, knee-crawl) the cape rides the chest along the tilted back and its
	# hem would stick up like a plank; a negative lift drapes the hem down and in over the hips instead.
	lift = lerpf(lift, float(SoldierLook.config().get("cape_downed_lift", 0.0)), clampf(float(pose.weights["downed"]), 0.0, 1.0))
	_cape_lift = lerpf(_cape_lift, lift, 1.0 - exp(-delta / float(cape["smooth_s"])))
	armor.set_instance_shader_parameter(&"cape_lift", _cape_lift)
	if armor_far != null:
		armor_far.set_instance_shader_parameter(&"cape_lift", _cape_lift)
	var pitch_limit := deg_to_rad(float(_upper_cfg["aim_pitch_limit_deg"]))
	animation_tree.set("parameters/aim/blend_position", clampf(pawn.pitch / pitch_limit, -1.0, 1.0))


## S4: the model in the hand is the active weapon's: the rifle, or the blade when only the blade is held.
## The left hand lets go of the rifle's foregrip as far as a pose takes the arms (SoldierPose.arms_weight).
func _show_weapon() -> void:
	if rifle == null or blade == null:
		return
	var pawn := _pawn as Pawn
	var weapon := pawn.loadout.get_active() if pawn.loadout != null else null
	var melee := weapon != null and weapon.def.is_melee()
	if weapon != null and not melee and weapon.def.id != shown_gun:
		show_gun(weapon.def.id)
	# M2 AN1 commit 6: a downed soldier crawls on both hands; the gun is slung (hidden) instead of dragging on the
	# ground from the right hand (data/art_soldier.json soldier.gun.hide_downed_weight).
	var downed := pose != null and float(pose.weights["downed"]) >= float(SoldierLook.config()["gun"]["hide_downed_weight"])
	rifle.visible = not melee and not downed and not gun_slung()
	blade.visible = melee
	if left_ik != null and pose != null:
		# M2 AN2: the climb and the one-shots take the left arm too (SoldierPose also counts them, a frame later).
		left_ik.influence = 1.0 - maxf(pose.arms_weight, maxf(climb_weight, action_weight()))


func bind_shot_fx(fx: ShotFx) -> void:
	fx.shot_shown.connect(_on_shot_shown)


func _on_shot_shown(_origin: Vector3, _end: Vector3) -> void:
	var pawn := _pawn as Pawn
	var weapon := pawn.loadout.get_active()
	if pawn.is_alive() and weapon != null and not weapon.def.is_melee():
		animation_tree.set("parameters/fire/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
		recoil_left_s = _recoil_recover_s
		_update_recoil(0.0)


func _update_recoil(delta: float) -> void:
	if rifle == null:
		return
	recoil_left_s = maxf(0.0, recoil_left_s - delta)
	var weight := pow(recoil_left_s / _recoil_recover_s, _recoil_power) if _recoil_recover_s > 0.0 else 0.0
	rifle.transform = Transform3D(_rifle_rest.basis * Basis(Vector3.RIGHT, _recoil_pitch * weight), _rifle_rest.origin + _recoil_kick * weight)


func _on_reload_started() -> void:
	var weapon := (_pawn as Pawn).loadout.get_active()
	if weapon == null or weapon.def.is_melee():
		return
	reload_duration_s = weapon.def.reload_s
	var library := animation_tree.get_animation_library(&"")
	library.remove_animation(&"reload")
	var clips := animation_tree.get_meta(&"clip_library") as ClipLibrary
	library.add_animation(&"reload", SoldierAnimation.resolve_slot(clips, "reload", SoldierAnimation.reload_clip(skeleton, reload_duration_s, _upper_cfg), skeleton))
	animation_tree.set("parameters/reload/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)


func _on_weapon_switched(_slot: int) -> void:
	animation_tree.set("parameters/reload/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_ABORT)
	animation_tree.set("parameters/fire/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_ABORT)


func _on_visibility_changed() -> void:
	if not _pawn.visible:
		_on_weapon_switched(0)

## M2 AN1: the cycle distance the blend shows: forward motion blends the slow walk, the jog and the sprint by
## speed; sideways and backward motion use the jog's cycle (the strafe and back slots play the jog).
func cycle_m(blend: Vector2) -> float:
	var jog := float(_cycles.get("walk_fwd", 0.0))
	var speed := blend.length()
	if speed <= 0.0001 or jog <= 0.0:
		return jog
	var slow_at := float(_gait_cfg["walk_slow_blend"])
	var slow := float(_cycles.get("walk_slow", jog))
	var sprint := float(_cycles.get("run_fwd", jog))
	var ahead := jog
	if speed <= slow_at:
		ahead = slow
	elif speed <= 1.0:
		ahead = lerpf(slow, jog, (speed - slow_at) / (1.0 - slow_at))
	else:
		ahead = lerpf(jog, sprint, clampf((speed - 1.0) / maxf(_sprint - 1.0, 0.0001), 0.0, 1.0))
	return lerpf(jog, ahead, clampf(-blend.y / speed, 0.0, 1.0))


## Every gait slot plays at ground speed / cycle_m, so the stance foot moves with the ground; the strafe slots
## swap to the reversed cycle in the back half while SoldierGait turns the hips toward the motion.
func _drive_gait(blend: Vector2, ground_speed: float) -> void:
	if _cycles.is_empty():
		return
	var distance := cycle_m(blend)
	gait_rate = ground_speed / distance if distance > 0.0 else 0.0
	for slot: String in _cycles:
		animation_tree.set("parameters/locomotion/" + slot + "/speed/scale", gait_rate * SoldierClips.CYCLE_S)
	var cover_mix: Variant = animation_tree.get("parameters/cover_mix/blend_amount")
	gait.lift_weight = 1.0 - (float(cover_mix) if cover_mix != null else 0.0)
	var moving := blend
	if (_pawn as Pawn).drop_state != Pawn.Drop.NONE or not (_pawn as Pawn).is_alive():
		moving = Vector2.ZERO
	if gait.steer(moving) and _cycles.has("strafe_l"):
		var space := (animation_tree.tree_root as AnimationNodeBlendTree).get_node(&"locomotion") as AnimationNodeBlendSpace2D
		for i in space.get_blend_point_count():
			var point := space.get_blend_point_node(i)
			if point is AnimationNodeBlendTree and (point as AnimationNodeBlendTree).has_node(&"clip"):
				var clip := (point as AnimationNodeBlendTree).get_node(&"clip") as AnimationNodeAnimation
				if clip.has_meta(&"strafe"):
					clip.animation = &"walk_back" if gait.backward else StringName(clip.get_meta(&"strafe"))


## Jump, fall off a ledge: the library's airborne loop after air.min_s off the floor with real vertical speed.
func _drive_air(delta: float) -> void:
	if (animation_tree.tree_root as AnimationNodeBlendTree).get_node(&"lower").input_count < 2:
		return
	var pawn := _pawn as Pawn
	var air: Dictionary = _gait_cfg["air"]
	var vertical := _replica_vy if pawn.net_mode == Pawn.NetMode.REPLICA else pawn.velocity.y
	var off := pawn.drop_state == Pawn.Drop.NONE and pawn.is_alive() and absf(vertical) > float(air["min_vertical_mps"]) and not pawn.climbing
	if pawn.net_mode != Pawn.NetMode.REPLICA:
		off = off and not pawn.is_on_floor()
	_air_s = _air_s + delta if off else 0.0
	var now := _air_s >= float(air["min_s"])
	if now != airborne:
		airborne = now
		animation_tree.set("parameters/lower/transition_request", "air" if airborne else "stand")


## A drop in shield + health while alive (any role: replicas get both from the host snapshot) asks for a flinch:
## the head clip for a hit of hit.head_drop or more (no hit zone reaches the victim's visuals), else the chest clip.
func _watch_hits() -> void:
	var pawn := _pawn as Pawn
	if pawn.bridge == null or not animation_tree.tree_root.has_node(&"hit"):
		return
	var hp := float(pawn.bridge.state.shield) + float(pawn.bridge.state.health)
	var hit_cfg: Dictionary = _gait_cfg["hit"]
	if _last_hp >= 0.0 and hp < _last_hp - float(hit_cfg["min_drop"]) and pawn.is_alive():
		flinch(_last_hp - hp >= float(hit_cfg["head_drop"]))
	_last_hp = hp


func flinch(head: bool) -> void:
	hit_count += 1
	animation_tree.set("parameters/hit_which/transition_request", "head" if head else "chest")
	animation_tree.set("parameters/hit/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)


## M2 AN2 item 5: a visual-only one-shot (door_open, chest_open, pickup_ground) on this soldier. Ignored (false)
## while downed, dead, climbing or without the keyed clip; it never touches gameplay state. Gameplay has no signal
## that names the acting pawn yet (WorldProps.prop_changed, MatchDirector.try_pickup): the call is listed for Lanista.
func play_action(action: StringName) -> bool:
	var pawn := _pawn as Pawn
	var key := String(action)
	if pawn == null or pose == null or not ACTIONS.has(key) or not _action_clips.has(key):
		return false
	if not pawn.is_alive() or pawn.is_downed() or pawn.climbing or climb_weight > 0.0 or float(pose.weights["downed"]) > 0.0:
		return false
	action_name = key
	action_s = 0.0
	action_count += 1
	return true


## True while the model turns itself (on a ladder and stepping off its top); CoverAnim leaves the yaw alone then.
func owns_yaw() -> bool:
	return _yaw_owned


## The gun is slung (hidden) on the ladder and in the both-hands actions (data/anim_third_person.json keyed.actions.hide_gun).
func gun_slung() -> bool:
	var hide: Array = (_keyed.get("actions", {}) as Dictionary).get("hide_gun", [])
	if climb_weight >= 0.5 and hide.has(climb_clip):
		return true
	return not action_name.is_empty() and hide.has(action_name) and action_weight() >= 0.5


## The one-shot's weight now: faded in and out over keyed.actions.fade_s.
func action_weight() -> float:
	if action_name.is_empty() or not _action_clips.has(action_name):
		return 0.0
	var fade := float((_keyed.get("actions", {}) as Dictionary).get("fade_s", 0.1))
	var length := (_action_clips[action_name] as Animation).length
	if fade <= 0.0:
		return 1.0
	var fade_in := 1.0 if action_name == "ladder_top" else action_s / fade  # the top step continues the climb pose
	return clampf(minf(fade_in, (length - action_s) / fade), 0.0, 1.0)


## Per frame (from _process; tools and tests may call it with their own delta): the climb from pawn.climbing and the
## feet's height on the ladder, the top step, the one-shots, all handed to SoldierPose's action layer.
func drive_actions(delta: float) -> void:
	if pose == null or _pawn == null:
		return
	var pawn := _pawn as Pawn
	var lad: Dictionary = _keyed.get("ladder", {})
	var acts: Dictionary = _keyed.get("actions", {})
	var ladder := pawn.current_ladder()
	var climbing := pawn.climbing and pawn.is_alive() and not pawn.is_downed() and _action_clips.has("ladder_up")
	# The top step: the climb ended this frame with the feet set forward onto the ledge (Pawn._ladder_tick).
	if _was_climbing and not pawn.climbing and pawn.is_alive() and _action_clips.has("ladder_top"):
		var moved := _pawn.global_position - _climb_last_pos
		if Vector2(moved.x, moved.z).length() > 0.3:
			var back := Basis(Vector3.UP, _ladder_yaw).inverse() * (-moved)  # old feet minus new, model frame
			_top_offset = back - LowpolyKit.vec(lad.get("top_catchup_m", [0, 0, 0]))
			action_name = "ladder_top"
			action_s = 0.0
			action_count += 1
			climb_weight = 0.0  # ladder_top starts in the climbing pose where the body was: it takes over at once
	_was_climbing = pawn.climbing
	_climb_last_pos = _pawn.global_position
	if climbing:
		if ladder != null:
			_ladder_foot_y = ladder.foot().y
			var into := ladder.into_dir()
			_ladder_yaw = atan2(-into.x, -into.z)
		action_name = ""
		var vertical := _replica_vy if pawn.net_mode == Pawn.NetMode.REPLICA else pawn.velocity.y
		var dir_mps := float(lad.get("dir_mps", 0.05))
		if vertical > dir_mps:
			_climb_up = true
		elif vertical < -dir_mps:
			_climb_up = false
	var blend_s := float(lad.get("blend_s", 0.15))
	climb_weight = move_toward(climb_weight, 1.0 if climbing else 0.0, delta / blend_s if blend_s > 0.0 else 1.0)
	if not action_name.is_empty():
		action_s += delta
		if not _action_clips.has(action_name) or action_s >= (_action_clips[action_name] as Animation).length:
			action_name = ""
	if climb_weight > 0.0:
		climb_clip = "ladder_up" if _climb_up or not _action_clips.has("ladder_down") else "ladder_down"
		var clip := _action_clips[climb_clip] as Animation
		var phase := fposmod((_pawn.global_position.y - _ladder_foot_y) / maxf(float(lad.get("cycle_m", 0.9)), 0.01), 1.0)
		pose.action_clip = clip
		pose.action_time = (phase if climb_clip == "ladder_up" else 1.0 - phase) * clip.length
		pose.action_weight = climb_weight
		pose.action_bones = []
		pose.action_offset = Vector3.ZERO
	elif not action_name.is_empty():
		climb_clip = ""
		pose.action_clip = _action_clips[action_name]
		pose.action_time = action_s
		pose.action_weight = action_weight()
		var full: Array = acts.get("full_body", [])
		pose.action_bones = [] if full.has(action_name) else (acts.get("upper_bones", []) as Array)
		var catchup := float(lad.get("top_catchup_s", 0.6))
		pose.action_offset = _top_offset * (1.0 - smoothstep(0.0, catchup, action_s)) if action_name == "ladder_top" else Vector3.ZERO
	else:
		climb_clip = ""
		pose.action_weight = 0.0
		pose.action_clip = null
	# The climber faces the ladder (the pawn keeps the look yaw); back to the pawn's facing afterwards.
	var face := climb_weight > 0.0 or action_name == "ladder_top"
	var turn := deg_to_rad(float(lad.get("turn_deg_s", 720.0))) * delta
	if face:
		_yaw_owned = true
		rotation.y += clampf(angle_difference(rotation.y, _ladder_yaw - _pawn.global_rotation.y), -turn, turn)
	elif _yaw_owned:
		rotation.y += clampf(angle_difference(rotation.y, 0.0), -turn, turn)
		if absf(angle_difference(rotation.y, 0.0)) < 0.0001:
			rotation.y = 0.0
			_yaw_owned = false


## Explicit collider-free copy: avoids duplicating scripts or hitboxes and never re-runs _ready.
func make_corpse() -> Node3D:
	return SoldierCorpse.build(self)
