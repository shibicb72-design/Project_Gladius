class_name LootLook
extends Node3D
## S6: how ground loot looks. The loot field (gameplay) keeps one plain box node per item; this node hides
## those boxes and draws every item of a kind as one batch of a small model, plus one batch of glow rings and
## beams for all items, rebuilt whenever an item node enters or leaves the loot field. It reads the field's
## public `items` and never changes it. Data: data/art_loot.json (placeholders, OQ-GFX-LOOT).
## An item id without a model keeps its box. Presentation only.

const PATH := "res://data/art_loot.json"
static var _registry := DataRegistry.new()
static var _meshes := {}
static var _glow_mesh: ArrayMesh

var loot: LootField
var batches := {}  # item id -> MultiMeshInstance3D
var glow: MultiMeshInstance3D
var shown := 0  # items drawn by the batches after the last sync
var _dirty := false


static func config() -> Dictionary:
	return _registry.load_file(PATH)


## The model mesh of an item id (cached), or null when the data has none.
static func model_mesh(item_id: String) -> ArrayMesh:
	if _meshes.has(item_id):
		return _meshes[item_id]
	var models: Dictionary = config()["models"]
	var mesh: ArrayMesh = null
	if models.has(item_id):
		var parts: Array = []
		for part: Dictionary in models[item_id]["parts"]:
			var plain := part.duplicate()
			if not plain.has("shape"):
				plain["shape"] = "block"  # small parts: the plain box, not the 64-triangle chamfered one
			parts.append(WorldKit._kit_part(plain))
		mesh = LowpolyKit.merge(parts)
	_meshes[item_id] = mesh
	return mesh


## Where an item's model sits relative to the item's ground point.
static func model_transform(item_id: String, at: Vector3, yaw: float) -> Transform3D:
	var model: Dictionary = config()["models"][item_id]
	var tilt: Array = model["tilt_deg"]
	var basis := Basis(Vector3.UP, yaw) * Basis.from_euler(Vector3(deg_to_rad(float(tilt[0])), deg_to_rad(float(tilt[1])), deg_to_rad(float(tilt[2]))))
	return Transform3D(basis.scaled(Vector3.ONE * float(model["scale"])), at + Vector3.UP * float(model["lift_m"]))


static func _glow_shape() -> ArrayMesh:
	if _glow_mesh != null:
		return _glow_mesh
	var g: Dictionary = config()["glow"]
	var r := float(g["ring_radius_m"])
	var h := float(g["beam_height_m"])
	var w := float(g["beam_width_m"]) * 0.5
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# UV2.x says which part a vertex belongs to: 0 = the ring on the ground, 1 = the beam.
	var quads: Array = [
		[0.0, Vector3(-r, 0.02, -r), Vector3(r, 0.02, -r), Vector3(r, 0.02, r), Vector3(-r, 0.02, r)],
		[1.0, Vector3(-w, 0, 0), Vector3(w, 0, 0), Vector3(w, h, 0), Vector3(-w, h, 0)],
		[1.0, Vector3(0, 0, -w), Vector3(0, 0, w), Vector3(0, h, w), Vector3(0, h, -w)],
	]
	var uvs: Array[Vector2] = [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
	for quad: Array in quads:
		for index: int in [0, 1, 2, 0, 2, 3]:
			st.set_uv(uvs[index])
			st.set_uv2(Vector2(float(quad[0]), 0.0))
			st.add_vertex(quad[index + 1])
	_glow_mesh = st.commit()
	var material := ShaderMaterial.new()
	material.shader = load("res://scripts/visual/shaders/loot_glow.gdshader")
	material.set_shader_parameter("strength", float(g["strength"]))
	material.set_shader_parameter("pulse_speed", float(g["pulse_speed"]))
	_glow_mesh.surface_set_material(0, material)
	return _glow_mesh


func bind(field: LootField) -> void:
	loot = field
	loot.child_entered_tree.connect(_mark)
	loot.child_exiting_tree.connect(_mark)
	_dirty = true


func _mark(_node: Node) -> void:
	_dirty = true


func _process(_delta: float) -> void:
	if loot == null:
		var world := get_parent()
		var root := world.get_parent() if world != null else null
		if root != null and root.get("loot") != null and is_instance_valid(root.loot):
			bind(root.loot)
	if loot != null and _dirty and is_instance_valid(loot):
		_dirty = false
		sync()


## Rebuilds the batches from the loot field's current items.
func sync() -> void:
	var cfg := config()
	var by_id := {}
	var glow_at: Array[Vector3] = []
	var glow_color: Array[Color] = []
	var by_kind: Dictionary = cfg["glow"]["by_kind"]
	shown = 0
	for id: int in loot.items:
		var entry: Dictionary = loot.items[id]
		var item_id := String(entry["item_id"])
		var node := entry.get("node") as Node3D
		var mesh := model_mesh(item_id)
		if node == null or not is_instance_valid(node) or mesh == null:
			continue
		node.visible = false  # the plain box stays the loot field's node; the batch below is what is seen
		var at: Vector3 = entry["pos"]
		if not by_id.has(item_id):
			by_id[item_id] = []
		(by_id[item_id] as Array).append(model_transform(item_id, at, fposmod(float(id) * 2.399963, TAU)))
		glow_at.append(at)
		glow_color.append(GreyboxArt.color_value(by_kind.get(String(loot.def(item_id).get("kind", "")), [1, 1, 1, 1])))
		shown += 1
	for item_id: String in batches.keys():
		if not by_id.has(item_id):
			(batches[item_id] as Node).queue_free()
			batches.erase(item_id)
	for item_id: String in by_id:
		var transforms: Array = by_id[item_id]
		var batch := batches.get(item_id) as MultiMeshInstance3D
		if batch == null:
			batch = MultiMeshInstance3D.new()
			batch.name = "Loot_" + item_id
			batch.multimesh = MultiMesh.new()
			batch.multimesh.transform_format = MultiMesh.TRANSFORM_3D
			batch.multimesh.mesh = model_mesh(item_id)
			batch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if bool(cfg["cast_shadows"]) else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(batch)
			batches[item_id] = batch
		batch.multimesh.instance_count = transforms.size()
		for i in transforms.size():
			batch.multimesh.set_instance_transform(i, transforms[i])
		batch.set_meta(&"transforms", transforms)  # a headless renderer keeps no instance data to read back
	if bool(cfg["glow"]["enabled"]):
		if glow == null:
			glow = MultiMeshInstance3D.new()
			glow.name = "LootGlow"
			glow.multimesh = MultiMesh.new()
			glow.multimesh.transform_format = MultiMesh.TRANSFORM_3D
			glow.multimesh.use_colors = true
			glow.multimesh.mesh = _glow_shape()
			glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(glow)
		glow.multimesh.instance_count = glow_at.size()
		for i in glow_at.size():
			glow.multimesh.set_instance_transform(i, Transform3D(Basis.IDENTITY, glow_at[i]))
			glow.multimesh.set_instance_color(i, glow_color[i])
