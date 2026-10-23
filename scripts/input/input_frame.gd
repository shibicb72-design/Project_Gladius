class_name InputFrame
extends RefCounted
## One tick of merged input. Plain data, serializable for networking.

const BUTTONS: Array[String] = ["fire", "aim", "reload", "swap_weapon", "jump", "pause"]

var move: Vector2 = Vector2.ZERO
var look: Vector2 = Vector2.ZERO
var fire_pressed: bool = false
var aim_pressed: bool = false
var reload_pressed: bool = false
var swap_weapon_pressed: bool = false
var jump_pressed: bool = false
var pause_pressed: bool = false
var fire_just_pressed: bool = false
var aim_just_pressed: bool = false
var reload_just_pressed: bool = false
var swap_weapon_just_pressed: bool = false
var jump_just_pressed: bool = false
var pause_just_pressed: bool = false
## World point under the camera centre (right-shoulder camera, GBTN4); set by the match, not by a provider.
var has_aim_point: bool = false
var aim_point: Vector3 = Vector3.ZERO


func is_pressed(action: String) -> bool:
	return bool(get(action + "_pressed"))


func is_just_pressed(action: String) -> bool:
	return bool(get(action + "_just_pressed"))


func set_button(action: String, pressed: bool, just_pressed: bool) -> void:
	set(action + "_pressed", pressed)
	set(action + "_just_pressed", just_pressed)


## [move.x, move.y, look.x, look.y, pressed_mask, just_pressed_mask, has_aim_point, aim.x, aim.y, aim.z]
func to_array() -> Array:
	var held := 0
	var just := 0
	for i in BUTTONS.size():
		if is_pressed(BUTTONS[i]):
			held |= 1 << i
		if is_just_pressed(BUTTONS[i]):
			just |= 1 << i
	return [move.x, move.y, look.x, look.y, held, just, has_aim_point, aim_point.x, aim_point.y, aim_point.z]


static func from_array(a: Array) -> InputFrame:
	var f := InputFrame.new()
	if a.size() < 6:
		return f
	f.move = Vector2(a[0], a[1])
	f.look = Vector2(a[2], a[3])
	for i in BUTTONS.size():
		f.set_button(BUTTONS[i], (int(a[4]) >> i) & 1 == 1, (int(a[5]) >> i) & 1 == 1)
	if a.size() >= 10:
		f.has_aim_point = bool(a[6])
		f.aim_point = Vector3(a[7], a[8], a[9])
	return f
