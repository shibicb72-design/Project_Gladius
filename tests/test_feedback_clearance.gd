extends "res://tests/test_case.gd"
## GBTN2: every action-feedback widget (reload bar/text, hit marker, swap toast, Full/Empty/No reserve cues) and the
## permanent centre crosshair (OQ-CROSSHAIR), shown in its visible state, must not overlap a stick or an action
## button. Same assertions as tests/test_touch_controls.gd _check_hud_clear, at the four landscape sizes and both
## move-stick modes.

const _HudScene := preload("res://scenes/ui/touch_hud.tscn")
const _TouchHud := preload("res://scripts/ui/touch_hud.gd")
const SIZES: Array[Vector2] = [Vector2(1512, 648), Vector2(2520, 1080), Vector2(1152, 959), Vector2(2176, 1812)]
const MODES: Array[String] = ["virtual", "custom"]
const ACTIONS: Array[String] = ["fire", "aim", "reload", "swap_weapon", "jump", "swap_shoulder"]


func _root() -> Window:
	return (Engine.get_main_loop() as SceneTree).root


func _check(sz: Vector2, mode: String) -> void:
	var tree: SceneTree = Engine.get_main_loop()
	_TouchHud.move_stick_override = mode
	var touch: Control = _HudScene.instantiate()
	_root().add_child(touch)
	touch.cfg["force_touch_hud"] = true
	touch.refresh_visibility()
	touch.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	touch.size = sz
	touch.relayout()
	var game: GameHud = load("res://scenes/ui/hud.tscn").instantiate()
	_root().add_child(game)
	game.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	game.size = sz
	await tree.process_frame
	# Longest texts: the widest cue and a real weapon name for the toast.
	game.show_cue("No reserve")
	game.show_toast("Gladius Rifle")
	game.show_hit_marker()
	game.show_banner("HILL CONTESTED")
	game.own_death_label.visible = true
	game.respawn_label.visible = true
	game.respawn_label.text = "Respawn in 5"
	game.reload_box.visible = true
	await tree.process_frame
	await tree.process_frame
	var widgets := {"reload_box": game.reload_box, "cue_label": game.cue_label, "toast_label": game.toast_label,
			"hit_marker": game.hit_marker, "crosshair": game.crosshair, "banner_label": game.banner_label,
			"own_death_label": game.own_death_label}
	var touch_items := {"move_stick": touch.get_move_visual_rect(), "look_stick": touch.look_stick.get_global_rect()}
	for action in ACTIONS:
		touch_items["button_" + action] = touch.get_button_rect(action)
	var view := Rect2(Vector2.ZERO, sz)
	game.respawn_label.text = "Respawn in 5"
	assert_true(not game.own_death_label.get_global_rect().intersects(game.respawn_label.get_global_rect()), "own death clear of respawn")
	for other: Control in [game.crosshair, game.hit_marker, game.respawn_label, game.toast_label, game.cue_label, game.reload_box]:
		assert_true(not game.banner_label.get_global_rect().intersects(other.get_global_rect()),
				"banner clear of %s at %s" % [other, sz])
	assert_true(not game.banner_label.get_global_rect().intersects(game.own_death_label.get_global_rect()), "banners clear")
	for wname in widgets:
		var c: Control = widgets[wname]
		var r := c.get_global_rect()
		var tag := "%s %s mode=%s" % [wname, sz, mode]
		assert_true(c.is_visible_in_tree(), "%s is shown" % tag)
		assert_true(r.size.x > 0.0 and r.size.y > 0.0, "%s has size" % tag)
		assert_true(view.encloses(r), "%s inside viewport, got %s" % [tag, r])
		for tname in touch_items:
			assert_true(not r.intersects(touch_items[tname]), "%s %s overlaps %s %s" % [tag, r, tname, touch_items[tname]])
	game.free()
	touch.free()


func test_feedback_widgets_clear_of_sticks_and_buttons() -> void:
	for sz in SIZES:
		for mode in MODES:
			await _check(sz, mode)
