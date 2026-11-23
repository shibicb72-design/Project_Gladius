class_name GraphicsPresets
extends RefCounted
## Data-driven graphics quality presets (data/graphics_presets.json).
## W1a: the quality levels are preset ids (Low = "default", Medium = "pc_medium", High = "pc_high"). One preset is
## ACTIVE per process (active_id); get_preset("") returns it, so every reader of the art_* / fx_* switches follows
## the player's choice. Boot picks it (choose_id: the saved graphics_quality on a PC, Auto = data "auto_pc" on a PC,
## "default" anywhere else and in every headless run) and Settings changes it live (apply_settings).

const PATH := "res://data/graphics_presets.json"
## Tools only (tools/frame_time.gd switches single effects off to time them): keys here replace the preset's
## for every get_preset() call in this process. Empty in the game and in the tests.
static var overrides: Dictionary = {}
## W1a: the active preset id; "" = the file's "default" entry (today's preset) until Boot or Settings sets one.
## Tests that change it put it back to "".
static var active_id: String = ""
## W1a: what the last apply() handed the engine for the keys it cannot read back (RenderingServer has no getter
## for the directional shadow atlas size; a headless DisplayServer keeps no vsync mode). Diagnostics and tests.
static var applied: Dictionary = {}

## Viewport.anisotropic_filtering_level for a preset's anisotropic_level (1 = off, 2, 4, 8, 16).
const ANISO_LEVELS := {1: Viewport.ANISOTROPY_DISABLED, 2: Viewport.ANISOTROPY_2X, 4: Viewport.ANISOTROPY_4X,
		8: Viewport.ANISOTROPY_8X, 16: Viewport.ANISOTROPY_16X}


static func config() -> Dictionary:
	return DataRegistry.new().load_file(PATH)


## The id get_preset("") resolves to: active_id, or the file's "default" entry while none is set.
static func resolved_active_id() -> String:
	return active_id if not active_id.is_empty() else str(config().get("default", "default"))


## Returns the preset dictionary for `preset_id` (empty id = the ACTIVE preset); {} if unknown. The active id is
## resolved first, then the static `overrides` are merged on top.
func get_preset(preset_id: String = "") -> Dictionary:
	var cfg := config()
	var id := preset_id if not preset_id.is_empty() else resolved_active_id()
	var preset: Dictionary = Dictionary(cfg.get("presets", {})).get(id, {})
	return preset if overrides.is_empty() or preset.is_empty() else preset.merged(overrides, true)


## The renderer the data expects the project to be set to ("mobile" or "forward_plus"; OQ-GFX-RENDERER).
func renderer_expected() -> String:
	return str(config().get("renderer_expected", "mobile"))


## W1a: the preset ids a saved graphics_quality may name ("" = Auto), from data quality_levels.
static func quality_ids() -> Array:
	var out: Array = []
	for level: Variant in config().get("quality_levels", []):
		if level is Dictionary:
			out.append(str((level as Dictionary).get("id", "")))
	return out


## W1a (OQ-WEB-GFX-AUTO): the preset for a saved quality on this platform. Not a PC (phones, and every headless run,
## see PlatformServices.is_pc): "default", whatever is saved (the Quality row is PC only). A PC: the saved id when it
## names a preset, else Auto = data "auto_pc".
static func choose_id(saved_quality: String, pc: bool) -> String:
	if not pc:
		return "default"
	var cfg := config()
	if not saved_quality.is_empty() and quality_ids().has(saved_quality) and Dictionary(cfg.get("presets", {})).has(saved_quality):
		return saved_quality
	return str(cfg.get("auto_pc", "default"))


## Applies a preset to the engine and, when given, a viewport. Returns the applied preset. LIVE keys only (see data
## _pc_keys_note); shadow_mode and shadow_max_distance_m are read when the next match look is built. The "default"
## preset has none of vsync / directional_shadow_size / anisotropic_level, so applying it touches exactly what it
## touched before W1a; after a PC preset set one of them (recorded in `applied`), a preset without the key puts the
## project's own setting back, so going back to Low undoes High.
func apply(preset_id: String = "", viewport: Viewport = null) -> Dictionary:
	var p := get_preset(preset_id)
	if p.is_empty():
		return p
	Engine.max_fps = int(p.get("max_fps", 60))
	if p.has("vsync"):
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if bool(p["vsync"]) else DisplayServer.VSYNC_DISABLED)
		applied["vsync"] = bool(p["vsync"])
	elif applied.has("vsync"):
		DisplayServer.window_set_vsync_mode(project_vsync_mode())
		applied.erase("vsync")
	if p.has("directional_shadow_size"):
		RenderingServer.directional_shadow_atlas_set_size(int(p["directional_shadow_size"]), project_shadow_atlas_16_bits())
		applied["directional_shadow_size"] = int(p["directional_shadow_size"])
	elif applied.has("directional_shadow_size"):
		RenderingServer.directional_shadow_atlas_set_size(project_shadow_atlas_size(), project_shadow_atlas_16_bits())
		applied.erase("directional_shadow_size")
	if viewport != null:
		viewport.scaling_3d_scale = float(p.get("scale_3d", 1.0))
		match int(p.get("msaa_3d", 0)):
			2: viewport.msaa_3d = Viewport.MSAA_2X
			4: viewport.msaa_3d = Viewport.MSAA_4X
			8: viewport.msaa_3d = Viewport.MSAA_8X
			_: viewport.msaa_3d = Viewport.MSAA_DISABLED
		if p.has("anisotropic_level"):
			viewport.anisotropic_filtering_level = ANISO_LEVELS.get(int(p["anisotropic_level"]), project_anisotropy())
			applied["anisotropic_level"] = int(p["anisotropic_level"])
		elif applied.has("anisotropic_level"):
			viewport.anisotropic_filtering_level = project_anisotropy()
			applied.erase("anisotropic_level")
	return p


## The project's vsync mode (display/window/vsync/vsync_mode: 0 disabled, 1 enabled, 2 adaptive, 3 mailbox).
static func project_vsync_mode() -> DisplayServer.VSyncMode:
	return int(ProjectSettings.get_setting("display/window/vsync/vsync_mode", DisplayServer.VSYNC_ENABLED)) as DisplayServer.VSyncMode


## The project's directional shadow atlas size and depth (what the engine starts with; tests restore these).
static func project_shadow_atlas_size() -> int:
	return int(ProjectSettings.get_setting("rendering/lights_and_shadows/directional_shadow/size", 4096))


static func project_shadow_atlas_16_bits() -> bool:
	return bool(ProjectSettings.get_setting("rendering/lights_and_shadows/directional_shadow/16_bits", true))


## The project's anisotropic filtering level (what a viewport starts with).
static func project_anisotropy() -> Viewport.AnisotropicFiltering:
	return int(ProjectSettings.get_setting("rendering/textures/default_filters/anisotropic_filtering_level", Viewport.ANISOTROPY_4X)) as Viewport.AnisotropicFiltering


## W1a: the player's layer over the applied preset `p` (PC only; Boot and Settings call it through apply_settings):
## frame_cap replaces max_fps (0 = no cap) and render_scale multiplies scale_3d. Both LIVE.
func apply_user_layer(profile: Dictionary, viewport: Viewport, p: Dictionary) -> void:
	Engine.max_fps = SaveService.frame_cap(profile.get("frame_cap", null))
	if viewport != null:
		viewport.scaling_3d_scale = float(p.get("scale_3d", 1.0)) * SaveService.render_scale(profile.get("render_scale", null))


## W1a: picks the active preset for `profile` on this platform (choose_id), applies it and, on a PC, the player's
## layer. Boot calls it at start, Settings after every graphics change. Returns the applied preset.
func apply_settings(profile: Dictionary, viewport: Viewport, pc: bool) -> Dictionary:
	active_id = choose_id(SaveService.graphics_quality(profile.get("graphics_quality", null)), pc)
	var p := apply("", viewport)
	if pc and not p.is_empty():
		apply_user_layer(profile, viewport, p)
	return p
