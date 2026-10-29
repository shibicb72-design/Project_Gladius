class_name SoldierModel
extends Node3D
## One shared vertex-colour surface, no hitboxes. Only reads pawn velocity.
static var _mesh: ArrayMesh
static var _rifle: ArrayMesh
static var _corpse_mesh: ArrayMesh
var skeleton: Skeleton3D
var armor: MeshInstance3D
var local_part_bounds: Array[AABB] = []
var part_bones := PackedInt32Array()
var animation_tree: AnimationTree
var _animation_cfg: Dictionary
var _previous_position := Vector3.ZERO
var _replica_velocity := Vector3.ZERO
var _upper_cfg: Dictionary
var reload_duration_s := 0.0
var rifle: MeshInstance3D
var hand_attachment: BoneAttachment3D
var foregrip: Marker3D
var barrel_tip: Marker3D
var left_ik: TwoBoneIK3D
var right_hand_bone := -1
var pose_cache: Array[Transform3D] = []
var hand_error_m := 0.0
var sway_enabled := true
var _clock := 0.0
var _pawn: CharacterBody3D
var _cfg: Dictionary
var part_bounds: Array[AABB] = []

func _ready() -> void:
	_cfg = LowpolyKit.config()["soldier"]
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
	local_part_bounds = SoldierRig.part_local_bounds(parts, skeleton)
	pose_cache.resize(skeleton.get_bone_count())
	_cache_pose()
	skeleton.skeleton_updated.connect(_cache_pose)
	var mapping: Dictionary = SoldierRig.config()["part_bones"]
	var names: Array[String] = []
	for part: Dictionary in parts:
		names.append(part["name"])
		part_bones.append(skeleton.find_bone(mapping[part["name"]]))
		var size := LowpolyKit.vec(part["size"])
		part_bounds.append(AABB(LowpolyKit.vec(part["at"]) - size * 0.5, size))
	set_meta("parts", names)
	if _pawn != null:
		(_pawn.get_node("Body") as MeshInstance3D).visible = false
	_animation_cfg = SoldierRig.config()["locomotion"]
	var registry := DataRegistry.new()
	var movement := registry.get_movement_cfg()
	var initial_weapon := registry.get_weapon_def(String(registry.get_loadout_ids((_pawn as Pawn).class_id).get("primary", "")))
	var initial_reload := initial_weapon.reload_s if initial_weapon != null and initial_weapon.reload_s > 0.0 else float(_animation_cfg["idle_s"])
	animation_tree = SoldierAnimation.build(skeleton, float(movement["sprint_speed_multiplier"]["value"]), initial_reload)
	add_child(animation_tree)
	_previous_position = _pawn.global_position
	_upper_cfg = SoldierRig.config()["upper_body"]
	var pawn := _pawn as Pawn
	pawn.reload_started.connect(_on_reload_started)
	pawn.weapon_switched.connect(_on_weapon_switched)
	pawn.visibility_changed.connect(_on_visibility_changed)

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
	if _rifle == null:
		_rifle = LowpolyKit.merge(LowpolyKit.config()["rifle"]["parts"])
	var rifle := MeshInstance3D.new()
	rifle.name = "RifleModel"
	rifle.mesh = _rifle
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
	var rifle_parts: Array = LowpolyKit.config()["rifle"]["parts"]
	foregrip = Marker3D.new()
	foregrip.name = "Foregrip"
	rifle.add_child(foregrip)
	barrel_tip = Marker3D.new()
	barrel_tip.name = "BarrelTip"
	rifle.add_child(barrel_tip)
	for part: Dictionary in rifle_parts:
		if part["name"] == "grip":
			rifle.position = -LowpolyKit.vec(part["at"])
		elif part["name"] == "handguard":
			foregrip.position = LowpolyKit.vec(part["at"])
		elif part["name"] == "barrel":
			barrel_tip.position = LowpolyKit.vec(part["at"]) + Vector3.FORWARD * float(part["size"][2]) * 0.5
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

func _process(delta: float) -> void:
	if _pawn == null or not is_visible_in_tree():
		return
	_clock += delta
	var pawn := _pawn as Pawn
	var observed := (_pawn.global_position - _previous_position) / delta if delta > 0.0 else Vector3.ZERO
	_previous_position = _pawn.global_position
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
	animation_tree.set("parameters/locomotion/blend_position", Vector2(local.x, local.z) / pawn.get_move_speed())
	var pitch_limit := deg_to_rad(float(_upper_cfg["aim_pitch_limit_deg"]))
	animation_tree.set("parameters/aim/blend_position", clampf(pawn.pitch / pitch_limit, -1.0, 1.0))


func bind_shot_fx(fx: ShotFx) -> void:
	fx.shot_shown.connect(_on_shot_shown)


func _on_shot_shown(_origin: Vector3, _end: Vector3) -> void:
	var pawn := _pawn as Pawn
	var weapon := pawn.loadout.get_active()
	if pawn.is_alive() and weapon != null and not weapon.def.is_melee():
		animation_tree.set("parameters/fire/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)


func _on_reload_started() -> void:
	var weapon := (_pawn as Pawn).loadout.get_active()
	if weapon == null or weapon.def.is_melee():
		return
	reload_duration_s = weapon.def.reload_s
	var library := animation_tree.get_animation_library(&"")
	library.remove_animation(&"reload")
	library.add_animation(&"reload", SoldierAnimation.reload_clip(skeleton, reload_duration_s, _upper_cfg))
	animation_tree.set("parameters/reload/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)


func _on_weapon_switched(_slot: int) -> void:
	animation_tree.set("parameters/reload/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_ABORT)
	animation_tree.set("parameters/fire/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_ABORT)


func _on_visibility_changed() -> void:
	if not _pawn.visible:
		_on_weapon_switched(0)

## Explicit collider-free copy: avoids duplicating scripts or hitboxes and never re-runs _ready.
func make_corpse() -> Node3D:
	var corpse := Node3D.new()
	corpse.name = "SoldierCorpse"
	corpse.set_meta("corpse", true)
	var mesh := MeshInstance3D.new()
	# F will replace this rest-mesh fallback with a frozen independent rig.
	if _corpse_mesh == null:
		_corpse_mesh = LowpolyKit.merge(_cfg["parts"])
	mesh.mesh = _corpse_mesh
	mesh.transform = transform
	corpse.add_child(mesh)
	# The locked yellow shell belongs to the pawn; reproduce it for a complete corpse silhouette.
	var shell := MeshInstance3D.new()
	var head := _pawn.get_node("Head/HeadMesh") as MeshInstance3D
	shell.mesh = head.mesh
	shell.material_override = head.material_override
	shell.transform = (_pawn.get_node("Head") as Node3D).transform * head.transform
	corpse.add_child(shell)
	return corpse
