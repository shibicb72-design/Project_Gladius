class_name HillZone
extends Area3D
## Presentation node for the hill. Reports occupancy (squad id -> living pawns inside); scores nothing.

var _shape := CylinderShape3D.new()
var visual := MeshInstance3D.new()
var _visual_mesh := CylinderMesh.new()
var _visual_material := StandardMaterial3D.new()
var _visual_cfg: Dictionary = {}
var _visual_state: String = ""


func _init() -> void:
	collision_layer = 0
	collision_mask = 2
	var cs := CollisionShape3D.new()
	cs.shape = _shape
	add_child(cs)
	_visual_cfg = GreyboxArt.config()["hill"]
	visual.name = "PlaceholderHillVisual"
	visual.mesh = _visual_mesh
	_visual_mesh.radial_segments = int(_visual_cfg["radial_segments"])
	_visual_material.resource_name = "Placeholder_hill"
	_visual_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_visual_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_visual_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	visual.material_override = _visual_material
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(visual)
	_refresh_visual({})


## center is the hill's base centre; the cylinder is raised by half its height.
func configure(center: Vector3, radius_m: float, height_m: float) -> void:
	_shape.radius = radius_m
	_shape.height = height_m
	_visual_mesh.top_radius = radius_m
	_visual_mesh.bottom_radius = radius_m
	_visual_mesh.height = height_m
	position = center + Vector3(0.0, height_m * 0.5, 0.0)


func _process(_delta: float) -> void:
	_refresh_visual(occupancy())


func _refresh_visual(occupants: Dictionary) -> void:
	var state := "empty" if occupants.is_empty() else ("contested" if occupants.size() > 1 else "held")
	if state != _visual_state:
		_visual_state = state
		_visual_material.albedo_color = GreyboxArt.color_value(_visual_cfg[state])


func occupancy() -> Dictionary:
	var result: Dictionary = {}
	for body in get_overlapping_bodies():
		if body is Pawn and body.is_alive():
			result[body.squad_id] = int(result.get(body.squad_id, 0)) + 1
	return result
