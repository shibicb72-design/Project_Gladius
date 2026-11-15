class_name ViewFx
extends RefCounted
## The first-person tracer and muzzle flash of the view model (moved out of view_model.gd in M2 AN1, unchanged): they
## start at the VIEW-MODEL muzzle and end at the shot's real end point (fix 1). Colours, arms and limits are
## data/ui.json shot_fx; lives and sizes data/camera.json first_person.view_model (tracer_s, tracer_width_m, flash_s,
## flash_size_m). Presentation only.

var tracer: MeshInstance3D
var flash: MeshInstance3D
var tracer_start := Vector3.ZERO
var tracer_end := Vector3.ZERO

var _shot: Dictionary
var _tracer_s := 0.0
var _tracer_width := 0.0
var _flash_s := 0.0
var _tracer_left := 0.0
var _flash_left := 0.0
var _rng := RandomNumberGenerator.new()


static func color_of(c: Array) -> Color:
	return Color(c[0], c[1], c[2], c[3])


## Builds the tracer (a box) and the flash (crossed planes across the muzzle axis) under `owner`, both top level.
func _init(owner: Node3D, shot_cfg: Dictionary, tracer_s: float, tracer_width_m: float, flash_s: float, flash_size_m: float) -> void:
	_shot = shot_cfg
	_tracer_s = tracer_s
	_tracer_width = tracer_width_m
	_flash_s = flash_s
	_rng.randomize()
	var box := BoxMesh.new()
	box.material = _material(color_of(_shot["tracer_color"]))
	tracer = _mesh_node("Tracer", box, owner)
	tracer.top_level = true
	tracer.visible = false
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var narrow := flash_size_m * float(_shot["flash_arm_fraction"])
	var planes := int(_shot["flash_planes"])
	# Unlike ShotFx (seen from the side), the arms lie across the muzzle axis, so the eye behind it sees a star.
	for i in planes:
		var angle := PI * i / planes
		var axis := Vector3(cos(angle), sin(angle), 0.0)
		var side := Vector3(-sin(angle), cos(angle), 0.0)
		var points: Array[Vector3] = [axis * flash_size_m * 0.5, side * narrow, -axis * flash_size_m * 0.5, -side * narrow]
		for index in [0, 1, 2, 0, 2, 3]:
			st.add_vertex(points[index])
	var star := st.commit()
	var fmat := _material(color_of(_shot["flash_color"]))
	fmat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	fmat.cull_mode = BaseMaterial3D.CULL_DISABLED
	star.surface_set_material(0, fmat)
	flash = _mesh_node("Flash", star, owner)
	flash.top_level = true
	flash.visible = false


func _material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = bool(_shot["tracer_draw_on_top"])
	mat.render_priority = int(_shot["tracer_render_priority"])
	return mat


static func _mesh_node(node_name: String, mesh: Mesh, parent: Node) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	m.name = node_name
	m.mesh = mesh
	m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	m.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	parent.add_child(m)
	return m


## A shot shown: the tracer from the muzzle toward `end` (capped at tracer_max_length_m) and the flash at the muzzle.
func show_shot(muzzle: Transform3D, end: Vector3) -> void:
	var start := muzzle.origin
	var to_end := end - start
	var length := minf(to_end.length(), float(_shot["tracer_max_length_m"]))
	tracer_start = start
	tracer_end = start
	if length > 0.001:
		var dir := to_end.normalized()
		var up := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
		(tracer.mesh as BoxMesh).size = Vector3(_tracer_width, _tracer_width, length)
		tracer.global_transform = Transform3D(Basis.looking_at(dir, up), start + dir * length * 0.5)
		tracer_end = start + dir * length
		tracer.visible = true
		_tracer_left = _tracer_s
	var spin := deg_to_rad(float(_shot.get("flash_spin_deg", 45.0)))
	flash.set_meta(&"spin", _rng.randf_range(-spin, spin))
	flash.visible = true
	_flash_left = _flash_s
	flash.global_transform = muzzle


## Keeps a visible flash on the moving muzzle.
func follow(muzzle: Transform3D) -> void:
	if flash.visible:
		flash.global_transform = muzzle * Transform3D(Basis(Vector3.FORWARD, flash.get_meta(&"spin", 0.0)), Vector3.ZERO)


func tick(delta: float) -> void:
	if _tracer_left > 0.0:
		_tracer_left -= delta
		var color := color_of(_shot["tracer_color"])
		color.a *= clampf(_tracer_left / maxf(_tracer_s, 0.0001), 0.0, 1.0)
		((tracer.mesh as BoxMesh).material as StandardMaterial3D).albedo_color = color
		if _tracer_left <= 0.0:
			tracer.visible = false
	if _flash_left > 0.0:
		_flash_left -= delta
		if _flash_left <= 0.0:
			flash.visible = false
