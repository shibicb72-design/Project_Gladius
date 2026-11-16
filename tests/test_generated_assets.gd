extends "res://tests/test_case.gd"
## S2 / S5: the ledger of generated assets (data/asset_catalog.json "generated", written by
## tools/asset_hashes.gd). Every file under res://assets/generated is listed with the sha256 of the committed
## file and the tool that made it; nothing there comes from outside the project.
const AssetHashes := preload("res://tools/asset_hashes.gd")


func test_every_generated_file_is_listed_with_its_hash_and_tool() -> void:
	var catalog: Dictionary = DataRegistry.new().load_file("res://data/asset_catalog.json")
	var listed := {}
	for entry: Dictionary in catalog.get("generated", []):
		listed[String(entry["path"])] = entry
		assert_true(String(entry["path"]).begins_with("res://assets/generated/"), "generated path: " + String(entry["path"]))
		assert_true(FileAccess.file_exists(String(entry["path"])), "listed file exists: " + String(entry["path"]))
		assert_eq(FileAccess.get_sha256(String(entry["path"])), String(entry["sha256"]), "committed file hash of " + String(entry["path"]))
		assert_true(FileAccess.file_exists("res://" + String(entry["made_by"])), "the tool that made it is in the repo: " + String(entry["made_by"]))
	var files := AssetHashes.files(AssetHashes.ROOT)
	assert_true(files.size() >= 2, "generated assets exist")
	for path in files:
		assert_true(listed.has(path), "unlisted generated file: " + path)
	assert_eq(listed.size(), files.size(), "no stale ledger entry")
	# Generated files are not third-party assets: the third-party list does not name them.
	for entry: Dictionary in catalog.get("assets", []):
		assert_true(not String(entry["path"]).begins_with("res://assets/generated/"), "generated files stay out of the third-party list")


## M2 AN2: every .glb under res://assets/generated was written by a committed Blender script: its ledger entry names
## an existing tools/blender/*.py, the same one tools/blender/manifest.json records, and a derived_from names a
## third-party asset of the catalog. No manifest row points at a missing file.
func test_every_generated_glb_is_made_by_a_blender_script() -> void:
	var catalog: Dictionary = DataRegistry.new().load_file("res://data/asset_catalog.json")
	var ledger := {}
	for entry: Dictionary in catalog.get("generated", []):
		ledger[String(entry["path"])] = entry
	var third_party := {}
	for asset: Dictionary in catalog.get("assets", []):
		third_party[String(asset["id"])] = true
	var made := AssetHashes.manifest()
	var glbs := 0
	for path in AssetHashes.files(AssetHashes.ROOT):
		if not path.ends_with(".glb"):
			continue
		glbs += 1
		assert_true(ledger.has(path), "the ledger lists " + path)
		assert_true(made.has(path), "tools/blender/manifest.json lists " + path)
		if not ledger.has(path) or not made.has(path):
			continue
		var made_by := String(ledger[path]["made_by"])
		assert_true(made_by.begins_with("tools/blender/") and made_by.ends_with(".py"), "%s is made by a Blender script, not %s" % [path, made_by])
		assert_true(FileAccess.file_exists("res://" + made_by), "the Blender script exists: " + made_by)
		assert_eq(made_by, String(made[path]["made_by"]), "ledger and manifest agree on the maker of " + path)
		var derived := String(made[path].get("derived_from", ""))
		assert_eq(String(ledger[path].get("derived_from", "")), derived, "ledger and manifest agree on the source of " + path)
		if derived != "":
			assert_true(third_party.has(derived), "derived_from names a catalogued third-party asset: " + derived)
			assert_true(String(ledger[path]["licence"]).contains(derived), "the licence of %s names its source" % path)
		else:
			assert_eq(String(ledger[path]["licence"]), AssetHashes.NO_SOURCE, "a file without a source says so: " + path)
	for path: String in made.keys():
		assert_true(FileAccess.file_exists(path), "a manifest row names an existing file: " + path)
	assert_true(glbs >= 1, "at least the pipeline proof .glb exists")


func test_surface_texture_matches_the_material_data() -> void:
	var cfg := WorldSurface.config()
	assert_true(bool(cfg["_placeholder"]) and String(cfg["_todo"]).contains("OQ-GFX-MATERIALS"), "material numbers are placeholders with an OQ id")
	var layers: Array = cfg["layers"]
	var texture := load(String(cfg["texture"])) as TextureLayered
	assert_true(texture != null and texture.get_layered_type() == TextureLayered.LAYERED_TYPE_2D_ARRAY, "the surface texture imports as a texture array")
	if texture != null:
		assert_eq(texture.get_layers(), layers.size(), "one array layer per named layer")
		print("GFX_TEXTURES surfaces %dx%d x %d layers, mipmaps=%s" % [texture.get_width(), texture.get_height(), texture.get_layers(), texture.has_mipmaps()])
	var order: Array = cfg["surface_order"]
	assert_true(order.size() <= WorldSurface.MAX_SURFACES, "surface ids fit the shader's arrays")
	for surface: String in order:
		assert_true((cfg["surfaces"] as Dictionary).has(surface), "surface_order names a surface: " + surface)
		assert_true(layers.has(cfg["surfaces"][surface]["layer"]), surface + " names a texture layer")
	for paint: String in cfg["paint"]:
		assert_true((LowpolyKit.config()["colors"] as Dictionary).has(paint), "paint key is a kit colour: " + paint)
		assert_true(order.has(cfg["paint"][paint]), "paint %s names a surface" % paint)
	assert_eq(WorldSurface.surface_name(WorldSurface.id_for_paint("marble")), "marble", "a paint colour finds its surface")
	assert_eq(WorldSurface.surface_name(WorldSurface.id_for_paint("stone", "sandbags")), "burlap", "a kit kind may swap a colour's surface")
	assert_eq(WorldSurface.surface_name(WorldSurface.id_for_paint("no_such_colour")), "plain", "an unknown colour is plain")
