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
var _button_touch: Dictionary = {}  # touch index -> action
var _buttons: Dictionary = {}  # action -> Control
var move_stick: StickVisual
var look_stick: StickVisual
var _emulation_overridden: bool = false
var _prev_emulation: bool = true


func _ready() -> void:
	cfg = _DataRegistry.new().load_file("res://data/input.json")
	_layout = cfg.get("touch_layout", {})
	provider.configure(cfg)
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var anchor: Array = _layout.get("button_anchor", [1.0, 1.0])
	for action in _layout.get("buttons", {}):
		var spec: Dictionary = _layout["buttons"][action]
		var b := Button.new()
		b.text = String(spec.get("label", action))
		b.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.focus_mode = Control.FOCUS_NONE
		b.anchor_left = anchor[0]
		b.anchor_right = anchor[0]
		b.anchor_top = anchor[1]
		b.anchor_bottom = anchor[1]
		add_child(b)
		_buttons[action] = b
	for s in ["move_stick", "look_stick"]:
		var v := StickVisual.new()
		v.name = s
		v.ring_alpha = float(_layout.get("ring_alpha", 0.35))
		v.knob_frac = float(_layout.get("knob_frac_of_radius", 0.4))
		add_child(v)
	move_stick = get_node("move_stick")
	look_stick = get_node("look_stick")
	resized.connect(relayout)
	get_viewport().size_changed.connect(relayout)
	relayout()
	refresh_visibility()


func _exit_tree() -> void:
	_restore_emulation()
	for idx in _button_touch:
		Input.action_release(_button_touch[idx])
	_button_touch.clear()
	if _fire_pulse_s > 0.0:
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


func _process(delta: float) -> void:
	if _look_touch != -1:
		_look_down_s += delta
	if _fire_pulse_s > 0.0:
		_fire_pulse_s -= delta
		if _fire_pulse_s <= 0.0:
			Input.action_release("fire")


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
	var s := _button_size()
	for action in _buttons:
		var b: Button = _buttons[action]
		var cell := _cell_rect(_layout["buttons"][action])
		b.offset_left = cell.position.x - _anchor_point().x
		b.offset_top = cell.position.y - _anchor_point().y
		b.offset_right = b.offset_left + s
		b.offset_bottom = b.offset_top + s
		b.add_theme_font_size_override("font_size", int(s * float(_layout.get("button_font_frac_of_size", 0.24))))
		_style_button(b, _button_touch.values().has(action))
	_update_sticks()


## Rest centre of a stick in HUD space, from data (x of width, y of height).
func _rest_center(key: String, fallback: Array) -> Vector2:
	var a: Array = _layout.get(key, fallback)
	var s := _area()
	return Vector2(float(a[0]) * s.x, float(a[1]) * s.y)


func get_move_rest() -> Vector2:
	return _rest_center("move_stick_rest", [0.15, 0.76])


func get_look_rest() -> Vector2:
	return _rest_center("look_stick_rest", [0.58, 0.76])


## Places both stick rings: look is fixed at rest; move follows the thumb while held and returns to rest on release.
func _update_sticks() -> void:
	if move_stick == null:
		return
	var r := _radius()
	var look_c := get_look_rest()
	look_stick.place(look_c, r)
	look_stick.set_knob_offset((_look_pos - _look_origin) if _look_touch != -1 else Vector2.ZERO)
	if _move_touch != -1:
		move_stick.place(_move_origin, r)
		move_stick.set_knob_offset(_move_pos - _move_origin)
	else:
		move_stick.place(get_move_rest(), r)
		move_stick.set_knob_offset(Vector2.ZERO)


func _anchor_point() -> Vector2:
	var a: Array = _layout.get("button_anchor", [1.0, 1.0])
	var area := _area()
	return Vector2(float(a[0]) * area.x, float(a[1]) * area.y)


func _button_size() -> float:
	return float(_layout.get("button_size_frac_of_height", 0.16)) * _area().y


func _cell_rect(spec: Dictionary) -> Rect2:
	var s := _button_size()
	var step := s + float(_layout.get("button_gap_frac_of_height", 0.02)) * _area().y
	var corner := _anchor_point()
	return Rect2(corner.x - s - int(spec.get("col", 0)) * step, corner.y - s - int(spec.get("row", 0)) * step, s, s)


## Screen rect of the button for an action (the HUD is full-screen, so this is viewport space).
func get_button_rect(action: String) -> Rect2:
	var r := _cell_rect(_layout["buttons"][action])
	r.position += global_position
	return r


func get_button_label(action: String) -> String:
	return (_buttons[action] as Button).text


func get_button_actions() -> Array:
	return _buttons.keys()


func _style_button(b: Button, held: bool) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.5 if held else 0.22)
	sb.border_color = Color(1, 1, 1, 0.6)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(int(ceil(_button_size() * 0.5)))
	for state in ["normal", "hover", "pressed", "disabled"]:
		b.add_theme_stylebox_override(state, sb)


func _button_at(pos: Vector2) -> String:
	for action in _buttons:
		if get_button_rect(action).has_point(pos):
			return action
	return ""


func _radius() -> float:
	return maxf(1.0, float(_layout.get("stick_radius_frac_of_height", 0.12)) * _area().y)


## Analog stick vector: distance from the origin over the radius, clamped to 1, with a dead zone.
func _stick(pos: Vector2, origin: Vector2, dead: float) -> Vector2:
	var v := (pos - origin) / _radius()
	if v.length() > 1.0:
		v = v.normalized()
	return Vector2.ZERO if v.length() < dead else v


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventScreenTouch:
		if event.pressed:
			_on_down(event.index, event.position)
		else:
			_on_up(event.index)
	elif event is InputEventScreenDrag:
		_on_drag(event.index, event.position, event.relative)


func _on_down(idx: int, pos: Vector2) -> void:
	var action := _button_at(pos)
	if action != "":
		_button_touch[idx] = action
		Input.action_press(action)
		_style_button(_buttons[action], true)
	elif _move_touch == -1 and _zone_rect("move_zone").has_point(pos):
		_move_touch = idx
		_move_origin = pos
		_move_pos = pos
		_update_sticks()
	elif _look_touch == -1 and _zone_rect("look_zone").has_point(pos):
		_look_touch = idx
		_look_origin = pos
		_look_pos = pos
		_look_down_s = 0.0
		_look_moved = false
		_look_travel = 0.0
		provider.clear_look()
		_update_sticks()


func _on_up(idx: int) -> void:
	if _button_touch.has(idx):
		var action: String = _button_touch[idx]
		_button_touch.erase(idx)
		if not _button_touch.values().has(action):
			Input.action_release(action)
			_style_button(_buttons[action], false)
	elif idx == _move_touch:
		_move_touch = -1
		provider.move_value = Vector2.ZERO
		_update_sticks()
	elif idx == _look_touch:
		if not _look_moved and _look_down_s <= float(_layout.get("tap_fire_max_s", 0.2)):
			Input.action_press("fire")
			_fire_pulse_s = float(_layout.get("fire_pulse_s", 0.08))
		_look_touch = -1
		provider.clear_look()
		_update_sticks()


func _on_drag(idx: int, pos: Vector2, relative: Vector2) -> void:
	var dz: Dictionary = cfg.get("dead_zones", {})
	if idx == _move_touch:
		_move_pos = pos
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
			var v := _stick(pos, _look_origin, float(dz.get("touch_look", 0.1)))
			if v != Vector2.ZERO:
				_look_moved = true
			provider.look_value = v
		_update_sticks()
