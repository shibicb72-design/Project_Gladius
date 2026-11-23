extends "res://tests/test_case.gd"
## M2U1 boot screen: the logo over the dusk backdrop, a data-driven bounded hold, and exactly one trip to the menu.

const BOOT_SCENE := "res://scenes/boot/boot.tscn"
const MENU_PROFILE_PATH := "user://test_boot_profile.json"


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _frames(n: int) -> void:
	for i: int in n:
		await _tree().process_frame


func test_boot_hold_comes_from_data_and_is_bounded() -> void:
	assert_eq(Boot.hold_seconds(), 0.0, "no hold when headless")
	var boot_cfg: Dictionary = MenuStyle.cfg().get("boot", {})
	var raw: Variant = boot_cfg.get("hold_s")
	assert_true(raw is float or raw is int, "menu_style.boot.hold_s is a number")
	assert_true(float(raw) >= 0.0 and float(raw) <= Boot.MAX_HOLD_S, "data hold within 0 .. 3")
	var fade := Boot.logo_fade_seconds()
	assert_true(fade >= 0.0 and fade <= Boot.MAX_FADE_S, "logo fade within 0 .. 2")
	assert_eq(Boot.clamp_hold(99.0), 3.0, "a huge hold is capped")
	assert_eq(Boot.clamp_hold(-1.0), 0.0, "a negative hold is floored")


## Stages the boot scene with a counting navigate; returns [boot, counter array].
func _stage(auto: bool) -> Array:
	var count: Array[int] = [0]
	var boot: Boot = load(BOOT_SCENE).instantiate()
	boot.auto_advance = auto
	boot.navigate = func() -> void: count[0] += 1
	_tree().root.add_child(boot)
	return [boot, count]


## W1a: Boot applies the graphics preset (GraphicsPresets.apply_settings); these are the engine values and statics it
## may change beyond fps, 3D scale and MSAA. Returns them for _restore_gfx.
func _save_gfx() -> Dictionary:
	var vp := _tree().root
	return {"aniso": vp.anisotropic_filtering_level, "vsync": DisplayServer.window_get_vsync_mode()}


func _restore_gfx(saved: Dictionary) -> void:
	_tree().root.anisotropic_filtering_level = saved["aniso"]
	DisplayServer.window_set_vsync_mode(saved["vsync"])
	RenderingServer.directional_shadow_atlas_set_size(GraphicsPresets.project_shadow_atlas_size(), GraphicsPresets.project_shadow_atlas_16_bits())
	GraphicsPresets.active_id = ""
	GraphicsPresets.applied = {}


func test_boot_shows_the_logo_and_goes_to_the_menu_once() -> void:
	var saved_profile: Dictionary = AppFlow.profile.duplicate(true)
	var saved_fps := Engine.max_fps
	var vp := _tree().root
	var saved_scale := vp.scaling_3d_scale
	var saved_msaa := vp.msaa_3d
	var saved_gfx := _save_gfx()
	AppFlow.profile = {}
	var staged := _stage(false)
	var boot: Boot = staged[0]
	var count: Array[int] = staged[1]
	await _frames(3)
	assert_true(boot.logo != null, "boot has a logo")
	assert_true(boot.logo.get_font_px() > 0.0, "logo has a font size")
	var visible := vp.get_visible_rect()
	var lr := boot.logo.get_global_rect()
	assert_true(lr.size.x > 0.0 and lr.size.y > 0.0, "logo has a size")
	assert_true(visible.encloses(lr), "logo inside the visible rect (%s in %s)" % [lr, visible])
	assert_true(not AppFlow.profile.is_empty(), "boot loaded the profile")
	assert_eq(count[0], 0, "no auto advance when auto_advance is false")
	# The logo sits exactly where the main menu shows it, so the cut from boot to menu does not move it.
	var menu: MainMenu = load("res://scenes/ui/main_menu.tscn").instantiate()
	menu.save = SaveService.new(MENU_PROFILE_PATH)
	vp.add_child(menu)
	await _frames(3)
	var mr := menu.logo.get_global_rect()
	lr = boot.logo.get_global_rect()
	assert_true(lr.position.distance_to(mr.position) <= 1.0, "boot logo position %s matches menu %s" % [lr.position, mr.position])
	assert_true(absf(lr.size.x - mr.size.x) <= 1.0 and absf(lr.size.y - mr.size.y) <= 1.0,
			"boot logo size %s matches menu %s" % [lr.size, mr.size])
	assert_eq(boot.logo.get_font_px(), menu.logo.get_font_px(), "boot and menu logo font sizes match")
	menu.queue_free()
	await _frames(1)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(MENU_PROFILE_PATH))
	boot.go_to_menu()
	boot.go_to_menu()
	assert_eq(count[0], 1, "go_to_menu navigates exactly once")
	boot.queue_free()
	await _frames(1)
	AppFlow.profile = saved_profile
	Engine.max_fps = saved_fps
	vp.scaling_3d_scale = saved_scale
	vp.msaa_3d = saved_msaa
	_restore_gfx(saved_gfx)


func test_boot_auto_advances_after_the_hold() -> void:
	var saved_profile: Dictionary = AppFlow.profile.duplicate(true)
	var saved_fps := Engine.max_fps
	var vp := _tree().root
	var saved_scale := vp.scaling_3d_scale
	var saved_msaa := vp.msaa_3d
	var saved_gfx := _save_gfx()
	var staged := _stage(true)
	var boot: Boot = staged[0]
	var count: Array[int] = staged[1]
	await _frames(4)
	assert_eq(count[0], 1, "auto advance after the (headless 0 s) hold")
	await _frames(4)
	assert_eq(count[0], 1, "still exactly once")
	boot.queue_free()
	await _frames(1)
	AppFlow.profile = saved_profile
	Engine.max_fps = saved_fps
	vp.scaling_3d_scale = saved_scale
	vp.msaa_3d = saved_msaa
	_restore_gfx(saved_gfx)
