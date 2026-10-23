extends "res://tests/test_case.gd"
## Haptics (G2f): category gating, High/Low values from data, unsupported device, profile round trip, and
## gameplay events reaching the service through Haptics.play in a real (offline) match.

const _MatchScene := preload("res://scenes/match/match.tscn")
const PROFILE_PATH := "user://test_haptics_profile.json"


class FakeBackend extends HapticsBackend:
	var supported: bool = true
	var calls: Array = []  # [duration_ms, amplitude]

	func is_supported() -> bool:
		return supported

	func vibrate(duration_ms: int, amplitude: float) -> void:
		calls.append([duration_ms, amplitude])


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _make(supported: bool = true) -> HapticsService:
	var fake := FakeBackend.new()
	fake.supported = supported
	return HapticsService.new({}, fake)


func _calls(s: HapticsService) -> Array:
	return (s.backend as FakeBackend).calls


func test_defaults_match_data() -> void:
	var s := _make()
	var d: Dictionary = DataRegistry.new().load_file("res://data/haptics.json")["defaults"]
	assert_eq(s.enabled, bool(d["enabled"]), "master default from data")
	assert_eq(s.quality, str(d["quality"]), "quality default from data")
	for cat in d["categories"]:
		assert_eq(s.is_category_enabled(cat), bool(d["categories"][cat]), "category default " + cat)


func test_each_category_toggle_gates_its_events() -> void:
	var cfg: Dictionary = DataRegistry.new().load_file("res://data/haptics.json")
	var events: Dictionary = cfg["events"]
	for cat in cfg["categories"]:
		var s := _make()
		s.set_category(cat, false)
		for id in events:
			var played := s.play(id)
			if events[id]["category"] == cat:
				assert_true(not played, "%s blocked when %s is off" % [id, cat])
			else:
				assert_true(played, "%s still plays when only %s is off" % [id, cat])
		var blocked := 0
		for id in events:
			if events[id]["category"] == cat:
				blocked += 1
		assert_eq(_calls(s).size(), events.size() - blocked, "backend called only for the other categories")


func test_master_off_blocks_everything() -> void:
	var s := _make()
	s.set_enabled(false)
	assert_true(not s.play("weapon_fire"), "master off blocks")
	assert_eq(_calls(s).size(), 0, "no backend calls")


func test_unknown_event_does_nothing() -> void:
	var s := _make()
	assert_true(not s.play("no_such_event"), "unknown event is ignored")
	assert_eq(_calls(s).size(), 0, "no backend calls")


func test_quality_selects_high_or_low_values_from_data() -> void:
	var events: Dictionary = DataRegistry.new().load_file("res://data/haptics.json")["events"]
	for q in ["high", "low"]:
		var s := _make()
		s.set_quality(q)
		for id in events:
			s.play(id)
		var i := 0
		for id in events:
			var want: Dictionary = events[id][q]
			assert_eq(_calls(s)[i], [int(want["duration_ms"]), float(want["amplitude"])], "%s %s values" % [id, q])
			i += 1
	var hi: Dictionary = events["weapon_fire"]["high"]
	var lo: Dictionary = events["weapon_fire"]["low"]
	assert_true(float(lo["amplitude"]) < float(hi["amplitude"]) and int(lo["duration_ms"]) < int(hi["duration_ms"]),
			"Low is weaker and shorter than High")


func test_bad_quality_is_ignored() -> void:
	var s := _make()
	s.set_quality("loud")
	assert_eq(s.quality, "high", "unknown quality keeps the current one")


func test_unsupported_device_is_off_and_never_calls() -> void:
	var s := _make(false)
	assert_true(not s.is_supported(), "not supported")
	assert_true(not s.is_enabled(), "reads as off even though the stored switch is on")
	assert_true(s.enabled, "the stored choice is kept")
	assert_true(not s.play("weapon_fire"), "play refused")
	assert_true(not s.play("death"), "play refused")
	assert_eq(_calls(s).size(), 0, "no backend calls")


func test_real_backend_is_a_noop_off_device() -> void:
	var b := HapticsBackend.new()
	if OS.get_name() in ["Android", "iOS"] and DisplayServer.get_name() != "headless":
		return
	assert_true(not b.is_supported(), "desktop and headless are unsupported")
	b.vibrate(10, 0.5)  # must not error


func test_profile_round_trip() -> void:
	var save := SaveService.new(PROFILE_PATH)
	var s := _make()
	s.set_enabled(false)
	s.set_quality("low")
	s.set_category("status", false)
	var p := save.load_profile()
	p["haptics"] = s.to_dict()
	assert_true(save.save_profile(p), "saved")
	var back := _make()
	back.apply_settings(save.load_profile()["haptics"])
	assert_eq(back.enabled, false, "master round-trips")
	assert_eq(back.quality, "low", "quality round-trips")
	assert_eq(back.is_category_enabled("status"), false, "status round-trips")
	assert_eq(back.is_category_enabled("weapons"), true, "weapons round-trips")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PROFILE_PATH))


func test_corrupt_haptics_profile_gives_defaults() -> void:
	var out := HapticsService.sanitize({"enabled": "yes", "quality": "extreme", "categories": {"weapons": 3, "bogus": false}})
	assert_eq(out, HapticsService.default_settings(), "bad values fall back to the data defaults")
	assert_eq(HapticsService.sanitize(null), HapticsService.default_settings(), "null gives defaults")


func test_screen_toggles_persist_and_unsupported_shows_text() -> void:
	var holder := Control.new()
	_tree().root.add_child(holder)
	var save := SaveService.new(PROFILE_PATH)
	var screen: HapticsScreen = load("res://scenes/ui/haptics_screen.tscn").instantiate()
	screen.save = save
	screen.service = _make(true)
	holder.add_child(screen)
	await _tree().process_frame
	assert_true(not screen.unsupported_label.visible, "supported: no unavailable text")
	screen.category_buttons["weapons"].pressed.emit()
	screen.quality_buttons["low"].pressed.emit()
	var h: Dictionary = save.load_profile()["haptics"]
	assert_eq(h["categories"]["weapons"], false, "weapons toggle saved")
	assert_eq(h["quality"], "low", "quality saved")
	holder.queue_free()

	var holder2 := Control.new()
	_tree().root.add_child(holder2)
	var screen2: HapticsScreen = load("res://scenes/ui/haptics_screen.tscn").instantiate()
	screen2.save = SaveService.new(PROFILE_PATH)
	screen2.service = _make(false)
	holder2.add_child(screen2)
	await _tree().process_frame
	assert_true(screen2.unsupported_label.visible, "unsupported: text shown")
	assert_eq(screen2.unsupported_label.text, "Not available on this device", "exact text")
	assert_true(screen2.master_button.disabled, "master disabled")
	assert_true(screen2.master_button.text.ends_with("Off"), "reads Off")
	var min_h := 48.0 * PlatformServices.new().get_dp_scale()
	assert_true(screen2.master_button.size.y >= min_h - 0.5 or screen2.master_button.custom_minimum_size.y >= min_h - 0.5,
			"touch target at least 48 dp")
	holder2.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PROFILE_PATH))


func test_status_event_precedence() -> void:
	var r := DamageRules.HitResult.new()
	assert_eq(HapticsEvents.status_event(r), "damage_taken", "plain damage")
	r.shield_broken = true
	assert_eq(HapticsEvents.status_event(r), "shield_break", "shield break")
	r.killed = true
	assert_eq(HapticsEvents.status_event(r), "death", "death wins")


func test_match_gameplay_events_reach_the_service() -> void:
	var prev := Haptics.service
	var svc := _make()
	Haptics.service = svc
	var vp := SubViewport.new()
	vp.own_world_3d = true
	vp.size = Vector2i(64, 64)
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_tree().root.add_child(vp)
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.fill_bots = false
	vp.add_child(m)
	await _tree().physics_frame
	m.director.load_config()
	if not m.begin():
		failures.append("match did not begin")
	var p: Pawn = m.local_player
	if p != null:
		p.fire_shot()
		assert_eq(_calls(svc).size(), 1, "a fired shot -> one weapon_fire haptic call")
		var fire: Dictionary = DataRegistry.new().load_file("res://data/haptics.json")["events"]["weapon_fire"]["high"]
		assert_eq(_calls(svc)[0] if _calls(svc).size() > 0 else [], [int(fire["duration_ms"]), float(fire["amplitude"])],
				"the call carries the data values")
		p.reload_started.emit()
		assert_eq(_calls(svc).size(), 2, "reload -> a call")
		p.melee_landed.emit()
		assert_eq(_calls(svc).size(), 3, "melee hit -> a call")
		var hit := DamageRules.HitResult.new()
		hit.damage_dealt = 10.0
		hit.killed = true
		p.damaged.emit(hit)
		assert_eq(_calls(svc).size(), 4, "damage -> a call")
		svc.set_category("weapons", false)
		p.fire_shot()
		assert_eq(_calls(svc).size(), 4, "weapons off -> the next shot makes no call")
	else:
		failures.append("no local player")
	m.queue_free()
	vp.queue_free()
	Haptics.service = prev
