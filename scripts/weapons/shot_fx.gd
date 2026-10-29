class_name ShotFx
extends Node3D
## Shot visuals for one pawn: muzzle flash, tracer, impact, placeholder weapon mesh.
## Sizes/colours/durations from data/ui.json "shot_fx". Presentation only ? Hitscan stays elsewhere.
## Path A: Kenney Starter-Kit-FPS muzzle/impact/viewmodel patterns (procedural CC0-style; no NC art).

var tracer: MeshInstance3D
var flash: MeshInstance3D
var weapon_mesh: MeshInstance3D
var impact: MeshInstance3D

var _cfg: Dictionary = {}
var _tracer_left_s: float = 0.0
var _flash_left_s: float = 0.0
var _impact_left_s: float = 0.0
var _tracer_start: Vector3 = Vector3.ZERO
var _tracer_end: Vector3 = Vector3.ZERO
var _weapon_rest: Vector3 = Vector3.ZERO
var _recoil_left_s: float = 0.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_cfg = DataRegistry.new().load_file("res://data/ui.json")["shot_fx"]
	_rng.randomize()
	# Tracer, flash, impact live in world space (top_level); the weapon mesh follows the pawn.
	tracer = _make_mesh(BoxMesh.new(), _color("tracer_color"))
	flash = _make_mesh(SphereMesh.new(), _color("flash_color"))
	impact = _make_mesh(SphereMesh.new(), _color_or("impact_color", Color(1.0, 0.85, 0.4, 1.0)))
	tracer.top_level = true
	flash.top_level = true
	impact.top_level = true
	# The tracer runs almost along the third-person view axis, behind the pawn body; drawing it without depth
	# test keeps it readable instead of hidden by the capsule (GBTN2 measurement).
	var tmat := (tracer.mesh as BoxMesh).material as StandardMaterial3D
	tmat.no_depth_test = bool(_cfg["tracer_draw_on_top"])
	tmat.render_priority = int(_cfg["tracer_render_priority"])
	(flash.mesh as SphereMesh).material.set("no_depth_test", bool(_cfg["tracer_draw_on_top"]))
	(impact.mesh as SphereMesh).material.set("no_depth_test", bool(_cfg["tracer_draw_on_top"]))
	var s: float = _cfg["flash_size_m"]
	(flash.mesh as SphereMesh).radius = s * 0.5
	(flash.mesh as SphereMesh).height = s
	var isz: float = float(_cfg.get("impact_size_m", 0.18))
	(impact.mesh as SphereMesh).radius = isz * 0.5
	(impact.mesh as SphereMesh).height = isz
	tracer.visible = false
	flash.visible = false
	impact.visible = false
	weapon_mesh = _make_mesh(BoxMesh.new(), _color("weapon_mesh_color"))
	(weapon_mesh.mesh as BoxMesh).size = _vec3("weapon_mesh_size_m")
	_weapon_rest = _vec3("weapon_mesh_offset_m")
	weapon_mesh.position = _weapon_rest
	SoldierModel.add_rifle(weapon_mesh)


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


func _color_or(key: String, fallback: Color) -> Color:
	if not _cfg.has(key):
		return fallback
	return _color(key)


func _vec3(key: String) -> Vector3:
	var v: Array = _cfg[key]
	return Vector3(v[0], v[1], v[2])


## Flash at muzzle, tracer toward `end`, Kenney-style impact at `end`, viewmodel recoil kick.
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
	# Kenney Starter-Kit-FPS: random muzzle spin + scale jitter.
	var spin: float = float(_cfg.get("flash_spin_deg", 45.0))
	var smin: float = float(_cfg.get("flash_scale_min", 0.4))
	var smax: float = float(_cfg.get("flash_scale_max", 0.75))
	flash.rotation_degrees.z = _rng.randf_range(-spin, spin)
	var flash_s := _rng.randf_range(smin, smax)
	flash.scale = Vector3.ONE * flash_s
	flash.global_position = origin
	tracer.visible = length > 0.001
	flash.visible = true
	_tracer_left_s = _cfg["tracer_duration_s"]
	_flash_left_s = _cfg["flash_duration_s"]
	# Impact spark at the far point (Kenney impact spawn pattern; procedural mesh).
	if length > 0.001 and impact != null:
		impact.global_position = end
		impact.scale = Vector3.ONE * _rng.randf_range(0.7, 1.2)
		impact.visible = true
		_impact_left_s = float(_cfg.get("impact_duration_s", 0.12))
	# Viewmodel recoil kick (eases back in _physics_process).
	if weapon_mesh != null and _cfg.has("viewmodel_recoil_m"):
		var kick: Array = _cfg["viewmodel_recoil_m"]
		weapon_mesh.position = _weapon_rest + Vector3(kick[0], kick[1], kick[2])
		_recoil_left_s = float(_cfg.get("viewmodel_recoil_recover_s", 0.08))


## World-space start and end of the tracer segment drawn by the last show_shot (equal when nothing was drawn).
func get_tracer_endpoints() -> PackedVector3Array:
	return PackedVector3Array([_tracer_start, _tracer_end])


func is_tracer_visible() -> bool:
	return tracer != null and tracer.visible


func is_flash_visible() -> bool:
	return flash != null and flash.visible


func is_impact_visible() -> bool:
	return impact != null and impact.visible


func _physics_process(delta: float) -> void:
	if _tracer_left_s > 0.0:
		_tracer_left_s -= delta
		if _tracer_left_s <= 0.0:
			tracer.visible = false
	if _flash_left_s > 0.0:
		_flash_left_s -= delta
		if _flash_left_s <= 0.0:
			flash.visible = false
	if _impact_left_s > 0.0:
		_impact_left_s -= delta
		if _impact_left_s <= 0.0 and impact != null:
			impact.visible = false
	if _recoil_left_s > 0.0 and weapon_mesh != null:
		var recover: float = float(_cfg.get("viewmodel_recoil_recover_s", 0.08))
		_recoil_left_s = maxf(0.0, _recoil_left_s - delta)
		var t := 0.0 if recover <= 0.0 else 1.0 - (_recoil_left_s / recover)
		weapon_mesh.position = weapon_mesh.position.lerp(_weapon_rest, clampf(t, 0.0, 1.0))
