class_name LayoutEditor
extends Control
## HUD layout editor (G2e), opened from Settings. Shows the live touch HUD (both sticks, every button, the Sprint
## lock button). Tap an element to select it, drag to move it, and use the size / opacity sliders. Three saved
## layouts (slots 1-3) with an active slot; Save and Reset act on the slots, Reset restores the G2L default.
## Positions are stored as fractions of the HUD so a layout scales with the screen. The gear (top-right) is not
## editable. An element partly outside the safe viewport at any checked size blocks Save and is named in a
## warning; overlap with the gear, the HUD bars or (M2 H1a) the main look area only warns (data
## layout_editor.overlap_policy). In look mode "drag" (the default) there is no look stick element to edit.
## The 48 dp floor: the size slider cannot go lower, and TouchHud never draws a target below it.
## Landscape only (OQ-PORTRAIT).

signal closed
## Emitted after Save wrote the profile (the host re-reads it).
signal changed

const _Theme := preload("res://scenes/ui/menu_theme.tres")
const _TouchScene := preload("res://scenes/ui/touch_hud.tscn")
const _HudScene := preload("res://scenes/ui/hud.tscn")
const _SAMPLE_TEXT := {"alive": "Alive XVIII   Squads VI", "zone": "Zone closes in 1:00", "downed": "DOWNED 0:24",
		"weapon": "Gladius Rifle", "ammo": "120 / 360"}
const _TOLERANCE_PX := 0.5

var save := SaveService.new()
var model: HudLayoutModel
var cfg: Dictionary = {}
var preview: Control  # the live TouchHud
var selected: String = ""
var issues: Array = []  # {slot, size, element, kind ("offscreen" | "overlap"), text}
var slot_buttons: Array[Button] = []
var size_slider: HSlider
var alpha_slider: HSlider
var save_button: Button
var reset_button: Button
var back_button: Button
var element_label: Label
var warn_label: Label
var _marks: Control
var _fixed: Control
## M2 H1b commit 5: names of the fixed elements the last _draw_fixed drew (tests).
var drawn_fixed: Array = []
var _check_view: SubViewport
var _checkers: Dictionary = {}  # Vector2i -> {touch, hud, pause}
var _dragging: bool = false
var _grab: Vector2 = Vector2.ZERO
var _built: bool = false


func _ready() -> void:
	theme = _Theme
	set_anchors_preset(Control.PRESET_FULL_RECT)
	process_mode = Node.PROCESS_MODE_ALWAYS
	build()
	UiScale.bind(self)
	# The HUD bars and gear used by the overlap check are laid out by containers one frame later.
	await get_tree().process_frame
	await get_tree().process_frame
	if is_inside_tree():
		refresh()


## Builds the screen from the profile (callable from tests after `save` is set).
func build() -> void:
	if _built:
		return
	_built = true
	cfg = HudLayoutModel.cfg()
	model = HudLayoutModel.from_dict(save.load_profile().get("hud_layouts", null))
	var bg := ColorRect.new()
	bg.color = MenuStyle.color("night")  # a calm flat ground: placement on the HUD preview must stay readable
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	# M2 H1b commit 5: the fixed (not movable) HUD pieces, drawn under the live buttons so the player sees what they must
	# stay clear of.
	_fixed = Control.new()
	_fixed.name = "FixedElements"
	_fixed.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fixed.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fixed.draw.connect(_draw_fixed)
	add_child(_fixed)
	preview = _TouchScene.instantiate()
	MenuStyle.skip(preview)  # the live HUD keeps its own look; the kit must not wire or size it
	preview.theme = preload("res://scenes/ui/theme.tres")  # editor chrome uses the menu theme; the HUD keeps its own until H1
	add_child(preview)
	preview.cfg["force_touch_hud"] = true
	preview.use_profile_lock_fallback = false  # the slots own the Sprint lock position while editing
	preview.show_move_stick_for_editing = true  # M2 H1c (OQ-STICK-VISIBLE): the stick is drawn only here, to drag it
	preview.visible = true
	preview.set_suspended(true)  # the editor handles all touches; no sticks or fire while editing
	_ignore_mouse(preview)
	_marks = Control.new()
	_marks.set_anchors_preset(Control.PRESET_FULL_RECT)
	_marks.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_marks.draw.connect(_draw_marks)
	add_child(_marks)
	_check_view = SubViewport.new()
	_check_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_check_view)
	_build_panel()
	preview.apply_slot_layout(model.active_slot())
	resized.connect(_on_resized)
	refresh()


func _ignore_mouse(node: Node) -> void:
	if node is Control:
		(node as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	for c in node.get_children():
		_ignore_mouse(c)


func _dp() -> float:
	return PlatformServices.new().get_dp_scale()


func _build_panel() -> void:
	var dp_h := float(cfg["min_target_dp"]) * _dp()
	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.anchor_left = 0.18
	panel.anchor_right = 0.82
	panel.anchor_top = 0.0
	panel.anchor_bottom = 0.0
	add_child(panel)
	var col := VBoxContainer.new()
	MenuStyle.gap(col, 1.0)
	panel.add_child(col)
	var row1 := HBoxContainer.new()
	MenuStyle.gap(row1, 0.75)
	col.add_child(row1)
	for i in model.slots.size():
		var b := Button.new()
		b.text = "Slot %d" % (i + 1)
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(0, dp_h)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(select_slot.bind(i))
		row1.add_child(b)
		slot_buttons.append(b)
	save_button = _button(row1, "Save", save_layout, dp_h)
	save_button.theme_type_variation = &"PrimaryButton"  # the screen's one crimson control (no primary(): same height)
	reset_button = _button(row1, "Reset", reset_current, dp_h)
	back_button = _button(row1, "Back", close, dp_h)
	var row2 := HBoxContainer.new()
	MenuStyle.gap(row2, 0.75)
	col.add_child(row2)
	element_label = Label.new()
	element_label.custom_minimum_size = Vector2(110.0 * _dp(), 0)
	row2.add_child(element_label)
	size_slider = _slider(row2, cfg["size_pct"], dp_h, _on_size_changed)
	alpha_slider = _slider(row2, cfg["alpha_pct"], dp_h, _on_alpha_changed)
	warn_label = Label.new()
	warn_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	warn_label.theme_type_variation = &"WarnLabel"
	col.add_child(warn_label)


func _button(parent: Control, text: String, handler: Callable, min_h: float) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, min_h)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(handler)
	parent.add_child(b)
	return b


func _slider(parent: Control, range_cfg: Dictionary, min_h: float, handler: Callable) -> HSlider:
	var s := HSlider.new()
	s.min_value = float(range_cfg["min"])
	s.max_value = float(range_cfg["max"])
	s.step = float(range_cfg["step"])
	s.custom_minimum_size = Vector2(0, min_h)
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.value_changed.connect(handler)
	parent.add_child(s)
	return s


# --- element helpers -------------------------------------------------------------------------------

func element_name(key: String) -> String:
	match key:
		"move_stick":
			return "Move stick"
		"look_stick":
			return "Look stick"
		HudLayoutModel.LOCK_KEY:
			return "Sprint lock"
		HudLayoutModel.LEFT_FIRE_KEY:
			return "Left Fire"
	return String(preview.cfg["touch_layout"]["buttons"].get(key, {}).get("label", key))


## Smallest size_pct whose touch target is still at least 48 dp at this device scale and HUD size.
func min_size_pct(key: String) -> float:
	var base: float = preview.get_element_base_px(key)
	var step := float(cfg["size_pct"]["step"])
	var floor_pct := ceilf(preview.get_element_min_px(key) / base * 100.0 / step) * step
	return maxf(float(cfg["size_pct"]["min"]), floor_pct)


func _element_at(global_pos: Vector2) -> String:
	var keys: Array = preview.get_element_keys()
	keys.reverse()  # buttons and the lock button first: they sit on top of the big stick rings
	for k in keys:
		if (preview.get_element_rect(k) as Rect2).has_point(global_pos):
			return k
	return ""


func select_element(key: String) -> void:
	selected = key
	refresh()


func _sync_controls() -> void:
	for i in slot_buttons.size():
		slot_buttons[i].set_pressed_no_signal(i == model.active)
	size_slider.editable = selected != ""
	alpha_slider.editable = selected != ""
	element_label.text = element_name(selected) if selected != "" else "Tap an element"
	if selected == "":
		return
	size_slider.min_value = minf(min_size_pct(selected), float(cfg["size_pct"]["max"]))
	var entry: Dictionary = model.active_slot().get(selected, {})
	size_slider.set_value_no_signal(float(entry.get("size_pct", cfg["default_size_pct"])))
	alpha_slider.set_value_no_signal(float(entry.get("alpha_pct", cfg["default_alpha_pct"])))


func _on_size_changed(v: float) -> void:
	if selected == "":
		return
	model.set_size_pct(model.active, selected, maxf(v, min_size_pct(selected)))
	_apply_and_refresh()


func _on_alpha_changed(v: float) -> void:
	if selected == "":
		return
	model.set_alpha_pct(model.active, selected, v)
	_apply_and_refresh()


## Moves the selected element's centre to `frac` (fractions of the HUD).
func move_selected_to(frac: Vector2) -> void:
	if selected == "":
		return
	model.set_pos(model.active, selected, frac)
	_apply_and_refresh()


func select_slot(i: int) -> void:
	model.set_active(i)
	_apply_and_refresh()


func _on_resized() -> void:
	if _built:
		refresh()


func _apply_and_refresh() -> void:
	preview.apply_slot_layout(model.active_slot())
	refresh()


# --- input -----------------------------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var global_pos: Vector2 = get_global_rect().position + event.position
		if event.pressed:
			var key := _element_at(global_pos)
			if key != "":
				selected = key
				_dragging = true
				_grab = global_pos - (preview.get_element_rect(key) as Rect2).get_center()
				refresh()
		else:
			_dragging = false
	elif event is InputEventMouseMotion and _dragging:
		var global_pos: Vector2 = get_global_rect().position + event.position
		var area: Vector2 = preview.size
		move_selected_to((global_pos - _grab - preview.global_position) / area)


# --- checks ----------------------------------------------------------------------------------------

func _checker(sz: Vector2i) -> Dictionary:
	if _checkers.has(sz):
		return _checkers[sz]
	var fsz := Vector2(sz)
	var touch: Control = _TouchScene.instantiate()
	_check_view.add_child(touch)
	touch.cfg["force_touch_hud"] = true
	touch.use_profile_lock_fallback = false
	touch.set_suspended(true)
	touch.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	touch.size = fsz
	var hud: GameHud = _HudScene.instantiate()
	_check_view.add_child(hud)
	hud.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	hud.size = fsz
	hud.alive_label.text = _SAMPLE_TEXT["alive"]
	hud.zone_label.text = _SAMPLE_TEXT["zone"]
	hud.downed_label.text = _SAMPLE_TEXT["downed"]
	hud.weapon_label.text = _SAMPLE_TEXT["weapon"]
	hud.ammo_label.text = _SAMPLE_TEXT["ammo"]
	touch.relayout()
	_checkers[sz] = {"touch": touch, "hud": hud}
	return _checkers[sz]


func _safe_rect(sz: Vector2) -> Rect2:
	var ins := PlatformServices.new().get_safe_insets()
	return Rect2(ins.x * sz.x, ins.y * sz.y, sz.x * (1.0 - ins.x - ins.z), sz.y * (1.0 - ins.y - ins.w))


## Issues of one slot at one viewport size. Needs the checker's containers laid out (a frame after build()).
func check_slot(slot_i: int, sz: Vector2i) -> Array:
	var c := _checker(sz)
	var touch: Control = c["touch"]
	touch.apply_slot_layout(model.slots[slot_i])
	var out: Array = []
	var safe := _safe_rect(Vector2(sz)).grow(_TOLERANCE_PX)
	var bars := {}
	var hud: GameHud = c["hud"]
	for n in ["shield_bar", "health_bar", "weapon_label", "ammo_label", "alive_label", "zone_label", "downed_label"]:
		bars[n] = (hud.get(n) as Control).get_global_rect()
	bars["gear"] = gear_rect(Vector2(sz))
	# M2 H1b (OQ-HUD): the whole weapon block (slots too) and the reserved minimap's tap target.
	bars["weapon_block"] = hud.weapon_block.get_global_rect()
	bars["minimap"] = HudArrangement.minimap_tap_rect(Vector2(sz))
	# M2 H1b commit 5 (OQ-COACH): the first-play coach's Skip (a fixed touch target while the coach runs). Warn only.
	bars["coach_skip"] = HudCoach.skip_rect(Vector2(sz))
	var look_area: Rect2 = touch.get_look_area_rect()
	for key in touch.get_element_keys():
		var r: Rect2 = touch.get_element_rect(key)
		if not safe.encloses(r):
			out.append(_issue(slot_i, sz, key, "offscreen", "%s is partly off-screen at %dx%d" % [element_name(key), sz.x, sz.y]))
		# M2 H1a: a control in the main look area (touch_layout.look_area) is where the look thumb lands by accident.
		# Warned only, never blocked (overlap_policy warn_only): the player may want it there.
		# The look stick (look mode "stick" only) rests inside the look area by design, so it is never warned.
		if key != "look_stick" and r.intersects(look_area):
			out.append(_issue(slot_i, sz, key, "look_area", "%s is in the look area at %dx%d" % [element_name(key), sz.x, sz.y]))
		for bname in bars:
			if r.intersects(bars[bname]):
				var what: String = "the gear" if bname == "gear" else "the HUD (%s)" % String(bname).replace("_", " ")
				out.append(_issue(slot_i, sz, key, "overlap", "%s overlaps %s at %dx%d" % [element_name(key), what, sz.x, sz.y]))
				break
	return out


## M2 H1b commit 5: the fixed (not movable) HUD pieces the editor shows, in view space for a HUD of `view` size, in draw
## order: the passive weapon block, objective line, alive / zone chip and radar + minimap panel; the fixed touch targets
## (the minimap's tap target, the gear, the coach's Skip). Same rects as the match (HudArrangement, PauseMenu, HudCoach).
static func fixed_elements(view: Vector2) -> Dictionary:
	var ui := HudArrangement.ui()
	return {"weapon_block": HudArrangement.weapon_block_rect(view), "objective": HudArrangement.objective_rect(view),
		"chip": HudArrangement.chip_rect(view), "panel": HudArrangement.panel_rect(view),
		"minimap_tap": HudArrangement.minimap_tap_rect(view), "gear": PauseMenu.gear_touch_rect(ui["pause_gear"], view),
		"coach_skip": HudCoach.skip_rect(view)}


## The fixed touch targets among fixed_elements (outlined solid; the passive displays get a dashed look).
const FIXED_TOUCH := ["minimap_tap", "gear", "coach_skip"]
const _FIXED_NAMES := {"weapon_block": "Weapon block", "objective": "Objective line", "chip": "Alive / zone",
	"panel": "Radar + map", "minimap_tap": "Map tap", "gear": "Menu", "coach_skip": "Coach Skip"}


func _draw_fixed() -> void:
	drawn_fixed.clear()
	if preview == null:
		return
	var view: Vector2 = preview.size
	if view.x <= 0.0 or view.y <= 0.0:
		return
	var off: Vector2 = preview.global_position - get_global_rect().position
	var u := HudArrangement.unit(view)
	var font := get_theme_default_font()
	var px := maxi(10, roundi(u * 0.5))
	var gold := MenuStyle.color("gold")
	var marble := MenuStyle.color("marble_dim")
	var els := fixed_elements(view)
	for key in els:
		var r: Rect2 = els[key]
		if r.size.x <= 0.0:
			continue
		r.position += off
		var touch: bool = FIXED_TOUCH.has(key)
		var fill := MenuStyle.color("surface")
		fill.a = 0.55 if touch else 0.35
		var line := gold
		line.a = 0.85 if touch else 0.45
		if key == "panel":
			var radar := HudArrangement.radar_rect(view)
			radar.position += off
			_fixed.draw_circle(radar.get_center(), radar.size.x * 0.5, fill)
			_fixed.draw_arc(radar.get_center(), radar.size.x * 0.5, 0.0, TAU, 48, line, 2.0, true)
			var mm := HudArrangement.minimap_rect(view)
			mm.position += off
			_fixed.draw_rect(mm, fill)
			_fixed.draw_rect(mm, line, false, 2.0)
		else:
			_fixed.draw_rect(r, fill)
			_fixed.draw_rect(r, line, false, 3.0 if touch else 2.0)
		var name_text := str(_FIXED_NAMES.get(key, key))
		var at := r.position + Vector2(u * 0.2, u * 0.2 + font.get_ascent(px))
		if key == "panel":
			# Under the panel, from the minimap's left edge (the editor's own panel covers the top centre).
			at = Vector2(HudArrangement.minimap_rect(view).position.x + off.x, r.end.y + u * 0.2 + font.get_ascent(px))
		_fixed.draw_string_outline(font, at, name_text, HORIZONTAL_ALIGNMENT_LEFT, maxf(r.size.x - u * 0.4, u * 3.0), px, 3, MenuStyle.color("night"))
		_fixed.draw_string(font, at, name_text, HORIZONTAL_ALIGNMENT_LEFT, maxf(r.size.x - u * 0.4, u * 3.0), px, gold if touch else marble)
		drawn_fixed.append(key)


## The (not editable) gear's touch rect for a viewport size; it stays top-right, data ui.json pause_gear.
func gear_rect(view_size: Vector2) -> Rect2:
	return PauseMenu.gear_touch_rect(DataRegistry.new().load_file("res://data/ui.json")["pause_gear"], view_size)


func _issue(slot_i: int, sz: Vector2i, key: String, kind: String, text: String) -> Dictionary:
	return {"slot": slot_i, "size": sz, "element": key, "kind": kind, "text": text}


func check_sizes() -> Array:
	var out: Array = []
	for s in cfg["check_sizes"]["list"]:
		out.append(Vector2i(int(s[0]), int(s[1])))
	return out


## Re-checks every edited slot at every checked size; fills `issues`.
func refresh_issues() -> void:
	issues.clear()
	for i in model.slots.size():
		if model.slots[i].is_empty() and i != model.active:
			continue  # an untouched slot is the data default, which the G2L tests keep inside the viewport
		for sz in check_sizes():
			issues.append_array(check_slot(i, sz))


func is_blocked() -> bool:
	for it in issues:
		if it["kind"] == "offscreen":
			return true
	return false


func refresh() -> void:
	if not _built:
		return
	refresh_issues()
	_sync_controls()
	save_button.disabled = is_blocked()
	reset_button.disabled = false
	var lines: Array[String] = []
	for it in issues:
		if lines.size() < 3:
			lines.append("%s%s" % ["" if it["slot"] == model.active else "Slot %d: " % (it["slot"] + 1), it["text"]])
	var extra := issues.size() - lines.size()
	if extra > 0:
		lines.append("(+%d more)" % extra)
	warn_label.text = "\n".join(lines)
	warn_label.visible = not lines.is_empty()
	if is_blocked():
		warn_label.text += "\nFix it or press Reset to save."
	_marks.queue_redraw()
	_fixed.queue_redraw()


func _draw_marks() -> void:
	var origin := get_global_rect().position
	for it in issues:
		if it["slot"] == model.active and it["size"] == Vector2i(preview.size) and preview.get_element_keys().has(it["element"]):
			var ir: Rect2 = preview.get_element_rect(it["element"])
			_marks.draw_rect(Rect2(ir.position - origin, ir.size).grow(3.0), Color(1.0, 0.3, 0.25), false, 3.0)
	if selected != "":
		var r: Rect2 = preview.get_element_rect(selected)
		_marks.draw_rect(Rect2(r.position - origin, r.size).grow(2.0), Color(0.9, 0.75, 0.25), false, 3.0)


# --- actions ---------------------------------------------------------------------------------------

## Reset for the current slot: back to the G2L default layout (data/input.json touch_layout).
func reset_current() -> void:
	model.reset_slot(model.active)
	_apply_and_refresh()


## Persists all slots and the active slot to the profile. Blocked while any element is off-screen. The profile's
## sprint_lock_pos is mirrored from the active slot ([] when the slot keeps the data default).
func save_layout() -> bool:
	refresh()
	if is_blocked():
		return false
	var profile := save.load_profile()
	profile["hud_layouts"] = model.to_dict()
	var lock: Dictionary = model.active_slot().get(HudLayoutModel.LOCK_KEY, {})
	profile["sprint_lock_pos"] = lock.get("pos", [])
	if not save.save_profile(profile):
		return false
	AppFlow.profile = save.load_profile()
	changed.emit()
	return true


## Leaves the editor; unsaved edits are dropped.
func close() -> void:
	closed.emit()
