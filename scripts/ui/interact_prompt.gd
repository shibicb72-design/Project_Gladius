class_name InteractPrompt
extends Control
## M2 H1b commit 2: the prompt at the object. ONE prompt, for exactly the target the Interact button acts on (revive >
## pickup > chest > door: the director's *_target_for functions in the order of InteractButton._label_text and
## MatchRoot._on_action_triggered), drawn at that target's screen point and pointing at it, or clamped to the screen edge
## with an arrow when the target is off screen or behind the camera. Shown exactly while the Interact button is shown
## (it reads button.visible, so the menu, a hidden or suspended touch HUD and a LAN client hide both), never on its own.
## data/ui.json interact_prompt (every number and text a placeholder, OQ-HUD).
##
## Input (scripts/ui/, the touch HUD's own layer; no gameplay code reads raw touches): the prompt NEVER consumes a touch.
## The touch HUD sees every press on it as if it were not there (a look drag in the right half, the move stick in the
## left half, from the press point, so no look movement is lost). The prompt only watches the finger:
##   TAP (pickup, chest, door): released within tap_max_s and never more than tap_travel_dp from the press point ->
##        one interact press and release through touch_hud.provider (trigger_action / release_action "interact"), the
##        calls the Interact button makes.
##   HOLD (revive): the finger stays within tap_travel_dp for hold_start_s -> interact is pressed and held until the finger
##        lifts (release) or moves beyond tap_travel_dp (release; the finger goes on turning the view).
##   DRAG: the finger moves beyond tap_travel_dp first -> the prompt lets go of it and does nothing.
## The prompt and the Interact button never both press: a press inside the button's (or any touch HUD button's) rect
## is the button's; a press is ignored while the button is held; a pending press is dropped when the button goes down;
## while the prompt holds interact it swallows new presses on the Interact button. Release on hide: when the prompt
## hides while it holds interact it sends the release (cancel), as InteractButton.refresh does.

const ACTION := "interact"
const KIND_REVIVE := "revive"
const KIND_PICKUP := "pickup"
const KIND_CHEST := "chest"
const KIND_DOOR := "door"

var pawn: Pawn
var director: MatchDirector
var touch_hud: Control
var button: InteractButton
var pause_menu: PauseMenu
var cfg: Dictionary = {}
## data/ui.json interact_prompt.enabled; tests and tools may switch it in memory.
var enabled: bool = true

## The current target (read-only; tests read these). kind "" = none.
var kind: String = ""
var target_int: int = -1  # revive: player id; pickup: loot item id
var target_str: String = ""  # chest / door prop id
var text: String = ""
var target_world := Vector3.ZERO
## The screen point the pointer touches: the projected target point, or the screen-edge point toward it when clamped.
var anchor := Vector2.ZERO
var clamped: bool = false
var label: Label

var _dir := Vector2.ZERO  # unit direction toward an off-screen target (screen space)
var _text_key: String = ""
var _text_px: float = 0.0
var _text_w: float = 0.0
var _view := Vector2.ZERO
var _obs: Array[Rect2] = []
var _obs_age: float = INF
var _plate_style: StyleBoxFlat
var _style_u: float = -1.0
# finger tracking
var _track: int = -1
var _mouse_track: bool = false
var _start := Vector2.ZERO
var _held_s: float = 0.0
var _holding: bool = false


func _ready() -> void:
	name = "InteractPrompt"
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme = preload("res://scenes/ui/theme.tres")
	if cfg.is_empty():
		cfg = HudArrangement.ui().get("interact_prompt", {})
	enabled = bool(cfg.get("enabled", true))
	set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	label = HudStyle.label(self, HORIZONTAL_ALIGNMENT_LEFT, HudStyle.role("text"))
	visible = false


func bind(local_pawn: Pawn, match_director: MatchDirector, touch: Control, interact: InteractButton, menu: PauseMenu) -> void:
	pawn = local_pawn
	director = match_director
	touch_hud = touch
	button = interact
	pause_menu = menu


func _f(key: String) -> float:
	return float(cfg[key])


func _dp() -> float:
	return HudArrangement.dp()


# --- target ------------------------------------------------------------------------------------------------------------

## The Interact button's target, read through the director in the button's order (InteractButton._label_text):
## revive, then pickup (with loot), then chest, then door (with props). Sets kind / target_int / target_str.
func resolve() -> void:
	kind = ""
	target_int = -1
	target_str = ""
	if not is_instance_valid(director) or not is_instance_valid(pawn):
		return
	var id := pawn.player_id
	var r := director.revive_target_for(id)
	if r >= 0:
		kind = KIND_REVIVE
		target_int = r
		return
	var item := director.pickup_target_for(id)
	if item >= 0 and director.loot != null:
		kind = KIND_PICKUP
		target_int = item
		return
	var chest := director.chest_target_for(id)
	if chest != "":
		kind = KIND_CHEST
		target_str = chest
		return
	var door := director.door_target_for(id)
	if door != "" and director.props != null:
		kind = KIND_DOOR
		target_str = door


## World point of the current target (before anchor_up_m); false when it cannot be read.
func _target_point() -> bool:
	match kind:
		KIND_REVIVE:
			var p: Pawn = director.player(target_int)
			if p == null or not is_instance_valid(p):
				return false
			target_world = p.global_position
		KIND_PICKUP:
			if not director.loot.items.has(target_int):
				return false
			target_world = director.loot.items[target_int]["pos"]
		KIND_CHEST:
			var c: Node3D = director.props.chests.get(target_str)
			if c == null or not is_instance_valid(c):
				return false
			target_world = c.global_position
		KIND_DOOR:
			var d: Node3D = director.props.doors.get(target_str)
			if d == null or not is_instance_valid(d):
				return false
			target_world = d.global_position
		_:
			return false
	target_world.y += float(cfg["anchor_up_m"].get(kind, 0.0))
	return true


## The prompt text for the current target (data texts); rebuilt only when the target or the door state changes.
func _update_text() -> void:
	var key := kind
	if kind == KIND_DOOR:
		key = "%s_%s_%d" % [target_str, director.props.door_kind(target_str), director.props.state_of(target_str)]
	elif kind == KIND_PICKUP:
		key = "p%d" % target_int
	elif kind == KIND_REVIVE:
		key = "revive"
	if key == _text_key:
		return
	_text_key = key
	var t: Dictionary = cfg["texts"]
	match kind:
		KIND_REVIVE:
			text = str(t["revive"])
		KIND_PICKUP:
			text = str(t["pickup"]) % director.loot.display_name(target_int)
		KIND_CHEST:
			text = str(t["chest"])
		KIND_DOOR:
			var noun := "gate" if director.props.door_kind(target_str) == Door.KIND_GATE else "door"
			var open := director.props.state_of(target_str) == WorldProps.OPEN
			text = str(t["%s_%s" % [noun, "close" if open else "open"]])
	label.text = text
	_text_px = -1.0  # re-measure


# --- refresh and placement ---------------------------------------------------------------------------------------------

func _process(delta: float) -> void:
	_obs_age += delta
	refresh()


## Shown exactly while the Interact button is shown (and the prompt is enabled, a camera exists and the target point can
## be read). Hiding while holding interact sends the release (cancel), as the button does.
func refresh() -> void:
	var show := enabled and is_instance_valid(button) and button.visible and is_instance_valid(touch_hud)
	if show:
		resolve()
		show = kind != "" and _target_point()
	var cam: Camera3D = get_viewport().get_camera_3d() if show else null
	show = show and cam != null
	if not show:
		if visible or _track != -1 or _mouse_track:
			_drop_finger(true)
		visible = false
		return
	_update_text()
	visible = true
	_place(cam)


## Camera3D.unproject_position gives viewport pixels; the HUD draws in canvas units, which differ under the project's
## canvas_items stretch (the root window): undo the viewport's stretch (identity in a plain SubViewport).
static func to_canvas(cam: Camera3D, pixel: Vector2) -> Vector2:
	return cam.get_viewport().get_final_transform().affine_inverse() * pixel


## Screen anchor of a world point: the projected point when it is on screen (inside `inner`), else the point where the
## ray from the screen centre toward the target meets `inner` (behind the camera: toward the target in camera space).
## Sets anchor, clamped and _dir. Public so tests can call it with any camera and point.
func screen_anchor(cam: Camera3D, world: Vector3, view: Vector2, margin: float) -> void:
	var inner := Rect2(Vector2.ONE * margin, view - Vector2.ONE * 2.0 * margin)
	var behind := cam.is_position_behind(world)
	var p := Vector2.ZERO
	if not behind:
		p = to_canvas(cam, cam.unproject_position(world))
		if inner.has_point(p):
			anchor = p
			clamped = false
			_dir = Vector2.ZERO
			return
	var d := Vector2.ZERO
	if behind:
		var local := cam.global_transform.affine_inverse() * world
		d = Vector2(local.x, -local.y)
	else:
		d = p - view * 0.5
	if d.length_squared() < 1e-6:
		d = Vector2(0.0, 1.0)
	d = d.normalized()
	var c := view * 0.5
	var half := inner.size * 0.5
	var t := INF
	if absf(d.x) > 1e-6:
		t = minf(t, half.x / absf(d.x))
	if absf(d.y) > 1e-6:
		t = minf(t, half.y / absf(d.y))
	anchor = c + d * t
	clamped = true
	_dir = d


## The plate (and tap target) rect in view space for the current text, anchor and view. Public for tests.
func plate_rect(view: Vector2) -> Rect2:
	var u := HudArrangement.unit(view)
	var px := _f("font_units") * u
	if absf(px - _text_px) > 0.01:
		_text_px = px
		HudStyle.set_font_px(label, px)
		# The outline on both sides plus a little slack: the label cuts its text with an ellipsis at its exact width.
		_text_w = label.get_theme_font("font").get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, roundi(px)).x \
				+ 2.0 * maxf(1.0, roundf(px * 0.12)) + 0.3 * px
	var min_tap := _f("min_tap_dp") * _dp()
	var h := maxf(_f("height_units") * u, min_tap)
	var w := _f("pad_units") * u * 2.0 + _f("icon_units") * u + _f("icon_gap_units") * u + _text_w
	w = clampf(w, min_tap, maxf(min_tap, _f("max_width_frac") * view.x))
	var margin := _f("screen_margin_dp") * _dp()
	var tail := _f("tail_units") * u
	var r := Rect2()
	if not clamped:
		r = Rect2(anchor.x - w * 0.5, anchor.y - tail - h, w, h)
	else:
		var half_along := absf(_dir.x) * w * 0.5 + absf(_dir.y) * h * 0.5
		var c := anchor - _dir * (half_along + tail)
		r = Rect2(c - Vector2(w, h) * 0.5, Vector2(w, h))
	r = _clamp_rect(r, view, margin)
	return _avoid(r, view, margin)


static func _clamp_rect(r: Rect2, view: Vector2, margin: float) -> Rect2:
	r.position.x = clampf(r.position.x, margin, maxf(margin, view.x - margin - r.size.x))
	r.position.y = clampf(r.position.y, margin, maxf(margin, view.y - margin - r.size.y))
	return r


## Every other touch target the prompt should not cover (view space): the touch HUD buttons (as its hit test sees them),
## the Sprint lock button, the Interact button, the fire-mode button, the pause gear and (when drawn) the minimap tap; and
## the passive weapon block, objective strip and alive / zone chip (so the prompt never hides them).
## Refreshed on a view change and every avoid_refresh_s.
func _refresh_obstacles(view: Vector2) -> void:
	if view == _view and _obs_age < _f("avoid_refresh_s"):
		return
	_view = view
	_obs_age = 0.0
	var n := 0
	var keys: Dictionary = touch_hud._buttons
	_obs.resize(keys.size() + 8)
	# The passive weapon block, objective strip and chip are not touch targets, but the prompt must not hide them.
	_obs[n] = HudArrangement.weapon_block_rect(view)
	_obs[n + 1] = HudArrangement.objective_rect(view)
	_obs[n + 2] = HudArrangement.chip_rect(view)
	n += 3
	for key in keys:
		_obs[n] = touch_hud.get_button_rect(key)
		n += 1
	_obs[n] = touch_hud.get_lock_button_rect()
	_obs[n + 1] = button.get_touch_rect() if is_instance_valid(button) else Rect2()
	_obs[n + 2] = FireModeButton.touch_rect(HudArrangement.ui()["fire_mode_button"], view)
	_obs[n + 3] = pause_menu.get_gear_touch_rect() if is_instance_valid(pause_menu) else Rect2()
	_obs[n + 4] = HudArrangement.minimap_tap_rect(view) if bool(HudArrangement.ui()["minimap"].get("enabled", false)) else Rect2()


## Moves the rect off any touch target or display it covers (a few passes; above a target in the bottom half, below one in
## the top half); if that would leave the screen, keeps the clamped place (the targets still win their presses:
## _accept_point).
func _avoid(r: Rect2, view: Vector2, margin: float) -> Rect2:
	if not is_instance_valid(touch_hud):
		return r
	_refresh_obstacles(view)
	var gap := _f("avoid_gap_dp") * _dp()
	var out := r
	for i in 3:
		var moved := false
		for o in _obs:
			if o.size.x <= 0.0 or not out.intersects(o.grow(gap)):
				continue
			if o.get_center().y < view.y * 0.5:
				out.position.y = o.end.y + gap  # a target in the top half: below it
			else:
				out.position.y = o.position.y - gap - out.size.y  # in the bottom half: above it
			moved = true
		if not moved:
			break
	if out.position.y < margin or out.end.y > view.y - margin:
		return r
	return out


func _place(cam: Camera3D) -> void:
	var view := get_viewport_rect().size
	screen_anchor(cam, target_world, view, _f("screen_margin_dp") * _dp())
	var r := plate_rect(view)
	global_position = r.position
	size = r.size
	var u := HudArrangement.unit(view)
	var pad := _f("pad_units") * u
	var icon := _f("icon_units") * u
	var x0 := pad + icon + _f("icon_gap_units") * u
	label.position = Vector2(x0, 0.0)
	label.size = Vector2(maxf(1.0, r.size.x - x0 - pad), r.size.y)
	if absf(u - _style_u) > 0.01:
		_style_u = u
		_plate_style = HudStyle.plate(0.35 * r.size.y, maxf(1.0, _f("line_units") * u), _f("plate_alpha"))
	queue_redraw()


# --- drawing -----------------------------------------------------------------------------------------------------------

func _draw() -> void:
	if cfg.is_empty() or size.x <= 0.0 or _plate_style == null:
		return
	var u := HudArrangement.unit(_view if _view != Vector2.ZERO else get_viewport_rect().size)
	var gold := MenuStyle.color("gold")
	var night := MenuStyle.color("night")
	var line := maxf(1.0, _f("line_units") * u)
	var pressed := _track != -1 or _mouse_track
	var plate := Rect2(Vector2.ZERO, size)
	var a := anchor - global_position
	# Pointer: a tapered tail from the plate edge toward the anchor, then a thin line and a marker (or, clamped, an arrow).
	var c := plate.get_center()
	var v := a - c
	if not plate.has_point(a) and v.length() > 1.0:
		var t := INF
		if absf(v.x) > 1e-4:
			t = minf(t, plate.size.x * 0.5 / absf(v.x))
		if absf(v.y) > 1e-4:
			t = minf(t, plate.size.y * 0.5 / absf(v.y))
		var b := c + v * minf(t, 1.0)
		var vn := v.normalized()
		var perp := Vector2(-vn.y, vn.x) * _f("tail_base_units") * u * 0.5
		var dist := b.distance_to(a)
		var tail_len := minf(_f("tail_units") * u, dist)
		var tip := b + vn * tail_len
		var tri := PackedVector2Array([b + perp, tip, b - perp])
		if clamped:
			# Off screen: a short gold arrowhead out of the plate toward the target (it never reaches across other controls).
			tri = PackedVector2Array([b + perp * 1.3, tip, b - perp * 1.3])
			draw_colored_polygon(tri, gold)
			tri.append(tri[0])
			draw_polyline(tri, night, line, true)
		else:
			draw_colored_polygon(tri, night)
			draw_polyline(PackedVector2Array([b + perp, tip, b - perp]), gold, line, true)
		if not clamped:
			if dist > tail_len + 0.5:
				draw_line(tip, a, night, line * 3.0, true)
				draw_line(tip, a, gold, line, true)
			var m := _f("marker_units") * u
			var dia := PackedVector2Array([a + Vector2(0, -m), a + Vector2(m, 0), a + Vector2(0, m), a + Vector2(-m, 0)])
			draw_colored_polygon(dia, gold)
			dia.append(dia[0])
			draw_polyline(dia, night, line, true)
	var sb := _plate_style
	if pressed:
		sb.bg_color.a = _f("pressed_alpha")
		sb.border_color = MenuStyle.color("gold_hi")
	else:
		sb.bg_color.a = _f("plate_alpha")
		sb.border_color = Color(gold, 0.9)
	draw_style_box(sb, plate)
	_draw_icon(Vector2(_f("pad_units") * u + _f("icon_units") * u * 0.5, size.y * 0.5), _f("icon_units") * u * 0.5, line)


## Our own drawn icon per kind on a disc: pickup an arrow into a tray, chest a box with a lid, door a doorway with its
## leaf, revive a cross (crimson disc). While the revive is held, a gold ring fills over the revive time.
func _draw_icon(c: Vector2, r: float, line: float) -> void:
	var gold := MenuStyle.color("gold")
	var night := MenuStyle.color("night")
	var disc := MenuStyle.color("crimson_hi") if kind == KIND_REVIVE else gold
	var ink := MenuStyle.color("marble") if kind == KIND_REVIVE else night
	draw_circle(c, r, disc, true, -1.0, true)
	draw_arc(c, r, 0.0, TAU, 32, night, line, true)
	var s := r * 0.55
	var w := maxf(1.0, line * 1.8)
	match kind:
		KIND_PICKUP:
			draw_line(c + Vector2(0, -s), c + Vector2(0, s * 0.45), ink, w, true)
			draw_polyline(PackedVector2Array([c + Vector2(-s * 0.5, 0), c + Vector2(0, s * 0.5), c + Vector2(s * 0.5, 0)]), ink, w, true)
			draw_line(c + Vector2(-s * 0.8, s * 0.85), c + Vector2(s * 0.8, s * 0.85), ink, w, true)
		KIND_CHEST:
			draw_rect(Rect2(c + Vector2(-s * 0.85, -s * 0.45), Vector2(s * 1.7, s * 1.2)), ink, false, w)
			draw_line(c + Vector2(-s * 0.85, -s * 0.05), c + Vector2(s * 0.85, -s * 0.05), ink, w, true)
			draw_rect(Rect2(c + Vector2(-s * 0.15, -s * 0.15), Vector2(s * 0.3, s * 0.3)), ink, true)
		KIND_DOOR:
			draw_polyline(PackedVector2Array([c + Vector2(-s * 0.7, s), c + Vector2(-s * 0.7, -s), c + Vector2(s * 0.7, -s), c + Vector2(s * 0.7, s)]), ink, w, true)
			draw_rect(Rect2(c + Vector2(-s * 0.7, -s), Vector2(s * 0.7, s * 2.0)), ink, true)
		KIND_REVIVE:
			draw_rect(Rect2(c + Vector2(-s * 0.25, -s * 0.8), Vector2(s * 0.5, s * 1.6)), ink, true)
			draw_rect(Rect2(c + Vector2(-s * 0.8, -s * 0.25), Vector2(s * 1.6, s * 0.5)), ink, true)
			if _holding:
				var revive_s := maxf(0.01, float(director.mode_cfg.get("downed", {}).get("revive_s", 1.0)))
				var k := clampf((_held_s - _f("hold_start_s")) / revive_s, 0.0, 1.0)
				draw_arc(c, r + line * 2.0, -PI * 0.5, -PI * 0.5 + TAU * k, 40, MenuStyle.color("gold_hi"), line * 2.5, true)


# --- input -------------------------------------------------------------------------------------------------------------

func _input_provider() -> InputProvider:
	if is_instance_valid(touch_hud) and touch_hud.provider != null:
		return touch_hud.provider
	return null


func _button_pressed() -> bool:
	return is_instance_valid(button) and button._is_pressed()


## A press the prompt may watch: on its tap target, while shown, not on the Interact button or any other touch HUD
## target (those keep their presses), and not while the button is held.
func _accept_point(p: Vector2) -> bool:
	if not visible or not is_visible_in_tree() or not get_global_rect().has_point(p) or _button_pressed():
		return false
	if is_instance_valid(button) and button.visible and button.get_touch_rect().has_point(p):
		return false
	if touch_hud._button_at(p) != "" or touch_hud.lock_button_hit(p):  # M2 H1c: the lock button only while shown
		return false
	return true


func _travel_px() -> float:
	return _f("tap_travel_dp") * _dp()


func _begin(p: Vector2) -> void:
	_start = p
	_held_s = 0.0
	_holding = false
	queue_redraw()


func _press() -> void:
	var input := _input_provider()
	if input != null:
		input.trigger_action(ACTION)


func _release(cancel: bool) -> void:
	var input := _input_provider()
	if input != null:
		input.release_action(ACTION, cancel)


## Lets go of the finger (or mouse). If the prompt holds interact, releases it.
func _drop_finger(cancel: bool) -> void:
	if _holding:
		_release(cancel)
	_holding = false
	_track = -1
	_mouse_track = false
	queue_redraw()


## The finger lifted: a TAP on a tap kind presses and releases interact once; a held revive is released.
func _finish() -> void:
	if _holding:
		_drop_finger(false)
		return
	var tap := kind != KIND_REVIVE and kind != "" and _held_s <= _f("tap_max_s") and not _button_pressed() and visible
	_drop_finger(false)
	if tap:
		_press()
		_release(false)


func _moved(p: Vector2) -> void:
	if p.distance_to(_start) > _travel_px():
		_drop_finger(false)  # a drag: the touch HUD already turns the view (or moves the stick) from the press point


func _physics_process(delta: float) -> void:
	if _track == -1 and not _mouse_track:
		return
	if not visible or (_button_pressed() and not _holding):
		_drop_finger(true)
		return
	_held_s += delta
	if kind == KIND_REVIVE and not _holding and _held_s >= _f("hold_start_s"):
		_holding = true
		_press()
	if _holding:
		queue_redraw()


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			if _holding and is_instance_valid(button) and button.visible and button.get_touch_rect().has_point(event.position):
				get_viewport().set_input_as_handled()  # never both: the prompt holds interact
			elif _track == -1 and not _mouse_track and _accept_point(event.position):
				_track = event.index
				_begin(event.position)
		elif event.index == _track:
			_finish()
	elif event is InputEventScreenDrag:
		if event.index == _track:
			_moved(event.position)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.device != InputEvent.DEVICE_ID_EMULATION:
		if event.pressed:
			if _track == -1 and not _mouse_track and _accept_point(event.position):
				_mouse_track = true
				_begin(event.position)
		elif _mouse_track:
			_finish()
	elif event is InputEventMouseMotion and _mouse_track and event.device != InputEvent.DEVICE_ID_EMULATION:
		_moved(event.position)


func _exit_tree() -> void:
	if _holding:
		_release(true)
	_holding = false
	_track = -1
	_mouse_track = false
