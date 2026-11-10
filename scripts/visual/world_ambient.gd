class_name WorldAmbient
extends Node3D
## Visual-only, collider-free world detail. One CPU driver; cloth/foliage use TIME.
var config: Dictionary = {}
var enabled := false
var cloth_material: ShaderMaterial
var foliage_material: ShaderMaterial
var lights: Array[OmniLight3D] = []
var beacons: Array[SpotLight3D] = []
var particles: Array[CPUParticles3D] = []
var elapsed := 0.0
var flicker := FastNoiseLite.new()

func configure(cfg: Dictionary, on: bool) -> void:
	config = cfg
	flicker.seed = int(cfg["braziers"]["flicker_seed"])
	flicker.frequency = float(cfg["braziers"]["flicker_speed"])
	enabled = on
	for child in get_children():
		remove_child(child)
		child.queue_free()
	lights.clear()
	beacons.clear()
	particles.clear()
	visible = on
	set_process(on)
	cloth_material = _sway_material("res://scripts/visual/shaders/world_cloth.gdshader", cfg["cloth"])
	foliage_material = _sway_material("res://scripts/visual/shaders/world_foliage.gdshader", cfg["foliage"])
	foliage_material.set_shader_parameter("height_m", float(cfg["foliage"]["size"][1]))
	if not on:
		cloth_material.set_shader_parameter("amplitude", 0.0)
		foliage_material.set_shader_parameter("amplitude", 0.0)
		return
	_build_flags()
	_build_tents()
	_build_foliage()
	_build_dust()
	_build_braziers()
	_build_beacons()
	_build_props()

func _sway_material(path: String, cfg: Dictionary) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load(path)
	mat.set_shader_parameter("amplitude", float(cfg["amplitude_m"]))
	mat.set_shader_parameter("speed", float(cfg["speed"]))
	mat.set_shader_parameter("frequency", float(cfg["frequency"]))
	mat.set_shader_parameter("roughness", float(cfg["roughness"]))
	mat.set_shader_parameter("base_color", GreyboxArt.color_value(cfg["color"]))
	if path.ends_with("world_cloth.gdshader"):
		# S7: the cloth shows the shared weave tile and a gold trim.
		var surfaces := WorldSurface.config()
		mat.set_shader_parameter("surfaces", load(String(surfaces["texture"])))
		mat.set_shader_parameter("cloth_layer", float((surfaces["layers"] as Array).find("cloth")))
		if cfg.has("trim_color"):
			mat.set_shader_parameter("trim_color", GreyboxArt.color_value(cfg["trim_color"]))
	return mat


static var _tuft: ArrayMesh
static var _flame: ArrayMesh
static var _brazier := {}

## S7: a grass tuft: `blades` thin triangles leaning out from one root, dark at the root and light at the tip.
static func _tuft_mesh(size: Vector3, blades: int) -> ArrayMesh:
	if _tuft != null:
		return _tuft
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in blades:
		var angle := TAU * float(i) / blades + float(i) * 0.7
		var out := Vector3(cos(angle), 0.0, sin(angle))
		var side := Vector3(-out.z, 0.0, out.x) * size.x * 0.5
		var root := out * size.z * 0.3
		var tip := out * size.z * (1.0 + 0.4 * sin(float(i) * 2.1)) + Vector3.UP * size.y * (0.7 + 0.3 * cos(float(i) * 1.3))
		for corner: Array in [[root - side, 0.35], [root + side, 0.35], [tip, 1.0]]:
			st.set_normal(Vector3.UP)
			st.set_color(Color(float(corner[1]), float(corner[1]), float(corner[1]), 1.0))
			st.add_vertex(corner[0])
	_tuft = st.commit()
	return _tuft


## S7: a flame: two crossed upright quads (UV.y 1 at the root, 0 at the tip) with the fire shader.
static func _flame_mesh(size: Vector2) -> ArrayMesh:
	if _flame != null:
		return _flame
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half := size.x * 0.5
	for across: Vector3 in [Vector3.RIGHT, Vector3.BACK]:
		var corners: Array = [[-across * half, Vector2(0, 1)], [across * half, Vector2(1, 1)], [across * half + Vector3.UP * size.y, Vector2(1, 0)], [-across * half + Vector3.UP * size.y, Vector2(0, 0)]]
		for index: int in [0, 1, 2, 0, 2, 3]:
			st.set_uv(corners[index][1])
			st.add_vertex(corners[index][0])
	_flame = st.commit()
	var mat := ShaderMaterial.new()
	mat.shader = load("res://scripts/visual/shaders/fire.gdshader")
	mat.set_shader_parameter("noise_pack", load(String(WorldSurface.config()["noise"])))
	_flame.surface_set_material(0, mat)
	return _flame

func _mesh(mesh: Mesh, at: Vector3, parent: Node3D = null) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.position = at
	if parent == null:
		parent = self
	parent.add_child(node)
	return node

func _cloth(size: Vector2, at: Vector3, parent: Node3D) -> MeshInstance3D:
	var plane := PlaneMesh.new()
	plane.orientation = PlaneMesh.FACE_Z
	plane.size = size
	plane.subdivide_width = int(config["cloth"]["subdivisions"])
	plane.subdivide_depth = int(config["cloth"]["subdivisions"])
	var node := _mesh(plane, at, parent)
	node.material_override = cloth_material
	return node

func _build_flags() -> void:
	var cfg: Dictionary = config["flags"]
	var pole := LowpolyKit.build("pillar", LowpolyKit.vec(cfg["pole_size"]))
	for at: Array in cfg["positions"]:
		var flag := Node3D.new()
		flag.name = "Banner_%d" % get_child_count()
		flag.position = LowpolyKit.vec(at)
		add_child(flag)
		_mesh(pole, Vector3(0, float(cfg["pole_size"][1]) * 0.5, 0), flag)
		var size := Vector2(cfg["size"][0], cfg["size"][1])
		_cloth(size, Vector3(size.x * 0.5, float(cfg["cloth_y_m"]), 0), flag)

func _build_tents() -> void:
	var cfg: Dictionary = config["tents"]
	var size := LowpolyKit.vec(cfg["size"])
	for at: Array in cfg["positions"]:
		var tent := Node3D.new()
		tent.name = "Tent_%d" % get_child_count()
		tent.position = LowpolyKit.vec(at)
		add_child(tent)
		# Two pitched cloth roof planes; their ridge stays structurally fixed.
		for side in [-1, 1]:
			var roof := _cloth(Vector2(size.z, Vector2(size.x * 0.5, size.y).length()), Vector3(side * size.x * 0.25, size.y * 0.5, 0), tent)
			roof.rotation = Vector3(0, PI * 0.5, side * atan2(size.x * 0.5, size.y))

func _build_foliage() -> void:
	var cfg: Dictionary = config["foliage"]
	var batch := MultiMeshInstance3D.new()
	batch.name = "Foliage"
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.mesh = _tuft_mesh(LowpolyKit.vec(cfg["size"]), int(cfg.get("blades", 5)))
	multi.instance_count = int(cfg["count"])
	var rng := RandomNumberGenerator.new()
	rng.seed = int(cfg["seed"])
	# S7: tufts grow where the ground's paint map shows the surface the data names (grass), when the map
	# builder above this node has one; a few tries per tuft, then it stands where the last try fell.
	var builder := get_parent()
	var paint: Image = builder.get("ground_paint") if builder != null else null
	var wanted := String(cfg.get("on_surface", ""))
	for i in multi.instance_count:
		var at := Vector3.ZERO
		for attempt in maxi(int(cfg.get("place_tries", 1)), 1):
			var angle := rng.randf_range(0, TAU)
			var radius := rng.randf_range(float(cfg["radius_min_m"]), float(cfg["radius_max_m"]))
			at = Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
			if paint == null or wanted == "" or GroundPaint.surface_at(paint, float(builder.ground_size_m), at) == wanted:
				break
		var grow := rng.randf_range(float(cfg.get("scale_min", 1.0)), float(cfg.get("scale_max", 1.0)))
		multi.set_instance_transform(i, Transform3D(Basis(Vector3.UP, rng.randf_range(0, TAU)).scaled(Vector3.ONE * grow), at))
	batch.multimesh = multi
	batch.material_override = foliage_material
	batch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF  # S7: many small blades; no shadow draw for them
	add_child(batch)

func _build_dust() -> void:
	var cfg: Dictionary = config["dust"]
	var mote := SphereMesh.new()
	mote.radius = float(cfg["radius_m"])
	mote.height = mote.radius * 2
	mote.radial_segments = int(cfg["radial_segments"])
	mote.rings = int(cfg["rings"])
	var mat := StandardMaterial3D.new()
	mat.albedo_color = GreyboxArt.color_value(cfg["color"])
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mote.material = mat
	for at: Array in cfg["positions"]:
		var dust := CPUParticles3D.new()
		dust.name = "DriftingDust"
		dust.position = LowpolyKit.vec(at)
		dust.amount = int(cfg["amount"])
		dust.lifetime = float(cfg["lifetime_s"])
		dust.one_shot = false
		dust.mesh = mote
		dust.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
		dust.emission_box_extents = LowpolyKit.vec(cfg["box_extents"])
		dust.direction = LowpolyKit.vec(cfg["direction"])
		dust.spread = float(cfg["spread_deg"])
		dust.initial_velocity_min = float(cfg["velocity_min"])
		dust.initial_velocity_max = float(cfg["velocity_max"])
		dust.gravity = LowpolyKit.vec(cfg["gravity"])
		add_child(dust)
		dust.emitting = true
		particles.append(dust)

func _build_braziers() -> void:
	var cfg: Dictionary = config["braziers"]
	for at: Array in cfg["positions"]:
		var base := Node3D.new()
		base.name = "Brazier"
		base.position = LowpolyKit.vec(at)
		add_child(base)
		var stand := LowpolyKit.vec(cfg["stand_size"])
		var bowl := LowpolyKit.vec(cfg["bowl_size"])
		if cfg.has("parts"):
			# S7: a bronze bowl on a tripod (kit parts from data) with a flame standing in it.
			if not _brazier.has("mesh"):
				var parts: Array = []
				for part: Dictionary in cfg["parts"]:
					parts.append(WorldKit._kit_part(part))
				_brazier["mesh"] = LowpolyKit.merge(parts)
			_mesh(_brazier["mesh"], Vector3.ZERO, base)
			var flame := _mesh(_flame_mesh(Vector2(float(cfg["flame_size"][0]), float(cfg["flame_size"][1]))), Vector3(0, float(cfg["flame_y_m"]), 0), base)
			flame.name = "Flame"
			flame.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		else:
			_mesh(LowpolyKit.build("pillar", stand), Vector3(0, stand.y * 0.5, 0), base)
			_mesh(LowpolyKit.build("barrier", bowl), Vector3(0, stand.y, 0), base)
		var light := OmniLight3D.new()
		light.position.y = float(cfg["light_y_m"])
		light.omni_range = float(cfg["range_m"])
		light.light_color = GreyboxArt.color_value(cfg["color"])
		light.light_energy = float(cfg["energy"])
		light.shadow_enabled = bool(cfg["shadows"])
		base.add_child(light)
		lights.append(light)

func _build_beacons() -> void:
	var cfg: Dictionary = config["beacons"]
	for at: Array in cfg["positions"]:
		var light := SpotLight3D.new()
		light.name = "Searchlight"
		light.position = LowpolyKit.vec(at)
		light.spot_range = float(cfg["range_m"])
		light.spot_angle = float(cfg["angle_deg"])
		light.light_energy = float(cfg["energy"])
		light.light_color = GreyboxArt.color_value(cfg["color"])
		light.rotation_degrees.x = float(cfg["pitch_deg"])
		light.shadow_enabled = bool(cfg["shadows"])
		add_child(light)
		beacons.append(light)

func _build_props() -> void:
	for entry: Dictionary in config["props"]:
		_mesh(LowpolyKit.build(entry["kind"], LowpolyKit.vec(entry["size"])), LowpolyKit.vec(entry["at"]))
	for cable: Dictionary in config["cables"]:
		var start := LowpolyKit.vec(cable["from"])
		var end := LowpolyKit.vec(cable["to"])
		var segments := int(cable["segments"])
		for i in segments:
			var t0 := float(i) / segments
			var t1 := float(i + 1) / segments
			var a := start.lerp(end, t0) - Vector3.UP * sin(t0 * PI) * float(cable["sag_m"])
			var b := start.lerp(end, t1) - Vector3.UP * sin(t1 * PI) * float(cable["sag_m"])
			var box := BoxMesh.new()
			box.material = GreyboxArt.material_for("camp")
			box.size = Vector3(float(cable["thickness_m"]), float(cable["thickness_m"]), a.distance_to(b))
			var piece := _mesh(box, (a + b) * 0.5)
			piece.basis = Basis.looking_at(b - a)

func _process(delta: float) -> void:
	elapsed += delta
	var brazier: Dictionary = config["braziers"]
	for i in lights.size():
		lights[i].light_energy = float(brazier["energy"]) * (1.0 + flicker.get_noise_1d(elapsed + i) * float(brazier["flicker_amplitude"]))
	var beacon: Dictionary = config["beacons"]
	for light in beacons:
		light.rotation.y = sin(elapsed * float(beacon["sweep_speed"])) * float(beacon["sweep_rad"])
