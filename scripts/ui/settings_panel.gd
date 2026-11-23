class_name SettingsPanel
extends VBoxContainer
## Shared settings UI (gyro, move stick, stick layout, sprint sensitivity), used by the main menu and the
## in-match menu. Every change is written to the profile at once (persist()).

signal changed

var save := SaveService.new()
## Optional: extra profile keys owned by the host screen (main menu: gamertag, last_ip), merged on save.
var extra_fields: Callable = Callable()
const _SensitivityScene := preload("res://scenes/ui/sensitivity_screen.tscn")

var gyro_button: Button
var sensitivity_button: Button
var sensitivity_layer: CanvasLayer
var gyro_mode: String = "off"
var gyro_enabled: bool = false
var move_stick_button: Button
var stick_layout_button: Button
var move_stick_mode: String = "virtual"
var vjoy_layout: String = "floating"
var sprint_label: Label
var sprint_slider: HSlider
const _LayoutScene := preload("res://scenes/ui/layout_editor.tscn")
var layout_button: Button
var layout_layer: CanvasLayer
const _HapticsScene := preload("res://scenes/ui/haptics_screen.tscn")
var haptics_button: Button
var haptics_layer: CanvasLayer
var left_fire_button: Button
var left_fire_enabled: bool = false
var sprint_lock_pos: Array = []  # kept so saving does not drop the layout editor's value
## M2 H1a: the touch shooting mode ("advanced" | "simple", data/input.json shooting, OQ-SHOOT-MODE).
var shooting_mode_button: Button
var shooting_mode: String = "advanced"
## M2 H1b (OQ-MINIMAP): the small minimap turns with the heading (true, default) or stays north up.
var minimap_button: Button
var minimap_rotate: bool = true
## M2 H1b commit 5 (OQ-COACH): "Replay the coach" sets the profile's coach_done false, so the next real match shows the
## first-play coach again. A coach running in this match is not restarted (it shows on the next match).
var coach_button: Button
## W1a: the GRAPHICS rows (PC only: built when PlatformServices.is_pc(), so phones and headless runs have none).
## Quality (Auto / Low / Medium / High) and Frame cap (60 / 120) show; Field of view, Render scale and the 144 /
## Unlimited caps are built but hidden unless data/graphics_presets.json show_advanced_graphics (OQ-WEB-GFX-ADVANCED).
## Every change is saved and applied at once (GraphicsPresets.apply_settings; the shadow keys on the next match).
var graphics_built: bool = false
var quality_button: Button
var frame_cap_button: Button
var fov_button: Button
var render_scale_label: Label
var render_scale_slider: HSlider
var graphics_quality: String = ""
var frame_cap: int = SaveService.FRAME_CAP_DEFAULT
var fov: Variant = ""
var render_scale: float = 1.0


func _ready() -> void:
	var profile := save.load_profile()
	gyro_mode = SensitivitySettings.from_profile(profile).gyro_mode
	gyro_enabled = gyro_mode != "off"
	MenuStyle.gap(self, 1.25)
	# G2d: the Sensitivity screen owns the gyro mode, tables and inversion; this quick toggle (Off <-> Always)
	# is kept because tests/test_decisions_batch1.gd and tests/test_pause_menu.gd still pin it.
	add_child(MenuStyle.caption("AIM"))
	sensitivity_button = _button("Sensitivity", open_sensitivity, "crosshair")
	gyro_button = _button("", toggle_gyro, "gyro")
	_refresh_gyro_text()
	add_child(MenuStyle.caption("MOVEMENT"))
	var input_cfg: Dictionary = DataRegistry.new().load_file("res://data/input.json")["touch_layout"]
	move_stick_mode = str(profile["move_stick"]) if str(profile["move_stick"]) != "" else str(input_cfg["move_stick"])
	vjoy_layout = str(profile["vjoy_layout"]) if str(profile["vjoy_layout"]) != "" else str(input_cfg["vjoy_layout"])
	move_stick_button = _button("", toggle_move_stick, "stick")  # Settings: Virtual / Custom move stick
	stick_layout_button = _button("", toggle_stick_layout, "stick")  # Settings: Floating / Fixed (virtual stick)
	_refresh_stick_text()
	sprint_lock_pos = profile["sprint_lock_pos"]
	_build_sprint_slider(float(profile["sprint_sensitivity"]))
	add_child(MenuStyle.caption("LAYOUT"))
	left_fire_enabled = bool(profile["left_fire_enabled"])
	left_fire_button = _button("", toggle_left_fire, "target")  # G3e
	_refresh_left_fire_text()
	shooting_mode = SaveService.shooting_mode(profile.get("shooting_mode", null))
	shooting_mode_button = _button("", toggle_shooting_mode, "target")  # M2 H1a: Advanced / Simple (touch)
	_refresh_shooting_mode_text()
	minimap_rotate = SaveService.minimap_rotate(profile.get("minimap_rotate", null))
	minimap_button = _button("", toggle_minimap_rotate, "layout")  # M2 H1b: Minimap: Rotates / North up
	_refresh_minimap_text()
	layout_button = _button("HUD layout", open_layout_editor, "layout")  # G2e
	coach_button = _button("", replay_coach, "target")  # M2 H1b commit 5: Replay the coach
	_refresh_coach_text(SaveService.coach_done(profile.get("coach_done", null)))
	add_child(MenuStyle.caption("VIBRATION"))
	haptics_button = _button("Haptics", open_haptics, "vibrate")  # G2f
	if PlatformServices.new().is_pc():
		_build_graphics(profile)
	UiScale.apply_to(self)


## W1a: the GRAPHICS caption and rows (see graphics_built).
func _build_graphics(profile: Dictionary) -> void:
	graphics_built = true
	graphics_quality = SaveService.graphics_quality(profile.get("graphics_quality", null))
	frame_cap = SaveService.frame_cap(profile.get("frame_cap", null))
	fov = SaveService.fov(profile.get("fov", null))
	render_scale = SaveService.render_scale(profile.get("render_scale", null))
	var advanced := show_advanced_graphics()
	add_child(MenuStyle.caption("GRAPHICS"))
	quality_button = _button("", cycle_quality, "gear")
	frame_cap_button = _button("", cycle_frame_cap, "gear")
	fov_button = _button("", cycle_fov, "crosshair")
	fov_button.visible = advanced
	var r: Dictionary = GraphicsPresets.config().get("render_scale", {})
	render_scale_label = Label.new()
	render_scale_label.visible = advanced
	add_child(render_scale_label)
	render_scale_slider = HSlider.new()
	render_scale_slider.min_value = float(r.get("min", 0.5))
	render_scale_slider.max_value = float(r.get("max", 1.0))
	render_scale_slider.step = float(r.get("step", 0.05))
	render_scale_slider.custom_minimum_size = Vector2(0, 48.0 * PlatformServices.new().get_dp_scale())
	render_scale_slider.value = render_scale
	render_scale_slider.visible = advanced
	render_scale_slider.value_changed.connect(_on_render_scale_changed)
	add_child(render_scale_slider)
	_refresh_graphics_text()


## W1a (OQ-WEB-GFX-ADVANCED): data/graphics_presets.json show_advanced_graphics.
static func show_advanced_graphics() -> bool:
	return GraphicsPresets.config().get("show_advanced_graphics", false) == true


## The frame caps the row cycles through: data frame_caps, plus advanced_frame_caps when the advanced rows show.
static func frame_cap_choices() -> Array:
	var cfg := GraphicsPresets.config()
	var out: Array = []
	for cap: Variant in Array(cfg.get("frame_caps", [])) + (Array(cfg.get("advanced_frame_caps", [])) if show_advanced_graphics() else []):
		out.append(int(cap))
	return out


## The Field of view row's choices: "" (Auto), then data/camera.json fov_setting min_deg .. max_deg by step_deg.
static func fov_choices() -> Array:
	var r: Dictionary = DataRegistry.new().get_camera_cfg().get("fov_setting", {})
	var out: Array = [""]
	var v := float(r.get("min_deg", 60.0))
	while v <= float(r.get("max_deg", 95.0)) + 0.001:
		out.append(v)
		v += maxf(float(r.get("step_deg", 5.0)), 1.0)
	return out


## Quality: Auto -> Low -> Medium -> High -> Auto (data quality_levels).
func cycle_quality() -> void:
	var ids := GraphicsPresets.quality_ids()
	graphics_quality = str(ids[(ids.find(graphics_quality) + 1) % ids.size()])
	_graphics_changed()


func cycle_frame_cap() -> void:
	var caps := frame_cap_choices()
	frame_cap = int(caps[(caps.find(frame_cap) + 1) % caps.size()])
	_graphics_changed()


func cycle_fov() -> void:
	var choices := fov_choices()
	var at := -1
	for i in choices.size():
		if (choices[i] is String and fov is String) or (choices[i] is float and fov is float and is_equal_approx(choices[i], fov)):
			at = i
	fov = choices[(at + 1) % choices.size()]
	_graphics_changed()


func _on_render_scale_changed(v: float) -> void:
	render_scale = v
	_graphics_changed()


## Saves, then applies at once: the preset, frame cap and render scale (GraphicsPresets.apply_settings) and the
## Field of view on every live camera rig (CameraRig.GROUP).
func _graphics_changed() -> void:
	_refresh_graphics_text()
	persist()
	GraphicsPresets.new().apply_settings(AppFlow.profile, get_viewport(), true)
	if is_inside_tree():
		get_tree().call_group(CameraRig.GROUP, "apply_fov")


func _refresh_graphics_text() -> void:
	var label := "Auto"
	for level: Variant in GraphicsPresets.config().get("quality_levels", []):
		if level is Dictionary and str((level as Dictionary).get("id", "")) == graphics_quality:
			label = str((level as Dictionary).get("label", label))
	quality_button.text = "Quality: %s" % label
	frame_cap_button.text = "Frame cap: %s" % ("Unlimited" if frame_cap == 0 else "%d fps" % frame_cap)
	fov_button.text = "Field of view: %s" % ("Auto" if fov is String else "%d" % roundi(float(fov)))
	render_scale_label.text = "Render scale: %d%%" % roundi(render_scale * 100.0)


## A list row with its icon (docs/UI_STYLE.md 8).
func _button(text: String, handler: Callable, icon: String) -> Button:
	var b := Button.new()
	b.text = text
	b.mouse_filter = Control.MOUSE_FILTER_PASS  # both host menus scroll this panel: STOP would swallow touch drags
	b.pressed.connect(handler)
	MenuStyle.row(b)
	MenuStyle.add_icon(b, icon)
	add_child(b)
	return b


## Quick toggle: any gyro mode goes to off, off goes to always_on. Reads the stored sensitivity first so a
## change made on the Sensitivity screen is not overwritten.
func toggle_gyro() -> void:
	var s := SensitivitySettings.from_profile(save.load_profile())
	s.set_gyro_mode("off" if s.gyro_mode != "off" else "always_on")
	gyro_mode = s.gyro_mode
	gyro_enabled = gyro_mode != "off"
	_refresh_gyro_text()
	var profile := save.load_profile()
	profile["sensitivity"] = s.to_dict()
	save.save_profile(profile)
	persist()


func _refresh_gyro_text() -> void:
	var names := {"off": "Off", "scope_on": "ADS", "always_on": "On"}
	gyro_button.text = "Gyro aim: %s" % names[gyro_mode]


## Opens the Sensitivity screen on top of everything (own CanvasLayer, so it works in the menu and in a match).
func open_sensitivity() -> void:
	if sensitivity_layer != null:
		return
	sensitivity_layer = CanvasLayer.new()
	sensitivity_layer.layer = 100
	sensitivity_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	var screen: SensitivityScreen = _SensitivityScene.instantiate()
	screen.save = save
	screen.closed.connect(_close_sensitivity)
	screen.changed.connect(changed.emit)  # the host (in-match: MatchRoot) re-reads the profile
	sensitivity_layer.add_child(screen)
	add_child(sensitivity_layer)


func _close_sensitivity() -> void:
	if sensitivity_layer == null:
		return
	sensitivity_layer.queue_free()
	sensitivity_layer = null
	var profile := save.load_profile()
	gyro_mode = SensitivitySettings.from_profile(profile).gyro_mode
	gyro_enabled = gyro_mode != "off"
	_refresh_gyro_text()


## Opens the HUD layout editor (G2e) on top of everything, like the Sensitivity screen.
func open_layout_editor() -> void:
	if layout_layer != null:
		return
	layout_layer = CanvasLayer.new()
	layout_layer.layer = 100
	layout_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	var editor: LayoutEditor = _LayoutScene.instantiate()
	editor.save = save
	editor.closed.connect(_close_layout_editor)
	editor.changed.connect(_on_layout_saved)
	layout_layer.add_child(editor)
	add_child(layout_layer)


func _on_layout_saved() -> void:
	sprint_lock_pos = save.load_profile()["sprint_lock_pos"]  # the editor mirrors the active slot's lock position
	changed.emit()  # the host (in-match: MatchRoot) re-applies the layout to the live HUD


func _close_layout_editor() -> void:
	if layout_layer == null:
		return
	layout_layer.queue_free()
	layout_layer = null
	sprint_lock_pos = save.load_profile()["sprint_lock_pos"]


## Opens the Haptics screen (G2f) on top of everything, like the Sensitivity screen.
func open_haptics() -> void:
	if haptics_layer != null:
		return
	haptics_layer = CanvasLayer.new()
	haptics_layer.layer = 100
	haptics_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	var screen: HapticsScreen = _HapticsScene.instantiate()
	screen.save = save
	screen.closed.connect(_close_haptics)
	screen.changed.connect(changed.emit)
	haptics_layer.add_child(screen)
	add_child(haptics_layer)


func _close_haptics() -> void:
	if haptics_layer == null:
		return
	haptics_layer.queue_free()
	haptics_layer = null


func toggle_move_stick() -> void:
	move_stick_mode = "custom" if move_stick_mode == "virtual" else "virtual"
	_refresh_stick_text()
	persist()


func toggle_stick_layout() -> void:
	vjoy_layout = "fixed" if vjoy_layout == "floating" else "floating"
	_refresh_stick_text()
	persist()


## G3e: the optional second Fire button for the left thumb (touch HUD).
func toggle_left_fire() -> void:
	left_fire_enabled = not left_fire_enabled
	_refresh_left_fire_text()
	persist()


func _refresh_left_fire_text() -> void:
	left_fire_button.text = "Left Fire button: %s" % ("On" if left_fire_enabled else "Off")


## M2 H1a: the touch shooting mode, cycling through data/input.json shooting.modes (Advanced -> Simple -> ...).
func toggle_shooting_mode() -> void:
	var modes: Array = DataRegistry.new().load_file("res://data/input.json")["shooting"]["modes"]
	shooting_mode = str(modes[(modes.find(shooting_mode) + 1) % modes.size()])
	_refresh_shooting_mode_text()
	persist()


func _refresh_shooting_mode_text() -> void:
	shooting_mode_button.text = "Shooting mode: %s" % shooting_mode.capitalize()


## M2 H1b: Minimap: Rotates <-> North up (profile minimap_rotate; the minimap reads AppFlow.profile, so a match picks it
## up at once).
func toggle_minimap_rotate() -> void:
	minimap_rotate = not minimap_rotate
	_refresh_minimap_text()
	persist()


func _refresh_minimap_text() -> void:
	minimap_button.text = "Minimap: %s" % ("Rotates" if minimap_rotate else "North up")


## M2 H1b commit 5: coach_done = false in the stored profile at once (persist() never writes coach_done, so it keeps it).
func replay_coach() -> void:
	var profile := save.load_profile()
	profile["coach_done"] = false
	save.save_profile(profile)
	persist()
	_refresh_coach_text(false)


## The row's wording (data/coach.json settings): "Replay the coach", or the pending text once the replay is set.
func _refresh_coach_text(done: bool) -> void:
	var s: Dictionary = HudCoach.data().get("settings", {})
	coach_button.text = str(s.get("replay_text", "Replay the coach")) if done else str(s.get("replay_pending_text", "Coach: shows next match"))


func _refresh_stick_text() -> void:
	move_stick_button.text = "Move stick: %s" % move_stick_mode.capitalize()
	stick_layout_button.text = "Stick: %s" % vjoy_layout.capitalize()
	stick_layout_button.disabled = move_stick_mode != "virtual"


## Settings: sprint sensitivity slider (range/step from data/input.json sprint_sensitivity). Higher = shorter push to sprint.
func _build_sprint_slider(value: float) -> void:
	var cfg: Dictionary = DataRegistry.new().load_file("res://data/input.json")["sprint_sensitivity"]
	sprint_label = Label.new()
	add_child(sprint_label)
	sprint_slider = HSlider.new()
	sprint_slider.min_value = float(cfg["min"])
	sprint_slider.max_value = float(cfg["max"])
	sprint_slider.step = float(cfg["step"])
	sprint_slider.custom_minimum_size = Vector2(0, 48.0 * PlatformServices.new().get_dp_scale())
	sprint_slider.value = value
	sprint_slider.value_changed.connect(_on_sprint_sensitivity_changed)
	add_child(sprint_slider)
	_refresh_sprint_text()


func _on_sprint_sensitivity_changed(_v: float) -> void:
	_refresh_sprint_text()
	persist()


func _refresh_sprint_text() -> void:
	sprint_label.text = "Sprint sensitivity: %d" % int(sprint_slider.value)


## The profile keys this panel owns.
func fields() -> Dictionary:
	var out := {"move_stick": move_stick_mode, "vjoy_layout": vjoy_layout,
			"sprint_sensitivity": sprint_slider.value, "sprint_lock_pos": sprint_lock_pos,
			"left_fire_enabled": left_fire_enabled, "shooting_mode": shooting_mode, "minimap_rotate": minimap_rotate}
	if graphics_built:  # W1a: only where the GRAPHICS rows exist; elsewhere the stored values are kept
		out.merge({"graphics_quality": graphics_quality, "frame_cap": frame_cap, "render_scale": render_scale, "fov": fov}, true)
	return out


## Writes the stored profile + the host screen's extra keys + this panel's keys, then reloads AppFlow.profile.
func persist() -> void:
	var profile := save.load_profile()
	if extra_fields.is_valid():
		profile.merge(extra_fields.call(), true)
	profile.merge(fields(), true)
	save.save_profile(profile)
	AppFlow.profile = save.load_profile()
	changed.emit()
