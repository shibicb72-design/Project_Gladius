extends "res://tests/test_case.gd"
## M2 audio space: distance filters and reverb zones. Every positional player takes its distance low-pass
## (attenuation_filter_cutoff_hz / attenuation_filter_db) from data/audio.json, a reused pool voice never keeps the
## previous sound's values, and the shipped data keeps far reports duller than footsteps.


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _sfx() -> Node:
	return _tree().root.get_node_or_null("Sfx")


func _free_voices() -> void:
	var sfx := _sfx()
	for i in sfx._pool_until.size():
		sfx._pool_until[i] = 0
	sfx._last_play.clear()


func _valid_loops() -> int:
	var n := 0
	for loop: Variant in _sfx()._loops:
		if is_instance_valid(loop):
			n += 1
	return n


## Every footstep id listed under footsteps.surfaces.
func _step_ids() -> Array[String]:
	var out: Array[String] = []
	var surfaces: Dictionary = _sfx().cfg["footsteps"]["surfaces"]
	for surface: String in surfaces:
		for id: Variant in surfaces[surface]:
			out.append(String(id))
	return out


## The far report ids: hooks.shot_far and each value of hooks.shot_far_by_weapon.
func _far_ids() -> Array[String]:
	var hooks: Dictionary = _sfx().cfg["hooks"]
	var out: Array[String] = [String(hooks["shot_far"])]
	for weapon: String in hooks["shot_far_by_weapon"]:
		out.append(String(hooks["shot_far_by_weapon"][weapon]))
	return out


func _assert_filter(player: AudioStreamPlayer3D, id: String, what: String) -> void:
	var s: Dictionary = _sfx().sound(id)
	assert_eq(player.attenuation_filter_cutoff_hz, float(s["attenuation_filter_cutoff_hz"]), "%s: %s cutoff from data" % [what, id])
	assert_eq(player.attenuation_filter_db, float(s["attenuation_filter_db"]), "%s: %s filter db from data" % [what, id])


## Plays an id on the first pool voice (every voice made free first, so index 0 is picked).
func _play_on_first_voice(id: String) -> AudioStreamPlayer3D:
	_free_voices()
	return _sfx().play_at(id, Vector3(2.0, 0.0, 0.0))


func test_play_at_sets_each_sounds_filter_on_a_reused_voice() -> void:
	var sfx := _sfx()
	var far := _far_ids()[0]
	var step := _step_ids()[0]
	var plain := "shield_break"  # no filter keys of its own: the defaults
	assert_true(not (sfx.cfg["sounds"][plain] as Dictionary).has("attenuation_filter_cutoff_hz"), "%s uses the default filter" % plain)
	assert_true(sfx.sound(far)["attenuation_filter_cutoff_hz"] != sfx.sound(step)["attenuation_filter_cutoff_hz"], "far and step cutoffs differ in data")
	var first := _play_on_first_voice(far)
	assert_true(first != null, "%s plays" % far)
	if first == null:
		return
	assert_true(first == sfx._pool[0], "the first free voice is picked")
	_assert_filter(first, far, "far report")
	var second := _play_on_first_voice(step)
	assert_true(second == first, "%s reuses the same voice" % step)
	_assert_filter(second, step, "footstep after a far report")
	var third := _play_on_first_voice(plain)
	assert_true(third == first, "%s reuses the same voice" % plain)
	_assert_filter(third, plain, "default after a footstep")
	assert_eq(third.attenuation_filter_cutoff_hz, float(sfx.cfg["defaults"]["attenuation_filter_cutoff_hz"]), "%s gets the default cutoff" % plain)
	assert_eq(third.attenuation_filter_db, float(sfx.cfg["defaults"]["attenuation_filter_db"]), "%s gets the default filter db" % plain)
	# Synthetic values, so this does not hang on today's numbers.
	var entry: Dictionary = sfx.cfg["sounds"][plain]
	var saved := entry.duplicate(true)
	entry["attenuation_filter_cutoff_hz"] = 1234.0
	entry["attenuation_filter_db"] = -7.0
	var fourth := _play_on_first_voice(plain)
	sfx.cfg["sounds"][plain] = saved
	assert_true(fourth == first, "the synthetic play reuses the same voice")
	if fourth != null:
		assert_eq(fourth.attenuation_filter_cutoff_hz, 1234.0, "a synthetic cutoff reaches the voice")
		assert_eq(fourth.attenuation_filter_db, -7.0, "a synthetic filter db reaches the voice")
	assert_true(not (sfx.cfg["sounds"][plain] as Dictionary).has("attenuation_filter_cutoff_hz"), "the synthetic values are restored away")
	var fifth := _play_on_first_voice(far)
	if fifth != null:
		_assert_filter(fifth, far, "far report after the synthetic values")
	_free_voices()


func test_make_loop_sets_each_sounds_filter() -> void:
	var sfx := _sfx()
	var fire := String(sfx.cfg["ambience"]["brazier_loop"])
	var hum := "zone_hum_loop"
	var before := _valid_loops()
	var saved := {fire: (sfx.cfg["sounds"][fire] as Dictionary).duplicate(true), hum: (sfx.cfg["sounds"][hum] as Dictionary).duplicate(true)}
	sfx.cfg["sounds"][fire]["attenuation_filter_cutoff_hz"] = 2345.0
	sfx.cfg["sounds"][fire]["attenuation_filter_db"] = -9.0
	sfx.cfg["sounds"][hum]["attenuation_filter_cutoff_hz"] = 6789.0
	sfx.cfg["sounds"][hum]["attenuation_filter_db"] = -3.0
	var holder := Node3D.new()
	_tree().root.add_child(holder)
	var a: Node = sfx.make_loop(fire, holder, true)
	var b: Node = sfx.make_loop(hum, holder, true)
	for id: String in saved:
		sfx.cfg["sounds"][id] = saved[id]
	assert_true(a is AudioStreamPlayer3D, "%s positional loop is an AudioStreamPlayer3D" % fire)
	assert_true(b is AudioStreamPlayer3D, "%s positional loop is an AudioStreamPlayer3D" % hum)
	if a is AudioStreamPlayer3D:
		assert_eq((a as AudioStreamPlayer3D).attenuation_filter_cutoff_hz, 2345.0, "%s loop carries its cutoff" % fire)
		assert_eq((a as AudioStreamPlayer3D).attenuation_filter_db, -9.0, "%s loop carries its filter db" % fire)
	if b is AudioStreamPlayer3D:
		assert_eq((b as AudioStreamPlayer3D).attenuation_filter_cutoff_hz, 6789.0, "%s loop carries its own cutoff" % hum)
		assert_eq((b as AudioStreamPlayer3D).attenuation_filter_db, -3.0, "%s loop carries its own filter db" % hum)
	assert_eq(_valid_loops(), before + 2, "both loops count against max_loops")
	holder.free()
	assert_eq(_valid_loops(), before, "freeing the holder leaves no loop behind")
	for id: String in saved:
		assert_true(not (sfx.cfg["sounds"][id] as Dictionary).has("attenuation_filter_cutoff_hz"), "%s data is restored" % id)


func test_far_reports_are_filtered_harder_than_footsteps() -> void:
	var sfx := _sfx()
	var steps := _step_ids()
	assert_true(not steps.is_empty(), "footsteps list ids")
	for far in _far_ids():
		var f: Dictionary = sfx.sound(far)
		assert_true(not f.is_empty(), "%s is a sound" % far)
		for step in steps:
			var s: Dictionary = sfx.sound(step)
			assert_true(float(f["attenuation_filter_cutoff_hz"]) < float(s["attenuation_filter_cutoff_hz"]), "%s cutoff below %s" % [far, step])
			assert_true(float(f["attenuation_filter_db"]) <= float(s["attenuation_filter_db"]), "%s filter db at least as deep as %s" % [far, step])


func test_every_sound_resolves_a_sane_filter() -> void:
	var sfx := _sfx()
	for id: String in sfx.cfg["sounds"]:
		if id.begins_with("_"):
			continue
		var s: Dictionary = sfx.sound(id)
		var cutoff := float(s["attenuation_filter_cutoff_hz"])
		var db := float(s["attenuation_filter_db"])
		assert_true(cutoff >= 20.0 and cutoff <= 20500.0, "%s cutoff %s within 20..20500 Hz" % [id, cutoff])
		assert_true(db <= 0.0, "%s filter db %s is a cut" % [id, db])


func test_defaults_carry_both_filter_keys() -> void:
	var defaults: Dictionary = _sfx().cfg["defaults"]
	assert_true(defaults.has("attenuation_filter_cutoff_hz"), "defaults carry attenuation_filter_cutoff_hz")
	assert_true(defaults.has("attenuation_filter_db"), "defaults carry attenuation_filter_db")
