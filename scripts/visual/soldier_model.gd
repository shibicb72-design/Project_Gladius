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
	if not sway_enabled or _pawn == null or not is_visible_in_tree():
		return
	_clock += delta
	var speed := Vector2(_pawn.velocity.x, _pawn.velocity.z).length()
	position.y = sin(_clock * float(_cfg["bob_frequency"])) * float(_cfg["bob_amplitude_m"]) * minf(speed / float(_cfg["bob_full_speed_mps"]), 1.0)
	rotation.z = sin(_clock * float(_cfg["idle_frequency"])) * float(_cfg["idle_sway_rad"])

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
