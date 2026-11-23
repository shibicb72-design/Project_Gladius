extends "res://tests/test_case.gd"

const PROFILE_PATH := "user://a2_test_armour_profile.json"


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func test_armour_profile_validation_and_haptics_save() -> void:
	var previous := AppFlow.profile
	var save := SaveService.new(PROFILE_PATH)
	assert_eq(SaveService.defaults()["armour_set"], "legionary", "default is Legionary")
	for invalid: Variant in ["unknown_set", 72, null]:
		var raw := SaveService.defaults()
		if invalid == null:
			raw.erase("armour_set")
		else:
			raw["armour_set"] = invalid
		var file := FileAccess.open(PROFILE_PATH, FileAccess.WRITE)
		file.store_string(JSON.stringify(raw))
		file.close()
		assert_eq(save.load_profile()["armour_set"], "legionary", "invalid profile entry falls back to Legionary")
	var panel := SettingsPanel.new()
	panel.save = save
	_tree().root.add_child(panel)
	assert_eq(panel.armour_button.text, "Armour: Legionary", "settings starts at the stored set")
	panel.armour_button.pressed.emit()
	assert_eq(panel.armour_button.text, "Armour: Murmillo", "button cycles its label")
	assert_eq(save.load_profile()["armour_set"], "murmillo", "the selection survives a fresh load")
	var haptics := load("res://scenes/ui/haptics_screen.tscn").instantiate() as HapticsScreen
	haptics.save = save
	haptics.service = HapticsService.new()
	_tree().root.add_child(haptics)
	haptics._persist()
	assert_eq(save.load_profile()["armour_set"], "murmillo", "Haptics save carries the selected set")
	panel.armour_button.pressed.emit()
	assert_eq(save.load_profile()["armour_set"], "legionary", "the wardrobe cycle wraps")
	haptics.free()
	panel.free()
	AppFlow.profile = previous
	DirAccess.remove_absolute(PROFILE_PATH)
