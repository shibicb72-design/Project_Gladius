class_name ZoneWall
extends Node3D
## Battle royale zone visual: an energy wall at the current circle, a low ring at the next (target) circle and
## a beacon at the target's centre. Presentation only: reads MatchDirector.rules each frame and decides nothing.
## Heights come from data/ui.json "zone_wall" (the cfg passed to bind); the look (S3: field colours, lattice,
## ring and beacon) from data/art_zone.json (placeholders, OQ-BR-ZONE).

const LOOK_PATH := "res://data/art_zone.json"

var director: MatchDirector
var wall: MeshInstance3D
var target_ring: MeshInstance3D
var beacon: MeshInstance3D
var beacon_foot: MeshInstance3D
var _wall_mesh := CylinderMesh.new()
var _ring_mesh := CylinderMesh.new()
var _beacon_mesh := CylinderMesh.new()
var _foot_mesh := CylinderMesh.new()
var _wall_height_m: float = 40.0
var _look: Dictionary = {}


func bind(new_director: MatchDirector, cfg: Dictionary) -> void:
	director = new_director
	_look = DataRegistry.new().load_file(LOOK_PATH)
	_wall_height_m = float(cfg.get("wall_height_m", _wall_height_m))
	var w: Dictionary = _look["wall"]
	var wall_mat := _material("res://scripts/visual/shaders/zone_wall.gdshader", w)
	wall_mat.set_shader_parameter("wall_height_m", _wall_height_m)
	wall_mat.set_shader_parameter("noise_pack", load(String(WorldSurface.config()["noise"])))
	wall = _ring(_wall_mesh, _wall_height_m, wall_mat, int(w["radial_segments"]))
	wall.name = "Wall"
	var ring_mat := _material("res://scripts/visual/shaders/zone_marker.gdshader", _look["target_ring"])
	ring_mat.set_shader_parameter("mode", 0.0)
	target_ring = _ring(_ring_mesh, float(cfg.get("target_height_m", 0.6)), ring_mat, int(w["radial_segments"]))
	target_ring.name = "TargetRing"
	var b: Dictionary = _look["beacon"]
	var beacon_mat := _material("res://scripts/visual/shaders/zone_marker.gdshader", b)
	beacon_mat.set_shader_parameter("mode", 1.0)
	beacon = _ring(_beacon_mesh, float(b["height_m"]), beacon_mat, 12)
	beacon.name = "Beacon"
	beacon_foot = _ring(_foot_mesh, float(b["base_ring_height_m"]), ring_mat, 24)
	beacon_foot.name = "BeaconFoot"
	refresh()


## A shader material whose colour and number uniforms are the entries of `values` with the same names.
static func _material(shader_path: String, values: Dictionary) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load(shader_path)
	for key: String in values:
		var value: Variant = values[key]
		if value is Array and (value as Array).size() == 4:
			mat.set_shader_parameter(key, _color(value))
		elif value is float or value is int:
			mat.set_shader_parameter(key, float(value))
	return mat


func _ring(mesh: CylinderMesh, height: float, material: Material, segments: int) -> MeshInstance3D:
	mesh.height = height
	mesh.top_radius = 1.0  # set once; _place scales the node
	mesh.bottom_radius = 1.0
	mesh.cap_top = false
	mesh.cap_bottom = false
	mesh.radial_segments = segments
	mesh.rings = 1
	mesh.material = material
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi


static func _color(a: Array) -> Color:
	return Color(float(a[0]), float(a[1]), float(a[2]), float(a[3]) if a.size() > 3 else 1.0)


func _process(_delta: float) -> void:
	refresh()


## Moves the wall, the ring and the beacon to the rules' current and target circles (hidden before the rules exist).
func refresh() -> void:
	var rules: BrRules = director.rules if director != null else null
	visible = rules != null
	if rules == null or wall == null:
		return
	_place(wall, _wall_mesh, rules.zone_center(), rules.zone_radius(), _wall_height_m)
	var final_state := rules.zone_state() == "final"
	target_ring.visible = not final_state
	_place(target_ring, _ring_mesh, rules.zone_target_center(), rules.zone_target_radius(), _ring_mesh.height)
	var b: Dictionary = _look.get("beacon", {})
	var show_beacon := not final_state and bool(b.get("enabled", false))
	beacon.visible = show_beacon
	beacon_foot.visible = show_beacon
	if show_beacon:
		_place(beacon, _beacon_mesh, rules.zone_target_center(), float(b["radius_m"]), _beacon_mesh.height)
		_place(beacon_foot, _foot_mesh, rules.zone_target_center(), float(b["base_ring_radius_m"]), _foot_mesh.height)


## The meshes keep radius 1; the node scales, so no mesh is rebuilt per frame on the phone.
static func _place(mi: MeshInstance3D, mesh: CylinderMesh, center: Vector2, radius: float, height: float) -> void:
	var r := maxf(radius, 0.01)
	mi.scale = Vector3(r, 1.0, r)
	mi.position = Vector3(center.x, height * 0.5, center.y)


## Current radius drawn by a ring (its x scale).
static func drawn_radius(mi: MeshInstance3D) -> float:
	return mi.scale.x
