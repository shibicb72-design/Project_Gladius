extends "res://tests/test_case.gd"

func test_mode_button_clearance_at_device_density() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var profile := AppFlow.profile
	AppFlow.profile = {"left_fire_enabled": true}
	var touch_script := load("res://scripts/ui/touch_hud.gd")
	var ui := DataRegistry.new().load_file("res://data/ui.json")
	for dpi in [420.0, 373.0]:
		PlatformServices.dpi_override = dpi
		for mode in ["custom", "virtual"]:
			touch_script.move_stick_override = mode
			for sz in [Vector2(1512, 648), Vector2(2520, 1080), Vector2(1152, 959), Vector2(2176, 1812)]:
				var touch: Control = load("res://scenes/ui/touch_hud.tscn").instantiate()
				tree.root.add_child(touch)
				touch.cfg["force_touch_hud"] = true
				touch.refresh_visibility()
				touch.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
				touch.size = sz
				touch.relayout()
				var game: GameHud = load("res://scenes/ui/hud.tscn").instantiate()
				tree.root.add_child(game)
				game.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
				game.size = sz
				game.scores_label.text = "Squad VIII: XXXVIII   Squad II: XXIX"
				game.timer_label.text = "10:00"
				game.hill_label.text = "Hill: contested"
				game.respawn_label.text = "Respawn in 5"
				game.show_cue("No reserve")
				game.show_toast("Gladius Rifle")
				game.show_banner("HILL CONTESTED")
				game.show_hit_marker()
				game.respawn_label.show()
				game.own_death_label.show()
				game.reload_box.show()
				await tree.process_frame
				await tree.process_frame
				var rect := FireModeButton.touch_rect(ui["fire_mode_button"], sz)
				assert_true(Rect2(Vector2.ZERO, sz).encloses(rect), "mode button on-screen")
				assert_true(rect.size.x / PlatformServices.new().get_dp_scale() >= 48.0, "mode button >=48dp")
				var reserved := {"move": touch.get_move_visual_rect(), "look": touch.get_element_rect("look_stick"),
						"lock": touch.get_lock_button_rect(), "target": touch.get_lock_target_rect(), "gear": PauseMenu.gear_touch_rect(ui["pause_gear"], sz)}
				for key in touch.get_button_actions():
					reserved[key] = touch.get_element_rect(key)
				for widget: Control in [game.scores_label, game.timer_label, game.hill_label, game.crosshair, game.hit_marker,
						game.banner_label, game.own_death_label, game.respawn_label, game.reload_box, game.cue_label, game.toast_label,
						game.shield_bar, game.health_bar, game.weapon_label, game.ammo_label]:
					reserved[str(widget)] = widget.get_global_rect()
				for key in reserved:
					assert_true(not rect.intersects(reserved[key]), "mode rect %s clear of %s %s at %s dpi %s" % [rect, key, reserved[key], sz, dpi])
				print("FIRE_MODE_BUTTON_DPI ", dpi, " ", sz, " ", mode, " rect=", rect)
				game.free()
				touch.free()
	PlatformServices.dpi_override = 0.0
	AppFlow.profile = profile
