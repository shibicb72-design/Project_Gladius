extends SceneTree
## Ledger of the generated assets (S2 textures, S5 sounds, M2 AN2 Blender characters and weapons):
##   godot --headless --path . --script res://tools/asset_hashes.gd -- --write
## Lists every file under res://assets/generated (not the .import / .uid files Godot writes beside them) with
## its sha256 and size in data/asset_catalog.json "generated". Without --write it only reports differences.
## tests/test_generated_assets.gd checks the same list, so a regenerated file must be re-recorded here.
## made_by is recorded per file: a file listed in tools/blender/manifest.json (written by the Blender scripts under
## tools/blender/, M2 AN2) takes its maker from there; any other file takes the tool of its top folder (TOOLS).
## A manifest row may name derived_from, the data/asset_catalog.json "assets" id of the CC0 source the file was
## made from (e.g. clips retargeted from the Quaternius UAL); its licence then says so instead of "no source".

const ROOT := "res://assets/generated"
const CATALOG := "res://data/asset_catalog.json"
const MANIFEST := "res://tools/blender/manifest.json"
const TOOLS := {"textures": "tools/gen_textures.gd", "audio": "tools/gen_audio.gd"}
const NO_SOURCE := "generated in this project (no source material)"


static func files(path: String) -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(path)
	if dir == null:
		return out
	for name in dir.get_files():
		if not (name.ends_with(".import") or name.ends_with(".uid")):
			out.append(path.path_join(name))
	for name in dir.get_directories():
		out.append_array(files(path.path_join(name)))
	out.sort()
	return out


## The rows of tools/blender/manifest.json: res:// path -> {"made_by": "tools/blender/<script>.py", "derived_from": id}.
static func manifest() -> Dictionary:
	if not FileAccess.file_exists(MANIFEST):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST))
	return (parsed as Dictionary).get("files", {}) if parsed is Dictionary else {}


## The licence text of a file derived from the third-party asset `id` of the catalog's "assets" list.
static func derived_licence(catalog: Dictionary, id: String) -> String:
	for asset: Dictionary in catalog.get("assets", []):
		if String(asset.get("id", "")) == id:
			return "derived in this project from %s (data/asset_catalog.json assets id %s, %s)" % [String(asset.get("source", id)), id, String(asset.get("licence", "?"))]
	return "derived in this project from unknown source id " + id


static func entries(catalog: Dictionary = {}) -> Array:
	if catalog.is_empty():
		catalog = JSON.parse_string(FileAccess.get_file_as_string(CATALOG))
	var made := manifest()
	var out: Array = []
	for path in files(ROOT):
		var folder := path.trim_prefix(ROOT + "/").get_slice("/", 0)
		var row: Dictionary = made.get(path, {})
		var entry := {"path": path, "made_by": String(row.get("made_by", TOOLS.get(folder, "")))}
		var derived := String(row.get("derived_from", ""))
		if derived != "":
			entry["derived_from"] = derived
		entry["licence"] = derived_licence(catalog, derived) if derived != "" else NO_SOURCE
		entry["bytes"] = FileAccess.get_file_as_bytes(path).size()
		entry["sha256"] = FileAccess.get_sha256(path)
		out.append(entry)
	return out


func _initialize() -> void:
	var write := OS.get_cmdline_user_args().has("--write")
	var catalog: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(CATALOG))
	var now := entries(catalog)
	var before := {}
	for entry: Dictionary in catalog.get("generated", []):
		before[entry["path"]] = entry["sha256"]
	var changed := 0
	var total := 0
	for entry: Dictionary in now:
		total += int(entry["bytes"])
		if String(before.get(entry["path"], "")) != String(entry["sha256"]):
			changed += 1
			print("ASSET_HASH %s %s -> %s" % [entry["path"], String(before.get(entry["path"], "(new)")).left(12), String(entry["sha256"]).left(12)])
	print("ASSET_HASH files=%d bytes=%d changed=%d write=%s" % [now.size(), total, changed, write])
	if write:
		catalog["version"] = int(catalog.get("version", 1))  # JSON numbers parse as floats; keep the file's integer
		catalog["generated"] = now
		catalog["_generated_note"] = "S2 / S5 / M2 AN2: files made by the project's own tools: textures and sounds by tools/gen_textures.gd and tools/gen_audio.gd from noise and maths, no source material; characters and weapons (.glb) by the Blender scripts under tools/blender/, each file's maker recorded per file (tools/blender/manifest.json). An entry with derived_from was made from that CC0 asset of the assets list (its licence says so); every other entry has no source material. Re-record with tools/asset_hashes.gd -- --write after regenerating."
		var file := FileAccess.open(CATALOG, FileAccess.WRITE)
		file.store_string(JSON.stringify(catalog, "\t", false) + "\n")
		file.close()
	quit()
