extends "res://tests/test_case.gd"
## Shibi's decisions of 2026-10-22 (OQ batch 1): package id, orientation, class toggle, loadouts, gyro.

const _TMP := "user://test_profile_batch1.json"


func _remove_tmp() -> void:
	if FileAccess.file_exists(_TMP):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_TMP))


func _preset_option(key: String) -> String:
	var cfg := ConfigFile.new()
	if cfg.load("res://export_presets.cfg") != OK:
		return ""
	return str(cfg.get_value("preset.0.options", key, ""))


func test_package_id_and_launcher_name() -> void:
	assert_eq(_preset_option("package/unique_name"), "com.shibibabu.gladius", "package id")
	assert_eq(_preset_option("package/name"), "Project Gladius", "launcher name in preset")
	assert_eq(str(ProjectSettings.get_setting("application/config/name")), "Project Gladius", "project name")


func test_orientation_is_sensor_landscape() -> void:
	assert_eq(int(ProjectSettings.get_setting("display/window/handheld/orientation")), DisplayServer.SCREEN_SENSOR_LANDSCAPE,
			"sensor landscape")


func test_lobby_class_toggle_and_spawned_loadout() -> void:
	var lobby := LobbyState.new()
	lobby.setup(2, 3)
	assert_true(lobby.add_human(7, "Marcus"), "add human")
	assert_eq(str(lobby.humans[0]["class_id"]), "hastati", "default class")
	assert_true(lobby.set_class(7, "sagittarii"), "toggle to sagittarii")
	var slot: Dictionary = lobby.assign()[0]
	assert_eq(str(slot["class_id"]), "sagittarii", "slot class follows toggle")
	var pawn := Pawn.new()
	pawn.setup(str(slot["class_id"]), int(slot["squad_id"]))
	assert_eq(pawn.loadout.slots[0].def.id, "sagittarii_rifle", "spawned primary")
	assert_eq(pawn.loadout.slots[1].def.id, "gladius_lux", "spawned secondary")
	assert_true(lobby.set_class(7, "hastati"), "toggle back")
	pawn.setup(str(lobby.assign()[0]["class_id"]), 0)
	assert_eq(pawn.loadout.slots[0].def.id, "pilum_br", "hastati primary")
	assert_eq(pawn.loadout.slots[1].def.id, "gladius_lux", "hastati secondary")
	pawn.free()


func test_sagittarii_rifle_data() -> void:
	var reg := DataRegistry.new()
	var l := Loadout.from_class("sagittarii", reg)
	assert_true(l.slots[0] != null and l.slots[0].def.id == "sagittarii_rifle", "rifle in loadout")
	var d := reg.get_weapon_def("sagittarii_rifle")
	assert_true(d != null and d.kind == "hitscan" and d.burst_count == 1 and d.is_placeholder, "single-shot hitscan placeholder")
	assert_true(bool(reg.get_movement_cfg().get("jump_enabled", false)), "jump stays in")
	assert_eq(int(reg.load_file("res://data/match.json").get("squads", 0)), 2, "2 squads")


## Test double: pretends the device has a gyro and reports a fixed rate.
class FakeGyroPlatform extends PlatformServices:
	func has_gyro() -> bool:
		return true

	func get_gyro_rate() -> Vector3:
		return Vector3(0.5, 0.25, 0.0)


func test_gyro_sensor_enabled_in_project() -> void:
	assert_eq(ProjectSettings.get_setting("input_devices/sensors/enable_gyroscope"), true, "engine gyro sensor on")


func test_gyro_sensitivity_from_data() -> void:
	var cfg: Dictionary = DataRegistry.new().load_file("res://data/input.json")
	assert_true(cfg.has("gyro") and cfg["gyro"].has("sensitivity"), "gyro.sensitivity in input.json")
	assert_true(not cfg.has("gyro_mode"), "no dead gyro_mode in input.json")
	var g := GyroProvider.new()
	g.configure({"gyro_mode": "on", "sensitivity": 2.5})
	assert_eq(g.sensitivity, 2.5, "sensitivity applied from config")


func test_gyro_off_by_default_ignores_injected_reading() -> void:
	var p := SaveService.new("user://test_profile_batch1_off.json").load_profile()
	var g := GyroProvider.new()
	g.configure({"gyro_mode": SaveService.gyro_mode(p)})
	g._platform = FakeGyroPlatform.new()
	assert_eq(g.get_look(), Vector2.ZERO, "off by default: provider returns zero despite fake gyro")
	var router := InputRouter.new()
	router.add_provider(g)
	assert_eq(router.update_frame().look, Vector2.ZERO, "router adds no gyro look while off")
	# Sanity: the fake reading really would flow if the profile toggle were on.
	g.configure({"gyro_mode": "on"})
	assert_eq(g.get_look(), Vector2(0.25, 0.5), "fake reading flows when toggled on")
	router.free()


func test_gyro_default_off_and_toggle_persists() -> void:
	_remove_tmp()
	var svc := SaveService.new(_TMP)
	var p := svc.load_profile()
	assert_eq(p["gyro_enabled"], false, "gyro default off")
	assert_eq(SaveService.gyro_mode(p), "off", "gyro mode off by default")
	var g := GyroProvider.new()
	g.configure({"gyro_mode": SaveService.gyro_mode(p)})
	assert_true(not g.enabled, "provider off by default")
	var menu: MainMenu = load("res://scenes/ui/main_menu.tscn").instantiate()
	(Engine.get_main_loop() as SceneTree).root.add_child(menu)
	menu.save = svc
	menu.toggle_gyro()
	assert_eq(menu.gyro_button.text, "Gyro aim: On", "button text")
	var reloaded := SaveService.new(_TMP).load_profile()
	assert_eq(reloaded["gyro_enabled"], true, "gyro persisted on")
	assert_eq(SaveService.gyro_mode(reloaded), "on", "mode on")
	menu.toggle_gyro()
	assert_eq(SaveService.new(_TMP).load_profile()["gyro_enabled"], false, "gyro persisted off")
	menu.free()
	AppFlow.profile = {}
	_remove_tmp()
