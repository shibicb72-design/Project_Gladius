extends "res://tests/test_case.gd"
## W1c: the shader warm-up (scripts/visual/shader_warmup.gd, data/warmup.json). Headless there is no GL, so these
## check the logic: the item list (derived from the scene, deduplicated by draw key, plus the listed items), the
## stepping (one item per frame, copies freed, progress to 100 percent) and COVERAGE: every res://**/*.gdshader is
## warmed, and every draw key of a built alesia_500 match in dusk, night and storm (after the start: loot placed,
## zone wall built) is in the warm-up's set, so a new material or shader the warm-up would miss fails here.

const _MatchScene := preload("res://scenes/match/match.tscn")
const MAP_500 := "res://data/maps/alesia_500.json"
const VARIANTS: Array[String] = ["dusk", "night", "storm"]


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _frames(n: int) -> void:
	for i in n:
		await _tree().process_frame


static func _mesh_instance(mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.material = mat
	mi.mesh = box
	return mi


func test_keys_separate_what_selects_a_program() -> void:
	var a := StandardMaterial3D.new()
	var b := StandardMaterial3D.new()
	b.albedo_color = Color.RED  # a value, not a feature
	assert_eq(ShaderWarmup.material_key(a), ShaderWarmup.material_key(b), "colours do not change the key")
	b.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	assert_true(ShaderWarmup.material_key(a) != ShaderWarmup.material_key(b), "a feature flag does")
	var c := StandardMaterial3D.new()
	c.albedo_texture = GradientTexture2D.new()
	assert_true(ShaderWarmup.material_key(a) != ShaderWarmup.material_key(c), "a texture slot in use does")
	var sm := ShaderMaterial.new()
	sm.shader = load("res://scripts/visual/shaders/fire.gdshader")
	assert_eq(ShaderWarmup.material_key(sm), "shader:res://scripts/visual/shaders/fire.gdshader", "a shader material: its file")
	var plain := _mesh_instance(a)
	var mm := MultiMeshInstance3D.new()
	mm.multimesh = MultiMesh.new()
	mm.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	mm.multimesh.mesh = plain.mesh
	var k_plain := ShaderWarmup.draw_keys(plain)
	var k_mm := ShaderWarmup.draw_keys(mm)
	assert_eq(k_plain.size(), 1, "one key per surface")
	assert_true(k_plain[0].begins_with("mesh|") and k_mm[0].begins_with("multimesh:"), "the draw kind is part of the key")
	assert_true(k_plain[0] != k_mm[0], "a multimesh draw is its own entry")
	mm.multimesh.use_colors = true
	assert_true(ShaderWarmup.draw_keys(mm)[0] != k_mm[0], "the instance format is part of the key")
	plain.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	assert_true(ShaderWarmup.draw_keys(plain)[0] != k_plain[0], "shadow casting is part of the key")
	plain.free()
	mm.free()


## A small scene: the derived items are one per source with a new key, the listed items follow, one item starts per
## step, the copies are freed and the progress reaches 100 percent.
func test_items_steps_and_progress() -> void:
	var root := Node3D.new()
	root.name = "FakeMatch"
	var shared := StandardMaterial3D.new()
	for i in 3:
		root.add_child(_mesh_instance(shared))  # three nodes, one key
	var hidden := _mesh_instance(StandardMaterial3D.new())
	(hidden.mesh as BoxMesh).material.set("emission_enabled", true)
	hidden.visible = false  # hidden nodes count (shown later)
	root.add_child(hidden)
	_tree().root.add_child(root)
	var w := ShaderWarmup.new()
	w.quiet = true  # no pawn or director here: the soldier and corpse items cannot be made (reported, not warned)
	root.add_child(w)
	w.setup(root, null)
	var derived := w.items.filter(func(i: Dictionary) -> bool: return i["source"] == "derived")
	assert_eq(derived.size(), 2, "one derived item per new key (shared material once, the hidden one once)")
	assert_true(w.items.size() > derived.size(), "the listed items follow")
	assert_eq(w.contexts.size(), 1, "no omni or spot light in the scene: the sun-only context")
	assert_true(w.camera != null and w.camera.is_current(), "the warm camera is current")
	assert_eq(w.progress(), 0.0, "nothing started")
	assert_true(w.covered.is_empty(), "nothing is covered before a copy is drawn")
	var copy_frames := int(ShaderWarmup._num(w.cfg["copy_frames"]))
	var steps := 0
	var cells_max := 0
	while not w.step() and steps < 500:
		steps += 1
		assert_eq(w.index, mini(steps, w.items.size()), "one item starts per step")
		var live := 0
		for h in (w.get_node("Cell_base") as Node).get_children():
			if String(h.name).begins_with("Item") and not h.is_queued_for_deletion():
				live += 1
		cells_max = maxi(cells_max, live)
		await _tree().process_frame
	assert_true(w.done, "done")
	assert_eq(w.progress(), 1.0, "progress 100 percent")
	assert_true(steps >= w.items.size(), "at least one frame per item (%d steps, %d items)" % [steps, w.items.size()])
	assert_true(cells_max >= 1 and cells_max <= copy_frames, "a cell holds at most copy_frames (%d) items' copies at once (%d)" % [copy_frames, cells_max])
	var chk := w.check()
	for item: Dictionary in derived:
		assert_eq(item["status"], "ok", "%s: its copy drew its keys" % item["id"])
		for k: String in item["expected"]:
			assert_true(w.covered.has(k), "%s: covered from the copy" % k)
	var failed_ids: Array = (chk["failed"] as Array).map(func(f: Dictionary) -> String: return String(f["id"]))
	assert_true(failed_ids.has("listed:corpse"), "without a local pawn the corpse is reported failed: %s" % str(failed_ids))
	await _frames(1)
	var left := 0
	for cell in w.get_children():
		if cell is Node3D and String(cell.name).begins_with("Cell_"):
			left += cell.get_child_count() - cell.find_children("Warm_*", "Light3D", false, false).size()
	assert_eq(left, 0, "every copy was freed")
	root.queue_free()
	await _frames(1)


## Builds alesia_500 through the staged open (headless opt-in) in `variant` with every art_* switch of the presets on,
## lets the started match run until its loot is placed, and returns {match, session, report}.
func _open_500(variant: String) -> Dictionary:
	MatchLook.variant_override = variant
	var s := NetSession.new()
	s.name = "W1cWarmSession_" + variant
	s.isolated = true
	_tree().root.add_child(s)
	s.start_offline()
	s.lobby.host_open(2, 1, "Solus")
	s.lobby.state.start()
	var m: MatchRoot = _MatchScene.instantiate()
	m.open_path = MatchRoot.OpenPath.STAGED
	m.session_override = s
	m.lobby_override = s.lobby.state
	m.seed_override = 4242
	m.map_path_override = MAP_500
	_tree().root.add_child(m)
	var n := 0
	while m.opening and n < 4000:
		await _tree().process_frame
		n += 1
	for i in 3:
		await _tree().physics_frame
	await _tree().process_frame
	return {"match": m, "session": s, "report": m.warmup_report}


static func _all_shaders(dir_path: String, out: PackedStringArray) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for f in dir.get_files():
		if f.ends_with(".gdshader"):
			out.append(dir_path.path_join(f))
	for d in dir.get_directories():
		if not d.begins_with("."):
			_all_shaders(dir_path.path_join(d), out)


func test_every_shader_and_every_built_draw_is_warmed_in_each_variant() -> void:
	var saved_overrides := GraphicsPresets.overrides.duplicate()
	for key: String in (GraphicsPresets.config().get("presets", {}) as Dictionary).get("pc_high", {}):
		if key.begins_with("art_") and key.ends_with("_enabled"):
			GraphicsPresets.overrides[key] = true  # every look part on, so every shader of the look is in play
	var shaders_seen := {}
	for path: String in ShaderWarmup.config().get("canvas_shaders", []):
		shaders_seen[path] = "canvas (drawn under the overlay)"
	for variant in VARIANTS:
		var r: Dictionary = await _open_500(variant)
		var m: MatchRoot = r["match"]
		var report: Dictionary = r["report"]
		assert_true(m.director.running, "%s: the match started" % variant)
		assert_true(m.loot != null and m.loot.placed and m.zone_wall != null, "%s: loot placed, zone wall built" % variant)
		var covered: Dictionary = report.get("covered", {})
		assert_true(covered.size() > 10, "%s: the warm-up covered %d draw keys" % [variant, covered.size()])
		var missing := ShaderWarmup.uncovered(m, covered)
		assert_true(missing.is_empty(), "%s: every draw key of the started match is warmed; missing: %s" % [variant, "; ".join(missing)])
		for key: String in covered:
			for part in key.split("|"):
				for sub in part.split("+"):
					if sub.begins_with("shader:res://"):
						shaders_seen[sub.substr(7)] = variant
		for path in ShaderWarmup.screen_shaders(m):
			shaders_seen[path] = variant + " screen"
		for entry: Dictionary in ShaderWarmup.config().get("not_drawn", []):
			if String(entry.get("check", "")) == "no_shaft_places":
				var builder := m.map.get_node_or_null("ArtBuilder")
				if MatchLook.shaft_places(builder).is_empty():
					shaders_seen[String(entry["shader"])] = "not drawn: no shaft places (%s)" % variant
		if variant == "storm":
			# Negative cases: a material and a shader the warm-up never saw are reported.
			var odd := StandardMaterial3D.new()
			odd.subsurf_scatter_enabled = true
			odd.rim_enabled = true
			var injected := _mesh_instance(odd)
			injected.name = "W1cInjected"
			m.map.add_child(injected)
			var sm := ShaderMaterial.new()
			sm.shader = Shader.new()
			sm.shader.code = "shader_type spatial;\nvoid fragment() { ALBEDO = vec3(0.3); }\n"
			var injected2 := _mesh_instance(sm)
			m.map.add_child(injected2)
			var now := ShaderWarmup.uncovered(m, covered)
			assert_eq(now.size(), 2, "the injected material and shader are reported uncovered: %s" % "; ".join(now))
			assert_true(now.has(ShaderWarmup.draw_keys(injected)[0]) and now.has(ShaderWarmup.draw_keys(injected2)[0]), "by their keys")
		m.queue_free()
		await _frames(2)
		(r["session"] as NetSession).leave()
		(r["session"] as NetSession).queue_free()
		await _frames(1)
	MatchLook.variant_override = ""
	GraphicsPresets.overrides = saved_overrides
	var files := PackedStringArray()
	_all_shaders("res://", files)
	assert_true(files.size() >= 14, "found the project's shaders (%d)" % files.size())
	var not_warmed := PackedStringArray()
	for f in files:
		if not shaders_seen.has(f):
			not_warmed.append(f)
	assert_true(not_warmed.is_empty(), "every .gdshader is warmed (derived, listed or canvas); not: %s" % ", ".join(not_warmed))
