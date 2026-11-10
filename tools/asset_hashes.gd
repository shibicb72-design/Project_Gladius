extends SceneTree
## Ledger of the generated assets (S2 textures, S5 sounds):
##   godot --headless --path . --script res://tools/asset_hashes.gd -- --write
## Lists every file under res://assets/generated (not the .import / .uid files Godot writes beside them) with
## its sha256 and size in data/asset_catalog.json "generated". Without --write it only reports differences.
## tests/test_generated_assets.gd checks the same list, so a regenerated file must be re-recorded here.

const ROOT := "res://assets/generated"
const CATALOG := "res://data/asset_catalog.json"
const TOOLS := {"textures": "tools/gen_textures.gd", "audio": "tools/gen_audio.gd"}


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


static func entries() -> Array:
	var out: Array = []
	for path in files(ROOT):
		var folder := path.trim_prefix(ROOT + "/").get_slice("/", 0)
		out.append({
			"path": path,
			"made_by": String(TOOLS.get(folder, "")),
			"licence": "generated in this project (no source material)",
			"bytes": FileAccess.get_file_as_bytes(path).size(),
			"sha256": FileAccess.get_sha256(path),
		})
	return out


func _initialize() -> void:
	var write := OS.get_cmdline_user_args().has("--write")
	var catalog: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(CATALOG))
	var now := entries()
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
		catalog["_generated_note"] = "S2 / S5: files made by the project's own tools (tools/gen_textures.gd, tools/gen_audio.gd) from noise and maths, no source material. Re-record with tools/asset_hashes.gd -- --write after regenerating."
		var file := FileAccess.open(CATALOG, FileAccess.WRITE)
		file.store_string(JSON.stringify(catalog, "\t", false) + "\n")
		file.close()
	quit()
