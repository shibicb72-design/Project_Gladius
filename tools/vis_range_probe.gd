extends SceneTree
## M2P1C stop 1: from which point does the renderer measure GeometryInstance3D.visibility_range_end? A windowed
## probe (the headless dummy renderer culls nothing, so the suite cannot answer this).
##   godot.cmd --path . --resolution 1280x720 --audio-driver Dummy --script res://tools/vis_range_probe.gd --log-file build/p1c/vis_range_probe.log
## Each probe is a bright red unshaded object on a black background, alone in view; "drawn" = red pixels in the
## viewport image (every 2nd pixel each way) and is cross-checked with the viewport's objects-in-frame count.
## Probes, all with visibility_range_end = RANGE, begin 0, margin 0, fade mode disabled:
##   mm_origin       MultiMeshInstance3D at the world origin, three 8 m boxes ~400 m away (world instance transforms)
##   mm_centred      the same content with the node at the content centre and local instance transforms
##   mesh_offcentre  MeshInstance3D at the origin with an 8 m box whose vertices sit ~400 m away (a terrain chunk)
##   mesh_long       MeshInstance3D at the origin, a 200 x 8 x 8 m box (x 300..500): AABB centre vs nearest point
##   margin          an 8 m box with range_end_margin = MARGIN, the camera walking out and back in: how margin applies
## Camera spots: near_content (30 m from the content, 370 m from the node origin), near_origin (30 m from the
## origin, 430 m from the content, narrow field of view), each also with the range off as a control.
## One "VISRANGE " line per case, then "VISRANGE finding=...". The camera far plane is 10000 m here.

const CONTENT := Vector3(400.0, 0.0, 0.0)
const RANGE := 100.0
const MARGIN := 10.0
const RED_MIN_PX := 20

var _cam: Camera3D
var _probes := {}  # name -> GeometryInstance3D
var _results := {}  # case name -> bool drawn


func _initialize() -> void:
	await process_frame
	var world := Node3D.new()
	world.name = "VisRangeProbe"
	root.add_child(world)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.BLACK
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new()
	we.environment = env
	world.add_child(we)
	_cam = Camera3D.new()
	_cam.near = 0.05
	_cam.far = 10000.0
	world.add_child(_cam)
	_cam.current = true

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1, 0, 0)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var box := BoxMesh.new()
	box.size = Vector3(8, 8, 8)
	var offsets := [Vector3(0, 0, -12), Vector3.ZERO, Vector3(0, 0, 12)]

	var mm_origin := _multimesh(box, mat, Vector3.ZERO, offsets.map(func(o: Vector3) -> Vector3: return CONTENT + o))
	var mm_centred := _multimesh(box, mat, CONTENT, offsets)
	var mesh_off := _shifted_box(Vector3(8, 8, 8), CONTENT, mat)
	var mesh_long := _shifted_box(Vector3(200, 8, 8), CONTENT, mat)
	var margin := MeshInstance3D.new()
	margin.mesh = box
	margin.material_override = mat
	margin.position = CONTENT
	margin.visibility_range_end_margin = MARGIN
	_probes = {"mm_origin": mm_origin, "mm_centred": mm_centred, "mesh_offcentre": mesh_off, "mesh_long": mesh_long, "margin": margin}
	for key: String in _probes:
		var probe: GeometryInstance3D = _probes[key]
		probe.name = key
		probe.visibility_range_end = RANGE
		probe.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
		probe.visible = false
		world.add_child(probe)

	print("VISRANGE setup renderer=%s driver=%s version=%s range_end=%.0f margin=%.0f far=%.0f" % [
			RenderingServer.get_current_rendering_method(), RenderingServer.get_current_rendering_driver_name(),
			Engine.get_version_info()["string"], RANGE, MARGIN, _cam.far])

	var near_content := CONTENT + Vector3(-30, 0, 0)
	var near_origin := Vector3(-30, 0, 0)
	for key in ["mm_origin", "mm_centred", "mesh_offcentre"]:
		await _case("%s/near_content_ctl" % key, key, near_content, 70.0, false)
		await _case("%s/near_origin_ctl" % key, key, near_origin, 8.0, false)
		await _case("%s/near_content" % key, key, near_content, 70.0, true)
		await _case("%s/near_origin" % key, key, near_origin, 8.0, true)
	# AABB centre vs nearest point: (290,0,0) is 10 m from the box end and 110 m from its centre; (400,0,103)
	# is 99 m from its side and 103 m from its centre.
	await _case("mesh_long/end_ctl", "mesh_long", Vector3(290, 0, 0), 70.0, false)
	await _case("mesh_long/end_near10_centre110", "mesh_long", Vector3(290, 0, 0), 70.0, true)
	await _case("mesh_long/side_ctl", "mesh_long", Vector3(400, 0, 103), 70.0, false)
	await _case("mesh_long/side_near99_centre103", "mesh_long", Vector3(400, 0, 103), 70.0, true)
	await _case("mesh_long/side_near86_centre90", "mesh_long", Vector3(400, 0, 90), 70.0, true)
	# Margin: walk out and back in along +z (distance to the centre = d), several frames per step.
	var walk := [50.0, 105.0, 115.0, 105.0, 95.0, 85.0, 50.0]
	var seq := PackedStringArray()
	for i in walk.size():
		var drawn := await _case("margin/step%d_d%d" % [i, int(walk[i])], "margin", CONTENT + Vector3(0, 0, walk[i]), 30.0, true)
		seq.append("%d:%s" % [int(walk[i]), "V" if drawn else "H"])

	var origin_based: bool = _results["mm_origin/near_origin"] and not _results["mm_origin/near_content"]
	var bounds_based := true
	for key in ["mm_origin", "mm_centred", "mesh_offcentre"]:
		bounds_based = bounds_based and _results["%s/near_content" % key] and not _results["%s/near_origin" % key]
		for ctl in ["near_content_ctl", "near_origin_ctl"]:
			if not _results["%s/%s" % [key, ctl]]:
				print("VISRANGE warning: control %s/%s not drawn, the result is not trustworthy" % [key, ctl])
	var point := "unclear"
	if _results["mesh_long/end_ctl"] and _results["mesh_long/side_ctl"]:
		var at_end: bool = _results["mesh_long/end_near10_centre110"]
		var at_side: bool = _results["mesh_long/side_near99_centre103"]
		if not at_end and not at_side:
			point = "aabb_centre"
		elif at_end and at_side:
			point = "aabb_nearest_point"
	var measured := "node_origin" if origin_based else ("instance_bounds" if bounds_based else "mixed_or_unclear")
	print("VISRANGE finding=%s point=%s margin_walk=%s (fade disabled; d = distance camera to point)" % [measured, point, ",".join(seq)])
	quit()


func _multimesh(mesh: Mesh, mat: Material, at: Vector3, points: Array) -> MultiMeshInstance3D:
	var batch := MultiMesh.new()
	batch.transform_format = MultiMesh.TRANSFORM_3D
	batch.mesh = mesh
	batch.instance_count = points.size()
	for i in points.size():
		batch.set_instance_transform(i, Transform3D(Basis.IDENTITY, points[i]))
	var node := MultiMeshInstance3D.new()
	node.multimesh = batch
	node.material_override = mat
	node.position = at
	return node


## A MeshInstance3D at the origin whose box vertices are moved by `centre` (world-space vertices).
func _shifted_box(size: Vector3, centre: Vector3, mat: Material) -> MeshInstance3D:
	var src := BoxMesh.new()
	src.size = size
	var arrays := src.get_mesh_arrays()
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	for i in verts.size():
		verts[i] += centre
	arrays[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = mat
	return node


## Shows only probe `key`, puts the camera at `cam_at` looking at the probe's AABB centre, renders a few frames
## and reports whether the probe was drawn. `ranged` false turns the range off (a control).
func _case(label: String, key: String, cam_at: Vector3, fov: float, ranged: bool) -> bool:
	for other: String in _probes:
		(_probes[other] as GeometryInstance3D).visible = other == key
	var probe: GeometryInstance3D = _probes[key]
	var want := RANGE if ranged else 0.0
	if probe.visibility_range_end != want:  # an unchanged set could reset the renderer's hysteresis state
		probe.visibility_range_end = want
	var aabb: AABB = probe.global_transform * probe.get_aabb()
	var centre := aabb.get_center()
	_cam.fov = fov
	var look := centre
	if key == "mesh_long" and cam_at.x < aabb.position.x:
		look = Vector3(aabb.end.x, centre.y, centre.z)
	_cam.look_at_from_position(cam_at, look, Vector3.UP if absf((look - cam_at).normalized().y) < 0.99 else Vector3.FORWARD)
	for i in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	var red := _red_pixels(root.get_viewport().get_texture().get_image())
	var objects := RenderingServer.viewport_get_render_info(root.get_viewport().get_viewport_rid(),
			RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_OBJECTS_IN_FRAME)
	var nearest := cam_at.clamp(aabb.position, aabb.end)
	var drawn := red >= RED_MIN_PX
	_results[label] = drawn
	print("VISRANGE case=%s drawn=%s red_px=%d objects=%d range_end=%s d_node_origin=%.1f d_aabb_centre=%.1f d_aabb_nearest=%.1f node=%s aabb_centre=%s cam=%s" % [
			label, "yes" if drawn else "no", red, objects, ("%.0f" % RANGE) if ranged else "off",
			cam_at.distance_to(probe.global_position), cam_at.distance_to(centre), cam_at.distance_to(nearest),
			probe.global_position, centre, cam_at])
	return drawn


static func _red_pixels(image: Image) -> int:
	image.convert(Image.FORMAT_RGB8)
	var data := image.get_data()
	var w := image.get_width()
	var h := image.get_height()
	var count := 0
	for y in range(0, h, 2):
		var row := y * w * 3
		for x in range(0, w, 2):
			var i := row + x * 3
			if data[i] > 200 and data[i + 1] < 60 and data[i + 2] < 60:
				count += 1
	return count
