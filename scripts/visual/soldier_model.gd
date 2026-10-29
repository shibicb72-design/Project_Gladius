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
	var movement := DataRegistry.new().get_movement_cfg()
	animation_tree = SoldierAnimation.build(skeleton, float(movement["sprint_speed_multiplier"]["value"]))
	add_child(animation_tree)
	_previous_position = _pawn.global_position

## Fill a caller-owned array; no allocation in the animation path.
func posed_bounds(out: Array[AABB]) -> void:
	for i in local_part_bounds.size():
		out[i] = skeleton.global_transform * skeleton.get_bone_global_pose(part_bones[i]) * local_part_bounds[i]

static func add_rifle(parent: MeshInstance3D) -> MeshInstance3D:
	if _rifle == null:
		_rifle = LowpolyKit.merge(LowpolyKit.config()["rifle"]["parts"])
	var rifle := MeshInstance3D.new()
	rifle.name = "RifleModel"
	rifle.mesh = _rifle
	parent.add_child(rifle)
	parent.layers = 0
	return rifle

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
