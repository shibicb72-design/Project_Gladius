extends "res://tests/test_case.gd"
## M2 AN1 commit 4: where every third-person state's animation comes from, that the library clips are really used
## (no silent fallback to the code-built ones), that they are baked once and shared by every soldier, that the
## UAL mannequin mesh is never loaded, that the reload clip lasts the weapon's own reload time, and the soldier's
## triangle and draw counts (printed for the lead's budgets).

const UAL := "res://assets/third_party/quaternius_ual/UAL1_Standard.glb"
## state -> [library slot, expected source]. "code" = built in code on purpose (see SOURCES_WHY).
## M2 AN2 item 2: the library slots resolve to "blender" (soldier_clips.glb, baked on the soldier's own rig); the UAL
## candidates stay listed behind them as the fallback.
const STATES := {
	"idle": ["idle", "blender"], "walk (slow)": ["walk_slow", "blender"], "move speed (jog)": ["walk_fwd", "blender"],
	"sprint": ["run_fwd", "blender"], "back-pedal (reversed jog)": ["walk_back", "blender"], "strafe left": ["strafe_l", "blender"],
	"strafe right": ["strafe_r", "blender"], "airborne": ["jump_air", "blender"], "hit chest": ["hit_chest", "blender"],
	"hit head": ["hit_head", "blender"], "death": ["death", "blender"], "revive (reviver)": ["revive", "blender"],
	"blade swing": ["blade_swing", "blender"], "cover crouch": ["cover_crouch_idle", "blender"],
	"cover crouch move": ["cover_crouch_move", "blender"],
	"aim": ["aim", "procedural"], "aim up": ["aim_up", "procedural"], "aim down": ["aim_down", "procedural"],
	"fire": ["fire", "procedural"], "reload": ["reload", "procedural"],
}


func _pawn() -> Pawn:
	var tree: SceneTree = Engine.get_main_loop()
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	tree.root.add_child(pawn)
	pawn.set_physics_process(false)
	return pawn


func test_every_state_resolves_to_its_source_and_library_clips_are_really_used() -> void:
	var pawn := _pawn()
	var model := pawn.get_node("SoldierModel") as SoldierModel
	var clips := ClipLibrary.new()
	for state: String in STATES:
		var slot: String = STATES[state][0]
		var expected: String = STATES[state][1]
		var resolved := clips.resolve(slot, Animation.new(), model.skeleton)
		print("CLIP_SOURCE %s slot=%s source=%s" % [state, slot, clips.source_for(slot)])
		assert_eq(clips.source_for(slot), expected, "%s comes from %s" % [state, expected])
		if expected == "blender":
			assert_true(resolved != null and resolved.get_track_count() > 10, "%s: a baked library clip with the soldier's tracks" % state)
	# The graph plays the library clips, not the code-built fallbacks.
	var graph_clips := model.animation_tree.get_meta(&"clip_library") as ClipLibrary
	for slot in ["idle", "walk_slow", "walk_fwd", "walk_back", "strafe_l", "strafe_r", "run_fwd"]:
		assert_eq(graph_clips.source_for(slot), "blender", "the soldier's graph resolved %s from the Blender clips" % slot)
	assert_eq(model.animation_tree.get_animation(&"idle"), clips.resolve("idle", null, model.skeleton), "the graph's idle is the shared library clip")
	assert_true(not (model.animation_tree.get_meta(&"gait_cycles") as Dictionary).is_empty(), "the gait cycles were measured on the library clips")
	assert_true(model.animation_tree.has_animation(&"jump_air") and model.animation_tree.has_animation(&"hit_chest"), "airborne and flinch clips are in the graph")
	assert_true(model.pose._swing_clip != null and model.pose._revive_clip != null, "the blade swing and the reviver use the library clips")
	assert_true(model.crawl != null and model.crawl.cfg.size() > 0, "the downed crawl is code-built (the UAL has no crawl)")
	# Corpse: the authored fall.
	var corpse := model.make_corpse()
	assert_true(corpse.has_meta("authored_fall"), "the corpse plays the library death")
	corpse.free()
	pawn.free()


func test_clips_are_baked_once_and_shared_and_the_mannequin_is_never_loaded() -> void:
	var first := _pawn()
	var count := ClipLibrary.cached_count()
	var second := _pawn()
	assert_eq(ClipLibrary.cached_count(), count, "a second soldier bakes nothing new")
	var a := (first.get_node("SoldierModel") as SoldierModel).animation_tree
	var b := (second.get_node("SoldierModel") as SoldierModel).animation_tree
	for clip in ["idle", "walk_slow", "walk_fwd", "walk_back", "strafe_l", "strafe_r", "run_fwd", "jump_air", "hit_chest", "hit_head"]:
		assert_true(a.get_animation(clip) == b.get_animation(clip), "one shared %s for every soldier" % clip)
	assert_eq(ClipLibrary._held.size(), 0, "the UAL source scene is released after the bake")
	# The import skips the 13.7k-triangle mannequin: the imported scene has a skeleton and clips, no mesh.
	var scene: PackedScene = load(UAL)
	var instance := scene.instantiate()
	assert_eq(instance.find_children("*", "MeshInstance3D", true, false).size(), 0, "no mannequin mesh in the imported UAL scene")
	assert_eq(instance.find_children("*", "Skeleton3D", true, false).size(), 1, "the UAL skeleton is imported")
	instance.free()
	first.free()
	second.free()


func test_reload_clip_lasts_each_weapons_reload_time() -> void:
	var pawn := _pawn()
	var model := pawn.get_node("SoldierModel") as SoldierModel
	var registry := DataRegistry.new()
	var weapons: Dictionary = registry.load_file("res://data/stats.json")["weapons"]
	var checked := 0
	for id: String in weapons:
		var def := registry.get_weapon_def(id)
		if def == null or def.is_melee() or def.reload_s <= 0.0:
			continue  # gladius_lux: no reload
		pawn.loadout.slots[pawn.loadout.active] = Weapon.new(def)
		pawn.reload_started.emit()
		assert_true(is_equal_approx(model.animation_tree.get_animation(&"reload").length, def.reload_s), "%s: reload clip %.3f s = WeaponDef.reload_s %.3f s" % [id, model.animation_tree.get_animation(&"reload").length, def.reload_s])
		checked += 1
	assert_true(checked >= 2, "several ranged weapons checked (%d)" % checked)
	pawn.free()


func test_soldier_triangles_and_draw_calls() -> void:
	var pawn := _pawn()
	var model := pawn.get_node("SoldierModel") as SoldierModel
	var tris := 0
	var draws := 0
	var shown: Array[String] = []
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		if not mesh.is_visible_in_tree() or mesh.layers == 0 or mesh.mesh == null:
			continue
		for s in mesh.mesh.get_surface_count():
			var arrays := mesh.mesh.surface_get_arrays(s)
			var index: Variant = arrays[Mesh.ARRAY_INDEX]
			tris += (index.size() if index != null else (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()) / 3
			draws += 1
		shown.append(String(mesh.name))
	print("SOLDIER_BUDGET triangles=%d draw_calls=%d (colour pass; shadow casters add the same again) meshes=%s bones=%d" % [tris, draws, shown, model.skeleton.get_bone_count()])
	assert_true(tris > 0 and draws > 0, "the soldier draws")
	pawn.free()
