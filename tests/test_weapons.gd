extends "res://tests/test_case.gd"

const _Weapon := preload("res://scripts/weapons/weapon.gd")
const _Loadout := preload("res://scripts/weapons/loadout.gd")
const _Registry := preload("res://scripts/systems/data_registry.gd")
const _Range := preload("res://scenes/test/weapon_range.tscn")


func _weapon(id: String) -> Weapon:
	return _Weapon.new(_Registry.new().get_weapon_def(id))


# Gladius Lux is an energy blade now (OQ-07, no ammo), so the gun-timing tests use the single-shot rifle.
func test_fire_interval_respected() -> void:
	var w := _weapon("sagittarii_rifle")
	var interval: float = w.def.fire_interval_s
	assert_eq(w.update(0.0, true), 1, "first shot")
	assert_eq(w.update(interval * 0.5, true), 0, "too early")
	assert_eq(w.update(interval, true), 1, "second shot at interval")
	assert_eq(w.ammo_in_mag, w.def.magazine - 2, "ammo spent")


func test_burst_fires_burst_count() -> void:
	var w := _weapon("pilum_br")
	var total := 0
	var t := 0.0
	# Trigger held only briefly: the rest of the burst must still come out.
	total += w.update(t, true)
	for i in 10:
		t += w.def.burst_interval_s
		total += w.update(t, false)
	assert_eq(total, w.def.burst_count, "burst size")


func test_reload_refills_from_reserve() -> void:
	var w := _weapon("sagittarii_rifle")
	w.update(0.0, true)
	var reserve_before := w.reserve
	assert_true(w.start_reload(1.0), "reload started")
	assert_eq(w.update(1.0 + w.def.reload_s * 0.5, false), 0, "no shots while reloading")
	assert_true(w.reloading, "still reloading")
	w.update(1.0 + w.def.reload_s, false)
	assert_true(not w.reloading, "reload done")
	assert_eq(w.ammo_in_mag, w.def.magazine, "mag full")
	assert_eq(w.reserve, reserve_before - 1, "reserve decreased by one round")


func test_swap_switches_active_slot() -> void:
	var l := _Loadout.from_class("hastati", _Registry.new())
	assert_eq(l.get_active().def.id, "pilum_br", "starts on primary")
	assert_true(l.swap(), "swap succeeded")
	assert_eq(l.get_active().def.id, "gladius_lux", "now secondary")
	assert_true(l.swap(), "swap back (empty sidearm skipped)")
	assert_eq(l.get_active().def.id, "pilum_br", "back on primary")


func test_loadout_from_data_for_hastati_and_sagittarii() -> void:
	for cid in ["hastati", "sagittarii"]:
		var l := _Loadout.from_class(cid, _Registry.new())
		assert_true(l.slots[0] != null and l.slots[1] != null, cid + " has two weapons")
		assert_true(l.slots[2] == null, cid + " sidearm empty")


func test_hitscan_damages_dummy() -> void:
	var scene: Node = _Range.instantiate()
	var root: SceneTree = Engine.get_main_loop()
	root.root.add_child(scene)
	for i in 3:
		await root.physics_frame
	var player: Pawn = scene.get_node("Player")
	var dummy: Pawn = scene.get_node("Dummy")
	var before: float = dummy.bridge.state.shield
	var res := player.fire_shot()
	assert_true(not res.is_empty(), "ray hit something")
	assert_true(dummy.bridge.state.shield < before, "dummy shield dropped")
	scene.queue_free()
