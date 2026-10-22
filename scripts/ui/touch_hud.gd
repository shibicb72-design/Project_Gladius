extends Control
## Touch HUD: move stick (left), look stick with tap-to-fire (right), action buttons.
## Feeds TouchProvider; buttons press InputMap actions. Layout comes from data/input.json.

const _DataRegistry := preload("res://scripts/systems/data_registry.gd")
const _Platform := preload("res://scripts/platform/platform_services.gd")
const _TouchProvider := preload("res://scripts/input/providers/touch_provider.gd")

var provider: TouchProvider = _TouchProvider.new()
var cfg: Dictionary = {}
var _layout: Dictionary = {}
var _move_touch: int = -1
var _look_touch: int = -1
var _move_origin: Vector2 = Vector2.ZERO
var _look_origin: Vector2 = Vector2.ZERO
var _look_down_s: float = 0.0
var _look_moved: bool = false
var _fire_pulse_s: float = 0.0
var _button_touch: Dictionary = {}  # touch index -> action
var _buttons: Dictionary = {}  # action -> Control


func _ready() -> void:
	cfg = _DataRegistry.new().load_file("res://data/input.json")
	_layout = cfg.get("touch_layout", {})
	provider.configure(cfg)
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	for action in _layout.get("buttons", {}):
		var b := Button.new()
		b.text = String(action).substr(0, 1).to_upper()
		b.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.focus_mode = Control.FOCUS_NONE
		var spec: Dictionary = _layout["buttons"][action]
		var s := float(spec.get("size_px", 80.0))
		var a: Array = spec.get("anchor", [0.5, 0.5])
		b.anchor_left = a[0]
		b.anchor_right = a[0]
		b.anchor_top = a[1]
		b.anchor_bottom = a[1]
		b.offset_left = -s * 0.5
		b.offset_right = s * 0.5
		b.offset_top = -s * 0.5
		b.offset_bottom = s * 0.5
		add_child(b)
		_buttons[action] = b
	visible = should_show()


func should_show() -> bool:
	return bool(cfg.get("force_touch_hud", false)) or _Platform.new().is_touch_device()


func _process(delta: float) -> void:
	if _look_touch != -1:
		_look_down_s += delta
	if _fire_pulse_s > 0.0:
		_fire_pulse_s -= delta
		if _fire_pulse_s <= 0.0:
			Input.action_release("fire")


func _zone_rect(key: String) -> Rect2:
	var z: Dictionary = _layout.get(key, {})
	var s := size
	var l := float(z.get("left", 0.0)) * s.x
	var t := float(z.get("top", 0.0)) * s.y
	return Rect2(l, t, float(z.get("right", 1.0)) * s.x - l, float(z.get("bottom", 1.0)) * s.y - t)


func _button_at(pos: Vector2) -> String:
	for action in _buttons:
		if (_buttons[action] as Control).get_global_rect().has_point(pos):
			return action
	return ""


func _stick(pos: Vector2, origin: Vector2, dead: float) -> Vector2:
	var r := float(_layout.get("stick_radius_px", 120.0))
	var v := (pos - origin) / r
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
		_on_drag(event.index, event.position)


func _on_down(idx: int, pos: Vector2) -> void:
	var action := _button_at(pos)
	if action != "":
		_button_touch[idx] = action
		Input.action_press(action)
	elif _move_touch == -1 and _zone_rect("move_zone").has_point(pos):
		_move_touch = idx
		_move_origin = pos
	elif _look_touch == -1 and _zone_rect("look_zone").has_point(pos):
		_look_touch = idx
		_look_origin = pos
		_look_down_s = 0.0
		_look_moved = false


func _on_up(idx: int) -> void:
	if _button_touch.has(idx):
		Input.action_release(_button_touch[idx])
		_button_touch.erase(idx)
	elif idx == _move_touch:
		_move_touch = -1
		provider.move_value = Vector2.ZERO
	elif idx == _look_touch:
		if not _look_moved and _look_down_s <= float(_layout.get("tap_fire_max_s", 0.2)):
			Input.action_press("fire")
			_fire_pulse_s = float(_layout.get("fire_pulse_s", 0.08))
		_look_touch = -1
		provider.look_value = Vector2.ZERO


func _on_drag(idx: int, pos: Vector2) -> void:
	var dz: Dictionary = cfg.get("dead_zones", {})
	if idx == _move_touch:
		provider.move_value = _stick(pos, _move_origin, float(dz.get("touch_move", 0.1))) * Vector2(1, 1)
	elif idx == _look_touch:
		var v := _stick(pos, _look_origin, float(dz.get("touch_look", 0.1)))
		if v != Vector2.ZERO:
			_look_moved = true
		provider.look_value = v
