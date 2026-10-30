extends "res://tests/test_case.gd"

func test_empty_table_resolves_procedural_and_missing_candidates_are_safe() -> void:
	var library := ClipLibrary.new({})
	var fallback := Animation.new()
	var table := DataRegistry.new().load_file("res://data/anim_sources.json")
	for logical: String in table["clips"]:
		var slide := logical.begins_with("cover_slide_")
		assert_eq(library.resolve(logical, null if slide else fallback), null if slide else fallback, "empty-table fallback " + logical)
		assert_eq(library.source_for(logical), "none" if slide else "procedural", "fallback source " + logical)
	var missing := ClipLibrary.new({"clips": {"idle": {"ual": [{"path": "res://assets/third_party/unavailable_clip.glb"}]}}})
	assert_eq(missing.resolve("idle", fallback), fallback, "missing path skipped before load")
	assert_eq(missing.source_for("idle"), "procedural", "no false UAL source")

func test_committed_sources_never_depend_on_local_drops() -> void:
	var table := DataRegistry.new().load_file("res://data/anim_sources.json")
	assert_true(not JSON.stringify(table).to_lower().contains("import_local"), "default tests independent of local drops")
	for slot: Dictionary in table["clips"].values():
		assert_true(slot.get("mixamo_local", []).is_empty(), "local source wiring deferred")
	var ignore := FileAccess.get_file_as_string("res://.gitignore").split("\n")
	for line in ["assets/import_local/mixamo/*", "!assets/import_local/mixamo/README.md", "assets/import_local/quaternius_ual_drop/*", "!assets/import_local/quaternius_ual_drop/README.md"]:
		var found := false
		for actual in ignore:
			found = found or actual.strip_edges() == line
		assert_true(found, "ignore line " + line)

func test_existing_tree_builds_with_no_library_files() -> void:
	var scene: SceneTree = Engine.get_main_loop()
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	scene.root.add_child(pawn)
	pawn.set_physics_process(false)
	var model := pawn.get_node("SoldierModel") as SoldierModel
	model.set_process(false)
	model.animation_tree.advance(0.0)
	for clip in ["idle", "walk_fwd", "walk_back", "strafe_l", "strafe_r", "run_fwd", "aim_down", "aim", "aim_up", "fire", "reload"]:
		assert_true(model.animation_tree.has_animation(clip), "fallback tree clip " + clip)
	pawn.enable_cover(DataRegistry.new().load_file("res://data/cover.json"))
	var graph := model.animation_tree.tree_root as AnimationNodeBlendTree
	var machine := graph.get_node(&"cover") as AnimationNodeStateMachine
	assert_true(not machine.has_node(&"cover_slide_l") and not machine.has_node(&"cover_slide_r"), "no unsupported slide states")
	pawn.free()
