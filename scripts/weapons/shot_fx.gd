class_name ShotFx
extends Node3D
## Placeholder shot visuals for one pawn: a muzzle flash, a short tracer and a small weapon mesh.
## All sizes, colours and durations come from data/ui.json "shot_fx". Presentation only.

var tracer: MeshInstance3D
var flash: MeshInstance3D
var weapon_mesh: MeshInstance3D

var _cfg: Dictionary = {}
var _tracer_left_s: float = 0.0
var _flash_left_s: float = 0.0
var _tracer_start: Vector3 = Vector3.ZERO
var _tracer_end: Vector3 = Vector3.ZERO


func _ready() -> void:
	_cfg = DataRegistry.new().load_file("res://data/ui.json")["shot_fx"]
	# Tracer and flash live in world space (top_level); the weapon mesh follows the pawn.
	tracer = _make_mesh(BoxMesh.new(), _color("tracer_color"))
	flash = _make_mesh(SphereMesh.new(), _color("flash_color"))
	tracer.top_level = true
	flash.top_level = true
	# The tracer runs almost along the third-person view axis, behind the pawn body; drawing it without depth
	# test keeps it readable instead of hidden by the capsule (GBTN2 measurement).
	var tmat := (tracer.mesh as BoxMesh).material as StandardMaterial3D
	tmat.no_depth_test = bool(_cfg["tracer_draw_on_top"])
	tmat.render_priority = int(_cfg["tracer_render_priority"])
	(flash.mesh as SphereMesh).material.set("no_depth_test", bool(_cfg["tracer_draw_on_top"]))
	var s: float = _cfg["flash_size_m"]
	(flash.mesh as SphereMesh).radius = s * 0.5
	(flash.mesh as SphereMesh).height = s
	tracer.visible = false
	flash.visible = false
	weapon_mesh = _make_mesh(BoxMesh.new(), _color("weapon_mesh_color"))
	(weapon_mesh.mesh as BoxMesh).size = _vec3("weapon_mesh_size_m")
	weapon_mesh.position = _vec3("weapon_mesh_offset_m")


func _make_mesh(mesh: Mesh, color: Color) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh.material = mat
	m.mesh = mesh
	m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(m)
	return m


func _color(key: String) -> Color:
	var c: Array = _cfg[key]
	return Color(c[0], c[1], c[2], c[3])


func _vec3(key: String) -> Vector3:
	var v: Array = _cfg[key]
	return Vector3(v[0], v[1], v[2])


## Flash at `origin`, tracer from `origin` toward `end` (length capped by tracer_max_length_m).
func show_shot(origin: Vector3, end: Vector3) -> void:
	if tracer == null:
		return
	# Draw from the tip of the placeholder weapon mesh (beside the pawn) so the line is not hidden behind
	# the body in the third-person view.
	var mesh_len: float = (weapon_mesh.mesh as BoxMesh).size.z
	origin = weapon_mesh.global_transform * Vector3(0.0, 0.0, -mesh_len * 0.5)
	var to_end := end - origin
	var length := minf(to_end.length(), float(_cfg["tracer_max_length_m"]))
	if length > 0.001:
		var dir := to_end.normalized()
		var up := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
		var w: float = _cfg["tracer_width_m"]
		(tracer.mesh as BoxMesh).size = Vector3(w, w, length)
		tracer.global_transform = Transform3D(Basis.looking_at(dir, up), origin + dir * length * 0.5)
		_tracer_start = origin
		_tracer_end = origin + dir * length
	else:
		_tracer_start = origin
		_tracer_end = origin
	flash.global_position = origin
	tracer.visible = length > 0.001
	flash.visible = true
	_tracer_left_s = _cfg["tracer_duration_s"]
	_flash_left_s = _cfg["flash_duration_s"]


## World-space start and end of the tracer segment drawn by the last show_shot (equal when nothing was drawn).
func get_tracer_endpoints() -> PackedVector3Array:
	return PackedVector3Array([_tracer_start, _tracer_end])


func is_tracer_visible() -> bool:
	return tracer != null and tracer.visible


func is_flash_visible() -> bool:
	return flash != null and flash.visible


func _physics_process(delta: float) -> void:
	if _tracer_left_s > 0.0:
		_tracer_left_s -= delta
		if _tracer_left_s <= 0.0:
			tracer.visible = false
	if _flash_left_s > 0.0:
		_flash_left_s -= delta
		if _flash_left_s <= 0.0:
			flash.visible = false
