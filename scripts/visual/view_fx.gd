class_name ViewFx
extends RefCounted
## The first-person tracer, muzzle flash and muzzle light of the view model. Presentation only.
## M2 AN1 commit 5 (combat feedback):
##   flash: a designed burst (a short cone of petals and side spikes in the energy colour around a bright core, one
##     additive surface) PARENTED TO THE SHOWN GUN'S MUZZLE, so it follows the gun when the view turns or the gun kicks;
##     each shot gets a random roll and size. Shape, colours and sizes: data/art_soldier.json fx.flash; its life and size
##     data/camera.json first_person.view_model flash_s, flash_size_m (view-model metres before scale).
##   light: one OmniLight3D at the muzzle, shadows OFF, lit only while the flash shows (art_soldier.json fx.muzzle_light).
##     The view model exists only for the local player's pawn (ViewModel.attach), so no other pawn ever gets this light.
##   tracer: stays WORLD-FIXED (top level) from the muzzle's position at the shot to the shot's real end point (fix 1):
##     it is the path of the round, which does not swing with the view; it lives 0.08 s, so it reads as a streak.
## Tracer colour and limits: data/ui.json shot_fx; tracer life and width camera.json view_model tracer_s, tracer_width_m.

var tracer: MeshInstance3D
var flash: MeshInstance3D
var light: OmniLight3D
var tracer_start := Vector3.ZERO
var tracer_end := Vector3.ZERO

var _shot: Dictionary
var _fx: Dictionary
var _tracer_s := 0.0
var _tracer_width := 0.0
var _flash_s := 0.0
var _flash_size := 0.0
var _tracer_left := 0.0
var _flash_left := 0.0
var _home: Node3D  # where the flash waits while no gun is shown (the view model)
var _held := false  # hold(): a measuring tool keeps the flash and light on
var _rng := RandomNumberGenerator.new()


static func color_of(c: Array) -> Color:
	return Color(float(c[0]), float(c[1]), float(c[2]), float(c[3]) if c.size() > 3 else 1.0)


## Builds the tracer (a top-level box) and the flash with its light (under `owner` until the first shot moves them to
## a muzzle).
func _init(owner: Node3D, shot_cfg: Dictionary, tracer_s: float, tracer_width_m: float, flash_s: float, flash_size_m: float) -> void:
	_shot = shot_cfg
	_fx = ViewMesh.config().get("fx", {})
	_tracer_s = tracer_s
	_tracer_width = tracer_width_m
	_flash_s = flash_s
	_flash_size = flash_size_m
	_home = owner
	_rng.randomize()
	var box := BoxMesh.new()
	box.material = _material(color_of(_shot["tracer_color"]))
	tracer = _mesh_node("Tracer", box, owner)
	tracer.top_level = true
	tracer.visible = false
	flash = _mesh_node("Flash", flash_mesh(_fx.get("flash", {}), flash_size_m), owner)
	flash.visible = false
	light = OmniLight3D.new()
	light.name = "MuzzleLight"
	var lc: Dictionary = _fx.get("muzzle_light", {})
	light.light_color = color_of(lc.get("color", [0.5, 0.9, 1.0, 1.0]))
	light.light_energy = float(lc.get("energy", 1.5))
	light.omni_range = float(lc.get("range_m", 3.0))
	light.omni_attenuation = float(lc.get("attenuation", 1.5))
	light.shadow_enabled = false
	light.light_bake_mode = Light3D.BAKE_DISABLED
	light.visible = false
	flash.add_child(light)


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


## The flash burst in the muzzle's frame (-z = out of the barrel), `size` across: `petals` thin blades fanned out in a
## short cone (tips ahead and outward), `spikes` long side blades along the barrel axis (seen from the side), and a
## bright `core` disc; colours ride in the vertex stream, one additive unshaded surface.
static func flash_mesh(c: Dictionary, size: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var edge := color_of(c.get("edge_color", [0.25, 0.75, 1.0, 1.0]))
	var mid := color_of(c.get("color", [0.5, 0.95, 1.0, 1.0]))
	var core := color_of(c.get("core_color", [1.0, 1.0, 1.0, 1.0]))
	var petals := int(c.get("petals", 6))
	var r := size * 0.5
	var cone := deg_to_rad(float(c.get("cone_deg", 35.0)))
	var width := float(c.get("petal_width", 0.22))
	var reach := float(c.get("petal_length", 1.0))
	for i in petals:
		var a := TAU * (i + 0.5 * (i % 2)) / petals
		var radial := Vector3(cos(a), sin(a), 0.0)
		var side := Vector3(-sin(a), cos(a), 0.0)
		var long := reach * (1.0 if i % 2 == 0 else 0.7)
		var tip := (radial * sin(cone) - Vector3.BACK * cos(cone)) * r * long  # ahead (-z) and out
		var base := side * r * width * 0.5
		_tri(st, Vector3.ZERO + base, tip, Vector3.ZERO - base, mid, edge, mid)
	var spikes := int(c.get("spikes", 2))
	var spike_len := float(c.get("spike_length", 1.6))
	for i in spikes:
		var a := PI * i / maxi(spikes, 1) + PI * 0.25
		var side := Vector3(cos(a), sin(a), 0.0) * r * width * 0.4
		var tip := Vector3.FORWARD * r * spike_len
		_tri(st, side, tip, -side, mid, edge, mid)
	var core_r := r * float(c.get("core_fraction", 0.32))
	var n := 6
	for i in n:
		var a0 := TAU * i / n
		var a1 := TAU * (i + 1) / n
		_tri(st, Vector3.ZERO, Vector3(cos(a0), sin(a0), 0.0) * core_r, Vector3(cos(a1), sin(a1), 0.0) * core_r, core, mid, mid)
	var mesh := st.commit()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.render_priority = 3
	# Drawn over the gun and the hands (like the tracer): at the hip the support hand often hides the muzzle itself.
	mat.no_depth_test = bool(c.get("draw_on_top", true))
	mesh.surface_set_material(0, mat)
	return mesh


static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, ca: Color, cb: Color, cc: Color) -> void:
	for v: Array in [[a, ca], [b, cb], [c, cc]]:
		st.set_color(v[1])
		st.add_vertex(v[0])


## A shot shown: the world-fixed tracer from the muzzle toward `end` (capped at tracer_max_length_m), the flash and
## its light on `muzzle_node` (they follow it from now on) with a random roll and size.
func show_shot(muzzle_node: Node3D, end: Vector3) -> void:
	var muzzle := muzzle_node.global_transform
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
	if flash.get_parent() != muzzle_node:
		flash.reparent(muzzle_node, false)
	var fc: Dictionary = _fx.get("flash", {})
	var s := _rng.randf_range(float(fc.get("scale_min", 0.8)), float(fc.get("scale_max", 1.15)))
	flash.transform = Transform3D(Basis(Vector3.FORWARD, _rng.randf_range(0.0, TAU)).scaled(Vector3.ONE * s), Vector3.ZERO)
	flash.visible = true
	light.visible = true
	_flash_left = _flash_s


## The gun the flash sits on is going away (switch, pickup): park the flash on the view model, hidden.
func park() -> void:
	if flash.get_parent() != _home:
		flash.reparent(_home, false)
	_held = false
	_hide_flash()


func _hide_flash() -> void:
	_flash_left = 0.0
	flash.visible = false
	light.visible = false


## Measuring hook (tools/fp_light_cost.gd, tests): keeps the flash and its light on `muzzle_node` lit until released.
func hold(muzzle_node: Node3D, on: bool) -> void:
	_held = on
	if on:
		if flash.get_parent() != muzzle_node:
			flash.reparent(muzzle_node, false)
		flash.transform = Transform3D.IDENTITY
		flash.visible = true
		light.visible = true
		light.light_energy = float((_fx.get("muzzle_light", {}) as Dictionary).get("energy", 1.5))
	else:
		_hide_flash()


func is_light_on() -> bool:
	return light.visible and flash.is_visible_in_tree()


func tick(delta: float) -> void:
	if _tracer_left > 0.0:
		_tracer_left -= delta
		var color := color_of(_shot["tracer_color"])
		color.a *= clampf(_tracer_left / maxf(_tracer_s, 0.0001), 0.0, 1.0)
		((tracer.mesh as BoxMesh).material as StandardMaterial3D).albedo_color = color
		if _tracer_left <= 0.0:
			tracer.visible = false
	if _flash_left > 0.0 and not _held:
		_flash_left -= delta
		# The burst grows a little and the light fades over its short life.
		var life := clampf(_flash_left / maxf(_flash_s, 0.0001), 0.0, 1.0)
		light.light_energy = float((_fx.get("muzzle_light", {}) as Dictionary).get("energy", 1.5)) * life
		if _flash_left <= 0.0:
			_hide_flash()
