extends "res://tests/test_case.gd"
## G3d: the iOS export preset carries the motion usage string, signing stays empty, Android is untouched.

const PATH := "res://export_presets.cfg"
const SIGNING_KEYS := [
	"application/app_store_team_id",
	"application/code_sign_identity_debug",
	"application/code_sign_identity_release",
	"application/provisioning_profile_uuid_debug",
	"application/provisioning_profile_specifier_debug",
	"application/provisioning_profile_uuid_release",
	"application/provisioning_profile_specifier_release",
]


func _find_preset(cfg: ConfigFile, platform: String) -> String:
	for section in cfg.get_sections():
		if section.begins_with("preset.") and not section.ends_with(".options") \
				and cfg.get_value(section, "platform", "") == platform:
			return section
	return ""


func _load() -> ConfigFile:
	var cfg := ConfigFile.new()
	var err := cfg.load(PATH)
	assert_eq(err, OK, "cannot load " + PATH)
	return cfg


func test_ios_motion_usage_string() -> void:
	var cfg := _load()
	var section := _find_preset(cfg, "iOS")
	assert_true(section != "", "no preset with platform iOS")
	if section == "":
		return
	assert_eq(cfg.get_value(section, "name", ""), "iOS")
	var plist: String = cfg.get_value(section + ".options", "application/additional_plist_content", "")
	var key := "<key>NSMotionUsageDescription</key>"
	var at := plist.find(key)
	assert_true(at >= 0, "plist content lacks NSMotionUsageDescription")
	if at < 0:
		return
	var rest := plist.substr(at + key.length()).strip_edges()
	assert_true(rest.begins_with("<string>"), "key is not followed by a <string>")
	var close := rest.find("</string>")
	assert_true(close > "<string>".length(), "usage <string> is empty or unterminated")


func test_android_preset_still_present() -> void:
	var cfg := _load()
	var section := _find_preset(cfg, "Android")
	assert_true(section != "", "no preset with platform Android")
	if section != "":
		assert_eq(cfg.get_value(section, "name", ""), "Android")


func test_ios_signing_fields_empty() -> void:
	var cfg := _load()
	var section := _find_preset(cfg, "iOS")
	assert_true(section != "", "no preset with platform iOS")
	if section == "":
		return
	for k in SIGNING_KEYS:
		assert_true(cfg.has_section_key(section + ".options", k), "missing key " + k)
		assert_eq(cfg.get_value(section + ".options", k, "x"), "", k + " must be empty")
