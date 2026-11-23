class_name ShaderWarmup
extends Node3D
## W1c: draws every shader program variant a match will use once, behind the opaque loading overlay, before the
## player can act (docs/ARCHITECTURE.md "Staged match open and shader warm-up"; data/warmup.json, OQ-W1C-STEP,
## OQ-W1C-STAGE). The Compatibility renderer (WebGL 2) compiles and links a program the first time a draw needs it,
## and the browser's main thread waits for that link: multi-second freezes in play (W1c cause table).
##
## Runs in the match's own World3D (its sun, Environment, shadow mode and MSAA, after the graphics preset and the
## look variant are applied): a warm Camera3D is made current and looks at a row of cells high above the map, one cell
## per LIGHT CONTEXT (the sun only; plus an omni and / or a spot light of the warm-up's own, when the match holds lights
## of that kind: the renderer picks another program for an object lit by them). Each frame one ITEM starts: a copy of
## it in every cell, scaled down to the cell, kept for copy_frames frames, then freed.
## Items: DERIVED from the built match: every GeometryInstance3D under the MatchRoot, hidden ones included, grouped by
## draw key (draw kind: plain mesh / skinned / multimesh with its instance format / CPU or GPU particles; vertex format;
## material key: the shader path of a ShaderMaterial, or the feature flags of a BaseMaterial3D / ParticleProcessMaterial;
## shadow casting; instance transparency). One item per source with a key no earlier item had; a skinned mesh is copied
## with its whole Skeleton3D. LISTED in data/warmup.json "listed": what is absent at match start, made through its own
## public code path (SoldierRig.build, SoldierModel.make_corpse, ShotFx.show_shot, ShotImpacts.spawn,
## Breakable.break_now outside the tree, LootLook's model meshes, ZoneWall.bind), so its particles really emit.
## Nothing here touches match state: copies have no colliders, sounds, lights of their own, animation players or
## scripts (Node.duplicate(0)), and the SoldierRig statics a build changes are put back.
## Headless (no GL) the same item list, stepping and progress run; nothing is drawn.

const PATH := "res://data/warmup.json"
static var _registry := DataRegistry.new()
static var _primitive_formats: Dictionary = {}

var cfg: Dictionary = {}
## Every item: {"id", "source": "derived" | "listed", "node" (derived) or "kind" + "arg" (listed), "keys"}.
var items: Array[Dictionary] = []
## Draw key -> id of the item that warms it (derived keys at setup, listed keys when the item is made).
var covered: Dictionary = {}
## The light contexts in use (data/warmup.json "contexts" whose light kinds the match holds).
var contexts: Array[Dictionary] = []
## Items started so far.
var index: int = 0
var done: bool = false
var camera: Camera3D
var _match: Node
var _cells: Array[Node3D] = []
var _live: Array[Dictionary] = []  # {"nodes": Array[Node], "left": int}


static func config() -> Dictionary:
	return _registry.load_file(PATH)


static func _vec(a: Array) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


static func _num(block: Variant) -> float:
	return float((block as Dictionary).get("value", 0.0)) if block is Dictionary else float(block)


## ---- Keys (pure; tests/test_w1c_warmup_coverage.gd) ----

## The flags of a generated material (BaseMaterial3D, ParticleProcessMaterial) or node: every stored bool and int
## property plus whether each texture slot is set. Those select the generated shader; colours and numbers do not.
static func feature_signature(res: Object) -> String:
	var parts := PackedStringArray()
	for p: Dictionary in res.get_property_list():
		if not (int(p["usage"]) & PROPERTY_USAGE_STORAGE):
			continue
		var n := String(p["name"])
		if n == "render_priority" or n == "resource_local_to_scene" or n == "next_pass" or n.begins_with("metadata/"):
			continue
		match int(p["type"]):
			TYPE_BOOL, TYPE_INT:
				parts.append("%s=%s" % [n, str(res.get(n))])
			TYPE_OBJECT:
				if res.get(n) is Texture:
					parts.append(n + "=T")
	return ",".join(parts)


## "shader:<path>" for a ShaderMaterial (its code's hash when it has no file), "<Class>:<flags hash>" otherwise,
## "+<next pass key>" appended; "none" for no material.
static func material_key(mat: Material) -> String:
	if mat == null:
		return "none"
	var key := ""
	if mat is ShaderMaterial:
		var sh := (mat as ShaderMaterial).shader
		if sh == null:
			key = "shader:none"
		else:
			key = "shader:" + (sh.resource_path if sh.resource_path != "" else "code#%d" % sh.code.hash())
	else:
		key = "%s:%d" % [mat.get_class(), feature_signature(mat).hash()]
	if mat.next_pass != null and mat.next_pass != mat:
		key += "+" + material_key(mat.next_pass)
	return key


## The vertex format of a surface: an ArrayMesh's stored format, else (a PrimitiveMesh) the arrays it has.
static func surface_format(mesh: Mesh, s: int) -> int:
	if mesh is ArrayMesh:
		return (mesh as ArrayMesh).surface_get_format(s)
	var key := "%s%d%s" % [mesh.get_class(), s, str(mesh.get("add_uv2"))]  # a primitive's arrays: its type, not its sizes
	if not _primitive_formats.has(key):
		var arrays := mesh.surface_get_arrays(s)
		var f := 0
		for i in arrays.size():
			if arrays[i] != null:
				f |= 1 << i
		_primitive_formats[key] = f
	return int(_primitive_formats[key])


## True when the mesh deforms with a Skeleton3D (bone attributes and a skeleton at its skeleton path).
static func is_skinned(mi: MeshInstance3D) -> bool:
	if not (mi.mesh is ArrayMesh) or mi.mesh.get_surface_count() == 0:
		return false
	if (surface_format(mi.mesh, 0) & Mesh.ARRAY_FORMAT_BONES) == 0:
		return false
	return mi.get_node_or_null(mi.skeleton) is Skeleton3D


static func _mesh_keys(out: PackedStringArray, kind: String, mesh: Mesh, override: Material, tail: String) -> void:
	if mesh == null:
		return
	for s in mesh.get_surface_count():
		var mat := override if override != null else mesh.surface_get_material(s)
		out.append("%s|f%d|%s%s" % [kind, surface_format(mesh, s), material_key(mat), tail])


## The draw keys of one geometry node, one per surface (and per overlay): draw kind | vertex format | material key |
## shadow casting | instance transparency.
static func draw_keys(gi: GeometryInstance3D) -> PackedStringArray:
	var out := PackedStringArray()
	var tail := "|cs%d|tr%d" % [int(gi.cast_shadow), 1 if gi.transparency > 0.0 else 0]
	var meshes: Array[Mesh] = []
	var kind := gi.get_class()
	if gi is MeshInstance3D:
		var mi := gi as MeshInstance3D
		if mi.mesh == null:
			return out
		kind = "skinned" if is_skinned(mi) else "mesh"
		meshes.append(mi.mesh)
		for s in mi.mesh.get_surface_count():
			out.append("%s|f%d|%s%s" % [kind, surface_format(mi.mesh, s), material_key(mi.get_active_material(s)), tail])
	elif gi is MultiMeshInstance3D:
		var mm := (gi as MultiMeshInstance3D).multimesh
		if mm == null or mm.mesh == null:
			return out
		kind = "multimesh:t%d:c%d:d%d" % [mm.transform_format, int(mm.use_colors), int(mm.use_custom_data)]
		meshes.append(mm.mesh)
		_mesh_keys(out, kind, mm.mesh, gi.material_override, tail)
	elif gi is CPUParticles3D:
		kind = "cpu_particles"
		meshes.append((gi as CPUParticles3D).mesh)
		_mesh_keys(out, kind, (gi as CPUParticles3D).mesh, gi.material_override, tail)
	elif gi is GPUParticles3D:
		var gp := gi as GPUParticles3D
		kind = "gpu_particles:" + material_key(gp.process_material)
		for p in gp.draw_passes:
			meshes.append(gp.get_draw_pass_mesh(p))
			_mesh_keys(out, kind, gp.get_draw_pass_mesh(p), gi.material_override, tail)
	else:
		out.append("%s:%d|%s%s" % [kind, feature_signature(gi).hash(), material_key(gi.material_override), tail])
	if gi.material_overlay != null:
		for mesh in meshes:
			_mesh_keys(out, "overlay:" + kind, mesh, gi.material_overlay, tail)
	return out


## Every draw key under `root` -> the first geometry node (tree order) that has it. Hidden nodes count (a hidden node
## is shown later: the carrier, a gun, a muzzle flash); nodes under a ShaderWarmup do not.
static func collect(root: Node, out: Dictionary) -> void:
	for child in root.get_children():
		if child is ShaderWarmup:
			continue
		if child is GeometryInstance3D:
			for k in draw_keys(child as GeometryInstance3D):
				if not out.has(k):
					out[k] = child
		collect(child, out)


## The light kinds the match holds: "omni", "omni_shadow", "spot", "spot_shadow" -> true (hidden lights count).
static func light_kinds(root: Node) -> Dictionary:
	var out := {}
	for light in root.find_children("*", "Light3D", true, false):
		var kind := "omni" if light is OmniLight3D else ("spot" if light is SpotLight3D else "")
		if kind != "":
			out[kind + ("_shadow" if (light as Light3D).shadow_enabled else "")] = true
	return out


## The shader paths a match draws beside its geometry: the sky's, and every canvas_item ShaderMaterial under `root`
## (the vignette); both are drawn while the opaque overlay is up.
static func screen_shaders(root: Node) -> PackedStringArray:
	var out := PackedStringArray()
	var world := root.get_node_or_null("WorldEnvironment") as WorldEnvironment
	if world != null and world.environment != null and world.environment.sky != null:
		var sky_mat := world.environment.sky.sky_material as ShaderMaterial
		if sky_mat != null and sky_mat.shader != null:
			out.append(sky_mat.shader.resource_path)
	for c in root.find_children("*", "CanvasItem", true, false):
		var m := (c as CanvasItem).material as ShaderMaterial
		if m != null and m.shader != null and not out.has(m.shader.resource_path):
			out.append(m.shader.resource_path)
	return out


## The draw keys under `root` that `covered_keys` lacks (the coverage test; [] = all warmed).
static func uncovered(root: Node, covered_keys: Dictionary) -> PackedStringArray:
	var found := {}
	collect(root, found)
	var out := PackedStringArray()
	for k: String in found:
		if not covered_keys.has(k):
			out.append(k)
	return out


## ---- The warm-up ----

## Builds the item list from `match_root` (this node must already be its child), the cells and the warm camera
## (near / far / fov from `template`, the match camera), and makes the warm camera current.
func setup(match_root: Node, template: Camera3D) -> void:
	_match = match_root
	process_mode = Node.PROCESS_MODE_ALWAYS
	cfg = config()
	var lights := light_kinds(match_root)
	contexts.clear()
	for c: Dictionary in cfg.get("contexts", []):
		var ok := true
		for kind: String in c.get("lights", []):
			ok = ok and lights.has(kind)
		if ok:
			contexts.append(c)
	var found := {}
	collect(match_root, found)
	var by_source := {}
	for key: String in found:
		var src := _source_of(found[key] as GeometryInstance3D)
		if not by_source.has(src):
			var item := {"id": "derived:" + str(match_root.get_path_to(src)), "source": "derived", "node": src, "keys": PackedStringArray()}
			by_source[src] = item
			items.append(item)
		(by_source[src]["keys"] as PackedStringArray).append(key)
		covered[key] = by_source[src]["id"]
	for entry: Dictionary in cfg.get("listed", []):
		_expand_listed(entry)
	_build_stage(template)


func progress() -> float:
	return 1.0 if items.is_empty() else clampf(float(index) / float(items.size()), 0.0, 1.0)


## One frame of the warm-up: frees the copies whose time is up and starts the next item. True once every item has
## started and the last copies are gone.
func step() -> bool:
	if done:
		return true
	for i in range(_live.size() - 1, -1, -1):
		_live[i]["left"] = int(_live[i]["left"]) - 1
		if int(_live[i]["left"]) <= 0:
			for n: Node in _live[i]["nodes"]:
				if is_instance_valid(n):
					n.queue_free()
			_live.remove_at(i)
	if index >= items.size():
		done = _live.is_empty()
		return done
	var item := items[index]
	index += 1
	var nodes: Array[Node] = []
	for c in _cells.size():
		var holder := Node3D.new()
		holder.name = "Item%d" % index
		_cells[c].add_child(holder)
		_fill(item, holder)
		nodes.append(holder)
		if c == 0 and item["source"] == "listed":
			var keys := {}
			collect(holder, keys)
			for k: String in keys:
				(item["keys"] as PackedStringArray).append(k)
				if not covered.has(k):
					covered[k] = item["id"]
	_live.append({"nodes": nodes, "left": maxi(1, int(_num(cfg.get("copy_frames", 1))))})
	return false


func current_item_id() -> String:
	return String(items[index - 1]["id"]) if index > 0 and index <= items.size() else ""


## ---- Stage ----

func _build_stage(template: Camera3D) -> void:
	var st: Dictionary = cfg["stage"]
	var origin := _vec(st["origin_m"])
	var cell_m := float(st["cell_m"])
	var n := contexts.size()
	for i in n:
		var cell := Node3D.new()
		cell.name = "Cell_" + String(contexts[i].get("id", str(i)))
		add_child(cell)
		cell.global_position = origin + Vector3((float(i) - float(n - 1) * 0.5) * cell_m, 0.0, 0.0)
		for kind: String in contexts[i].get("lights", []):
			_add_light(cell, kind)
		_cells.append(cell)
	camera = Camera3D.new()
	camera.name = "WarmupCamera"
	if template != null:
		camera.near = template.near
		camera.far = template.far
		camera.fov = template.fov
		camera.keep_aspect = template.keep_aspect
	add_child(camera)
	camera.global_position = origin + Vector3(0.0, float(st["camera_up_m"]), float(st["camera_back_m"]))
	camera.look_at(origin)
	camera.make_current()


func _add_light(cell: Node3D, kind: String) -> void:
	var l: Dictionary = cfg["lights"]
	var light: Light3D
	if kind.begins_with("omni"):
		var omni := OmniLight3D.new()
		omni.omni_range = float(l["omni_range_m"])
		omni.light_energy = float(l["omni_energy"])
		light = omni
		cell.add_child(omni)
	else:
		var spot := SpotLight3D.new()
		spot.spot_range = float(l["spot_range_m"])
		spot.spot_angle = float(l["spot_angle_deg"])
		spot.light_energy = float(l["spot_energy"])
		light = spot
		cell.add_child(spot)
		spot.position = Vector3.UP * float(l["spot_height_m"])
		spot.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	light.name = "Warm_" + kind
	light.shadow_enabled = kind.ends_with("_shadow")
	light.light_bake_mode = Light3D.BAKE_DISABLED


## ---- Copies ----

func _source_of(gi: GeometryInstance3D) -> Node:
	if gi is MeshInstance3D and is_skinned(gi as MeshInstance3D):
		return gi.get_node((gi as MeshInstance3D).skeleton)
	return gi


func _fill(item: Dictionary, holder: Node3D) -> void:
	if item["source"] == "derived":
		var src: Node = item["node"]
		if src == null or not is_instance_valid(src):
			return
		var copy := _copy_of(src)
		if copy != null:
			holder.add_child(copy)
			_prepare(copy)
			_fit(holder, copy)
		return
	match String(item["kind"]):
		"soldier_set":
			_make_soldier(holder, String(item["arg"]))
		"corpse":
			_make_corpse(holder)
		"shot_fx":
			var host := Node3D.new()
			host.name = "ShotHost"
			holder.add_child(host)
			var fx := ShotFx.new()
			host.add_child(fx)
			var side := camera.global_transform.basis.x * float(cfg["stage"]["copy_size_m"]) * 0.5
			fx.show_shot(holder.global_position - side, holder.global_position + side)
			_bound_particles(holder)
		"impact":
			var pool := ShotImpacts.new()
			holder.add_child(pool)
			pool.spawn(String(item["arg"]), holder.global_position, Vector3.UP)
			_bound_particles(holder)
		"breakable_fx":
			var props := DataRegistry.new().load_file("res://data/props.json")
			var type := String(item["arg"])
			var body := Breakable.make({"id": "warmup_" + type, "type": type, "at": [0, 0, 0], "size": [1, 1, 1]}, props["breakables"][type])
			body.position = holder.global_position  # outside the tree: no sound, no group, no loot roll (emit false)
			body.fx_parent = holder
			body.fx_cfg = props.get("break_fx", {})
			body.break_now(false)
			_bound_particles(holder)
		"loot_model", "loot_glow":
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = MultiMesh.new()
			mmi.multimesh.transform_format = MultiMesh.TRANSFORM_3D
			var look := LootLook.config()
			if item["kind"] == "loot_glow":
				mmi.multimesh.use_colors = true
				mmi.multimesh.mesh = LootLook._glow_shape()
				mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			else:
				mmi.multimesh.mesh = LootLook.model_mesh(String(item["arg"]))
				mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if bool(look["cast_shadows"]) else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mmi.multimesh.instance_count = 1
			mmi.multimesh.set_instance_transform(0, Transform3D.IDENTITY)
			if mmi.multimesh.use_colors:
				mmi.multimesh.set_instance_color(0, Color.WHITE)
			holder.add_child(mmi)
			_fit(holder, mmi)
		"loot_box":
			var field := LootField.new()
			field.process_mode = Node.PROCESS_MODE_DISABLED  # never places a match's worth of items
			var director := _match.get("director") as MatchDirector
			field.setup(director.loot_cfg if director != null and not director.loot_cfg.is_empty() else DataRegistry.new().load_file(MatchDirector.LOOT_PATH), 1)
			holder.add_child(field)
			field.drop({"item_id": String(item["arg"])}, holder.global_position)
			_fit(holder, field)
		"zone_wall":
			var wall := ZoneWall.new()
			holder.add_child(wall)
			wall.bind(_match.get("director") as MatchDirector, DataRegistry.new().load_file(MatchRoot.UI_PATH).get("zone_wall", {}))
			wall.process_mode = Node.PROCESS_MODE_DISABLED  # its refresh would hide it again (no zone before the start)
			wall.visible = true
			_fit(holder, wall)


func _expand_listed(entry: Dictionary) -> void:
	var id := String(entry.get("id", ""))
	match String(entry.get("kind", "")):
		"soldier_sets":
			for set_id: String in SoldierRig.armour_sets():
				items.append(_listed(id + ":" + set_id, "soldier_set", set_id))
		"corpse":
			items.append(_listed(id, "corpse", ""))
		"shot_fx":
			items.append(_listed(id, "shot_fx", ""))
		"impacts":
			for kind: String in ((ViewMesh.config().get("fx", {}) as Dictionary).get("impacts", {}) as Dictionary):
				items.append(_listed(id + ":" + kind, "impact", kind))
		"breakable_fx":
			for type: String in DataRegistry.new().load_file("res://data/props.json").get("breakables", {}):
				items.append(_listed(id + ":" + type, "breakable_fx", type))
		"loot":
			for item_id: String in (LootLook.config().get("models", {}) as Dictionary):
				items.append(_listed(id + ":" + item_id, "loot_model", item_id))
			if bool((LootLook.config().get("glow", {}) as Dictionary).get("enabled", false)):
				items.append(_listed(id + ":glow", "loot_glow", ""))
			# The loot field's own box (drawn for an item id without a model; one material for every kind).
			var loot_items: Dictionary = DataRegistry.new().load_file(MatchDirector.LOOT_PATH).get("items", {})
			if not loot_items.is_empty():
				items.append(_listed(id + ":box", "loot_box", String(loot_items.keys()[0])))
		"zone_wall":
			items.append(_listed(id, "zone_wall", ""))
		_:
			push_warning("ShaderWarmup: unknown listed kind '%s' (data/warmup.json)" % entry.get("kind", ""))


static func _listed(id: String, kind: String, arg: String) -> Dictionary:
	return {"id": "listed:" + id, "source": "listed", "kind": kind, "arg": arg, "keys": PackedStringArray()}


## A visual-only copy: a geometry node with the same mesh, materials, instance format and shadow casting, or for a
## skinned source the whole Skeleton3D (Node.duplicate(0): no scripts, signals or groups).
func _copy_of(src: Node) -> Node3D:
	if src is MeshInstance3D:
		var s := src as MeshInstance3D
		var mi := MeshInstance3D.new()
		mi.mesh = s.mesh
		mi.material_override = s.material_override
		mi.material_overlay = s.material_overlay
		for i in s.get_surface_override_material_count():
			mi.set_surface_override_material(i, s.get_surface_override_material(i))
		_copy_instance(s, mi)
		return mi
	if src is MultiMeshInstance3D:
		var s := src as MultiMeshInstance3D
		var mmi := MultiMeshInstance3D.new()
		var mm := MultiMesh.new()
		mm.transform_format = s.multimesh.transform_format
		mm.use_colors = s.multimesh.use_colors
		mm.use_custom_data = s.multimesh.use_custom_data
		mm.mesh = s.multimesh.mesh
		mm.instance_count = 1
		if mm.transform_format == MultiMesh.TRANSFORM_3D:
			mm.set_instance_transform(0, Transform3D.IDENTITY)
		else:
			mm.set_instance_transform_2d(0, Transform2D.IDENTITY)
		if mm.use_colors:
			mm.set_instance_color(0, Color.WHITE)
		if mm.use_custom_data:
			mm.set_instance_custom_data(0, Color(0, 0, 0, 0))
		mmi.multimesh = mm
		mmi.material_override = s.material_override
		mmi.material_overlay = s.material_overlay
		_copy_instance(s, mmi)
		return mmi
	var dup := src.duplicate(0) as Node3D
	if dup != null:
		dup.transform = Transform3D.IDENTITY
	return dup


static func _copy_instance(from: GeometryInstance3D, to: GeometryInstance3D) -> void:
	to.cast_shadow = from.cast_shadow
	to.transparency = from.transparency
	to.layers = from.layers


## Strips what a copy must not have, shows everything, drops the visibility ranges and starts its particles.
func _prepare(root: Node) -> void:
	var strip: Array = []
	for n in root.find_children("*", "", true, false):
		if n is CollisionObject3D or n is CollisionShape3D or n is AudioStreamPlayer3D or n is AudioStreamPlayer \
				or n is Light3D or n is Camera3D or n is AnimationMixer:
			strip.append(n)
	for v: Variant in strip:
		if is_instance_valid(v):  # not already freed with a stripped parent
			var n := v as Node
			n.get_parent().remove_child(n)
			n.free()
	var nodes: Array[Node] = [root]
	nodes.append_array(root.find_children("*", "", true, false))
	for n in nodes:
		if n is Node3D:
			(n as Node3D).visible = true
		if n is GeometryInstance3D:
			var gi := n as GeometryInstance3D
			gi.visibility_range_begin = 0.0
			gi.visibility_range_end = 0.0
		if n is GPUParticles3D:
			(n as GPUParticles3D).emitting = true
			(n as GPUParticles3D).restart()
		elif n is CPUParticles3D:
			(n as CPUParticles3D).emitting = true
			(n as CPUParticles3D).restart()


## The local box of a geometry node's drawn mesh (a multimesh's or particle's mesh, not its instances).
static func _geom_aabb(gi: GeometryInstance3D) -> AABB:
	if gi is MeshInstance3D and (gi as MeshInstance3D).mesh != null:
		return (gi as MeshInstance3D).mesh.get_aabb()
	if gi is MultiMeshInstance3D and (gi as MultiMeshInstance3D).multimesh != null and (gi as MultiMeshInstance3D).multimesh.mesh != null:
		return (gi as MultiMeshInstance3D).multimesh.mesh.get_aabb()
	if gi is CPUParticles3D and (gi as CPUParticles3D).mesh != null:
		return (gi as CPUParticles3D).mesh.get_aabb()
	if gi is GPUParticles3D:
		return (gi as GPUParticles3D).visibility_aabb
	return AABB(Vector3.ZERO, Vector3.ZERO)


## Scales `copy` down (never up) so its geometry fits the cell, centred on the holder, and gives every geometry node
## a box that stays inside the cell, so only the cell's own warm light pairs with it.
func _fit(holder: Node3D, copy: Node3D) -> void:
	var size := float(cfg["stage"]["copy_size_m"])
	var box := AABB()
	var first := true
	var geoms: Array[Node] = []
	if copy is GeometryInstance3D:
		geoms.append(copy)
	geoms.append_array(copy.find_children("*", "GeometryInstance3D", true, false))
	for g in geoms:
		var local := _geom_aabb(g as GeometryInstance3D)
		var rel := Transform3D.IDENTITY
		var at: Node = g
		while at != copy and at != null:
			rel = (at as Node3D).transform * rel
			at = at.get_parent()
		var b := rel * local
		box = b if first else box.merge(b)
		first = false
	var longest := box.get_longest_axis_size()
	var s := minf(1.0, size / longest) if longest > 0.0 else 1.0
	copy.transform = Transform3D(Basis.from_scale(Vector3.ONE * s), -box.get_center() * s)
	_bound(geoms, size / s)


## Every geometry node gets a custom box of `local_size` (in its own space) around its mesh's centre.
static func _bound(geoms: Array[Node], local_size: float) -> void:
	for g in geoms:
		var gi := g as GeometryInstance3D
		var c := _geom_aabb(gi).get_center()
		gi.custom_aabb = AABB(c - Vector3.ONE * local_size * 0.5, Vector3.ONE * local_size)
		if gi is GPUParticles3D:
			(gi as GPUParticles3D).visibility_aabb = gi.custom_aabb


## Particles a spawn function made under `holder` (top level, unscaled) get a cell-sized box.
func _bound_particles(holder: Node3D) -> void:
	var geoms: Array[Node] = holder.find_children("*", "GeometryInstance3D", true, false)
	for g in geoms:
		var gi := g as GeometryInstance3D
		var size := float(cfg["stage"]["copy_size_m"])
		gi.custom_aabb = AABB(gi.global_transform.affine_inverse() * holder.global_position - Vector3.ONE * size * 0.5, Vector3.ONE * size)


func _local_pawn() -> Node3D:
	var pawn: Variant = _match.get("local_player") if _match != null else null
	return pawn as Node3D if pawn is Node3D and is_instance_valid(pawn) else null


func _make_soldier(holder: Node3D, set_id: String) -> void:
	var pawn := _local_pawn()
	if pawn == null or pawn.get_node_or_null("Head") == null:
		return
	var saved: Array = [SoldierRig.mesh, SoldierRig.mesh_far, SoldierRig.skin]
	var skeleton := SoldierRig.build(SoldierLook.parts(), (pawn.get_node("Head") as Node3D).position, set_id)
	for m: ArrayMesh in [SoldierRig.mesh, SoldierRig.mesh_far]:
		if m == null:
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = m
		mi.skin = SoldierRig.skin
		mi.skeleton = NodePath("..")
		skeleton.add_child(mi)
		SoldierSquadColour.apply(mi, 0)
		SoldierSquadColour.apply_tier(mi, 1)
	SoldierRig.mesh = saved[0]
	SoldierRig.mesh_far = saved[1]
	SoldierRig.skin = saved[2]
	holder.add_child(skeleton)
	_fit(holder, skeleton)


func _make_corpse(holder: Node3D) -> void:
	var pawn := _local_pawn()
	var model := pawn.get_node_or_null("SoldierModel") as SoldierModel if pawn != null else null
	if model == null:
		return
	var saved: Array = [SoldierRig.mesh, SoldierRig.mesh_far, SoldierRig.skin]
	var corpse := model.make_corpse()
	SoldierRig.mesh = saved[0]
	SoldierRig.mesh_far = saved[1]
	SoldierRig.skin = saved[2]
	holder.add_child(corpse)
	_prepare(corpse)
	_fit(holder, corpse)
