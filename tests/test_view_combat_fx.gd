extends "res://tests/test_case.gd"
## M2 AN1 commit 5: combat feedback, presentation only. The first-person muzzle flash rides the gun's muzzle (it follows
## when the view turns); the muzzle light is one shadowless OmniLight3D that exists only on the local player's view
## model and is lit only with the flash; the view-model budget (data/art_soldier.json) holds with the flash and light
## counted; impact bursts are classified by surface (ShotImpacts) and capped (fx.impact_cap); the reload drops a spent
## cell that falls away and is freed.

const DT := 1.0 / 60.0
const _RigScene := preload("res://scenes/player/camera_rig.tscn")
const _PawnScene := preload("res://scenes/player/pawn.tscn")

var _root: Node3D
var _pawn: Pawn
var _rig: CameraRig


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _vm_f(key: String) -> float:
	return float(DataRegistry.new().get_camera_cfg()["first_person"]["view_model"][key]["value"])


func _frames(n: int) -> void:
	for i in n:
		await _tree().physics_frame


func _box(at: Vector3, size: Vector3, body: PhysicsBody3D = null) -> PhysicsBody3D:
	var b := body if body != null else StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	b.add_child(shape)
	b.position = at
	_root.add_child(b)
	return b


## Floor, a wall 6 m ahead to shoot at, a local pawn (no Brain) with its rig.
func _fixture() -> void:
	_root = Node3D.new()
	_tree().root.add_child(_root)
	_box(Vector3(0, -0.1, 0), Vector3(30, 0.2, 30))
	_box(Vector3(0, 1.5, -6.0), Vector3(8, 3, 0.5))
	_pawn = _PawnScene.instantiate()
	_root.add_child(_pawn)
	_pawn.set_physics_process(false)
	_rig = _RigScene.instantiate()
	_rig.name = "CameraRig"
	_pawn.add_child(_rig)
	await _frames(ceili(_vm_f("swap_s") / DT) + 6)


func _cleanup() -> void:
	_root.queue_free()
	_root = null
	await _tree().process_frame


func _gun_vm() -> ViewModel:
	var vm := _rig.get_view_model()
	for i in 3:
		if vm != null and vm.get_shown_weapon() != null and vm.get_shown_weapon().has_node("Muzzle"):
			break
		_pawn.loadout.swap()
		_pawn.weapon_switched.emit(_pawn.loadout.active)
		await _frames(ceili(_vm_f("swap_s") / DT) + 4)
		vm = _rig.get_view_model()
	return vm


func test_flash_rides_the_muzzle_and_follows_a_view_turn() -> void:
	await _fixture()
	var vm := await _gun_vm()
	assert_true(vm != null and vm.get_shown_weapon().has_node("Muzzle"), "a gun is shown")
	var muzzle := vm.get_shown_weapon().get_node("Muzzle") as Node3D
	_pawn.fire_shot()
	await _frames(1)
	assert_true(vm.is_flash_visible(), "flash shown on the shot")
	assert_true(vm.flash.get_parent() == muzzle, "the flash is parented to the shown gun's muzzle")
	assert_true(vm.flash.global_position.distance_to(muzzle.global_position) < 0.001, "flash at the muzzle")
	var before := vm.flash.global_position
	_pawn.rotation.y += 0.6  # the view turns
	_pawn.pitch = 0.3
	await _frames(1)
	assert_true(vm.flash.global_position.distance_to(muzzle.global_position) < 0.001, "the flash follows the muzzle after the turn")
	assert_true(vm.flash.global_position.distance_to(before) > 0.01, "and the muzzle really moved (%.4f m)" % vm.flash.global_position.distance_to(before))
	# Every shot rolls the burst differently (random roll), and it is not a flat star: it has depth along the barrel.
	var aabb := vm.flash.mesh.get_aabb()
	assert_true(aabb.size.z > 0.01 and aabb.size.x > 0.01 and aabb.size.y > 0.01, "the burst is a 3D cone, not a flat star (%s)" % aabb.size)
	await _frames(ceili(_vm_f("flash_s") / DT) + 2)
	assert_true(not vm.is_flash_visible() and not vm.is_muzzle_light_on(), "flash and light expire")
	# A weapon switch parks the flash off the old gun.
	_pawn.loadout.swap()
	_pawn.weapon_switched.emit(_pawn.loadout.active)
	await _frames(ceili(_vm_f("swap_s") / DT) + 4)
	assert_true(vm.flash.get_parent() == vm or vm.flash.get_parent() == vm.get_shown_weapon().get_node_or_null("Muzzle"), "the flash left the hidden gun")
	await _cleanup()


func test_muzzle_light_is_shadowless_local_only_and_lit_with_the_flash() -> void:
	await _fixture()
	var vm := await _gun_vm()
	var light := vm.get_muzzle_light()
	assert_true(light != null and light is OmniLight3D, "an OmniLight3D muzzle light")
	assert_true(not light.shadow_enabled, "shadows off")
	assert_true(not vm.is_muzzle_light_on(), "dark before a shot")
	_pawn.fire_shot()
	await _frames(1)
	assert_true(vm.is_muzzle_light_on(), "lit with the flash")
	assert_eq(_root.find_children("*", "OmniLight3D", true, false).size(), 1, "one muzzle light in the scene (the local view model's)")
	# A pawn with a Brain (a bot) gets no view model, so no muzzle light.
	var bot: Pawn = _PawnScene.instantiate()
	var brain := Node.new()
	brain.name = "Brain"
	bot.add_child(brain)
	bot.position = Vector3(3, 0, 0)
	_root.add_child(bot)
	bot.set_physics_process(false)
	var bot_rig: CameraRig = _RigScene.instantiate()
	bot_rig.name = "CameraRig"
	bot.add_child(bot_rig)
	await _frames(4)
	assert_true(ViewModel.attach(bot_rig) == null, "no view model for a bot")
	bot.fire_shot()
	await _frames(1)
	assert_eq(bot.find_children("*", "OmniLight3D", true, false).size(), 0, "the bot's shot makes no light")
	await _cleanup()


func test_budget_holds_with_the_flash_and_light_counted() -> void:
	await _fixture()
	var vm := await _gun_vm()
	var art := ViewMesh.config()["budget"] as Dictionary
	for i in 2:
		vm.hold_muzzle_flash(true)
		await _frames(1)
		var tris := vm.view_triangle_count()
		var calls := vm.view_draw_calls()
		print("FP FX BUDGET %s flash+light triangles=%d draw_calls=%d (max %d / %d)" % [vm.get_shown_weapon_id(), tris, calls, int(art["max_triangles"]), int(art["max_draw_calls"])])
		assert_true(vm.is_muzzle_light_on(), "light held on")
		assert_true(tris <= int(art["max_triangles"]) and calls <= int(art["max_draw_calls"]), "%s with flash and light: %d tris / %d calls" % [vm.get_shown_weapon_id(), tris, calls])
		vm.hold_muzzle_flash(false)
		_pawn.setup("sagittarii", 0)
		await _frames(ceili(_vm_f("swap_s") / DT) + 6)
		vm = await _gun_vm()
	await _cleanup()


func test_impacts_by_surface_and_capped() -> void:
	await _fixture()
	var pool := ShotImpacts.for_node(_pawn.shot_fx)
	assert_true(pool != null and pool.get_parent() == _root, "one pool beside the pawns")
	assert_true(ShotImpacts.for_node(_pawn.shot_fx) == pool, "shared, not one per shot")
	var by: Dictionary = (ViewMesh.config()["fx"] as Dictionary)["impact_by_material"]
	var ground := _box(Vector3(10, 0.5, 0), Vector3(1, 1, 1))
	ground.name = "Ground"
	var standard := _box(Vector3(-10, 0.5, 0), Vector3(1, 1, 1))
	standard.set_meta(&"structure_type", "eagle_standard")  # metal (data/audio.json impacts)
	var soldier := _box(Vector3(0, 0.5, 10), Vector3(1, 1, 1), CharacterBody3D.new())
	await _frames(2)
	var world := _root.get_world_3d()
	assert_eq(String(pool.classify(world, Vector3(10, 0.5, 5), Vector3(10, 0.5, 0.5))["kind"]), String(by["ground"]), "the ground: dust")
	assert_eq(String(pool.classify(world, Vector3(-10, 0.5, 5), Vector3(-10, 0.5, 0.5))["kind"]), String(by["metal"]), "metal: sparks")
	assert_eq(String(pool.classify(world, Vector3(0, 0.5, 5), Vector3(0, 0.5, 9.5))["kind"]), String(by["soldier"]), "a soldier: energy splash")
	assert_true(String(by["soldier"]) != String(by["metal"]) and String(by["ground"]) != String(by["metal"]), "three distinct looks")
	# 18 players firing: never more than the cap alive, never more nodes than the cap.
	var cap := pool.cap()
	for i in 60:
		pool.spawn(["sparks", "dust", "energy"][i % 3], Vector3(i * 0.1, 1, 0), Vector3.UP)
	print("FP FX IMPACTS cap=%d alive=%d pool=%d" % [cap, pool.alive_count(), pool.pool_size()])
	assert_true(pool.alive_count() <= cap and pool.pool_size() <= cap, "at most %d bursts alive (%d) and pooled (%d)" % [cap, pool.alive_count(), pool.pool_size()])
	assert_true(cap == int((ViewMesh.config()["fx"] as Dictionary)["impact_cap"]), "the cap is data")
	# A real shot at the wall still shows ShotFx's impact at the end point and starts a burst.
	var res := _pawn.fire_shot()
	assert_true(res.has("position") and _pawn.shot_fx.is_impact_visible(), "a shot shows its impact")
	await _cleanup()


func test_reload_drops_a_spent_cell_that_falls_and_goes() -> void:
	await _fixture()
	var vm := await _gun_vm()
	_pawn.reload_started.emit()
	var seen := false  # a flag: the cell node is freed later, and a freed object compares equal to null
	var start := Vector3.ZERO
	var lowest := INF
	for i in ceili(_pawn.loadout.get_active().def.reload_s / DT) + 2:
		await _frames(1)
		var s := vm.get_spent_cell()
		if s != null and not seen:
			seen = true
			start = s.global_position
		if s != null:
			lowest = minf(lowest, s.global_position.y)
	assert_true(seen, "a spent cell dropped during the reload")
	assert_true(lowest < start.y - 0.01, "it falls (%.3f below)" % (start.y - lowest))
	await _frames(ceili(float((ViewMesh.config()["fx"] as Dictionary)["spent_cell"]["life_s"]) / DT) + 4)
	assert_true(vm.get_spent_cell() == null, "and is gone after its life")
	await _cleanup()
