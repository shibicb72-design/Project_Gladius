class_name GraphicsPresets
extends RefCounted
## Data-driven graphics quality presets (data/graphics_presets.json).

const PATH := "res://data/graphics_presets.json"
## Tools only (tools/frame_time.gd switches single effects off to time them): keys here replace the preset's
## for every get_preset() call in this process. Empty in the game and in the tests.
static var overrides: Dictionary = {}


## Returns the preset dictionary for `preset_id` (empty id = the file's default); {} if unknown.
func get_preset(preset_id: String = "") -> Dictionary:
	var cfg := DataRegistry.new().load_file(PATH)
	var id := preset_id if not preset_id.is_empty() else str(cfg.get("default", "default"))
	var preset: Dictionary = Dictionary(cfg.get("presets", {})).get(id, {})
	return preset if overrides.is_empty() or preset.is_empty() else preset.merged(overrides, true)


## The renderer the data expects the project to be set to ("mobile" or "forward_plus"; OQ-GFX-RENDERER).
func renderer_expected() -> String:
	return str(DataRegistry.new().load_file(PATH).get("renderer_expected", "mobile"))


## Applies a preset to the engine and, when given, a viewport. Returns the applied preset.
func apply(preset_id: String = "", viewport: Viewport = null) -> Dictionary:
	var p := get_preset(preset_id)
	if p.is_empty():
		return p
	Engine.max_fps = int(p.get("max_fps", 60))
	if viewport != null:
		viewport.scaling_3d_scale = float(p.get("scale_3d", 1.0))
		match int(p.get("msaa_3d", 0)):
			2: viewport.msaa_3d = Viewport.MSAA_2X
			4: viewport.msaa_3d = Viewport.MSAA_4X
			8: viewport.msaa_3d = Viewport.MSAA_8X
			_: viewport.msaa_3d = Viewport.MSAA_DISABLED
	return p
