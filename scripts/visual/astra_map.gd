extends Node3D
## Synchronous map construction: ready before MatchRoot bakes parsed static colliders.
var cover_bodies: Array[StaticBody3D] = []
var structure_bodies: Array[StaticBody3D] = []  # W1 world kit pieces (group "structure")
var decor_bodies: Array[StaticBody3D] = []  # W2 colliders of the solid rim decor (group "structure")
var ring_bodies: Array[StaticBody3D] = []  # W3 cover of the outer ring (groups "ring_cover" and "cover_wall")
var chest_bodies: Array[StaticBody3D] = []  # M2 L1b loot chests under Nav (group "loot_chest", never cover_wall)
var chunks: MapChunks  # M2P1A: the looks of cover, ring cover, structures and decor, batched per chunk (node "Chunks")
## M2P1A: decor id -> its batch type in source "decor" ("<kind>_<n>", n = the index of the entry's size among
## its kind's distinct sizes, first seen first). A decor look is chunks.batch_of("decor", decor_types[id], xform).
var decor_types := {}
## The map json this scene builds. MatchRoot sets it before the map enters the tree; scenes built
## directly keep the default.
@export var map_json: String = "res://data/maps/alesia_section.json"

const COVER_PATH := "res://data/maps/alesia_cover.json"

func _ready() -> void:
	var map := get_parent()
	var nav := map.get_node("Nav")
	var reg := DataRegistry.new()
	var map_def := reg.load_file(map_json)
	# Cover types and decor colliders always come from the alesia cover file; the pieces, ring pieces and
	# decor come from the map's "cover_data" file (default: the same alesia file).
	var base := reg.load_file(COVER_PATH)
	var placed := reg.load_file(String(map_def.get("cover_data", COVER_PATH)))
	var cfg := {
		"types": base["types"],
		"decor_colliders": base.get("decor_colliders", {}),
		"pieces": placed["pieces"],
		"ring_pieces": placed.get("ring_pieces", []),
		"decor": placed["decor"],
	}
	var meshes := {}
	for type: String in cfg["types"]:
		var definition: Dictionary = cfg["types"][type]
		meshes[type] = LowpolyKit.build_cover(definition)
	# M2P1A: cover, ring cover, structure and decor looks draw as one batch per chunk, source and type (MapChunks);
	# the grid comes from the ground size and is set before any piece is added (no ground: one chunk); build()
	# runs once, after the decor loop.
	ground_size_m = ground_size_of(map_def, nav)
	chunks = MapChunks.new()
	chunks.name = "Chunks"
	add_child(chunks)
	chunks.setup(ground_size_m)
	# M2P1B: resolved before the pieces so each stands on the ground under its origin (lifted()).
	terrain = MapTerrain.for_map(map_def)
	for entry: Dictionary in cfg["pieces"]:
		var definition: Dictionary = cfg["types"][entry["type"]]
		var body := StaticBody3D.new()
		body.name = entry["id"]
		body.set_meta(&"cover_palette", definition.get("palette", "citadel"))
		body.collision_layer = 1
		body.collision_mask = 0
		if bool(definition.get("coverable", false)):
			body.add_to_group(&"cover_wall")
		body.position = lifted(LowpolyKit.vec(entry["at"]))
		# M2P1C stop 4: no shadow argument; the batch class decides (map_build.json "classes", see MapChunks).
		chunks.add("cover", String(entry["type"]), meshes[entry["type"]], WorldSurface.palette_material(String(definition.get("palette", "citadel"))), body.transform, true)
		var shape := CollisionShape3D.new()
		shape.name = "Shape"
		var box := BoxShape3D.new()
		box.size = LowpolyKit.vec(definition["size"])
		shape.shape = box
		body.add_child(shape)
		nav.add_child(body)
		cover_bodies.append(body)
	# M2 L1b: breakables (the cover file's "breakables"; a map without the key gets no Props node). In cover_bodies
	# right after the pieces: the order of the paint's trodden points (tools/gen_alesia.gd trodden_of).
	if placed.has("breakables"):
		_build_breakables(placed["breakables"])
	for body in nav.get_children():
		if body in cover_bodies or body.name == &"Ground" or body is LootChest:  # a chest is never a wall, whatever the build order
			continue
		body.add_to_group(&"cover_wall")
		var mesh := body.get_node("Mesh") as MeshInstance3D
		var size := (body.get_node("Shape").shape as BoxShape3D).size
		var kind := "camp" if String(body.name).begins_with("CampBlock") else "wall"
		# Vertical walls reuse the same long-axis profile, rotated on the visual only.
		var profile := Vector3(size.z, size.y, size.x) if size.z > size.x else size
		var key := kind + str(profile)
		if not meshes.has(key):
			meshes[key] = LowpolyKit.build(kind, profile)
		mesh.mesh = meshes[key]
		if size.z > size.x:
			mesh.rotation.y = PI * 0.5
	# W1: world kit pieces come after the loop above, which takes every other Nav child for a one-box wall.
	# They are bodies in group "structure" (never cover_wall); their look is one batch per chunk and type.
	structure_bodies = WorldKit.populate(nav, chunks, WorldKit.pieces_for(map_def), terrain)
	_build_ring(nav, cfg, meshes)
	# W2: decor kinds listed in "decor_colliders" (rim arches and rocks) are solid; flat paving is not listed.
	# M2P1A: the decor looks draw as one batch per chunk, kind and size (source "decor", type "<kind>_<n>", see
	# decor_types); the scene's Decor node stays empty. Solid decor bodies still go under Nav.
	var decor_solid: Dictionary = cfg.get("decor_colliders", {})
	var size_index := {}  # kind + str(size) -> index of that size among the kind's sizes, first seen first
	var size_counts := {}  # kind -> distinct sizes seen so far
	for entry: Dictionary in cfg["decor"]:
		var kind := String(entry["kind"])
		var key: String = kind + str(entry["size"])
		if not meshes.has(key):
			meshes[key] = LowpolyKit.build(kind, LowpolyKit.vec(entry["size"]))
		if not size_index.has(key):
			size_index[key] = int(size_counts.get(kind, 0))
			size_counts[kind] = int(size_index[key]) + 1
		var type := "%s_%d" % [kind, int(size_index[key])]
		decor_types[String(entry["id"])] = type
		var at := LowpolyKit.vec(entry["at"])
		var lift := lifted(at).y - at.y
		var xform := Transform3D(Basis.from_euler(Vector3(0.0, deg_to_rad(float(entry["yaw"])), 0.0)), lifted(at))
		chunks.add("decor", type, meshes[key], null, xform, decor_solid.has(entry["kind"]))  # shadow: the batch class's
		if decor_solid.has(entry["kind"]):
			var solid := WorldKit.decor_body(entry, String(decor_solid[entry["kind"]]), meshes[key], lift)
			nav.add_child(solid)
			decor_bodies.append(solid)
	# M2 L1b: the loot chests (the cover file's "chests"), after the wall loop above (a chest has no "Mesh" child).
	if placed.has("chests"):
		_build_chests(nav, placed["chests"])
	chunks.build()
	for body in chest_bodies:
		chunks.hide_piece(LootChest.open_id((body as LootChest).prop_id))  # every chest starts closed
	_paint_ground(nav)
	_build_terrain(nav)
	# S6: the horizon (outer wall ring, hills, ground skirt): looks only, outside the ground square.
	# M2L1 (binding fix 5): a map json may switch it off ("backdrop": false; default true).
	if backdrop_wanted(map_def, bool(GraphicsPresets.new().get_preset().get("art_backdrop_enabled", false))):
		var backdrop := Backdrop.new()
		backdrop.name = "Backdrop"
		add_child(backdrop)
		backdrop.build(ground_material)
	# Attach below this builder: never add a sibling while the map root is in _ready.
	var ambient := WorldAmbient.new()
	ambient.name = "Ambient"
	add_child(ambient)  # before configure: the tufts ask this builder (their parent) where the grass is
	ambient.configure(DataRegistry.new().load_file("res://data/art_world.json"), bool(GraphicsPresets.new().get_preset().get("art_ambient_enabled", false)))


## M2 L1b: the breakable crates and barrels under ArtBuilder/Props: OUTSIDE Nav, so the navigation bake never
## parses them (bots path as if they were not there; Lanista's binding). Each is a Breakable (the cover contract,
## groups cover_wall and breakable, behaviour from data/props.json) standing on the terrain, appended to
## cover_bodies; its look is a named piece of the chunk batches (source "cover", type = the breakable type), hidden
## when it breaks; breaking takes it out of cover_bodies (_on_breakable_removed). Attached below this builder:
## never a sibling while the map root is in _ready.
func _build_breakables(entries: Array) -> void:
	var props_cfg := WorldProps.config()
	var types: Dictionary = props_cfg.get("breakables", {})
	var root := Node3D.new()
	root.name = "Props"
	add_child(root)
	var meshes := {}
	for entry: Dictionary in entries:
		var type := String(entry["type"])
		var type_cfg: Dictionary = types.get(type, {})
		var body := Breakable.make(entry, type_cfg)
		body.position = lifted(LowpolyKit.vec(entry["at"]))
		var key := type + str(entry["size"])
		if not meshes.has(key):
			var look: Dictionary = (type_cfg.get("look", {}) as Dictionary).duplicate()
			look["size"] = entry["size"]  # a "kind" look is sized by the collider box; "parts" carry their own sizes
			meshes[key] = LowpolyKit.build_cover(look)
		chunks.add("cover", type, meshes[key], WorldSurface.palette_material(body.palette), body.transform, true, body.prop_id)
		body.chunks = chunks
		body.fx_parent = self
		body.fx_cfg = props_cfg.get("break_fx", {})
		body.on_removed = _on_breakable_removed
		root.add_child(body)
		cover_bodies.append(body)


## M2 L1b: the loot chests, permanent StaticBody3D (LootChest) under Nav: the navigation bake parses them, so bots
## path around them. Group "loot_chest" only (never cover_wall, never in cover_bodies, so the paint's trodden points
## and the cover index are unchanged), layer 1, meta cover_palette, a "Shape" box. Looks: two named pieces in
## source "cover" per chest, the closed one (type "loot_chest", id = the chest id) and the open one (type
## "loot_chest_open", id LootChest.open_id), both at the body's transform; _ready hides the open one after build().
## The data/props.json looks are authored for chest.look_size and scaled to each entry's box.
func _build_chests(nav: Node, entries: Array) -> void:
	var chest_cfg: Dictionary = WorldProps.config().get("chest", {})
	var palette := String(chest_cfg.get("palette", "citadel"))
	var material := WorldSurface.palette_material(palette)
	var look_size := LowpolyKit.vec(chest_cfg.get("look_size", [1, 1, 1]))
	var meshes := {}
	for entry: Dictionary in entries:
		var body := LootChest.make(entry, palette)
		body.position = lifted(LowpolyKit.vec(entry["at"]))
		var key := str(entry["size"])
		if not meshes.has(key):
			var k := LowpolyKit.vec(entry["size"]) / look_size
			meshes[key] = [
				LowpolyKit.build_cover({"parts": scaled_parts((chest_cfg.get("look_closed", {}) as Dictionary).get("parts", []), k)}),
				LowpolyKit.build_cover({"parts": scaled_parts((chest_cfg.get("look_open", {}) as Dictionary).get("parts", []), k)}),
			]
		chunks.add("cover", "loot_chest", meshes[key][0], material, body.transform, true, body.prop_id)
		chunks.add("cover", "loot_chest_open", meshes[key][1], material, body.transform, true, LootChest.open_id(body.prop_id))
		body.chunks = chunks
		nav.add_child(body)
		chest_bodies.append(body)


## Look parts with every size and position scaled per axis by `k` (a chest look authored for look_size, fitted to a
## box).
static func scaled_parts(parts: Array, k: Vector3) -> Array:
	var out: Array = []
	for part: Dictionary in parts:
		var p := part.duplicate(true)
		var s := LowpolyKit.vec(p["size"]) * k
		var a := LowpolyKit.vec(p["at"]) * k
		p["size"] = [s.x, s.y, s.z]
		p["at"] = [a.x, a.y, a.z]
		out.append(p)
	return out


## M2 L1b: a breakable left the world (Breakable._leave).
func _on_breakable_removed(body: StaticBody3D) -> void:
	cover_bodies.erase(body)


## M2 L1b: the cover bodies that are breakables (group "breakable"), in build order.
func breakable_bodies() -> Array[StaticBody3D]:
	var out: Array[StaticBody3D] = []
	for body in cover_bodies:
		if body.is_in_group(Breakable.GROUP):
			out.append(body)
	return out


## M2P1C: the map leaves the tree (match end, a test or tool freeing it): MapTerrain's cache drops its terrain
## (heights, per-sample positions and normals, chunk meshes: megabytes on test_300). This builder keeps its own `terrain` reference; the next for_map regenerates.
func _exit_tree() -> void:
	MapTerrain.clear_cache()


## S2: the ground's blend material. The paint map comes from the map data (landmarks, cover and structure
## positions); `ground_paint` and `ground_size_m` stay readable for the footstep sounds (GroundPaint.surface_at).
var ground_paint: Image
var ground_size_m := 0.0
## M2P1B: the ground's material (flat ground mesh, terrain chunks and the backdrop's skirt); null without a ground.
var ground_material: ShaderMaterial
## M2P1B: the map's height field (map json "terrain"); null on a flat map (alesia).
var terrain: MapTerrain


## M2L1 (binding fix 5): true when the map gets the S6 backdrop: the graphics preset enables it and the map json
## does not switch it off ("backdrop": false; a missing key keeps today's behaviour).
static func backdrop_wanted(map_def: Dictionary, preset_enabled: bool) -> bool:
	return preset_enabled and bool(map_def.get("backdrop", true))


## M2P1B: a piece's file position raised by the terrain height under its origin (x, z); the piece files keep
## their y (half the height, or the template y, over flat ground). Unchanged on a flat map.
func lifted(at: Vector3) -> Vector3:
	return at if terrain == null else at + Vector3(0.0, terrain.height_at(at.x, at.z), 0.0)


## M2P1B: the square ground's width in metres, one value for the chunk grid, the paint and the footsteps.
## Data first ("terrain"."size_m", then "ground_size_m"); a map json without either (alesia, read-only) keeps
## the old source, the AABB of Nav/Ground/Mesh; no ground at all is 0.
static func ground_size_of(map_def: Dictionary, nav: Node) -> float:
	var terrain: Variant = map_def.get("terrain")
	if typeof(terrain) == TYPE_DICTIONARY and (terrain as Dictionary).has("size_m"):
		return float(terrain["size_m"])
	if map_def.has("ground_size_m"):
		return float(map_def["ground_size_m"])
	var ground := (nav.get_node_or_null("Ground/Mesh") as MeshInstance3D) if nav != null else null
	return ground.get_aabb().size.x if ground != null else 0.0


## Paints from the data size (no ground mesh needed); the material goes on Nav/Ground/Mesh when it exists.
func _paint_ground(nav: Node) -> void:
	if ground_size_m <= 0.0:
		return
	var map_def := DataRegistry.new().load_file(map_json)
	var landmark_path := String(map_def.get("landmarks", ""))
	var landmarks: Array = DataRegistry.new().load_file(landmark_path).get("landmarks", []) if landmark_path != "" else []
	var trodden := PackedVector2Array()
	for group: Array in [cover_bodies, ring_bodies, structure_bodies]:
		for body: StaticBody3D in group:
			trodden.append(Vector2(body.position.x, body.position.z))
	add_to_group(&"ground_paint")
	# M2L1 (binding fix 6): the map's "ground_paint" keys over the global ones; a map naming a "baked" paint loads
	# it (1 km: painting in GDScript at load is too slow) and paints as before, with one printed line, when the
	# file is missing or stale.
	var settings := GroundPaint.settings_for(map_def)
	var baked := String(settings.get("baked", ""))
	if baked != "":
		var px := GroundPaint.px_for(ground_size_m, settings)
		var want := GroundPaint.inputs_hash(ground_size_m, landmarks, trodden, settings)
		ground_paint = GroundPaint.load_baked(map_json, baked, px, want)
		if ground_paint == null:
			print("ArtBuilder: painting the ground at load: %s (rerun tools/gen_alesia.gd)" % GroundPaint.baked_problem(baked, px, want))
	if ground_paint == null:
		ground_paint = GroundPaint.build(map_json, ground_size_m, landmarks, trodden, settings)
	ground_material = WorldSurface.ground_material(GroundPaint.texture(map_json), ground_size_m, map_json)
	var ground_mesh := nav.get_node_or_null("Ground/Mesh") as MeshInstance3D
	if ground_mesh != null:
		ground_mesh.material_override = ground_material


## M2P1B: the terrain look, node "Terrain" with one Chunk_<ix>_<iz>/Mesh per cell of the chunk grid (every cell,
## identity transforms). Kept apart from Chunks, which holds only MultiMesh batches. The collider is
## _build_terrain_collider's. M2P1C: identity is kept on purpose: the renderer measures a visibility range from
## the centre of the mesh's world AABB (see MapChunks), so world-space vertices already measure from the cell.
## M2P1C stop 5: near and far. "Mesh" (full resolution) gets visibility_range_end = E and "Far" (a sibling,
## MapTerrain.far_chunk_mesh) visibility_range_begin = E, with E = terrain.far_swap_m + the chunk's radius (half
## its AABB diagonal) + classes.margin_m, and the same margin m on both (end margin, begin margin). "Far" takes
## "Mesh"'s AABB as its custom_aabb, so both measure the same distance d from the same centre. Godot's rule
## (state = drawn last frame): near hides when d > E + m and shows again when d <= E - m; far shows when
## d >= E + m and hides when d < E - m. So outwards far is on before near goes, inwards near is on before far
## goes: never neither, both only at d == E +- m. No end on Far: a terrain chunk is never culled. Without a
## usable far mesh (far_swap_m 0, a bad far_step_m: push_error, or a partial edge cell) "Mesh" keeps no range.
## The collider is untouched (one HeightMapShape3D of the full heights).
func _build_terrain(nav: Node) -> void:
	if terrain == null:
		return
	_build_terrain_collider(nav)
	var cfg: Dictionary = MapChunks.config().get("terrain", {})
	var shadow := GeometryInstance3D.SHADOW_CASTING_SETTING_ON if bool(cfg.get("cast_shadows", false)) else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var swap_m := float(cfg.get("far_swap_m", 0.0))
	var step_m := float(cfg.get("far_step_m", 0.0))
	if terrain.far_step_m > 0.0:
		step_m = terrain.far_step_m  # M2L1: the map's own far step (map_build.json's 5 m does not fit a 2 m grid)
	var margin_m := float((MapChunks.config().get("classes", {}) as Dictionary).get("margin_m", 0.0))
	if swap_m > 0.0:
		var problem := MapTerrain.far_step_problem(step_m, terrain.resolution_m, chunks.chunk_size_m)
		if problem != "":
			push_error("ArtBuilder: no far terrain: " + problem)
			swap_m = 0.0
	var root := Node3D.new()
	root.name = "Terrain"
	add_child(root)
	for iz in chunks.per_side:
		for ix in chunks.per_side:
			var chunk := Node3D.new()
			chunk.name = "Chunk_%d_%d" % [ix, iz]
			root.add_child(chunk)
			var mesh := MeshInstance3D.new()
			mesh.name = "Mesh"
			mesh.mesh = terrain.chunk_mesh(Vector2i(ix, iz), chunks.chunk_size_m, chunks.per_side)
			mesh.material_override = ground_material
			mesh.cast_shadow = shadow
			chunk.add_child(mesh)
			var far_mesh: ArrayMesh = terrain.far_chunk_mesh(Vector2i(ix, iz), chunks.chunk_size_m, chunks.per_side, step_m) if swap_m > 0.0 else null
			if far_mesh == null:
				continue
			var box := mesh.mesh.get_aabb()
			var end := MapChunks.range_end_for(swap_m, box.size.length() * 0.5, margin_m)
			mesh.visibility_range_end = end
			mesh.visibility_range_end_margin = margin_m
			var far := MeshInstance3D.new()
			far.name = "Far"
			far.mesh = far_mesh
			far.material_override = ground_material
			far.cast_shadow = shadow
			far.custom_aabb = box  # the same centre as "Mesh": both swap at the same measured distance
			far.visibility_range_begin = end
			far.visibility_range_begin_margin = margin_m
			chunk.add_child(far)


## M2P1B: the terrain collider, ONE HeightMapShape3D under Nav/Ground (one height field has no seams between
## chunk colliders for pawns or rays to catch on). The name stays "Ground": the audio code and the wall loop in
## _ready tell the ground apart by it. Leftover children (an old box) are freed so no second walkable layer
## can stay at y = 0. The shape is centred on its origin with samples 1 m apart, so with an odd sample count
## they land on the terrain's grid; resolution_m scales x and z (DataRegistry.validate_terrain).
func _build_terrain_collider(nav: Node) -> void:
	var ground := nav.get_node_or_null("Ground") as StaticBody3D
	if ground == null:
		ground = StaticBody3D.new()
		ground.name = "Ground"
		nav.add_child(ground)
	for child in ground.get_children():
		ground.remove_child(child)
		child.free()
	ground.transform = Transform3D.IDENTITY
	var height_map := HeightMapShape3D.new()
	height_map.map_width = terrain.samples
	height_map.map_depth = terrain.samples
	height_map.map_data = terrain.heights
	var shape := CollisionShape3D.new()
	shape.name = "Shape"
	shape.shape = height_map
	shape.scale = Vector3(terrain.resolution_m, 1.0, terrain.resolution_m)
	ground.add_child(shape)


## W3: the outer ring's cover (cfg "ring_pieces"): the same one-box cover types as the inner band, in their own
## list with their own rules ("ring_rules"). A ring body holds its Shape only (groups ring_cover and, when the
## type is coverable, cover_wall); the pieces of a type draw as one batch per chunk with the inner cover's
## material per palette; shadows per batch class (M2P1C stop 4: big ring pieces cast, small ones do not).
func _build_ring(nav: Node, cfg: Dictionary, meshes: Dictionary) -> void:
	for entry: Dictionary in cfg.get("ring_pieces", []):
		var type := String(entry["type"])
		var definition: Dictionary = cfg["types"][type]
		var body := StaticBody3D.new()
		body.name = entry["id"]
		body.set_meta(&"cover_palette", definition.get("palette", "citadel"))
		body.collision_layer = 1
		body.collision_mask = 0
		body.add_to_group(&"ring_cover")
		if bool(definition.get("coverable", false)):
			body.add_to_group(&"cover_wall")
		body.position = lifted(LowpolyKit.vec(entry["at"]))
		var shape := CollisionShape3D.new()
		shape.name = "Shape"
		var box := BoxShape3D.new()
		box.size = LowpolyKit.vec(definition["size"])
		shape.shape = box
		body.add_child(shape)
		nav.add_child(body)
		ring_bodies.append(body)
		# M2P1C stop 4: ring shadows come from the batch class (map_build.json "classes"), no longer always on.
		chunks.add("ring", type, meshes[type], WorldSurface.palette_material(String(definition.get("palette", "citadel"))), body.transform, true)
