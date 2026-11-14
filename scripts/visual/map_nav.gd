class_name MapNav
extends RefCounted
## M2P1B: a map's saved navigation mesh (data/maps/nav/<map>.res, baked by tools/bake_nav.gd) and its manifest
## (<map>.json: the sha256 of every file that shapes the baked colliders). MatchRoot.begin loads the saved mesh
## when the manifest still matches the data, so a phone does not bake seconds of navmesh at match start; a stale
## or missing mesh falls back to the runtime bake. Hashes cover data only: the scene and builder code are checked
## by tests/test_saved_nav.gd re-baking and comparing counts on the baking machine.

const DIR := "res://data/maps/nav/"
## Bump when the manifest layout changes: older manifests then read as stale.
const VERSION := 1
const _Builder := preload("res://scripts/visual/astra_map.gd")
## LowpolyKit.config()'s file: the arch proportions of the solid decor colliders and the decor meshes the hull
## colliders are built from.
const LOWPOLY_PATH := "res://data/art_astra.json"

## Why the last load_fresh returned null (empty after a load). MatchRoot prints the first one.
static var last_reasons := PackedStringArray()


static func saved_path(map_path: String) -> String:
	return DIR + map_path.get_file().get_basename() + ".res"


static func manifest_path(map_path: String) -> String:
	return DIR + map_path.get_file().get_basename() + ".json"


## The files whose content can change the baked colliders, sorted, without repeats:
## {"runtime": JSON files (exported verbatim, so a phone can hash them), "tool": files an exported game cannot
## hash (the map scene, which export converts; a binary heights file)}.
static func input_files(map_path: String) -> Dictionary:
	var runtime := {map_path: true, _Builder.COVER_PATH: true, WorldKit.PATH: true, LOWPOLY_PATH: true}
	var tool := {}
	var def := DataRegistry.parse_quiet(map_path)
	runtime[String(def.get("cover_data", _Builder.COVER_PATH))] = true
	runtime[String(def.get("structure_data", WorldKit.PATH))] = true
	if def.has("scene"):
		tool[String(def["scene"])] = true
	var terrain: Variant = def.get("terrain")
	if typeof(terrain) == TYPE_DICTIONARY:
		var source: Variant = (terrain as Dictionary).get("height_source")
		if typeof(source) == TYPE_DICTIONARY and str(source.get("type", "")) == "file":
			var heights := str(source.get("path", ""))
			if heights.get_extension().to_lower() == "json":
				runtime[heights] = true
			else:
				tool[heights] = true
	var runtime_list: Array = runtime.keys()
	var tool_list: Array = tool.keys()
	runtime_list.sort()
	tool_list.sort()
	return {"runtime": PackedStringArray(runtime_list), "tool": PackedStringArray(tool_list)}


## sha256 of a file, "" when it is missing. Text (json, tscn, tres) is hashed with every "\r" removed, so a
## CRLF checkout, an LF checkout and the exported copy agree; anything else is hashed as bytes.
static func file_hash(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	if path.get_extension().to_lower() in ["json", "tscn", "tres", "txt", "cfg"]:
		return text_hash(FileAccess.get_file_as_string(path))
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(FileAccess.get_file_as_bytes(path))
	return ctx.finish().hex_encode()


static func text_hash(text: String) -> String:
	return text.replace("\r", "").sha256_text()


## {path: sha256} of the given files ("" for a missing one).
static func hashes(paths: PackedStringArray) -> Dictionary:
	var out := {}
	for path in paths:
		out[path] = file_hash(path)
	return out


## The manifest tools/bake_nav.gd writes next to a freshly saved mesh. No timestamps: re-baking unchanged data
## must reproduce the same bytes.
static func manifest_for(map_path: String, mesh: NavigationMesh, mesh_path: String) -> Dictionary:
	var files := input_files(map_path)
	var version: Dictionary = Engine.get_version_info()
	return {
		"version": VERSION,
		"map": map_path,
		"inputs": hashes(files["runtime"]),
		"tool_inputs": hashes(files["tool"]),
		"polygons": mesh.get_polygon_count(),
		"vertices": mesh.get_vertices().size(),
		"mesh_bytes": FileAccess.get_file_as_bytes(mesh_path).size(),
		"mesh_sha256": file_hash(mesh_path),
		"godot": "%d.%d.%d" % [int(version["major"]), int(version["minor"]), int(version["patch"])],
	}


## Why the saved mesh of a map cannot be used (empty = fresh). The runtime check compares the runtime inputs
## only; include_tool_inputs (the bake tool, the CI test) also compares the tool inputs and the mesh's own hash.
static func stale_reasons(map_path: String, include_tool_inputs := false) -> PackedStringArray:
	return stale_reasons_at(map_path, saved_path(map_path), manifest_path(map_path), include_tool_inputs)


## stale_reasons with the two nav file paths given (a test seam: tests point them at user:// files).
static func stale_reasons_at(map_path: String, mesh_path: String, manifest_file: String, include_tool_inputs := false) -> PackedStringArray:
	var reasons := PackedStringArray()
	if not FileAccess.file_exists(mesh_path):
		reasons.append("saved mesh %s is missing" % mesh_path)
	var manifest := DataRegistry.parse_quiet(manifest_file)
	if manifest.is_empty():
		reasons.append("manifest %s is missing or not a json dictionary" % manifest_file)
		return reasons
	var files := input_files(map_path)
	var current := {"runtime": hashes(files["runtime"]), "tool": hashes(files["tool"]) if include_tool_inputs else {}}
	if include_tool_inputs and reasons.is_empty():
		current["mesh"] = file_hash(mesh_path)
	reasons.append_array(manifest_reasons(manifest, map_path, current))
	return reasons


## The comparison itself, on a parsed manifest and the current hashes {"runtime": {path: sha}, "tool": {path: sha}
## or absent/empty to skip, "mesh": sha or absent to skip}.
static func manifest_reasons(manifest: Dictionary, map_path: String, current: Dictionary) -> PackedStringArray:
	var reasons := PackedStringArray()
	if int(manifest.get("version", -1)) != VERSION:
		reasons.append("manifest version %s is not %d" % [str(manifest.get("version", "none")), VERSION])
		return reasons
	if str(manifest.get("map", "")) != map_path:
		reasons.append("manifest is for map '%s', not '%s'" % [str(manifest.get("map", "")), map_path])
	if typeof(manifest.get("inputs")) != TYPE_DICTIONARY:
		reasons.append("manifest has no inputs dictionary")
		return reasons
	reasons.append_array(_compare("input", manifest["inputs"], current.get("runtime", {})))
	var tool: Dictionary = current.get("tool", {})
	if not tool.is_empty():
		var saved: Variant = manifest.get("tool_inputs")
		reasons.append_array(_compare("tool input", saved if typeof(saved) == TYPE_DICTIONARY else {}, tool))
	if current.has("mesh") and str(manifest.get("mesh_sha256", "")) != str(current["mesh"]):
		reasons.append("saved mesh changed since the manifest was written")
	return reasons


static func _compare(what: String, saved: Dictionary, now: Dictionary) -> PackedStringArray:
	var reasons := PackedStringArray()
	for path: String in now:
		if String(now[path]) == "":
			reasons.append("%s %s is missing" % [what, path])
		elif not saved.has(path):
			reasons.append("%s %s is not in the manifest" % [what, path])
		elif str(saved[path]) != String(now[path]):
			reasons.append("%s %s changed since the bake" % [what, path])
	for path: String in saved:
		if not now.has(path):
			reasons.append("manifest %s %s is no longer an input" % [what, path])
	return reasons


## The saved mesh of a map when it is fresh (runtime inputs), else null (last_reasons says why). Loaded past the
## resource cache: bake_navigation_mesh changes an assigned mesh in place, so every match gets its own instance.
static func load_fresh(map_path: String) -> NavigationMesh:
	last_reasons = stale_reasons(map_path)
	if not last_reasons.is_empty():
		return null
	var mesh := load_saved(map_path)
	if mesh == null:
		last_reasons = PackedStringArray(["saved mesh %s did not load as a NavigationMesh" % saved_path(map_path)])
	return mesh


## The saved mesh without the freshness check, a new instance on every call (null when missing).
static func load_saved(map_path: String) -> NavigationMesh:
	var path := saved_path(map_path)
	if not FileAccess.file_exists(path):
		return null
	return ResourceLoader.load(path, "NavigationMesh", ResourceLoader.CACHE_MODE_IGNORE) as NavigationMesh
