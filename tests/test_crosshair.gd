extends "res://tests/test_case.gd"
## Path A2 (OQ-CROSSHAIR): the permanent centre reticle on GameHud. It is shown in play without aiming or firing, sits
## on the camera-centre aim ray at rest, ignores the mouse on every node, stays up through the hit marker flash,
## follows a runtime resize (fold/unfold) and hides while the local pawn is dead.

const _Rig := preload("res://tests/button_rig.gd")
## Fold canvases (cover 1512x648, inner 1152x959: windows 2520x1080 / 2176x1812 under canvas_items + expand), then the
## window sizes. The first step on one HUD is the unfold: cover canvas -> inner canvas.
const RESIZE_STEPS: Array[Vector2] = [Vector2(1512, 648), Vector2(1152, 959), Vector2(2520, 1080), Vector2(2176, 1812)]


func _root() -> Window:
	return (Engine.get_main_loop() as SceneTree).root


func _cfg() -> Dictionary:
	return DataRegistry.new().load_file("res://data/ui.json")["crosshair"]


## A GameHud in the tree at `sz`, laid out like tests/test_feedback_clearance.gd.
func _new_hud(sz: Vector2) -> GameHud:
	var game: GameHud = load("res://scenes/ui/hud.tscn").instantiate()
	_root().add_child(game)
	game.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	game.size = sz
	await (Engine.get_main_loop() as SceneTree).process_frame
	return game


## The reticle at HUD size `sz` against `cfg`: centred, span and arms from the height fractions, centre left open.
func _check_layout(game: GameHud, sz: Vector2, cfg: Dictionary) -> void:
	var tag := "size %s" % sz
	var span := float(cfg["size_frac_of_height"]) * sz.y
	var arm_len := (span - float(cfg["gap_frac_of_height"]) * sz.y) * 0.5
	var thick := maxf(1.0, float(cfg["thickness_frac_of_height"]) * sz.y)
	var centre := sz * 0.5
	var root := game.crosshair.get_global_rect()
	assert_true(root.get_center().distance_to(centre) <= 1.0, "%s: centred on %s, got %s" % [tag, centre, root.get_center()])
	assert_true(root.size.is_equal_approx(Vector2(span, span)),
			"%s: span %s from the height fraction, got %s" % [tag, span, root.size])
	var arms := game.crosshair.get_children()
	assert_eq(arms.size(), 4, "%s: four arms" % tag)
	var union := Rect2()
	for i in arms.size():
		var r := (arms[i] as Control).get_global_rect()
		union = r if i == 0 else union.merge(r)
		var horizontal := absf(r.get_center().x - centre.x) > absf(r.get_center().y - centre.y)
		var along := r.size.x if horizontal else r.size.y
		var across := r.size.y if horizontal else r.size.x
		var off_line := absf(r.get_center().y - centre.y) if horizontal else absf(r.get_center().x - centre.x)
		assert_true(is_equal_approx(along, arm_len), "%s: arm %s is %s long" % [tag, r, arm_len])
		assert_true(is_equal_approx(across, thick), "%s: arm %s is %s thick" % [tag, r, thick])
		assert_true(off_line < 0.01, "%s: arm %s on the centre line" % [tag, r])
		assert_true(root.grow(0.01).encloses(r), "%s: arm %s inside the root %s" % [tag, r, root])
		assert_true(not r.has_point(centre), "%s: arm %s leaves the centre open for the hit marker" % [tag, r])
	assert_true(union.grow(0.01).encloses(root), "%s: the arms reach every side of the root %s, got %s" % [tag, root, union])


func test_crosshair_values_are_marked_placeholders() -> void:
	var cfg := _cfg()
	assert_eq(cfg.get("_placeholder"), true, "data/ui.json crosshair is marked _placeholder")
	assert_true(str(cfg.get("_todo", "")).begins_with("OQ-CROSSHAIR"), "its _todo cites OQ-CROSSHAIR")


func test_crosshair_shown_while_alive_and_hidden_while_dead() -> void:
	var game: GameHud = await _new_hud(RESIZE_STEPS[0])
	assert_true(game.crosshair != null and game.crosshair.get_parent() == game, "crosshair is built as a GameHud child")
	assert_true(game.crosshair.is_visible_in_tree(), "shown before a pawn is bound")
	var director := MatchDirector.new()
	var pawn := Pawn.new()
	pawn.setup("hastati", 0)
	game.bind(director, pawn)
	assert_true(game.crosshair.is_visible_in_tree(), "shown while the local pawn is alive")
	pawn.bridge.state.health = 0.0  # the kill of tests/test_match_scene.gd test_dead_pawn_respawns_at_squad_spot_protected
	game.refresh_pawn()
	assert_true(game.respawn_label.visible, "respawn countdown shows while dead")
	assert_true(not game.crosshair.is_visible_in_tree(), "hidden while dead (no shot is possible)")
	pawn.bridge.state.health = pawn.bridge.state.max_health
	game.refresh_pawn()
	assert_true(game.crosshair.is_visible_in_tree(), "shown again once alive")
	game._ch["enabled"] = false
	game.refresh_pawn()
	assert_true(not game.crosshair.is_visible_in_tree(), "crosshair.enabled false hides it")
	game.free()
	pawn.free()
	director.free()


func test_crosshair_sits_on_the_aim_ray_at_rest() -> void:
	# The real match (tests/button_rig.gd: match.tscn with its Hud CanvasLayer) at both Fold window sizes.
	for sz in _Rig.SIZES:
		var ctx: Dictionary = await _Rig.setup(sz, "virtual")
		var tag: String = ctx["tag"]
		var hud: GameHud = ctx["hud"]
		var pawn: Pawn = ctx["pawn"]
		var rig := pawn.get_node("CameraRig") as CameraRig  # as match_root.gd _physics_process gets it
		var cam := rig.get_camera()
		assert_true(hud.crosshair.get_parent() == hud and hud.get_parent() is CanvasLayer,
				"%s: crosshair is GameHud UI on the Hud CanvasLayer" % tag)
		assert_eq(rig.get_knockback(), Vector2.ZERO, "%s: camera at rest" % tag)
		assert_true(hud.crosshair.is_visible_in_tree(), "%s: shown in play without aiming or firing" % tag)
		var centre := hud.crosshair.get_global_rect().get_center()
		var ray_px := cam.get_viewport().get_visible_rect().size * 0.5  # the screen point of AimMath.camera_aim_point
		assert_true(centre.distance_to(ray_px) <= 1.0, "%s: crosshair %s on the aim-ray screen point %s" % [tag, centre, ray_px])
		# Where shots go: the rig's aim point (match_root.gd frame.aim_point), projected back onto the screen.
		var aim := rig.get_aim_point(pawn.hitscan_exclude())
		assert_true(not cam.is_position_behind(aim), "%s: aim point %s in front of the camera" % [tag, aim])
		var aim_px := cam.unproject_position(aim)
		assert_true(centre.distance_to(aim_px) <= 1.0, "%s: crosshair %s on the projected aim point %s" % [tag, centre, aim_px])
		await _Rig.teardown(ctx)


func test_crosshair_hides_while_the_local_pawn_is_dead_in_the_match() -> void:
	var ctx: Dictionary = await _Rig.setup(_Rig.SIZES[0], "virtual")
	var hud: GameHud = ctx["hud"]
	var pawn: Pawn = ctx["pawn"]
	assert_true(pawn.is_alive() and hud.crosshair.is_visible_in_tree(), "shown while alive")
	pawn.bridge.state.health = 0.0
	await _Rig.frames(3)
	assert_true(not pawn.is_alive(), "dead, waiting to respawn")
	assert_true(hud.respawn_label.visible, "respawn countdown shows")
	assert_true(not hud.crosshair.is_visible_in_tree(), "crosshair hidden while dead")
	await _Rig.teardown(ctx)


func test_crosshair_ignores_the_mouse_on_every_node() -> void:
	var game: GameHud = await _new_hud(RESIZE_STEPS[0])
	var nodes: Array[Node] = [game.crosshair]
	nodes.append_array(game.crosshair.find_children("*", "Control", true, false))
	assert_true(nodes.size() > 1, "crosshair root and its arms found")
	for n in nodes:
		assert_eq((n as Control).mouse_filter, Control.MOUSE_FILTER_IGNORE, "%s ignores the mouse" % n.get_path())
	game.free()


func test_crosshair_stays_up_through_the_hit_marker_flash() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var game: GameHud = await _new_hud(RESIZE_STEPS[0])
	assert_true(game.crosshair.get_index() < game.hit_marker.get_index(), "hit marker is a later sibling: the X draws on top")
	game.show_hit_marker()
	assert_true(game.hit_marker.visible, "hit marker shows")
	assert_true(game.crosshair.is_visible_in_tree(), "crosshair stays up while the hit marker shows")
	var deadline := Time.get_ticks_msec() + 3000
	while game.hit_marker.visible and Time.get_ticks_msec() < deadline:
		await tree.process_frame
	assert_true(not game.hit_marker.visible, "hit marker expires")
	assert_true(game.crosshair.is_visible_in_tree(), "crosshair stays up after the hit marker expires")
	game.free()


func test_crosshair_recentres_and_resizes_with_the_hud() -> void:
	# One HUD resized in place: folding resizes it at runtime, so the reticle must follow `resized`, not just its build.
	var tree: SceneTree = Engine.get_main_loop()
	var game: GameHud = await _new_hud(RESIZE_STEPS[0])
	for sz in RESIZE_STEPS:
		game.size = sz
		await tree.process_frame
		_check_layout(game, sz, _cfg())
	# The 1 px floor: a zero thickness fraction still draws 1 px arms.
	var thin := _cfg()
	thin["thickness_frac_of_height"] = 0.0
	game._ch = thin
	game.size = RESIZE_STEPS[0]
	await tree.process_frame
	_check_layout(game, RESIZE_STEPS[0], thin)
	game.free()
