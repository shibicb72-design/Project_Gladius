extends Node3D
## Synchronous map construction: ready before MatchRoot bakes parsed static colliders. W1c stage B: or frame-sliced
## (`sliced`, MatchRoot's staged open only; see "the build as an ordered list of steps" below), same output.
var cover_bodies: Array[StaticBody3D] = []
var structure_bodies: Array[StaticBody3D] = []  # W1 world kit pieces (group "structure")
var decor_bodies: Array[StaticBody3D] = []  # W2 colliders of the solid rim decor (group "structure")
var ring_bodies: Array[StaticBody3D] = []  # W3 cover of the outer ring (groups "ring_cover" and "cover_wall")
var chest_bodies: Array[StaticBody3D] = []  # M2 L1b loot chests under Nav (group "loot_chest", never cover_wall)
var door_bodies: Array[StaticBody3D] = []  # M2 L1c doors and gates under Props, outside Nav (group "door", never cover_wall)
var ladders: Array[Area3D] = []  # M2 L1c commit 5 ladders under Props, outside Nav (Area3D, layer 0, group "ladder")
var chunks: MapChunks  # M2P1A: the looks of cover, ring cover, structures and decor, batched per chunk (node "Chunks")
## M2P1A: decor id -> its batch type in source "decor" ("<kind>_<n>", n = the index of the entry's size among
## its kind's distinct sizes, first seen first). A decor look is chunks.batch_of("decor", decor_types[id], xform).
var decor_types := {}
## M2W1 item 5: WorldClutter.populate's report ({} = no clutter on this map or the switch is off).
var clutter_report := {}
## M2W1 astraB: the place map (PlaceMap; null when the ground has no detail path).
var place_map: PlaceMap
const PlaceMap := preload("res://scripts/visual/place_map.gd")
## The map json this scene builds. MatchRoot sets it before the map enters the tree; scenes built
## directly keep the default.
@export var map_json: String = "res://data/maps/alesia_section.json"

const COVER_PATH := "res://data/maps/alesia_cover.json"
## W1c step 1: debug-only phase timing (debug web build + ?perf=1; a cached no-op everywhere else, no output change).
const _PerfMarks := preload("res://scripts/debug/perf_marks.gd")

## ---- W1c stage B: the build as an ordered list of steps ----
## _ready runs every step at once (the synchronous contract every test, tool, LAN match and non-web open relies on).
## With `sliced` set before the node enters the tree (MatchRoot's staged open only), _ready builds nothing and the
## owner calls build_step() once per frame until it returns true; each call runs steps until slice_budget_ms of work
## is spent. Both paths run the same step functions in the same order: a long step resumes item by item (the same
## items, the same arithmetic, the same order), so the built map is identical and only where the frame boundaries
## fall depends on the budget. Nothing here awaits or processes on its own: a builder freed mid-build leaves no work.
## While sliced and not build_done() the builder's fields describe a half-built map; nothing may read them then
## (MatchRoot's later stages wait for build_done()).
var sliced := false
## Milliseconds of build work per build_step() when sliced (MatchRoot passes data/warmup.json build_slice_ms,
## OQ-W1C-SLICE); 0 = no limit. Read only on the sliced path; it never changes the result.
var slice_budget_ms := 0
## build_step() calls that ran build work (1 on the synchronous path).
var build_slices := 0
var _steps: Array = []  # [label, Callable] in build order
var _step_at := 0
var _cur := 0  # the running step's next item (resumable steps)
var _fresh := true  # the running step has not been called yet
var _frac := 0.0  # the running step's done share, for build_progress()
var _deadline := -1  # engine usec at which this build_step() stops starting items; -1 = none
var _mark := ""  # extra text for the running step's GLADIUS_T line
var _script_usec := 0  # build work so far (GLADIUS_T map.total on the sliced path)
var _wall_usec := 0  # the first build_step()'s start
# The build's shared values (what _ready's locals were before W1c stage B).
var _nav: Node
var _map_def: Dictionary
var _placed: Dictionary
var _cfg: Dictionary
var _meshes: Dictionary
var _list: Array  # the running resumable step's items
var _types_kit: Dictionary  # WorldKit.config()["types"]
var _tb := {}  # _build_terrain's settings (_terrain_setup)


func _ready() -> void:
	_steps = [
		["data", _step_data],
		["cover_meshes", _step_cover_meshes],
		["terrain_heights", _step_chunks_and_heights],
		["cover_pieces", _step_cover_pieces],
		["breakables", _step_breakables],
		["walls", _step_walls],
		["world_kit", _step_world_kit],
		["ring", _step_ring],
		["decor", _step_decor],
		["chests_doors_ladders", _step_chests_doors_ladders],
		["paint_ground", _step_paint_ground],
		["place_map", _step_place_map],
		["place_map_bodies", _step_place_map_bodies],
		["place_map_tracks", _step_place_map_tracks],
		["place_map_noise", _step_place_map_noise],
		["place_map_stamps", _step_place_map_stamps],
		["clutter", _step_clutter, true],
		["place_contact", _step_place_contact],
		["chunks_build", _step_chunks_build],
		["terrain_build", _step_terrain_build],
		["backdrop", _step_backdrop, true],
		["ambient", _step_ambient],
	]
	_step_at = 0
	_cur = 0
	_fresh = true
	if not sliced:
		build_step()


## True once every step has run (at once after _ready on the synchronous path).
func build_done() -> bool:
	return not _steps.is_empty() and _step_at >= _steps.size()


## 0..1, never back: steps done plus the running step's done share.
func build_progress() -> float:
	if _steps.is_empty():
		return 0.0
	if build_done():
		return 1.0
	return (float(_step_at) + clampf(_frac, 0.0, 0.999)) / float(_steps.size())


## The label of the step that runs next ("" when done).
func build_step_label() -> String:
	return "" if build_done() or _steps.is_empty() else String(_steps[_step_at][0])


## Runs build steps (all of them unless sliced with a budget). True when the build is done.
func build_step() -> bool:
	if _steps.is_empty() or build_done():
		return build_done()
	var started := Time.get_ticks_usec()
	if build_slices == 0:
		_wall_usec = started
	_deadline = started + slice_budget_ms * 1000 if sliced and slice_budget_ms > 0 else -1
	build_slices += 1
	var ran := false
	while _step_at < _steps.size():
		var step: Array = _steps[_step_at]
		if ran and _deadline >= 0 and step.size() > 2 and bool(step[2]):
			break  # a step that cannot be split starts its own slice (the frame is then that step alone)
		ran = true
		var t := _PerfMarks.start()
		_mark = ""
		var finished: bool = (step[1] as Callable).call()
		if t >= 0:
			var extra := _mark
			if sliced:
				extra = ("%s slice=%d%s" % [extra, build_slices, "" if finished else " more=1"]).strip_edges()
			_PerfMarks.done("map." + String(step[0]), t, extra)
		if finished:
			_step_at += 1
			_cur = 0
			_fresh = true
			_frac = 0.0
		if _out_of_time():
			break
	var now := Time.get_ticks_usec()
	_script_usec += now - started
	if build_done() and _PerfMarks.enabled():
		_PerfMarks.emit("map.total", _script_usec / 1000.0, "slices=%d wall_ms=%.1f" % [build_slices, (now - _wall_usec) / 1000.0])
	return build_done()


func _out_of_time() -> bool:
	return _deadline >= 0 and Time.get_ticks_usec() >= _deadline


## A resumable step stops here (not done): records its done share of `total` items.
func _pause_at(total: int) -> bool:
	_frac = float(_cur) / float(maxi(total, 1))
	return false


func _step_data() -> bool:
	_nav = get_parent().get_node("Nav")
	var reg := DataRegistry.new()
	_map_def = reg.load_file(map_json)
	# Cover types and decor colliders always come from the alesia cover file; the pieces, ring pieces and
	# decor come from the map's "cover_data" file (default: the same alesia file).
	var base := reg.load_file(COVER_PATH)
	_placed = reg.load_file(String(_map_def.get("cover_data", COVER_PATH)))
	_cfg = {
		"types": base["types"],
		"decor_colliders": base.get("decor_colliders", {}),
		"pieces": _placed["pieces"],
		"ring_pieces": _placed.get("ring_pieces", []),
		"decor": _placed["decor"],
	}
	_meshes = {}
	return true


func _step_cover_meshes() -> bool:
	if _fresh:
		_fresh = false
		_list = (_cfg["types"] as Dictionary).keys()
	while _cur < _list.size():
		var type: String = _list[_cur]
		var definition: Dictionary = _cfg["types"][type]
		# M2W1 astraA (F4): the kit-parts cover look on the same box when the world-kit looks are on (WorldKit.cover_mesh).
		var look := WorldKit.cover_mesh(type)
		_meshes[type] = look if look != null else LowpolyKit.build_cover(definition)
		_cur += 1
		if _cur < _list.size() and _out_of_time():
			return _pause_at(_list.size())
	return true


func _step_chunks_and_heights() -> bool:
	# M2P1A: cover, ring cover, structure and decor looks draw as one batch per chunk, source and type (MapChunks);
	# the grid comes from the ground size and is set before any piece is added (no ground: one chunk); build()
	# runs once, after the decor loop.
	ground_size_m = ground_size_of(_map_def, _nav)
	chunks = MapChunks.new()
	chunks.name = "Chunks"
	add_child(chunks)
	chunks.setup(ground_size_m)
	# M2P1B: resolved before the pieces so each stands on the ground under its origin (lifted()).
	terrain = MapTerrain.for_map(_map_def)
	return true


func _step_cover_pieces() -> bool:
	var nav := _nav
	var cfg := _cfg
	var meshes := _meshes
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
	_mark = "n=%d" % cover_bodies.size()
	return true


func _step_breakables() -> bool:
	# M2 L1b: breakables (the cover file's "breakables"; a map without the key gets no Props node). In cover_bodies
	# right after the pieces: the order of the paint's trodden points (tools/gen_alesia.gd trodden_of).
	if _placed.has("breakables"):
		_build_breakables(_placed["breakables"])
	return true


func _step_walls() -> bool:
	var nav := _nav
	var meshes := _meshes
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
	return true


## Resumable by piece (WorldKit.populate's loop, one WorldKit.populate_one per piece, in order).
func _step_world_kit() -> bool:
	# W1: world kit pieces come after the loop above, which takes every other Nav child for a one-box wall.
	# They are bodies in group "structure" (never cover_wall); their look is one batch per chunk and type.
	if _fresh:
		_fresh = false
		_list = WorldKit.pieces_for(_map_def)
		_types_kit = WorldKit.config()["types"]
		structure_bodies = [] as Array[StaticBody3D]
	while _cur < _list.size():
		structure_bodies.append(WorldKit.populate_one(_nav, chunks, _types_kit, _list[_cur], terrain))
		_cur += 1
		if _cur < _list.size() and _out_of_time():
			_mark = "n=%d" % structure_bodies.size()
			return _pause_at(_list.size())
	_mark = "n=%d" % structure_bodies.size()
	return true


func _step_ring() -> bool:
	_build_ring(_nav, _cfg, _meshes)
	return true


func _step_decor() -> bool:
	var nav := _nav
	var cfg := _cfg
	var meshes := _meshes
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
	_mark = "n=%d" % decor_types.size()
	return true


func _step_chests_doors_ladders() -> bool:
	# M2 L1b: the loot chests (the cover file's "chests"), after the wall loop above (a chest has no "Mesh" child).
	if _placed.has("chests"):
		_build_chests(_nav, _placed["chests"])
	# M2 L1c: the doors and gates (the cover file's "doors"), last: outside Nav, outside every body list above.
	if _placed.has("doors"):
		_build_doors(_placed["doors"])
	# M2 L1c commit 5: the ladders (the cover file's "ladders"), after the doors: outside Nav, non-blocking triggers.
	if _placed.has("ladders"):
		_build_ladders(_placed["ladders"])
	return true


func _step_paint_ground() -> bool:
	# M2W1 item 5: the paint is made from the bodies' data only, so it comes before chunks.build(): the clutter
	# (looks only, MapChunks source "clutter") reads the paint and every body, door and ladder built above.
	_paint_ground(_nav)
	return true


## The place map's shapes, PlaceMap.build() as begin_build() and its phases, one per step (its pixel work queued:
## PlaceMap.deferred, run by place_map_stamps).
func _step_place_map() -> bool:
	# M2W1 astraB: the place map (looks only; from the built bodies, never saved, never a hashed input) for the ground
	# shader and the clutter; the clutter adds its contact blobs, then the texture goes to the ground material.
	place_map = null
	if ground_material != null and bool(ground_material.get_shader_parameter("detail_enabled")):
		place_map = PlaceMap.begin_build(self, ground_size_m, true)
		place_map.build_phase(0)
		_mark = "queued=%d" % place_map.queued()
	return true


func _step_place_map_bodies() -> bool:
	if place_map != null:
		place_map.build_phase(1)
		_mark = "queued=%d" % place_map.queued()
	return true


func _step_place_map_tracks() -> bool:
	if place_map != null:
		place_map.build_phase(2)
		_mark = "queued=%d" % place_map.queued()
	return true


## The last phase (the noise), then the gate approaches and the compacted soil colour.
func _step_place_map_noise() -> bool:
	if place_map == null:
		return true
	for phase in range(3, PlaceMap.BUILD_PHASES):
		place_map.build_phase(phase)
	place_map.add_gate_approaches(structure_bodies, get_parent())
	var soil: Array = PlaceMap.config(map_json.get_file().get_basename()).get("compacted_soil", [])
	if not soil.is_empty():
		ground_material.set_shader_parameter("compacted_soil", Color(soil[0], soil[1], soil[2], 1.0))
	_mark = "queued=%d" % place_map.queued()
	return true


## Resumable: the place map's queued stamps and noise rows, in queue order (PlaceMap.flush), before the clutter reads it.
func _step_place_map_stamps() -> bool:
	if place_map == null:
		return true
	var done: bool = place_map.flush(_deadline)
	_frac = 1.0 - float(place_map.pending()) / float(maxi(place_map.queued(), 1))
	return done


func _step_clutter() -> bool:
	clutter_report = WorldClutter.populate(self, chunks, _map_def)
	return true


## Resumable: the clutter's contact blobs (queued, then flushed like the place map's stamps), then the texture.
func _step_place_contact() -> bool:
	if place_map == null:
		return true
	if _fresh:
		_fresh = false
		var contact_started := Time.get_ticks_usec()
		place_map.add_contact(clutter_report.get("contact", []))
		place_map.build_ms += int((Time.get_ticks_usec() - contact_started) / 1000)
	if not place_map.flush(_deadline):
		_frac = 1.0 - float(place_map.pending()) / float(maxi(place_map.queued(), 1))
		return false
	var texture_started := Time.get_ticks_usec()
	place_map.deferred = false  # built: later stamps (tests, tools) apply at once again
	ground_material.set_shader_parameter("place_map", place_map.texture())
	ground_material.set_shader_parameter("place_enabled", 1.0)
	place_map.build_ms += int((Time.get_ticks_usec() - texture_started) / 1000)
	return true


func _step_chunks_build() -> bool:
	chunks.build()
	for body in chest_bodies:
		chunks.hide_piece(LootChest.open_id((body as LootChest).prop_id))  # every chest starts closed
	if _PerfMarks.enabled():
		_mark = "batches=%d" % chunks.batches().size()
	return true


## Resumable by terrain cell (_build_terrain's loop, one _terrain_cell per cell, in order).
func _step_terrain_build() -> bool:
	if terrain == null:
		return true
	var cells := chunks.per_side * chunks.per_side
	if _fresh:
		_fresh = false
		var terrain_cfg: Dictionary = _map_def.get("terrain", {})
		_terrain_setup(_nav, bool(terrain_cfg.get("far_keep_centre", false)))
		if _out_of_time() and cells > 0:
			return _pause_at(cells)
	while _cur < cells:
		_terrain_cell(_cur)
		_cur += 1
		if _cur < cells and _out_of_time():
			return _pause_at(cells)
	return true


func _step_backdrop() -> bool:
	# S6: the horizon (outer wall ring, hills, ground skirt): looks only, outside the ground square.
	# M2L1 (binding fix 5): a map json may switch it off ("backdrop": false; default true).
	if backdrop_wanted(_map_def, bool(GraphicsPresets.new().get_preset().get("art_backdrop_enabled", false))):
		var backdrop := Backdrop.new()
		backdrop.name = "Backdrop"
		add_child(backdrop)
		backdrop.build(ground_material, map_json, terrain)  # M2W1 item 9: a map with an art_backdrop.json "maps" block gets its far backdrop
	return true


func _step_ambient() -> bool:
	# Attach below this builder: never add a sibling while the map root is in _ready.
	var ambient := WorldAmbient.new()
	ambient.name = "Ambient"
	add_child(ambient)  # before configure: the tufts ask this builder (their parent) where the grass is
	ambient.configure(DataRegistry.new().load_file("res://data/art_world.json"), bool(GraphicsPresets.new().get_preset().get("art_ambient_enabled", false)))
	# The build's shared values are not needed any more (the fields above keep what readers use).
	_list = []
	_tb = {}
	return true


## M2 L1b: the breakable crates and barrels under ArtBuilder/Props: OUTSIDE Nav, so the navigation bake never
## parses them (bots path as if they were not there; Lanista's binding). Each is a Breakable (the cover contract,
## groups cover_wall and breakable, behaviour from data/props.json) standing on the terrain, appended to
## cover_bodies; its look is a named piece of the chunk batches (source "cover", type = the breakable type), hidden
## when it breaks; breaking takes it out of cover_bodies (_on_breakable_removed). Attached below this builder:
## never a sibling while the map root is in _ready.
func _build_breakables(entries: Array) -> void:
	var props_cfg := WorldProps.config()
	var types: Dictionary = props_cfg.get("breakables", {})
	var root := _props_root()
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
			# M2W1 astraA (F4): parts looks get the cover looks' vertex data (part shades, variation) when the kit is on.
			var kit_look := WorldKit.prop_look(key, look.get("parts", []))
			meshes[key] = kit_look if kit_look != null else LowpolyKit.build_cover(look)
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
			meshes[key] = []
			for look_key: String in ["look_closed", "look_open"]:
				var parts := scaled_parts((chest_cfg.get(look_key, {}) as Dictionary).get("parts", []), k)
				# M2W1 astraA (F4): the cover looks' vertex data (part shades, variation) when the kit is on.
				var kit_look := WorldKit.prop_look("chest_%s%s" % [look_key, key], parts)
				meshes[key].append(kit_look if kit_look != null else LowpolyKit.build_cover({"parts": parts}))
		chunks.add("cover", "loot_chest", meshes[key][0], material, body.transform, true, body.prop_id)
		chunks.add("cover", "loot_chest_open", meshes[key][1], material, body.transform, true, LootChest.open_id(body.prop_id))
		body.chunks = chunks
		nav.add_child(body)
		chest_bodies.append(body)


## M2 L1b/L1c: the ArtBuilder/Props node (made on first use): breakables and doors, outside Nav. Attached below
## this builder: never a sibling while the map root is in _ready.
func _props_root() -> Node3D:
	var root := get_node_or_null("Props") as Node3D
	if root == null:
		root = Node3D.new()
		root.name = "Props"
		add_child(root)
	return root


## M2 L1c: the doors and gates under ArtBuilder/Props: OUTSIDE Nav, so the navigation bake never parses them and
## paths are planned as if every door were open. Each is a Door (group "door" only: never cover_wall, never in
## cover_bodies or any body list the paint or the cover index reads; behaviour from data/props.json "door" and its
## "gate" variant) at the cover file's `at` lifted onto the terrain, in its start state. Its leaves draw as its own
## MeshInstance3D children (they slide, so they are not batch instances).
func _build_doors(entries: Array) -> void:
	var props_cfg := WorldProps.config()
	var root := _props_root()
	for entry: Dictionary in entries:
		var body := Door.make(entry, WorldProps.door_cfg(props_cfg, String(entry.get("kind", Door.KIND_DOOR))))
		body.position = lifted(LowpolyKit.vec(entry["at"]))
		root.add_child(body)
		door_bodies.append(body)


## M2 L1c commit 5: the ladders under ArtBuilder/Props: OUTSIDE Nav (the bake never parses them; no nav link is
## built, bots do not climb). Each is a Ladder (an Area3D on collision layer 0: it blocks no shot, sight or movement;
## group "ladder" only, never cover_wall, in no body list) at the cover file's foot lifted onto the terrain, its look
## its own MeshInstance3D child. Behaviour and looks: data/props.json "ladder" (OQ-PROPS-LADDER).
func _build_ladders(entries: Array) -> void:
	var ladder_cfg: Dictionary = WorldProps.config().get("ladder", {})
	var root := _props_root()
	for entry: Dictionary in entries:
		var ladder := Ladder.make(entry, ladder_cfg)
		ladder.position = lifted(LowpolyKit.vec(entry["at"]))
		root.add_child(ladder)
		ladders.append(ladder)


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
	var t := _PerfMarks.start()
	if ground_paint == null:
		ground_paint = GroundPaint.build(map_json, ground_size_m, landmarks, trodden, settings)
		_PerfMarks.done("map.paint_ground.paint_at_load", t)
	t = _PerfMarks.start()
	ground_material = WorldSurface.ground_material(GroundPaint.texture(map_json), ground_size_m, map_json)
	_PerfMarks.done("map.paint_ground.material", t, "baked=%s" % (baked != ""))
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
func _build_terrain(nav: Node, keep_centre: bool) -> void:
	if terrain == null:
		return
	_terrain_setup(nav, keep_centre)
	for i in chunks.per_side * chunks.per_side:
		_terrain_cell(i)


## _build_terrain's first part: the collider, the near/far settings (in _tb) and the "Terrain" node.
func _terrain_setup(nav: Node, keep_centre: bool) -> void:
	var t := _PerfMarks.start()
	_build_terrain_collider(nav)
	_PerfMarks.done("map.terrain_build.collider", t)
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
	var mid := floori(chunks.per_side * 0.5)
	var root := Node3D.new()
	root.name = "Terrain"
	add_child(root)
	_tb = {"shadow": shadow, "swap_m": swap_m, "step_m": step_m, "margin_m": margin_m, "mid": mid, "root": root, "keep_centre": keep_centre}


## One cell of _build_terrain's grid: i = iz * per_side + ix (the old nested loop's order). Settings from _terrain_setup.
func _terrain_cell(i: int) -> void:
	var ix := i % chunks.per_side
	var iz := i / chunks.per_side
	var shadow: GeometryInstance3D.ShadowCastingSetting = _tb["shadow"]
	var swap_m: float = _tb["swap_m"]
	var step_m: float = _tb["step_m"]
	var margin_m: float = _tb["margin_m"]
	var mid: int = _tb["mid"]
	var root: Node3D = _tb["root"]
	var keep_centre: bool = _tb["keep_centre"]
	var chunk := Node3D.new()
	chunk.name = "Chunk_%d_%d" % [ix, iz]
	root.add_child(chunk)
	var mesh := MeshInstance3D.new()
	mesh.name = "Mesh"
	mesh.mesh = terrain.chunk_mesh(Vector2i(ix, iz), chunks.chunk_size_m, chunks.per_side)
	mesh.material_override = ground_material
	mesh.cast_shadow = shadow
	chunk.add_child(mesh)
	if keep_centre and ix == mid and iz == mid:
		return
	var far_mesh: ArrayMesh = terrain.far_chunk_mesh(Vector2i(ix, iz), chunks.chunk_size_m, chunks.per_side, step_m) if swap_m > 0.0 else null
	if far_mesh == null:
		return
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
