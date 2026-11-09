class_name ZoneWall
extends Node3D
## Battle royale zone visual: a see-through wall at the current circle and a low ring at the next (target)
## circle. Presentation only: reads MatchDirector.rules each frame and decides nothing.
## Look values come from data/ui.json "zone_wall" (placeholders; S6 restyles it).

var director: MatchDirector
var wall: MeshInstance3D
var target_ring: MeshInstance3D
var _wall_mesh := CylinderMesh.new()
var _ring_mesh := CylinderMesh.new()
var _wall_height_m: float = 40.0


func bind(new_director: MatchDirector, cfg: Dictionary) -> void:
	director = new_director
	_wall_height_m = float(cfg.get("wall_height_m", _wall_height_m))
	wall = _ring(_wall_mesh, _wall_height_m, _color(cfg.get("wall_color", [0.35, 0.6, 1.0, 0.25])))
	wall.name = "Wall"
	target_ring = _ring(_ring_mesh, float(cfg.get("target_height_m", 0.6)),
			_color(cfg.get("target_color", [1.0, 1.0, 1.0, 0.45])))
	target_ring.name = "TargetRing"
	refresh()


func _ring(mesh: CylinderMesh, height: float, color: Color) -> MeshInstance3D:
	mesh.height = height
	mesh.cap_top = false
	mesh.cap_bottom = false
	mesh.radial_segments = 64
	mesh.rings = 1
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = color
	mesh.material = mat
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi


static func _color(a: Array) -> Color:
	return Color(float(a[0]), float(a[1]), float(a[2]), float(a[3]) if a.size() > 3 else 1.0)


func _process(_delta: float) -> void:
	refresh()


## Moves both rings to the rules' current and target circles (hidden before the rules exist).
func refresh() -> void:
	var rules: BrRules = director.rules if director != null else null
	visible = rules != null
	if rules == null or wall == null:
		return
	_place(wall, _wall_mesh, rules.zone_center(), rules.zone_radius(), _wall_height_m)
	var final_state := rules.zone_state() == "final"
	target_ring.visible = not final_state
	_place(target_ring, _ring_mesh, rules.zone_target_center(), rules.zone_target_radius(), _ring_mesh.height)


## The meshes keep radius 1; the node scales, so no mesh is rebuilt per frame on the phone.
static func _place(mi: MeshInstance3D, mesh: CylinderMesh, center: Vector2, radius: float, height: float) -> void:
	mesh.top_radius = 1.0
	mesh.bottom_radius = 1.0
	var r := maxf(radius, 0.01)
	mi.scale = Vector3(r, 1.0, r)
	mi.position = Vector3(center.x, height * 0.5, center.y)


## Current radius drawn by a ring (its x scale).
static func drawn_radius(mi: MeshInstance3D) -> float:
	return mi.scale.x
