class_name DataRegistry
extends RefCounted
## Typed loader for data/*.json with a cache. No autoload needed.

const _ClassDefScript := preload("res://scripts/classes/class_def.gd")
const _WeaponDefScript := preload("res://scripts/weapons/weapon_def.gd")
const STATS_PATH := "res://data/stats.json"
const LOADOUTS_PATH := "res://data/loadouts.json"
const CAMERA_PATH := "res://data/camera.json"
const MATCH_PATH := "res://data/match.json"
const MAP_PATH := "res://data/maps/alesia_section.json"
const MAP_SELECT_PATH := "res://data/map_select.json"
## Test-only performance map (M2P1A); validated with the shipping maps so its files cannot rot.
const TEST_MAP_PATH := "res://data/maps/test_300.json"
const MAP_DIR := "res://data/maps/"

var _cache: Dictionary = {}


## Returns the parsed dictionary, or {} if missing/invalid (no push_error).
func load_file(path: String) -> Dictionary:
	if _cache.has(path):
		return _cache[path]
	var data: Dictionary = {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f != null:
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		if typeof(parsed) == TYPE_DICTIONARY:
			data = parsed
	_cache[path] = data
	return data


func get_class_def(id: String) -> ClassDef:
	var classes: Dictionary = load_file(STATS_PATH).get("classes", {})
	if not classes.has(id):
		return null
	return ClassDef.from_dict(id, classes[id])


func get_weapon_def(id: String) -> WeaponDef:
	var weapons: Dictionary = load_file(STATS_PATH).get("weapons", {})
	if not weapons.has(id):
		return null
	return WeaponDef.from_dict(id, weapons[id])


func get_combat_cfg() -> Dictionary:
	return load_file(STATS_PATH).get("combat", {})


## DESIGN.md:15 melee rule numbers (stats.json "melee").
func get_melee_cfg() -> Dictionary:
	return load_file(STATS_PATH).get("melee", {})


func get_movement_cfg() -> Dictionary:
	return load_file(STATS_PATH).get("movement", {})


func get_aim_assist_cfg() -> Dictionary:
	return load_file(STATS_PATH).get("aim_assist", {})


## Aim-down-sights numbers (stats.json "aim"): aim_fov_mult, aim_zoom_s, aim_spread_mult.
func get_aim_cfg() -> Dictionary:
	return load_file(STATS_PATH).get("aim", {})


## Slot ids ("primary", "secondary", "sidearm") for a class, or {} if unknown.
func get_loadout_ids(class_id: String) -> Dictionary:
	return load_file(LOADOUTS_PATH).get("classes", {}).get(class_id, {})


func get_camera_cfg() -> Dictionary:
	return load_file(CAMERA_PATH)


## Returns a list of problems; empty means clean.
func validate() -> PackedStringArray:
	var problems := PackedStringArray()
	var data := load_file(STATS_PATH)
	if data.is_empty():
		problems.append("stats.json missing or invalid")
		return problems
	var classes: Dictionary = data.get("classes", {})
	for id in classes:
		var c := ClassDef.from_dict(id, classes[id])
		if c.shield <= 0.0 or c.health <= 0.0 or c.speed_pct <= 0.0:
			problems.append("class %s has non-positive stat" % id)
	var weapons: Dictionary = data.get("weapons", {})
	for id in weapons:
		var w := WeaponDef.from_dict(id, weapons[id])
		if w.damage <= 0.0 or w.fire_interval_s <= 0.0 or w.burst_count <= 0:
			problems.append("weapon %s has invalid stat" % id)
		if w.is_melee():
			if w.melee_range_m <= 0.0 or w.melee_arc_deg <= 0.0 or w.melee_arc_deg > 360.0:
				problems.append("melee weapon %s needs melee_range_m > 0 and 0 < melee_arc_deg <= 360" % id)
		elif w.magazine <= 0:
			problems.append("weapon %s has invalid stat" % id)
		if w.headshot_multiplier < 1.0:
			problems.append("weapon %s headshot_multiplier < 1" % id)
	problems.append_array(validate_melee(data.get("melee", {})))
	var combat: Dictionary = data.get("combat", {})
	for k in ["shield_regen_delay_s", "shield_regen_rate_per_s", "overflow_to_health"]:
		if not combat.has(k):
			problems.append("combat.%s missing" % k)
	problems.append_array(validate_squads(load_file(MATCH_PATH), load_file(MAP_PATH)))
	problems.append_array(validate_map(MAP_PATH))
	problems.append_array(validate_map(TEST_MAP_PATH))
	var selected := str(load_file(MAP_SELECT_PATH).get("map", MAP_PATH))
	if selected != MAP_PATH and selected != TEST_MAP_PATH:
		problems.append_array(validate_map(selected))
	return problems


## Problems of one map definition; empty means usable. The path must be res://data/maps/<file>.json.
## Never calls push_error (MatchRoot reports a bad selection once).
func validate_map(path: String) -> PackedStringArray:
	var problems := PackedStringArray()
	var file := path.trim_prefix(MAP_DIR)
	if not path.begins_with(MAP_DIR) or not path.ends_with(".json") or file.contains("/") or file.contains(".."):
		problems.append("map path '%s' is not res://data/maps/<file>.json" % path)
		return problems
	if not FileAccess.file_exists(path):
		problems.append("map file '%s' does not exist" % path)
		return problems
	var def := parse_quiet(path)
	if def.is_empty():
		problems.append("map file '%s' is not a non-empty json dictionary" % path)
		return problems
	problems.append_array(validate_map_def(def))
	return problems


## The dictionary in a json file, or {} when missing or invalid. Unlike JSON.parse_string it reports nothing.
static func parse_quiet(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK or typeof(json.data) != TYPE_DICTIONARY:
		return {}
	return json.data


## The content rules of a map definition (scene, spawns, optional piece files); validate_map adds the path rules.
static func validate_map_def(def: Dictionary) -> PackedStringArray:
	var problems := PackedStringArray()
	var scene: Variant = def.get("scene", "")
	if typeof(scene) != TYPE_STRING or String(scene) == "":
		problems.append("map has no scene")
	elif not ResourceLoader.exists(String(scene)):
		problems.append("map scene '%s' does not exist" % scene)
	var spawns: Variant = def.get("spawns", {})
	if typeof(spawns) != TYPE_DICTIONARY or (spawns as Dictionary).is_empty():
		problems.append("map has no spawn spots")
	# The map builder sizes the chunk grid and the ground paint from it (astra_map.gd ground_size_of).
	if def.has("ground_size_m"):
		var size: Variant = def["ground_size_m"]
		if (typeof(size) != TYPE_FLOAT and typeof(size) != TYPE_INT) or float(size) <= 0.0:
			problems.append("map ground_size_m must be a number greater than 0 (got %s)" % str(size))
	if def.has("terrain"):
		problems.append_array(validate_terrain(def["terrain"], def))
	for key in ["cover_data", "structure_data"]:
		if not def.has(key):
			continue
		var piece_path := str(def[key])
		var pieces := parse_quiet(piece_path)
		if pieces.is_empty():
			problems.append("map %s '%s' is missing or not a non-empty json dictionary" % [key, piece_path])
			continue
		# The map builder indexes these lists (astra_map.gd: cover "pieces" and "decor"; WorldKit: "pieces").
		var lists: Array = ["pieces", "decor"] if key == "cover_data" else ["pieces"]
		for list: String in lists:
			if typeof(pieces.get(list)) != TYPE_ARRAY:
				problems.append("map %s '%s' has no '%s' array" % [key, piece_path, list])
	problems.append_array(overrides_problems(def))
	if problems.is_empty():
		problems.append_array(yaw_problems(def))
		problems.append_array(reserved_spot_problems(def))
	return problems


## M2L1 (binding fixes 3, 22): the blocks a map's "overrides" may hold (merged over data/br.json and data/loot.json
## by MatchDirector.load_config). Keys starting with "_" are notes.
const OVERRIDE_BLOCKS := ["br", "loot"]
## br.json keys the lobby reads before any map is chosen (scripts/ui/lobby.gd: MatchDirector.team_layout and
## team_mode_of read "teams"): squad layouts stay global, so no map may override them.
const LOBBY_BR_KEYS := ["teams"]


## M2L1: problems of a map's "overrides" block (none when it has no block). Quiet.
static func overrides_problems(def: Dictionary) -> PackedStringArray:
	var problems := PackedStringArray()
	if not def.has("overrides"):
		return problems
	var block: Variant = def["overrides"]
	if typeof(block) != TYPE_DICTIONARY:
		problems.append("map overrides must be a dictionary")
		return problems
	for key: Variant in block:
		var name := str(key)
		if name.begins_with("_"):
			continue
		if not name in OVERRIDE_BLOCKS:
			problems.append("map overrides '%s' is not one of %s" % [name, ", ".join(OVERRIDE_BLOCKS)])
		elif typeof(block[key]) != TYPE_DICTIONARY:
			problems.append("map overrides '%s' must be a dictionary" % name)
		elif name == "br":
			for lobby_key: String in LOBBY_BR_KEYS:
				if (block[key] as Dictionary).has(lobby_key):
					problems.append("map overrides br must not set '%s': the lobby reads it from data/br.json before a map is chosen" % lobby_key)
	return problems


## M2L1 (binding fix 8): the structure types that may take any yaw on a map ("free_yaw_types"); only wall pieces.
const FREE_YAW_ALLOWED := ["wall_walk", "wall_stair", "gate", "watchtower"]
## M2L1 (binding fix 14): the kinds of the reserved J1 spots.
const RESERVED_KINDS := ["jump_pad", "man_cannon", "lily_trap"]


## M2L1: every structure piece's yaw is a multiple of alesia_structures.json rules.yaw_step_deg, except the
## types the map lists in "free_yaw_types" (only wall types may be listed). Quiet.
static func yaw_problems(def: Dictionary) -> PackedStringArray:
	var problems := PackedStringArray()
	var free: Variant = def.get("free_yaw_types", [])
	if typeof(free) != TYPE_ARRAY:
		problems.append("map free_yaw_types must be an array of wall types")
		return problems
	for type: Variant in free:
		if not FREE_YAW_ALLOWED.has(str(type)):
			problems.append("map free_yaw_types lists '%s'; only %s may take a free yaw" % [str(type), ", ".join(FREE_YAW_ALLOWED)])
	var step := float(WorldKit.config()["rules"]["yaw_step_deg"])
	for entry: Dictionary in WorldKit.pieces_for(def):
		var yaw := float(entry.get("yaw", 0.0))
		var off := fposmod(yaw, step)
		if minf(off, step - off) > 0.0001 and not (free as Array).has(str(entry.get("type", ""))):
			problems.append("structure %s (%s) has yaw %s, not a multiple of %s" % [str(entry.get("id", "?")), str(entry.get("type", "")), str(yaw), str(step)])
	return problems


## M2L1: the ground footprints of a map's colliders from its data (no scene): [{id, at: Vector2, yaw (rad),
## rect: Rect2 in piece space}], one per box of cover and ring pieces (alesia_cover.json types, no yaw), per
## structure collider (alesia_structures.json, its XZ bounds in piece space, then the piece's yaw) and per
## solid decor entry (its size and yaw).
static func collider_footprints(def: Dictionary) -> Array:
	var out: Array = []
	var base := parse_quiet("res://data/maps/alesia_cover.json")
	var types: Dictionary = base.get("types", {})
	var solid: Dictionary = base.get("decor_colliders", {})
	var placed := parse_quiet(str(def.get("cover_data", "res://data/maps/alesia_cover.json")))
	for list: String in ["pieces", "ring_pieces"]:
		for entry: Dictionary in placed.get(list, []):
			var size: Array = types.get(entry["type"], {}).get("size", [0, 0, 0])
			out.append({"id": str(entry["id"]), "at": Vector2(float(entry["at"][0]), float(entry["at"][2])), "yaw": 0.0,
				"rect": Rect2(-float(size[0]) * 0.5, -float(size[2]) * 0.5, float(size[0]), float(size[2]))})
	for entry: Dictionary in placed.get("decor", []):
		if solid.has(entry["kind"]):
			var size: Array = entry["size"]
			out.append({"id": str(entry["id"]), "at": Vector2(float(entry["at"][0]), float(entry["at"][2])), "yaw": deg_to_rad(float(entry.get("yaw", 0.0))),
				"rect": Rect2(-float(size[0]) * 0.5, -float(size[2]) * 0.5, float(size[0]), float(size[2]))})
	var kit: Dictionary = WorldKit.config()["types"]
	for entry: Dictionary in WorldKit.pieces_for(def):
		for collider: Dictionary in kit.get(entry["type"], {}).get("colliders", []):
			var rect := Rect2()
			var first := true
			for c in WorldKit.collider_corners(collider):
				rect = Rect2(Vector2(c.x, c.z), Vector2.ZERO) if first else rect.expand(Vector2(c.x, c.z))
				first = false
			out.append({"id": str(entry["id"]), "at": Vector2(float(entry["at"][0]), float(entry["at"][2])), "yaw": deg_to_rad(float(entry.get("yaw", 0.0))), "rect": rect})
	return out


## M2L1: the id of the first footprint (collider_footprints) that holds the ground point `p` (edges included), or "".
static func footprint_at(p: Vector2, footprints: Array) -> String:
	for fp: Dictionary in footprints:
		var d: Vector2 = p - (fp["at"] as Vector2)
		# Godot's yaw turns piece (x, z) to (x cos + z sin, -x sin + z cos); the inverse turn takes the offset back.
		var yaw: float = fp["yaw"]
		var local := Vector2(d.x * cos(yaw) - d.y * sin(yaw), d.x * sin(yaw) + d.y * cos(yaw))
		var rect: Rect2 = fp["rect"]
		if local.x >= rect.position.x and local.x <= rect.end.x and local.y >= rect.position.y and local.y <= rect.end.y:
			return str(fp["id"])
	return ""


## M2L1 (binding fix 14): the map's "reserved_spots" ([{id, kind, at: [x, z]}], places for J1's jump pads, man
## cannons and lily traps; no nodes are built): unique ids, a known kind, inside the play circle
## ("play_radius_m") and not inside any collider's ground footprint (collider_footprints, from the data). Quiet.
static func reserved_spot_problems(def: Dictionary) -> PackedStringArray:
	var problems := PackedStringArray()
	var spots: Variant = def.get("reserved_spots", [])
	if typeof(spots) != TYPE_ARRAY:
		problems.append("map reserved_spots must be an array")
		return problems
	if (spots as Array).is_empty():
		return problems
	var radius: Variant = def.get("play_radius_m")
	if not _is_num(radius) or float(radius) <= 0.0:
		problems.append("map reserved_spots need a play_radius_m greater than 0")
		return problems
	var footprints := collider_footprints(def)
	var ids := {}
	for spot: Variant in spots:
		if typeof(spot) != TYPE_DICTIONARY:
			problems.append("reserved spot must be a dictionary")
			continue
		var id := str(spot.get("id", ""))
		if id == "" or ids.has(id):
			problems.append("reserved spot id '%s' is empty or not unique" % id)
		ids[id] = true
		if not RESERVED_KINDS.has(str(spot.get("kind", ""))):
			problems.append("reserved spot %s has kind '%s' (known: %s)" % [id, str(spot.get("kind", "")), ", ".join(RESERVED_KINDS)])
		var at: Variant = spot.get("at")
		if typeof(at) != TYPE_ARRAY or (at as Array).size() != 2 or not _is_num(at[0]) or not _is_num(at[1]):
			problems.append("reserved spot %s at must be [x, z] numbers" % id)
			continue
		var p := Vector2(float(at[0]), float(at[1]))
		if p.length() > float(radius):
			problems.append("reserved spot %s at %s lies outside the play circle (%s m)" % [id, str(at), str(radius)])
		var inside := footprint_at(p, footprints)
		if inside != "":
			problems.append("reserved spot %s at %s lies inside the collider of %s" % [id, str(at), inside])
	return problems


static func _is_num(value: Variant) -> bool:
	return typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT


## M2P1B: the rules of a map's "terrain" block (MapTerrain reads it; for_map returns null on any problem).
## `def` is the whole map definition, for the ground_size_m cross-check. M2P1C: `read_heights` also reads a
## heights file and checks its grid against the block (MapTerrain.heights_file_problem; M2L1: a binary .res by
## its header only, MapTerrain.heights_header_problem); MapTerrain.from_block passes false because it reads the
## file itself.
static func validate_terrain(terrain: Variant, def: Dictionary = {}, read_heights := true) -> PackedStringArray:
	var problems := PackedStringArray()
	if typeof(terrain) != TYPE_DICTIONARY:
		problems.append("map terrain must be a dictionary")
		return problems
	var size: Variant = terrain.get("size_m")
	var res: Variant = terrain.get("resolution_m")
	if not _is_num(size) or float(size) <= 0.0 or not _is_num(res) or float(res) <= 0.0:
		problems.append("terrain size_m and resolution_m must be numbers greater than 0")
	else:
		var cells := float(size) / float(res)
		if absf(cells - roundf(cells)) > 1e-6 or roundi(cells) < 2:
			problems.append("terrain size_m %s must be a whole multiple (at least 2) of resolution_m %s" % [str(size), str(res)])
		if def.has("ground_size_m") and (not _is_num(def["ground_size_m"]) or not is_equal_approx(float(def["ground_size_m"]), float(size))):
			problems.append("map ground_size_m %s differs from terrain size_m %s" % [str(def["ground_size_m"]), str(size)])
	if terrain.has("max_piece_slope_deg"):
		var slope: Variant = terrain["max_piece_slope_deg"]
		if not _is_num(slope) or float(slope) <= 0.0 or float(slope) >= 90.0:
			problems.append("terrain max_piece_slope_deg must be a number in (0, 90)")
	if terrain.has("max_piece_float_m"):
		var float_m: Variant = terrain["max_piece_float_m"]
		if not _is_num(float_m) or float(float_m) <= 0.0:
			problems.append("terrain max_piece_float_m must be a number greater than 0")
	if terrain.has("far_step_m"):
		var step: Variant = terrain["far_step_m"]
		if not _is_num(step) or float(step) <= 0.0:
			problems.append("terrain far_step_m must be a number greater than 0")
		elif _is_num(res) and float(res) > 0.0:
			var problem := MapTerrain.far_step_problem(float(step), float(res), float(MapChunks.config()["chunk_size_m"]))
			if problem != "":
				problems.append("terrain " + problem)
	var source: Variant = terrain.get("height_source")
	if typeof(source) != TYPE_DICTIONARY:
		problems.append("terrain height_source must be a dictionary")
		return problems
	match str(source.get("type", "")):
		"file":
			var path: Variant = source.get("path")
			if typeof(path) != TYPE_STRING or not (String(path).ends_with(".json") or String(path).ends_with(".res")):
				problems.append("terrain heights file path must be a .json or .res string")
			elif not FileAccess.file_exists(path) and not ResourceLoader.exists(path):
				problems.append("terrain heights file '%s' does not exist" % path)
			elif read_heights and _is_num(size) and _is_num(res) and float(size) > 0.0 and float(res) > 0.0:
				# M2L1 (binding fix 13): a binary .res is checked from its header only (MapTerrain.heights_header_problem),
				# so its samples are read once per load, by MapTerrain.from_block; a JSON file is read whole as before.
				var grid := MapTerrain.heights_header_problem(String(path), float(size), float(res))
				if grid != "":
					problems.append(grid)
		"generated":
			if not _is_num(source.get("seed")):
				problems.append("terrain generated source needs a numeric seed")
			var noise: Variant = source.get("noise", {})
			if typeof(noise) != TYPE_DICTIONARY or not _is_num(noise.get("amplitude_m", 0)) or float(noise.get("amplitude_m", 0)) < 0.0 \
					or not _is_num(noise.get("wavelength_m", 1)) or float(noise.get("wavelength_m", 1)) <= 0.0:
				problems.append("terrain noise needs amplitude_m >= 0 and wavelength_m > 0")
			var flat: Variant = source.get("flat_centre", {})
			if typeof(flat) != TYPE_DICTIONARY:
				problems.append("terrain flat_centre must be a dictionary")
			else:
				for value: Variant in [flat.get("radius_m", 0), flat.get("blend_m", 0), source.get("edge_blend_m", 0)]:
					if not _is_num(value) or float(value) < 0.0:
						problems.append("terrain flat_centre radius_m, blend_m and edge_blend_m must be numbers >= 0")
						break
			var hills: Variant = source.get("hills", [])
			if typeof(hills) != TYPE_ARRAY:
				problems.append("terrain hills must be an array")
				hills = []
			for hill: Variant in hills:
				problems.append_array(_hill_problems(hill))
		var other:
			problems.append("terrain height_source type '%s' is not 'generated' or 'file'" % str(other))
	return problems


static func _hill_problems(hill: Variant) -> PackedStringArray:
	var problems := PackedStringArray()
	if typeof(hill) != TYPE_DICTIONARY:
		problems.append("terrain hill must be a dictionary")
		return problems
	var id := str(hill.get("id", "?"))
	var centre: Variant = hill.get("centre")
	if typeof(centre) != TYPE_ARRAY or (centre as Array).size() != 2 or not _is_num(centre[0]) or not _is_num(centre[1]):
		problems.append("terrain hill %s centre must be [x, z] numbers" % id)
	if not _is_num(hill.get("height_m")):
		problems.append("terrain hill %s height_m must be a number" % id)
	if not _is_num(hill.get("radius_m")) or float(hill["radius_m"]) <= 0.0:
		problems.append("terrain hill %s radius_m must be a number greater than 0" % id)
	if hill.has("outer_radius_m") and (not _is_num(hill["outer_radius_m"]) or float(hill["outer_radius_m"]) <= 0.0):
		problems.append("terrain hill %s outer_radius_m must be a number greater than 0" % id)
	if not MapTerrain.FALLOFFS.has(str(hill.get("falloff", "smoothstep"))):
		problems.append("terrain hill %s falloff '%s' is unknown (known: %s)" % [id, str(hill.get("falloff")), ", ".join(MapTerrain.FALLOFFS)])
	return problems


## Checks stats.json "melee" (a missing key is reported, never defaulted).
static func validate_melee(melee: Dictionary) -> PackedStringArray:
	var problems := PackedStringArray()
	if not melee.has("melee_front_shield_fraction"):
		problems.append("melee.melee_front_shield_fraction missing")
	else:
		var frac: float = float(melee["melee_front_shield_fraction"])
		if frac <= 0.0 or frac > 1.0:
			problems.append("melee.melee_front_shield_fraction must be in (0, 1]")
	if not melee.has("melee_back_angle_deg"):
		problems.append("melee.melee_back_angle_deg missing")
	else:
		var back: float = float(melee["melee_back_angle_deg"])
		if back <= 0.0 or back >= 180.0:
			problems.append("melee.melee_back_angle_deg must be in (0, 180)")
	if not melee.has("front_breaks_full_shield_classes"):
		problems.append("melee.front_breaks_full_shield_classes missing")
	return problems


## Checks the player caps in match.json and that the map has a spawn spot. Battle royale needs no
## one-spot-per-squad rule: squads share spots round-robin until the drop (S3).
static func validate_squads(match_cfg: Dictionary, map_def: Dictionary) -> PackedStringArray:
	var problems := PackedStringArray()
	var max_players := int(match_cfg.get("max_players", 0))
	var max_humans := int(match_cfg.get("max_humans", 0))
	var min_humans := int(match_cfg.get("min_humans", 0))
	if max_players <= 0:
		problems.append("match.json max_players must be positive")
	if min_humans < 1 or min_humans > max_humans or max_humans > max_players:
		problems.append("match.json needs 1 <= min_humans <= max_humans <= max_players")
	if map_def.get("spawns", {}).is_empty():
		problems.append("map has no spawn spots")
	return problems
