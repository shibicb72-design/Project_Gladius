extends "res://tests/test_case.gd"

func _weapon(mode: String) -> Weapon:
	var weapon := Weapon.new(DataRegistry.new().get_weapon_def("pilum_br"))
	weapon.fire_mode = mode
	return weapon


func test_semi_edge_latch_reload_and_empty() -> void:
	var w := _weapon("semi")
	var interval := w.def.fire_interval_s / w.def.burst_count
	assert_eq(w.update(0.0, true), 1, "press fires one")
	assert_eq(w.update(interval * 2.0, true), 0, "held semi never repeats")
	w.update(interval * 2.0, false)
	assert_eq(w.update(interval * 2.0, true), 1, "new press fires")
	w.update(interval * 2.1, false)
	assert_eq(w.update(interval * 2.2, true), 0, "cooldown tap armed")
	assert_eq(w.update(interval * 3.1, false), 1, "released tap latched until ready")
	w.update(interval * 3.2, true)
	assert_true(w.start_reload(interval * 3.3), "reload starts and clears latch")
	assert_eq(w.update(interval * 3.4, false), 0, "release recorded during reload")
	assert_eq(w.update(interval * 3.3 + w.def.reload_s, false), 0, "no armed round after reload")
	w.ammo_in_mag = 0
	assert_eq(w.update(10.0, true), 0, "empty stops semi")


func test_auto_and_semi_fixed_step_shots_pass_host_validator() -> void:
	for mode in ["auto", "semi"]:
		var w := _weapon(mode)
		var validator := NetValidator.new(DataRegistry.new().load_file("res://data/net.json")["validation"])
		var step := 1.0 / Engine.physics_ticks_per_second
		var interval := w.def.fire_interval_s / w.def.burst_count
		var shots := 0
		var previous := -INF
		for tick in 1000:
			var now := tick * step
			var count := w.update(now, true if mode == "auto" else tick % 2 == 0)
			assert_true(count <= 1, "one round maximum per update")
			for i in count:
				assert_true(now - previous >= interval, "%s gap >= own data interval" % mode)
				var result := validator.validate_fire(1, w.def.id, w.def, now, Vector3.ZERO, Vector3.ZERO, Vector3.FORWARD)
				assert_true(result["ok"], "%s shot %d host accepted" % [mode, shots])
				previous = now
				shots += 1
			if shots == 10:
				break
		assert_eq(shots, 10, "%s produces ten accepted shots" % mode)
		assert_eq(w.ammo_in_mag, w.def.magazine - 10, "each round spends ammo")
		print("FIRE_MODE ", mode, " interval_s=", interval, " tenth_shot_s=", previous)
		w.ammo_in_mag = 0
		assert_eq(w.update(100.0, true), 0, "empty stops auto and semi")


func test_every_local_round_emits_fired_and_other_weapons_keep_legacy() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	tree.root.add_child(pawn)
	pawn.set_physics_process(false)
	var emitted := [0]
	pawn.fired.connect(func() -> void: emitted[0] += 1)
	var w := pawn.loadout.get_active()
	w.fire_mode = "auto"
	var before := w.ammo_in_mag
	var frame := InputFrame.new()
	frame.fire_pressed = true
	pawn.set_frame(frame)
	for tick in 100:
		pawn._clock = tick / float(Engine.physics_ticks_per_second)
		pawn._apply_weapon()
	assert_true(emitted[0] >= 10, "every auto shot emits fired through unchanged pawn")
	assert_eq(before - w.ammo_in_mag, emitted[0], "fired matches rounds consumed")
	var bot := Weapon.new(w.def)
	assert_eq(bot.fire_mode, "", "new weapons never opt into modes")
	var total := bot.update(0.0, true)
	for tick in range(1, 10):
		total += bot.update(tick * bot.def.burst_interval_s, false)
	assert_eq(total, bot.def.burst_count, "default brief press still completes legacy burst")
	pawn.free()


func test_knockback_peak_at_shipped_rates() -> void:
	var cfg := DataRegistry.new().load_file("res://data/camera.json")
	var peaks: Array[float] = []
	for mode in ["auto", ""]:
		var w := _weapon(mode)
		var kick := CameraKnockback.new()
		kick.configure(cfg)
		var rounds := 0
		var peak := 0.0
		var step := 1.0 / Engine.physics_ticks_per_second
		for tick in 1000:
			kick.tick(step)
			for shot in w.update(tick * step, true if mode == "auto" else tick == 0):
				kick.kick()
				rounds += 1
				peak = maxf(peak, rad_to_deg(kick.offset.x))
			if rounds >= (10 if mode == "auto" else w.def.burst_count):
				break
		peaks.append(peak)
	assert_true(peaks[0] < peaks[1], "uniform auto spacing stacks less view kick than the old burst")
	print("FIRE_MODE measured fixed-step pitch_peak_deg auto_10=", peaks[0], " baseline_burst=", peaks[1])
