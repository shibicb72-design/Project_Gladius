extends Control
## Touch HUD: always-visible move stick (bottom-left, re-centres under the thumb) and look stick (bottom
## centre-right, drag with tap-to-fire), plus action buttons.
## Feeds TouchProvider; buttons press InputMap actions. Layout comes from data/input.json.

const _DataRegistry := preload("res://scripts/systems/data_registry.gd")
const _Platform := preload("res://scripts/platform/platform_services.gd")
const _TouchProvider := preload("res://scripts/input/providers/touch_provider.gd")
const _LookMath := preload("res://scripts/input/look_math.gd")

var provider: TouchProvider = _TouchProvider.new()
var cfg: Dictionary = {}
var _layout: Dictionary = {}
var _move_touch: int = -1
var _look_touch: int = -1
var _move_origin: Vector2 = Vector2.ZERO
var _move_pos: Vector2 = Vector2.ZERO
var _look_origin: Vector2 = Vector2.ZERO
var _look_pos: Vector2 = Vector2.ZERO
var _look_travel: float = 0.0
var _look_down_s: float = 0.0
var _look_moved: bool = false
var _fire_pulse_s: float = 0.0
var _look_hold_fire := false
var _hud_fire_down := false
var _shoulder_pulse_left_s: float = 0.0
var _button_touch: Dictionary = {}  # touch index -> element key (an action, or LEFT_FIRE_KEY)
var _buttons: Dictionary = {}  # action -> Control
var debug_label: Label  # null unless the touch debug overlay is enabled in data/ui.json
var _debug_touches: Dictionary = {}  # touch index -> overlay line
## Test-only hook ("" = use data/input.json touch_layout.move_stick): forces "virtual" or "custom".
static var move_stick_override: String = ""
const _VJOY_ACTIONS := ["vjoy_move_left", "vjoy_move_right", "vjoy_move_up", "vjoy_move_down"]

## "custom": a StickVisual driven by this script. "virtual": a Godot 4.7 VirtualJoystick (trial, OQ-VJOY).
var move_stick: Control
var look_stick: StickVisual
var lock_button: Button
var lock_target: Button
var _lock_btn_touch: int = -1
var move_mode: String = "custom"
var vjoy_layout: String = "floating"  # "floating" | "fixed"; only used when move_mode == "virtual"
var suspended: bool = false  # true while the in-match menu is open
## G2e: the active saved layout slot (element key -> {pos, size_pct, alpha_pct}); {} = the data defaults.
var slot_layout: Dictionary = {}
const LOCK_KEY := "sprint_lock"
var cover_controls_active := false
var _cover_hidden_slots: Array = []

## Context siblings call this synchronously, including refresh() before the next frame.
func set_cover_controls_active(active: bool) -> void:
	if _cover_hidden_slots.is_empty():
		_cover_hidden_slots = _DataRegistry.new().load_file("res://data/ui.json")["cover_buttons"]["hidden_slots"]
	if cover_controls_active != active:
		cover_controls_active = active
		for idx in _button_touch.keys():
			var key: String = _button_touch[idx]
			if is_cover_slot_hidden(key):
				Input.action_release(_action_of(key))
				_button_touch.erase(idx)
		_lock_btn_touch = -1
		_shoulder_pulse_left_s = 0.0
		_sync_fire_action()
	for key in _buttons:
		_buttons[key].visible = not is_cover_slot_hidden(key)
	if lock_button != null:
		lock_button.visible = not is_cover_slot_hidden(LOCK_KEY)

func is_cover_slot_hidden(key: String) -> bool:
	return cover_controls_active and key in _cover_hidden_slots
## G3e: element key of the optional left Fire button (not an InputMap action: it presses "fire").
const LEFT_FIRE_KEY := "fire_left"
const LEFT_FIRE_LABEL := "Fire"
## false in the layout editor: the slots alone decide the lock button, not the profile's mirrored sprint_lock_pos.
var use_profile_lock_fallback: bool = true
var _emulation_overridden: bool = false
var _prev_emulation: bool = true

## Read-only contextual-cover fact; gameplay never reads touch events.
func is_look_active() -> bool:
	return _look_touch != -1 and _look_moved


func _ready() -> void:
	cfg = _DataRegistry.new().load_file("res://data/input.json")
	_layout = cfg.get("touch_layout", {})
	reload_profile_layout()
	provider.configure(cfg)
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	for action in _layout["buttons"]:
		_add_button(action, String(_layout["buttons"][action].get("label", action)))
	if left_fire_enabled():
		_add_button(LEFT_FIRE_KEY, LEFT_FIRE_LABEL)
	if bool(_DataRegistry.new().load_file("res://data/ui.json")["touch_debug_overlay"]["enabled"]):
		debug_label = Label.new()
		debug_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		debug_label.position = Vector2(8, 8)
		add_child(debug_label)
	look_stick = _make_stick_visual("look_stick")
	add_child(look_stick)
	_make_sprint_elements()
	rebuild_move_stick()
	resized.connect(relayout)
	get_viewport().size_changed.connect(relayout)
	relayout()
	refresh_visibility()


func _add_button(key: String, label: String) -> void:
	var b := Button.new()
	b.text = label
	b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.focus_mode = Control.FOCUS_NONE
	b.anchor_left = 0.0  # offsets below are absolute HUD positions (relayout)
	b.anchor_right = 0.0
	b.anchor_top = 0.0
	b.anchor_bottom = 0.0
	add_child(b)
	_buttons[key] = b


## G3e: the InputMap action an element key presses (the left Fire button presses "fire").
func _action_of(key: String) -> String:
	return "fire" if key == LEFT_FIRE_KEY else key


## G3e: the profile's left_fire_enabled flag (its default comes from data/input.json touch_layout.left_fire).
func left_fire_enabled() -> bool:
	return bool(AppFlow.profile.get("left_fire_enabled", _layout["left_fire"]["enabled_default"]))


## G3e: builds or removes the left Fire button to match the profile flag (live toggle, tests). Touches held on
## a removed button are released; "fire" stays down while the other Fire button is still held.
func refresh_left_fire() -> void:
	var on := left_fire_enabled()
	if on and not _buttons.has(LEFT_FIRE_KEY):
		_add_button(LEFT_FIRE_KEY, LEFT_FIRE_LABEL)
	elif not on and _buttons.has(LEFT_FIRE_KEY):
		for idx in _button_touch.keys():
			if _button_touch[idx] == LEFT_FIRE_KEY:
				_button_touch.erase(idx)
		_sync_fire_action()
		var b: Button = _buttons[LEFT_FIRE_KEY]
		_buttons.erase(LEFT_FIRE_KEY)
		remove_child(b)
		b.free()
	if is_inside_tree() and move_stick != null:
		relayout()


## G2e: applies the profile's active layout slot over the data defaults.
func reload_profile_layout() -> void:
	apply_slot_layout(HudLayoutModel.from_dict(AppFlow.profile.get("hud_layouts", null)).active_slot())
	if move_stick != null:
		refresh_left_fire()  # G3e: a Settings toggle made while the HUD is live


## Applies a layout slot (also used live by the layout editor) and re-places everything.
func apply_slot_layout(slot: Dictionary) -> void:
	slot_layout = slot
	if is_inside_tree() and move_stick != null:
		relayout()


func _entry(key: String) -> Dictionary:
	return slot_layout.get(key, {})


func _scale(key: String) -> float:
	return float(_entry(key).get("size_pct", cfg["layout_editor"]["default_size_pct"])) / 100.0


func _alpha(key: String) -> float:
	return float(_entry(key).get("alpha_pct", cfg["layout_editor"]["default_alpha_pct"])) / 100.0


## Centre of an element in HUD space: its slot position (fractions of the HUD) or `default_px`.
func _center_px(key: String, default_px: Vector2) -> Vector2:
	var p: Array = _entry(key).get("pos", [])
	if p.size() != 2:
		return default_px
	return Vector2(float(p[0]) * _area().x, float(p[1]) * _area().y)


## Element keys the layout editor can edit: the two sticks, the Sprint lock button and every action button.
func get_element_keys() -> Array:
	var keys: Array = ["move_stick", "look_stick", LOCK_KEY]
	keys.append_array(_buttons.keys())
	if cover_controls_active:
		for key in _cover_hidden_slots:
			keys.erase(key)
	return keys


## Smallest touch target of an element in px (48 dp at this device's scale, data min_dp / min_target_dp).
func get_element_min_px(key: String) -> float:
	var dp := _Platform.new().get_dp_scale()
	if key == LOCK_KEY:
		return float(cfg["sprint"]["lock_button"]["min_dp"]) * dp
	if _buttons.has(key):
		return float(_layout["button_min_dp"]) * dp
	return float(cfg["layout_editor"]["min_target_dp"]) * dp


## Side of the element at 100 % (before its slot scale and the minimum), in px at the current HUD size.
func get_element_base_px(key: String) -> float:
	if key == LOCK_KEY:
		return float(cfg["sprint"]["lock_button"]["size_frac_of_height"]) * _area().y
	if _buttons.has(key):
		return float(_layout["button_size_frac_of_height"]) * _area().y
	return 2.0 * maxf(1.0, float(_layout.get("stick_radius_frac_of_height", 0.12)) * _area().y)


## Screen rect of an element as drawn (sticks at rest), for editing and layout checks.
func get_element_rect(key: String) -> Rect2:
	if key == LOCK_KEY:
		return get_lock_button_rect()
	if _buttons.has(key):
		return get_button_rect(key)
	if key == "move_stick":
		return get_move_visual_rect()
	var r := _radius(key)
	return _to_global_rect(Rect2(get_look_rest() - Vector2.ONE * r, Vector2.ONE * r * 2.0))


## Effective editable state of an element: centre as HUD fractions, size and opacity in percent.
func get_element_state(key: String) -> Dictionary:
	var c := (get_element_rect(key).get_center() - global_position) / _area()
	return {"pos": [c.x, c.y], "size_pct": _scale(key) * 100.0, "alpha_pct": _alpha(key) * 100.0}


## Sprint lock button (separate, movable HUD element showing the lock state) and the lock target that
## appears above the move stick while it is pushed past the sprint trigger. Purely visual: the lock
## itself is TouchProvider state, gameplay never reads these nodes.
func _make_sprint_elements() -> void:
	var sens: Dictionary = cfg["sprint_sensitivity"]
	provider.set_sprint_sensitivity(float(AppFlow.profile.get("sprint_sensitivity", sens["default"])))
	lock_button = Button.new()
	lock_button.name = "sprint_lock_button"
	lock_button.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lock_button.focus_mode = Control.FOCUS_NONE
	add_child(lock_button)
	lock_target = Button.new()
	lock_target.name = "sprint_lock_target"
	lock_target.text = "Lock"
	lock_target.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lock_target.focus_mode = Control.FOCUS_NONE
	lock_target.visible = false
	add_child(lock_target)


## Side of the lock button / target in px: its data fraction of the HUD height, never below min_dp.
func _lock_side(key: String) -> float:
	var spec: Dictionary = cfg["sprint"][key]
	var min_dp: float = cfg["sprint"]["lock_button"]["min_dp"]
	var scale := _scale(LOCK_KEY) if key == "lock_button" else 1.0
	return maxf(float(spec["size_frac_of_height"]) * _area().y * scale, min_dp * _Platform.new().get_dp_scale())


## Lock button centre in HUD space: the active layout slot (G2e) wins over the profile's sprint_lock_pos
## (which the editor mirrors from the slot), which wins over data/input.json.
func _lock_button_center() -> Vector2:
	var p: Array = AppFlow.profile.get("sprint_lock_pos", []) if use_profile_lock_fallback else []
	if p.size() != 2:
		p = _layout["sprint_lock_pos"]
	return _center_px(LOCK_KEY, Vector2(float(p[0]) * _area().x, float(p[1]) * _area().y))


func get_lock_button_rect() -> Rect2:
	var s := _lock_side("lock_button")
	return _to_global_rect(Rect2(_lock_button_center() - Vector2.ONE * s * 0.5, Vector2.ONE * s))


## Lock target above where the move stick started (the finger origin), clamped onto the screen.
## _move_origin is viewport space (event.position): it is converted to HUD space once here, the
## HUD-space rect is then shifted back through _to_global_rect.
func get_lock_target_rect() -> Rect2:
	var s := _lock_side("lock_target")
	var origin := _move_origin - global_position if _move_touch != -1 else get_move_rest()
	var c := origin - Vector2(0.0, float(cfg["sprint"]["lock_target"]["distance_radii"]) * _radius())
	c = c.clamp(Vector2.ONE * s * 0.5, _area() - Vector2.ONE * s * 0.5)
	return _to_global_rect(Rect2(c - Vector2.ONE * s * 0.5, Vector2.ONE * s))


func _place_sprint_elements() -> void:
	if lock_button == null:
		return
	var r := get_lock_button_rect()
	lock_button.position = r.position - global_position
	lock_button.size = r.size
	lock_button.text = "Locked" if provider.sprint_locked else "Sprint\nlock"
	lock_button.add_theme_font_size_override("font_size", int(r.size.x * float(_layout.get("button_font_frac_of_size", 0.24))))
	_style_round(lock_button, r.size.x, 0.6 if provider.sprint_locked else float(_layout["button_idle_alpha"]))
	lock_button.modulate.a = _alpha(LOCK_KEY)
	var t := get_lock_target_rect()
	lock_target.position = t.position - global_position
	lock_target.size = t.size
	lock_target.add_theme_font_size_override("font_size", int(t.size.x * float(_layout.get("button_font_frac_of_size", 0.24))))
	_style_round(lock_target, t.size.x, 0.5)
	lock_target.visible = provider.lock_target_visible()


func _style_round(b: Button, side: float, alpha: float) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, alpha)
	sb.border_color = Color(1, 1, 1, 0.6)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(int(ceil(side * 0.5)))
	for state in ["normal", "hover", "pressed", "disabled"]:
		b.add_theme_stylebox_override(state, sb)


func _make_stick_visual(node_name: String) -> StickVisual:
	var v := StickVisual.new()
	v.name = node_name
	v.ring_alpha = float(_layout["ring_alpha"])
	v.knob_frac = float(_layout.get("knob_frac_of_radius", 0.4))
	return v


## Value of a move-stick setting: the player profile (Settings in the main menu) wins over input.json;
## `override` (tests only) wins over both.
func _setting(key: String, override: String) -> String:
	if override != "":
		return override
	var from_profile := String(AppFlow.profile.get(key, ""))
	return from_profile if from_profile != "" else String(_layout[key])


## (Re)builds the move stick from the current profile / input.json / override. Also the hook for tests
## that change cfg["touch_layout"] after the HUD exists.
func rebuild_move_stick() -> void:
	if move_stick != null:
		remove_child(move_stick)
		move_stick.free()
	move_mode = _setting("move_stick", move_stick_override)
	vjoy_layout = _setting("vjoy_layout", "")
	provider.shape_move = move_mode == "virtual"
	provider.move_value = Vector2.ZERO
	_move_touch = -1
	move_stick = _make_virtual_joystick() if move_mode == "virtual" else _make_stick_visual("move_stick")
	add_child(move_stick)
	if is_inside_tree():
		relayout()


func _exit_tree() -> void:
	_restore_emulation()
	for idx in _button_touch:
		Input.action_release(_action_of(_button_touch[idx]))
	_button_touch.clear()
	_look_hold_fire = false
	_fire_pulse_s = 0.0
	_hud_fire_down = false
	Input.action_release("fire")


func should_show() -> bool:
	return bool(cfg.get("force_touch_hud", false)) or _Platform.new().is_touch_device()


## Re-evaluates should_show(). While shown, emulated mouse clicks from touches are switched off
## (runtime only, never the project setting) so a thumb cannot hold "fire"/"aim"; menus keep them.
func refresh_visibility() -> void:
	visible = should_show()
	if visible:
		if not _emulation_overridden:
			_prev_emulation = _Platform.new().set_mouse_emulation_from_touch(false)
			_emulation_overridden = true
	else:
		_restore_emulation()


func _restore_emulation() -> void:
	if _emulation_overridden:
		_Platform.new().set_mouse_emulation_from_touch(_prev_emulation)
		_emulation_overridden = false


## Builds the trial move stick. It drives four private InputMap actions (not the gameplay ones);
## _process turns them into TouchProvider.move_value, so gameplay never reads the joystick.
func _make_virtual_joystick() -> VirtualJoystick:
	var vj: Dictionary = _layout["vjoy"]
	var feel: Dictionary = cfg["move_feel"]
	for a in _VJOY_ACTIONS:
		if not InputMap.has_action(a):
			InputMap.add_action(a, 0.0)  # dead zone is applied radially in TouchProvider.get_move
	var j := VirtualJoystick.new()
	j.name = "move_stick"
	j.mouse_filter = Control.MOUSE_FILTER_STOP
	j.action_left = _VJOY_ACTIONS[0]
	j.action_right = _VJOY_ACTIONS[1]
	j.action_up = _VJOY_ACTIONS[2]
	j.action_down = _VJOY_ACTIONS[3]
	j.joystick_mode = VirtualJoystick.JOYSTICK_FIXED if vjoy_layout == "fixed" else VirtualJoystick.JOYSTICK_DYNAMIC
	j.visibility_mode = VirtualJoystick.VISIBILITY_WHEN_TOUCHED if String(vj["visibility"]) == "when_touched" else VirtualJoystick.VISIBILITY_ALWAYS
	j.deadzone_ratio = float(feel["vjoy_deadzone_ratio"]["value"])
	j.clampzone_ratio = float(feel["vjoy_clampzone_ratio"]["value"])
	var ring := Color(1, 1, 1, float(_layout["ring_alpha"]))
	var held := Color(1, 1, 1, minf(1.0, ring.a * 1.5))
	j.add_theme_stylebox_override("normal_joystick", _disc(Color(1, 1, 1, ring.a * 0.3), ring))
	j.add_theme_stylebox_override("pressed_joystick", _disc(Color(1, 1, 1, ring.a * 0.5), ring))
	j.add_theme_stylebox_override("normal_tip", _disc(Color(1, 1, 1, minf(1.0, ring.a * 2.0)), ring))
	j.add_theme_stylebox_override("pressed_tip", _disc(held, ring))
	j.released.connect(func(_v: Vector2) -> void: provider.move_value = Vector2.ZERO)
	return j


func _disc(fill: Color, border: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.border_color = border
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(512)
	return sb


## Touch target of the move stick in density-independent pixels (smaller side), from the platform layer.
func get_move_target_dp() -> float:
	var px := (move_stick as VirtualJoystick).joystick_size if move_mode == "virtual" else minf(move_stick.size.x, move_stick.size.y)
	return px / _Platform.new().get_dp_scale()


func _process(delta: float) -> void:
	if move_mode == "virtual":
		provider.move_value = Input.get_vector(_VJOY_ACTIONS[0], _VJOY_ACTIONS[1], _VJOY_ACTIONS[2], _VJOY_ACTIONS[3], 0.0)
	_place_sprint_elements()
	if _look_touch != -1:
		_look_down_s += delta
		if not _look_moved and _look_down_s > float(_layout["look_hold_fire"]["hold_min_s"]):
			_look_hold_fire = true
	if _fire_pulse_s > 0.0:
		_fire_pulse_s = maxf(0.0, _fire_pulse_s - delta)
	_sync_fire_action()
	if _shoulder_pulse_left_s > 0.0:
		_shoulder_pulse_left_s = maxf(0.0, _shoulder_pulse_left_s - delta)
		_apply_shoulder_pulse()


## View-only press feedback, separate from the camera shoulder ease and the held-state style.
## Quadratic ease-out release: EL's pick 2026-10-28 (OQ-SHOULDER presentation addendum).
func _apply_shoulder_pulse() -> void:
	var b: Button = _buttons["swap_shoulder"]
	b.pivot_offset = b.size * 0.5
	if _shoulder_pulse_left_s <= 0.0:
		b.scale = Vector2.ONE
		return
	var f := _shoulder_pulse_left_s / float(_layout["shoulder_pulse_release_s"]["value"])
	var press_scale := float(_layout["shoulder_pulse_scale"]["value"])
	b.scale = Vector2.ONE * (1.0 - (1.0 - press_scale) * f * f)


func _area() -> Vector2:
	return size if size.x > 0.0 and size.y > 0.0 else get_viewport_rect().size


func _zone_rect(key: String) -> Rect2:
	var z: Dictionary = _layout.get(key, {})
	var s := _area()
	var l := float(z.get("left", 0.0)) * s.x
	var t := float(z.get("top", 0.0)) * s.y
	return Rect2(l, t, float(z.get("right", 1.0)) * s.x - l, float(z.get("bottom", 1.0)) * s.y - t)


## Recomputes button sizes and positions from the current area (called on viewport/HUD resize,
## e.g. a foldable switching between cover and inner screen). Stick radius and zones are derived
## from the area on demand, so they follow automatically; this redraws any active stick.
func relayout() -> void:
	for action in _buttons:
		var b: Button = _buttons[action]
		var cell := _cell_rect(action)
		b.offset_left = cell.position.x
		b.offset_top = cell.position.y
		b.offset_right = b.offset_left + cell.size.x
		b.offset_bottom = b.offset_top + cell.size.y
		b.modulate.a = _alpha(action)
		b.add_theme_font_size_override("font_size", int(cell.size.x * float(_layout.get("button_font_frac_of_size", 0.24))))
		_style_button(b, _button_touch.values().has(action))
	_update_sticks()
	_place_sprint_elements()


## Rest centre of a stick in HUD space, from data (x of width, y of height).
func _rest_center(key: String) -> Vector2:
	var a: Array = _layout[key]
	var s := _area()
	return Vector2(float(a[0]) * s.x, float(a[1]) * s.y)


func get_move_rest() -> Vector2:
	return _center_px("move_stick", _rest_center("move_stick_rest"))


func get_look_rest() -> Vector2:
	return _center_px("look_stick", _rest_center("look_stick_rest"))


## Places both stick rings: look is fixed at rest; move follows the thumb while held and returns to rest on release.
func _update_sticks() -> void:
	if move_stick == null:
		return
	var r := _radius()
	var look_c := get_look_rest()
	look_stick.place(look_c, _radius("look_stick"))
	look_stick.modulate.a = _alpha("look_stick")
	move_stick.modulate.a = _alpha("move_stick")
	look_stick.set_knob_offset((_look_pos - _look_origin) if _look_touch != -1 else Vector2.ZERO)
	if move_mode == "virtual":
		var vj := move_stick as VirtualJoystick
		var side := _vjoy_side()
		var rest := _move_visual_local()
		if vjoy_layout == "fixed":
			# The Control is exactly the stick, so only touches on it grab it.
			move_stick.position = rest.position
			move_stick.size = rest.size
			vj.initial_offset_ratio = Vector2(0.5, 0.5)
		else:
			# Floating: the Control is the whole left half (a touch area, not drawn); a DYNAMIC base spawns
			# under the thumb inside it and rests at move_stick_rest (initial_offset_ratio) when released.
			var zone := _zone_rect("move_zone")
			move_stick.position = zone.position
			move_stick.size = zone.size
			vj.initial_offset_ratio = (get_move_rest() - zone.position) / zone.size
		vj.joystick_size = side
		vj.tip_size = side * float(_layout["vjoy"]["tip_frac_of_size"])
	elif _move_touch != -1:
		move_stick.place(_move_origin - global_position, r)  # _move_origin is viewport space, place() takes HUD space
		move_stick.set_knob_offset(_move_pos - _move_origin)
	else:
		move_stick.place(get_move_rest(), r)
		move_stick.set_knob_offset(Vector2.ZERO)


func _vjoy_side() -> float:
	return 2.0 * _radius() * float(_layout["vjoy"]["size_frac_of_ring"])


## Drawn base at rest in HUD space (the VirtualJoystick Control itself may be larger: see _update_sticks).
func _move_visual_local() -> Rect2:
	var side := Vector2.ONE * (_vjoy_side() if move_mode == "virtual" else 2.0 * _radius())
	return Rect2(get_move_rest() - side * 0.5, side)


## Global rect of the move stick as drawn at rest. Layout/clearance checks use this, not the touch area.
func get_move_visual_rect() -> Rect2:
	if move_mode != "virtual":
		return move_stick.get_global_rect()
	var local := _move_visual_local()
	return Rect2(get_global_rect().position + local.position, local.size)


## Hit-test space (P0): event.position is viewport space, so every hit rect (buttons, lock, zones, grab)
## is shifted by global_position through this one helper.
func _to_global_rect(local: Rect2) -> Rect2:
	return Rect2(local.position + global_position, local.size)


## Viewport-space rect of a touch zone (the local _zone_rect shifted into event space).
func _zone_hit_rect(key: String) -> Rect2:
	return _to_global_rect(_zone_rect(key))


## Where a touch grabs the move stick, in viewport space: the stick itself when fixed, else the whole move zone.
func _move_grab_rect() -> Rect2:
	if move_mode == "virtual" and vjoy_layout == "fixed":
		return _to_global_rect(_move_visual_local())
	return _zone_hit_rect("move_zone")


## Button side in px: its data fraction of the HUD height, never below button_min_dp (touch target floor).
func _button_size() -> float:
	return maxf(float(_layout["button_size_frac_of_height"]) * _area().y, float(_layout["button_min_dp"]) * _Platform.new().get_dp_scale())


## Side of a button in px: its slot scale on the default size, never below button_min_dp.
func _button_side(action: String) -> float:
	return maxf(float(_layout["button_size_frac_of_height"]) * _area().y * _scale(action), float(_layout["button_min_dp"]) * _Platform.new().get_dp_scale())


## A button's rect: its slot position, else its data offset (in default button sizes) from the DATA look stick
## rest centre (so moving the look stick in the editor does not drag the buttons along).
func _cell_rect(action: String) -> Rect2:
	var s := _button_size()
	var default_c: Vector2
	if action == LEFT_FIRE_KEY:
		var lp: Array = _layout["left_fire"]["pos"]
		default_c = Vector2(float(lp[0]) * _area().x, float(lp[1]) * _area().y)
	else:
		var o: Array = _layout["buttons"][action]["offset"]
		default_c = _rest_center("look_stick_rest") + Vector2(float(o[0]), float(o[1])) * s
	var c := _center_px(action, default_c)
	var side := _button_side(action)
	return Rect2(c - Vector2.ONE * side * 0.5, Vector2.ONE * side)


## Screen rect of the button for an action (the HUD is full-screen, so this is viewport space).
func get_button_rect(action: String) -> Rect2:
	return _to_global_rect(_cell_rect(action))


func get_button_label(action: String) -> String:
	return (_buttons[action] as Button).text


func get_button_actions() -> Array:
	return _buttons.keys()


func _style_button(b: Button, held: bool) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, float(_layout["button_held_alpha"]) if held else float(_layout["button_idle_alpha"]))
	sb.border_color = Color(1, 1, 1, 0.6)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(int(ceil(maxf(b.size.x, 1.0) * 0.5)))
	for state in ["normal", "hover", "pressed", "disabled"]:
		b.add_theme_stylebox_override(state, sb)


func _button_at(pos: Vector2) -> String:
	for action in _buttons:
		if not is_cover_slot_hidden(action) and get_button_rect(action).has_point(pos):
			return action
	return ""


## Stick radius in px: its slot scale on the default, never below half of the minimum target (48 dp).
func _radius(key: String = "move_stick") -> float:
	var base := maxf(1.0, float(_layout.get("stick_radius_frac_of_height", 0.12)) * _area().y)
	return maxf(base * _scale(key), 0.5 * get_element_min_px(key))


## Analog stick vector: distance from the origin over the radius, clamped to 1, with a dead zone.
func _stick(pos: Vector2, origin: Vector2, dead: float, key: String = "move_stick") -> Vector2:
	var v := (pos - origin) / _radius(key)
	if v.length() > 1.0:
		v = v.normalized()
	return Vector2.ZERO if v.length() < dead else v


## While the in-match menu is open the HUD ignores touches and drops everything it holds (sticks, buttons,
## fire pulse, sprint lock), so nothing is left pressed behind the menu.
func set_suspended(on: bool) -> void:
	suspended = on
	if not on:
		refresh_visibility()  # emulation off again: a thumb must not hold "fire"
		return
	_restore_emulation()  # menu buttons are clicked through emulated mouse events from touches
	for key in _button_touch.values():
		Input.action_release(_action_of(key))
		_style_button(_buttons[key], false)
	_button_touch.clear()
	for action in _VJOY_ACTIONS:
		Input.action_release(action)
	Input.action_release("fire")
	_fire_pulse_s = 0.0
	_look_hold_fire = false
	_hud_fire_down = false
	_shoulder_pulse_left_s = 0.0
	_apply_shoulder_pulse()
	_lock_btn_touch = -1
	_move_touch = -1
	_look_touch = -1
	provider.move_value = Vector2.ZERO
	provider.clear_look()
	provider.cancel_sprint_lock()
	_update_sticks()


func _input(event: InputEvent) -> void:
	if not visible or suspended:
		return
	if event is InputEventScreenTouch:
		if event.pressed:
			_on_down(event.index, event.position)
		else:
			_on_up(event.index)
		_debug_touch(event.index, event.pressed, event.position)
	elif event is InputEventScreenDrag:
		_on_drag(event.index, event.position, event.relative)


func _on_down(idx: int, pos: Vector2) -> void:
	# Hidden movement slots must not fall through into stick gestures either.
	if cover_controls_active:
		for key in _cover_hidden_slots:
			if get_element_rect(key).has_point(pos):
				return
	var action := _button_at(pos)
	if not is_cover_slot_hidden(LOCK_KEY) and get_lock_button_rect().has_point(pos):
		_lock_btn_touch = idx
		provider.toggle_sprint_lock()
	elif action != "":
		_button_touch[idx] = action  # the element key; _action_of(key) is the InputMap action it presses
		if _action_of(action) == "fire":
			_sync_fire_action()
		else:
			Input.action_press(_action_of(action))
		_style_button(_buttons[action], true)
		if action == "swap_shoulder":
			_shoulder_pulse_left_s = maxf(0.0, float(_layout["shoulder_pulse_release_s"]["value"]))
			_apply_shoulder_pulse()
	elif _move_touch == -1 and _move_grab_rect().has_point(pos):
		provider.cancel_sprint_lock()  # a new move-stick touch ends the lock (speed eases down in the pawn)
		_move_touch = idx  # under "virtual" this only tracks the finger; the VirtualJoystick gets the touch via the GUI
		_move_origin = pos
		_move_pos = pos
		_update_sticks()
	elif _look_touch == -1 and (_zone_hit_rect("look_zone").has_point(pos) or (vjoy_layout == "fixed" and move_mode == "virtual" and _zone_hit_rect("move_zone").has_point(pos))):
		_look_touch = idx
		_look_origin = pos
		_look_pos = pos
		_look_down_s = 0.0
		_look_hold_fire = false
		_look_moved = false
		_look_travel = 0.0
		provider.clear_look()
		_update_sticks()


## Debug overlay (data/ui.json touch_debug_overlay.enabled, default off): one line per held touch with its
## index, position and what it hit (button action, "move", "look" or "none").
func _debug_touch(idx: int, pressed: bool, pos: Vector2) -> void:
	if debug_label == null:
		return
	if pressed:
		var hit := "none"
		if _button_touch.has(idx):
			hit = String(_button_touch[idx])
		elif idx == _move_touch:
			hit = "move"
		elif idx == _look_touch:
			hit = "look"
		_debug_touches[idx] = "touch %d at (%d, %d) -> %s" % [idx, int(pos.x), int(pos.y), hit]
	else:
		_debug_touches.erase(idx)
	var lines: Array[String] = []
	for k in _debug_touches:
		lines.append(_debug_touches[k])
	debug_label.text = "\n".join(lines)


func _on_up(idx: int) -> void:
	if idx == _lock_btn_touch:
		_lock_btn_touch = -1
	elif _button_touch.has(idx):
		var key: String = _button_touch[idx]
		_button_touch.erase(idx)
		if not _button_touch.values().has(key):
			_style_button(_buttons[key], false)
		var still_held := false  # G3e: both Fire buttons press "fire"; it stays down while either is held
		for k in _button_touch.values():
			still_held = still_held or _action_of(k) == _action_of(key)
		if _action_of(key) == "fire":
			_sync_fire_action()
		elif not still_held:
			Input.action_release(_action_of(key))
	elif idx == _move_touch:
		# Released ON the lock target while pushed past the trigger: lock forward sprint. Anywhere else: stop.
		var on_target := provider.lock_target_visible() and get_lock_target_rect().has_point(_move_pos)
		_move_touch = -1
		provider.move_value = Vector2.ZERO
		if on_target:
			provider.lock_sprint()
		_update_sticks()
	elif idx == _look_touch:
		if not _look_hold_fire and not _look_moved and _look_down_s <= float(_layout.get("tap_fire_max_s", 0.2)):
			_fire_pulse_s = float(_layout.get("fire_pulse_s", 0.08))
		_look_touch = -1
		_look_hold_fire = false
		_sync_fire_action()
		provider.clear_look()
		_update_sticks()


## The general fire action is the union of Left Fire, a latched look hold and a tap pulse.
func _sync_fire_action() -> void:
	var held := _look_hold_fire or _fire_pulse_s > 0.0
	for key in _button_touch.values():
		held = held or _action_of(key) == "fire"
	if held and not suspended and not cover_controls_active:
		Input.action_press("fire")
		_hud_fire_down = true
	elif _hud_fire_down:
		Input.action_release("fire")
		_hud_fire_down = false


func _on_drag(idx: int, pos: Vector2, relative: Vector2) -> void:
	var dz: Dictionary = cfg.get("dead_zones", {})
	if idx == _move_touch:
		_move_pos = pos
		if move_mode != "virtual":
			provider.move_value = _stick(pos, _move_origin, float(dz.get("touch_move", 0.1)))
		_update_sticks()
	elif idx == _look_touch:
		_look_pos = pos
		if provider.look_mode == "drag":
			provider.add_drag(relative, _area().y)
			_look_travel += relative.length()
			if _look_travel > float(_layout.get("tap_slop_frac_of_height", 0.01)) * _area().y:
				_look_moved = true
		else:
			var v := _stick(pos, _look_origin, float(dz.get("touch_look", 0.1)), "look_stick")
			if v != Vector2.ZERO:
				_look_moved = true
			provider.look_value = v
		_update_sticks()
