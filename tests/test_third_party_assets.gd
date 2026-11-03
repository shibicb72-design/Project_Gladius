extends "res://tests/test_case.gd"
## Provenance format and raw-file guards; licence quotes still require human audit.

func _files(path: String) -> Array[String]:
	var result: Array[String] = []
	var directory := DirAccess.open(path)
	if directory == null:
		return result
	directory.include_hidden = true
	for name in directory.get_files():
		if not name.begins_with("."):
			result.append(path.path_join(name))
	for name in directory.get_directories():
		if not name.begins_with("."):
			result.append_array(_files(path.path_join(name)))
	return result

func _entries() -> Array:
	return DataRegistry.new().load_file("res://data/asset_catalog.json").get("assets", [])

func test_catalogue_files_licences_hashes_and_ledger() -> void:
	var ledger_path := "res://LICENSES/THIRD_PARTY_ASSETS.md"
	assert_true(FileAccess.file_exists(ledger_path), "asset ledger exists")
	var ledger := FileAccess.get_file_as_string(ledger_path)
	var ids: Array[String] = []
	for entry: Dictionary in _entries():
		for key in ["id", "path", "source", "source_url", "licence", "licence_url", "redistribution_quote", "download_date", "sha256"]:
			assert_true(entry.has(key) and entry[key] is String, "catalogue String field " + key)
		var path: String = entry.get("path", "")
		assert_true(path.begins_with("res://assets/third_party/"), "committed third-party path")
		assert_true(FileAccess.file_exists(path), "catalogue entry exists: " + path)
		assert_eq(FileAccess.get_sha256(path), entry.get("sha256", ""), "committed file hash")
		var licence: String = entry.get("licence", "")
		var url: Variant = entry.get("licence_url", "")
		var quote: Variant = entry.get("redistribution_quote", "")
		assert_true(licence == "CC0-1.0" or (not licence.strip_edges().is_empty() and url is String and not url.strip_edges().is_empty() and quote is String and not quote.strip_edges().is_empty()), "CC0 or explicit redistribution fields")
		assert_true(ledger.contains(String(entry.get("source", ""))), "ledger names pack")
		assert_true(not ids.has(String(entry.get("id", ""))), "unique catalogue id")
		ids.append(String(entry.get("id", "")))

func test_every_third_party_file_is_catalogued_or_documented_dependency() -> void:
	var listed: Array[String] = []
	for entry: Dictionary in _entries():
		listed.append(entry["path"])
		for dependency in entry.get("dependencies", []):
			assert_true(String(entry["path"]).get_extension().to_lower() in ["glb", "gltf", "fbx"], "dependency belongs to a catalogued model")
			assert_true(dependency is String and String(dependency).get_extension().to_lower() in ["bin", "png", "jpg", "jpeg"], "only model buffers/textures may be dependencies")
			assert_true(FileAccess.file_exists(dependency), "model dependency exists")
			listed.append(dependency)
	for path in _files("res://assets/third_party"):
		var name := path.get_file().to_lower()
		if name.ends_with(".import") or name.ends_with(".uid") or ((name.contains("license") or name.contains("licence") or name.contains("readme")) and name.ends_with(".txt")):
			continue
		assert_true(path in listed, "uncatalogued file: " + path)

func test_restricted_source_paths_and_product_filenames() -> void:
	var banned := "ha" + "lo"
	for path in _files("res://"):
		var lower := path.to_lower()
		assert_true(not path.get_file().to_lower().contains(banned), "restricted product filename: " + path)
		assert_true(not lower.contains("mixamo") or lower.begins_with("res://assets/import_local/mixamo/"), "restricted source path: " + path)

func test_no_restricted_rig_prefix_in_committed_animation_assets() -> void:
	var paths := _files("res://assets/third_party")
	paths.append_array(_files("res://assets/anim"))
	var prefix := "mixamorig".to_utf8_buffer()
	for path in paths:
		var bytes := FileAccess.get_file_as_bytes(path)
		var found := false
		for start in maxi(0, bytes.size() - prefix.size() + 1):
			if bytes[start] == prefix[0] and bytes.slice(start, start + prefix.size()) == prefix:
				found = true
				break
		assert_true(not found, "restricted rig prefix: " + path)
