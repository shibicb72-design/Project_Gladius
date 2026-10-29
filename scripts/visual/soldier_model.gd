class_name SoldierModel
extends Node3D
## One shared vertex-colour surface, no hitboxes. Only reads pawn velocity.
static var _mesh: ArrayMesh
static var _rifle: ArrayMesh
var sway_enabled := true
var _clock := 0.0
var _pawn: CharacterBody3D
var _cfg: Dictionary
var part_bounds: Array[AABB] = []

func _ready() -> void:
	_cfg = LowpolyKit.config()["soldier"]
	_pawn = get_parent() as CharacterBody3D
	var parts: Array = _cfg["parts"]
	if _mesh == null:
		_mesh = LowpolyKit.merge(parts)
	var mesh := MeshInstance3D.new()
	mesh.name = "Armor"
	mesh.mesh = _mesh
	add_child(mesh)
	var names: Array[String] = []
	for part: Dictionary in parts:
		names.append(part["name"])
		var size := LowpolyKit.vec(part["size"])
		part_bounds.append(AABB(LowpolyKit.vec(part["at"]) - size * 0.5, size))
	set_meta("parts", names)
	if _pawn != null:
		(_pawn.get_node("Body") as MeshInstance3D).visible = false

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
