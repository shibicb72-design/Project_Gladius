class_name HudCoach
extends Control
## M2 H1b commit 5 (OQ-COACH): the first-play coach. A short, skippable sequence of one-line hints on the player's first
## real match, ONE at a time, each pointing at its control with a gold ring and a pointer. Data: data/coach.json (steps,
## wording, timing, sizes; every number and text a placeholder).
## - Gate (HudCoach.wanted): coach.enabled AND the explicit real-match flag (AppFlow.coach_route, set only by the lobby
##   screen's match start, the one menu and lobby route; consumed by GameHud.bind) AND profile coach_done missing / false.
##   Tests, sims and capture tools never set the flag, so the coach never shows there unless they build one on purpose.
## - Steps (data order): move, look, aim, fire (per shooting mode: Advanced points at Fire; Simple at the crosshair, the sight
##   fires by itself), cover, pick up, the map (+ the radar in the same line). Each advances when the player does the thing
##   (read-only: pawn position / yaw / aiming / fired / in_cover, an interact press seen on the touch provider's
##   action_triggered signal, the minimap expanding) or after its timeout_s, whichever first. A step whose control is not
##   there (no Cover button on a LAN client, no pickup in reach) waits up to wait_s, nothing shown, then is skipped.
## - Never blocks input, never pauses: every node is mouse_filter IGNORE, _input consumes ONLY a press on Skip (like the
##   minimap's tap target). The coach never touches the tree's pause or the time scale.
## - Hidden and frozen (timers stop, the step resumes where it was) while: no touch HUD shown, the pause menu is open, the
##   touch HUD is suspended, the GameHud is hidden, the pawn is not ALIVE (downed, dead, spectating), the pawn is aboard or
##   falling (the drop), or the expanded map is open (except on the map step, which that open finishes).
## - When the sequence ends or Skip is pressed, coach_done = true is saved to the profile at once.
## - Hints avoid the objective line, the kill banner, the weapon block, the chip, the radar / minimap panel, the
##   crosshair, every touch control and the ring of the control they point at.

signal finished(was_skipped: bool)

const _Theme := preload("res://scenes/ui/theme.tres")
const NODE_NAME := "HudCoach"
const DATA_PATH := "res://data/coach.json"
const PHASE_START := "start"
const PHASE_SHOW := "show"
const PHASE_GAP := "gap"
const PHASE_WAIT := "wait"
const PHASE_DONE := "done"

## Capture tools / tests: a step index to force (shown at once, timers frozen), -1 = the normal sequence.
var forced_step: int = -1

var director: MatchDirector
var pawn: Pawn
var touch_hud: Control
var pause_menu: PauseMenu
## The GameHud (minimap, Interact button and prompt are read from it); null in some tests.
var game_hud: Control
var save: SaveService = SaveService.new()
var steps: Array = []
var index: int = 0
var phase: String = PHASE_START
var phase_s: float = 0.0
var skipped: bool = false
## Why the coach is hidden right now ("" = running): no_pawn, no_touch_hud, menu, hud_hidden, downed, drop, map.
var paused_reason: String = ""
## [{"id", "how": "action" | "timeout" | "not_applicable" | "lost" | "skipped"}] in order.
var history: Array = []

var _fired := false
var _interacted := false
var _moved_m := 0.0
var _turned_deg := 0.0
var _have_base := false
var _last_pos := Vector3.ZERO
var _last_yaw := 0.0
var _pulse_s := 0.0
var _provider_bound: InputProvider

static var _data: Dictionary = {}


static func data() -> Dictionary:
	if _data.is_empty():
		_data = DataRegistry.new().load_file(DATA_PATH)
	return _data


static func is_enabled() -> bool:
	return bool(data().get("enabled", false))


## The gate: the data switch, the explicit real-match flag and the profile's coach_done (missing = not done).
static func wanted(route_flag: bool, profile: Dictionary) -> bool:
	return is_enabled() and route_flag and not SaveService.coach_done(profile.get("coach_done", null))


func _init() -> void:
	name = NODE_NAME
	theme = _Theme
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 1  # over the other HUD siblings (the hint and its ring sit beside the controls, never on them)
	set_anchors_preset(Control.PRESET_FULL_RECT)
	steps = (data().get("steps", []) as Array).duplicate(true)
	visible = false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func bind(match_director: MatchDirector, local_pawn: Pawn, touch: Control, menu: PauseMenu, hud: Control = null) -> void:
	director = match_director
	if is_instance_valid(pawn) and pawn.fired.is_connected(_on_fired):
		pawn.fired.disconnect(_on_fired)
	pawn = local_pawn
	if is_instance_valid(pawn):
		pawn.fired.connect(_on_fired)
	touch_hud = touch
	pause_menu = menu
	game_hud = hud
	if is_instance_valid(_provider_bound) and _provider_bound.action_triggered.is_connected(_on_action):
		_provider_bound.action_triggered.disconnect(_on_action)
	_provider_bound = null
	if is_instance_valid(touch_hud) and "provider" in touch_hud and touch_hud.provider != null:
		_provider_bound = touch_hud.provider
		_provider_bound.action_triggered.connect(_on_action)


func _on_fired() -> void:
	_fired = true


func _on_action(action: String) -> void:
	if action == "interact":
		_interacted = true


func _cfg(block: String) -> Dictionary:
	return data().get(block, {})


# --- state ---------------------------------------------------------------------------------------------------------

func is_done() -> bool:
	return phase == PHASE_DONE


func current_step() -> Dictionary:
	return steps[index] if index >= 0 and index < steps.size() else {}


func current_id() -> String:
	return str(current_step().get("id", ""))


## A hint is on screen now.
func showing_hint() -> bool:
	return phase == PHASE_SHOW and paused_reason == ""


## Skip is on screen (and is a touch target) now: while a hint shows and in the short gap between two.
func skip_visible() -> bool:
	return (phase == PHASE_SHOW or phase == PHASE_GAP) and paused_reason == ""


func _hud_get(prop: String) -> Variant:
	if not is_instance_valid(game_hud):
		return null
	var v: Variant = game_hud.get(prop)
	return v if is_instance_valid(v) else null


func _minimap() -> HudMinimap:
	return _hud_get("minimap") as HudMinimap


func shooting_mode() -> String:
	if is_instance_valid(touch_hud) and touch_hud.has_method("shooting_mode"):
		return str(touch_hud.shooting_mode())
	return "advanced"


func pause_reason() -> String:
	if not is_instance_valid(pawn):
		return "no_pawn"
	if bool(data().get("require_touch_hud", true)) and (not is_instance_valid(touch_hud) or not touch_hud.is_visible_in_tree()):
		return "no_touch_hud"
	if is_instance_valid(pause_menu) and pause_menu.is_open:
		return "menu"
	if is_instance_valid(touch_hud) and bool(touch_hud.get("suspended")):
		return "menu"
	if is_instance_valid(game_hud) and not game_hud.is_visible_in_tree():
		return "hud_hidden"
	if pawn.life != Pawn.Life.ALIVE or (pawn.bridge != null and pawn.bridge.state.is_dead()):
		return "downed"
	if pawn.drop_state != Pawn.Drop.NONE:
		return "drop"
	var mm := _minimap()
	if mm != null and mm.expanded and str(current_step().get("advance", "")) != "map_opened":
		return "map"
	return ""


# --- the sequence ----------------------------------------------------------------------------------------------------

func _process(delta: float) -> void:
	tick(delta)


## One frame of the sequence (public so tests can step it without waiting).
func tick(delta: float) -> void:
	if phase == PHASE_DONE:
		return
	paused_reason = pause_reason()
	if paused_reason != "":
		_have_base = false
		visible = false
		return
	visible = true
	_pulse_s += delta
	if forced_step >= 0:
		if index != forced_step or phase != PHASE_SHOW:
			index = clampi(forced_step, 0, steps.size() - 1)
			_begin_show()
		queue_redraw()
		return
	phase_s += delta
	match phase:
		PHASE_START:
			if phase_s >= float(data().get("start_delay_s", 0.0)):
				_enter_step(0)
		PHASE_GAP:
			if phase_s >= float(data().get("gap_s", 0.0)):
				_enter_step(index + 1)
		PHASE_WAIT:
			_wait_tick()
		PHASE_SHOW:
			_show_tick()
	queue_redraw()


func _enter_step(i: int) -> void:
	index = i
	while index < steps.size():
		if applies(steps[index]):
			_begin_show()
			return
		if float(steps[index].get("wait_s", 0.0)) > 0.0:
			phase = PHASE_WAIT
			phase_s = 0.0
			return
		history.append({"id": str(steps[index].get("id", "")), "how": "not_applicable"})
		index += 1
	_finish(false)


func _wait_tick() -> void:
	var st := current_step()
	if applies(st):
		_begin_show()
	elif phase_s >= float(st.get("wait_s", 0.0)):
		history.append({"id": current_id(), "how": "not_applicable"})
		_enter_step(index + 1)


func _begin_show() -> void:
	phase = PHASE_SHOW
	phase_s = 0.0
	_fired = false
	_interacted = false
	_moved_m = 0.0
	_turned_deg = 0.0
	_have_base = false


func _show_tick() -> void:
	var st := current_step()
	if not applies(st):
		_end_step("lost")
		return
	_track()
	if action_done(str(st.get("advance", ""))):
		_end_step("action")
	elif phase_s >= float(st.get("timeout_s", 10.0)):
		_end_step("timeout")


func _end_step(how: String) -> void:
	history.append({"id": current_id(), "how": how})
	if index + 1 >= steps.size():
		_finish(false)
		return
	phase = PHASE_GAP
	phase_s = 0.0


## Distance walked and view turned since the hint showed (only counted while the coach runs).
func _track() -> void:
	if not is_instance_valid(pawn):
		return
	var p := pawn.global_position if pawn.is_inside_tree() else pawn.position
	var yaw := pawn.global_rotation.y if pawn.is_inside_tree() else pawn.rotation.y
	if not _have_base:
		_have_base = true
		_last_pos = p
		_last_yaw = yaw
		return
	_moved_m += Vector2(p.x - _last_pos.x, p.z - _last_pos.z).length()
	_turned_deg += absf(rad_to_deg(wrapf(yaw - _last_yaw, -PI, PI)))
	_last_pos = p
	_last_yaw = yaw


## Whether the player did the step's thing (read-only checks; nothing is consumed).
func action_done(advance: String) -> bool:
	var adv := _cfg("advance")
	match advance:
		"moved":
			return _moved_m >= float(adv.get("move_m", 2.0))
		"turned":
			return _turned_deg >= float(adv.get("look_deg", 45.0))
		"aimed":
			return is_instance_valid(pawn) and pawn.aiming
		"fired":
			return _fired
		"in_cover":
			return is_instance_valid(pawn) and pawn.in_cover()
		"interacted":
			return _interacted or (InputMap.has_action("interact") and Input.is_action_pressed("interact"))
		"map_opened":
			var mm := _minimap()
			return mm != null and mm.expanded
	return false


## Skip: ends the whole sequence and saves coach_done.
func skip() -> void:
	if phase == PHASE_DONE:
		return
	history.append({"id": current_id(), "how": "skipped"})
	_finish(true)


func _finish(was_skipped: bool) -> void:
	phase = PHASE_DONE
	skipped = was_skipped
	visible = false
	save_done()
	finished.emit(was_skipped)


## coach_done = true into the profile file at once (and the in-memory profile when one is loaded; an empty
## AppFlow.profile stays empty so MatchRoot keeps loading the file).
func save_done() -> void:
	var p := save.load_profile()
	p["coach_done"] = true
	save.save_profile(p)
	if not AppFlow.profile.is_empty():
		AppFlow.profile["coach_done"] = true


# --- targets ---------------------------------------------------------------------------------------------------------

func target_key(st: Dictionary) -> String:
	if st.has("target_by_mode"):
		var by: Dictionary = st["target_by_mode"]
		return str(by.get(shooting_mode(), by.values()[0]))
	return str(st.get("target", ""))


func step_text(st: Dictionary) -> String:
	if st.has("text_by_mode"):
		var by: Dictionary = st["text_by_mode"]
		return str(by.get(shooting_mode(), by.values()[0]))
	var t := str(st.get("text", ""))
	if str(st.get("advance", "")) == "map_opened":
		var radar: Dictionary = HudArrangement.ui().get("radar", {})
		if bool(radar.get("enabled", false)) and st.has("text_no_radar"):
			return t % int(float(radar.get("range_m", 25.0)))
		return str(st.get("text_no_radar", t))
	return t


func _view() -> Vector2:
	return size if size.x > 0.0 and size.y > 0.0 else get_viewport_rect().size


func _local(r: Rect2) -> Rect2:
	return Rect2(r.position - global_position, r.size)


## The crosshair's square (GameHud._size_crosshair: centred, data ui.json crosshair.size_frac_of_height).
static func crosshair_rect(view: Vector2) -> Rect2:
	var span := float(HudArrangement.ui()["crosshair"]["size_frac_of_height"]) * view.y
	return Rect2(view * 0.5 - Vector2.ONE * span * 0.5, Vector2.ONE * span)


## The point a look hint rings: the look area's centre (a touch there only turns the view).
func look_point() -> Vector2:
	if is_instance_valid(touch_hud) and touch_hud.has_method("get_look_point"):
		return touch_hud.get_look_point() - global_position
	var v := _view()
	return Vector2(v.x * 0.75, v.y * 0.45)


## The rect of the control a step points at (this node's space), or an empty rect when it is not on screen now.
func target_rect(key: String) -> Rect2:
	var view := _view()
	var u := HudArrangement.unit(view)
	if not is_instance_valid(touch_hud):
		return Rect2()
	match key:
		"move_stick":
			return _local(touch_hud.get_move_visual_rect())
		"look_area":
			var r := float(_cfg("layout").get("look_ring_units", 1.6)) * u
			return Rect2(look_point() - Vector2.ONE * r, Vector2.ONE * r * 2.0)
		"aim", "fire_right":
			return _local(touch_hud.get_button_rect(key)) if (touch_hud.get_button_actions() as Array).has(key) else Rect2()
		"cover":
			return _local(touch_hud.get_button_rect("swap_shoulder")) if bool(touch_hud.cover_slot_active) else Rect2()
		"crosshair":
			return crosshair_rect(view)
		"interact":
			var prompt := _hud_get("interact_prompt") as Control
			if prompt != null and prompt.is_visible_in_tree():
				return _local(prompt.get_global_rect())
			var b := _hud_get("interact_button") as InteractButton
			return _local(b.get_touch_rect()) if b != null and b.visible else Rect2()
		"minimap_tap":
			return HudMinimap.tap_rect(view) if HudMinimap.is_enabled() and _minimap() != null else Rect2()
	return Rect2()


## Whether a step can show now: its control is on screen (and, for the pickup step, the Interact target is a pickup or a
## chest: the host's or offline player's; a LAN client never shows Interact).
func applies(st: Dictionary) -> bool:
	var key := target_key(st)
	if target_rect(key).size.x <= 0.0:
		return false
	if key == "interact":
		if not is_instance_valid(director) or not is_instance_valid(pawn) or not director.authoritative:
			return false
		return director.pickup_target_for(pawn.player_id) >= 0 or director.chest_target_for(pawn.player_id) != ""
	return true


# --- layout ----------------------------------------------------------------------------------------------------------

## The coach's only touch target: under the alive / zone chip at the left edge (the top of the left half, outside the
## look area, clear of the Sprint lock and its target), at least skip.min_dp. Narrow (width_units): on 1512x648 at 420 dpi
## the Sprint lock target starts 164 px from the left 220 px down, and right of the chip the Sprint lock button sits
## (tools/layout_probe.gd).
static func skip_rect(view: Vector2) -> Rect2:
	var s: Dictionary = data().get("skip", {})
	var u := HudArrangement.unit(view)
	var chip := HudArrangement.chip_rect(view)
	var h := maxf(float(s.get("min_dp", 48.0)) * HudArrangement.dp(), float(s.get("height_units", 1.7)) * u)
	var w := maxf(h, float(s.get("width_units", 5.6)) * u)
	return Rect2(Vector2(chip.position.x, chip.end.y + float(s.get("gap_units", 0.35)) * u), Vector2(w, h))


func _font() -> Font:
	var f := get_theme_font("font", "Label")
	return f if f != null else ThemeDB.fallback_font


## Everything a hint must not cover (this node's space).
func obstacles(view: Vector2) -> Array[Rect2]:
	var u := HudArrangement.unit(view)
	var out: Array[Rect2] = [HudArrangement.objective_rect(view), HudArrangement.banner_rect(view),
		HudArrangement.weapon_block_rect(view), HudArrangement.chip_rect(view), HudArrangement.panel_rect(view), skip_rect(view),
		crosshair_rect(view).grow(float(_cfg("layout").get("crosshair_clear_units", 1.2)) * u),
		FireModeButton.touch_rect(HudArrangement.ui()["fire_mode_button"], view),
		PauseMenu.gear_touch_rect(HudArrangement.ui()["pause_gear"], view)]
	if is_instance_valid(touch_hud):
		for key in touch_hud.get_button_actions():
			out.append(_local(touch_hud.get_button_rect(key)))
		out.append(_local(touch_hud.get_lock_button_rect()))
		out.append(_local(touch_hud.get_move_visual_rect()))
	var b := _hud_get("interact_button") as InteractButton
	if b != null and b.visible:
		out.append(_local(b.get_touch_rect()))
	var prompt := _hud_get("interact_prompt") as Control
	if prompt != null and prompt.is_visible_in_tree():
		out.append(_local(prompt.get_global_rect()))
	return out


static func _overlap(r: Rect2, obs: Array[Rect2]) -> float:
	var a := 0.0
	for o in obs:
		if o.size.x > 0.0 and r.intersects(o):
			a += r.intersection(o).get_area()
	return a


## How many of 16 points along a -> b fall inside any of `rects`.
static func _line_hits(a: Vector2, b: Vector2, rects: Array[Rect2]) -> int:
	var n := 0
	for i in 16:
		var p := a.lerp(b, (i + 0.5) / 16.0)
		for r in rects:
			if r.has_point(p):
				n += 1
				break
	return n


## Where the current hint sits: {"text", "font_px", "text_w", "bubble", "target", "ring_c", "ring_r", "tip", "from"},
## or {} when no hint shows. The bubble is placed beside the ring, on screen, clear of every obstacle where possible.
func hint_layout(view: Vector2 = Vector2.ZERO) -> Dictionary:
	if view == Vector2.ZERO:
		view = _view()
	var st := current_step()
	if st.is_empty():
		return {}
	var key := target_key(st)
	var target := target_rect(key)
	if target.size.x <= 0.0:
		return {}
	var L := _cfg("layout")
	var u := HudArrangement.unit(view)
	var text := step_text(st)
	var font := _font()
	var font_px := maxi(1, roundi(float(L.get("font_units", 0.8)) * u))
	var pad := float(L.get("pad_units", 0.45)) * u
	var max_inner := maxf(u * 4.0, float(L.get("max_width_frac", 0.3)) * view.x - 2.0 * pad)
	var one := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_px)
	var inner := Vector2(one.x + font_px * 0.3, font.get_height(font_px))
	if one.x > max_inner:
		inner = font.get_multiline_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, max_inner, font_px)
		inner.x = max_inner
	var bsize := inner + Vector2(2.0 * pad, 1.6 * pad)
	var c := target.get_center()
	var ring_r := maxf(target.size.x, target.size.y) * 0.5 + float(L.get("ring_pad_units", 0.22)) * u
	if key == "look_area":
		ring_r = target.size.x * 0.5
	var margin := float(L.get("edge_margin_dp", 8.0)) * HudArrangement.dp()
	var obs := obstacles(view)
	var ring_box := Rect2(c - Vector2.ONE * ring_r, Vector2.ONE * ring_r * 2.0)
	# A wide target (the prompt at the object) gets a rounded-rect ring hugging it instead of a big circle.
	var wide := key != "look_area" and maxf(target.size.x, target.size.y) > 1.25 * minf(target.size.x, target.size.y)
	if wide:
		ring_box = target.grow(float(L.get("ring_pad_units", 0.22)) * u)
	obs.append(ring_box)
	if key == "crosshair":
		obs.append(target.grow(float(L.get("crosshair_clear_units", 1.2)) * u))
	# The displays a pointer should not cross either (where another place allows it).
	var keep: Array[Rect2] = [HudArrangement.weapon_block_rect(view), HudArrangement.objective_rect(view),
		HudArrangement.banner_rect(view)]
	if key != "crosshair":
		keep.append(crosshair_rect(view))
	var toward := (view * 0.5 - c)
	toward = toward.normalized() if toward.length() > 1.0 else Vector2.UP
	var dirs: Array[Vector2] = [Vector2.UP, Vector2.DOWN, Vector2.LEFT, Vector2.RIGHT,
		Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]
	var gap := float(L.get("gap_units", 0.55)) * u
	var best := Rect2()
	var best_score := INF
	for tier: float in [0.0, 2.0, 5.0, 9.0]:
		for d in dirs:
			var dist: float = gap + tier * u
			var off := Vector2(d.x * (ring_r * (0.72 if d.y != 0.0 else 1.0) + dist + bsize.x * 0.5),
				d.y * (ring_r * (0.72 if d.x != 0.0 else 1.0) + dist + bsize.y * 0.5))
			var r := Rect2(c + off - bsize * 0.5, bsize)
			r.position.x = clampf(r.position.x, margin, maxf(margin, view.x - margin - bsize.x))
			r.position.y = clampf(r.position.y, margin, maxf(margin, view.y - margin - bsize.y))
			# Lower is better: covered area first, then a pointer crossing a display, then distance, then the side facing
			# the screen centre.
			var score: float = _overlap(r, obs) * 1000.0 + tier * 10.0 - d.normalized().dot(toward)
			var fr := Vector2(clampf(c.x, r.position.x, r.end.x), clampf(c.y, r.position.y, r.end.y))
			score += _line_hits(fr, c + (fr - c).normalized() * ring_r, keep) * 50.0
			if score < best_score:
				best_score = score
				best = r
	var from := Vector2(clampf(c.x, best.position.x, best.end.x), clampf(c.y, best.position.y, best.end.y))
	var dir := from - c
	var tip := c + (dir.normalized() * ring_r if dir.length() > 0.001 else Vector2.ZERO)
	if wide:
		tip = Vector2(clampf(from.x, ring_box.position.x, ring_box.end.x), clampf(from.y, ring_box.position.y, ring_box.end.y))
	return {"text": text, "font_px": font_px, "text_w": inner.x, "pad": pad, "bubble": best, "target": target,
		"ring_c": c, "ring_r": ring_r, "ring_box": ring_box, "wide": wide, "tip": tip, "from": from, "key": key,
		"covered": _overlap(best, obs)}


# --- drawing ---------------------------------------------------------------------------------------------------------

func _color(key: String) -> Color:
	return MenuStyle.color(str(_cfg("layout").get("colors", {}).get(key, "marble")))


func _draw() -> void:
	if paused_reason != "" or phase == PHASE_DONE:
		return
	var view := _view()
	var u := HudArrangement.unit(view)
	var L := _cfg("layout")
	var line := maxf(1.0, u * 0.06)
	if skip_visible():
		_draw_skip(view, u, line)
	if not showing_hint():
		return
	var h := hint_layout(view)
	if h.is_empty():
		return
	var pulse := 1.0 - float(L.get("pulse_alpha", 0.35)) * (0.5 + 0.5 * sin(TAU * _pulse_s / maxf(0.1, float(L.get("pulse_period_s", 1.2)))))
	var ring_col := _color("ring")
	ring_col.a = pulse
	var dark := _color("outline")
	dark.a = 0.75
	var rw := maxf(2.0, float(L.get("ring_width_units", 0.12)) * u)
	var c: Vector2 = h["ring_c"]
	var rr: float = h["ring_r"]
	if h["wide"]:
		var box: Rect2 = h["ring_box"]
		for pass_i in 2:
			var sb := StyleBoxFlat.new()
			sb.draw_center = false
			sb.border_color = dark if pass_i == 0 else ring_col
			sb.set_border_width_all(maxi(1, roundi(rw * (2.2 if pass_i == 0 else 1.0))))
			sb.set_corner_radius_all(roundi(u * 0.4))
			sb.anti_aliasing = true
			draw_style_box(sb, box.grow(rw * (0.6 if pass_i == 0 else 0.0)))
	else:
		draw_arc(c, rr, 0.0, TAU, 64, dark, rw * 2.2, true)
		draw_arc(c, rr, 0.0, TAU, 64, ring_col, rw, true)
	if h["key"] == "look_area":
		_draw_swipe(c, rr * 0.6, rw, ring_col, dark)
	# The pointer: from the bubble's nearest edge to the ring, with an arrowhead on the ring.
	var from: Vector2 = h["from"]
	var tip: Vector2 = h["tip"]
	if from.distance_to(tip) > 1.0 and from.distance_to(c) > rr * (0.0 if h["wide"] else 1.0) + 1.0:
		var pw := maxf(2.0, float(L.get("pointer_width_units", 0.09)) * u)
		var pc := _color("pointer")
		var d := (tip - from).normalized()
		var a := float(L.get("arrow_units", 0.42)) * u
		var base := tip - d * a
		var head := PackedVector2Array([tip, base + d.orthogonal() * a * 0.55, base - d.orthogonal() * a * 0.55])
		draw_line(from, base, dark, pw * 2.4, true)
		draw_colored_polygon(PackedVector2Array([tip + d * pw, base + d.orthogonal() * (a * 0.55 + pw), base - d.orthogonal() * (a * 0.55 + pw)]), dark)
		draw_line(from, base, pc, pw, true)
		draw_colored_polygon(head, pc)
	# The bubble: a menu-style plate, gold edge, one line of marble text (two when it must wrap).
	var bubble: Rect2 = h["bubble"]
	var border := _color("border")
	border.a = 0.8
	draw_style_box(HudStyle.plate(u * 0.3, line, float(L.get("plate_alpha", 0.86)), border), bubble)
	var font := _font()
	var px: int = h["font_px"]
	var pad: float = h["pad"]
	var pos := bubble.position + Vector2(pad, pad * 0.8 + font.get_ascent(px))
	var outline := maxi(1, roundi(px * 0.12))
	draw_multiline_string_outline(font, pos, h["text"], HORIZONTAL_ALIGNMENT_LEFT, h["text_w"], px, -1, outline, _color("outline"))
	draw_multiline_string(font, pos, h["text"], HORIZONTAL_ALIGNMENT_LEFT, h["text_w"], px, -1, _color("text"))


## A left-right swipe mark inside the look ring.
func _draw_swipe(c: Vector2, half: float, w: float, col: Color, dark: Color) -> void:
	var a := half * 0.35
	for pass_i in 2:
		var cc := dark if pass_i == 0 else col
		var ww := w * (2.2 if pass_i == 0 else 1.0)
		draw_line(c - Vector2(half, 0), c + Vector2(half, 0), cc, ww, true)
		for s in [-1.0, 1.0]:
			var tip := c + Vector2(s * half, 0)
			draw_line(tip, tip + Vector2(-s * a, -a), cc, ww, true)
			draw_line(tip, tip + Vector2(-s * a, a), cc, ww, true)


func _draw_skip(view: Vector2, u: float, line: float) -> void:
	var s := _cfg("skip")
	var r := skip_rect(view)
	draw_style_box(HudStyle.plate(u * 0.3, line, float(_cfg("layout").get("plate_alpha", 0.86))), r)
	var font := _font()
	var px := maxi(1, roundi(float(s.get("font_units", 0.62)) * u))
	var px2 := maxi(1, roundi(float(s.get("counter_font_units", 0.5)) * u))
	var label := str(s.get("text", "Skip"))
	var counter := str(s.get("counter_format", "%d/%d")) % [mini(index + 1, steps.size()), steps.size()]
	var pad := float(s.get("pad_units", 0.3)) * u
	var w := r.size.x - 2.0 * pad
	# Two lines, centred: the word, and under it the step counter (dimmer, smaller).
	var total := font.get_height(px) + font.get_height(px2)
	var y := r.position.y + (r.size.y - total) * 0.5 + font.get_ascent(px)
	var y2 := y - font.get_ascent(px) + font.get_height(px) + font.get_ascent(px2)
	var dark := _color("outline")
	draw_string_outline(font, Vector2(r.position.x + pad, y), label, HORIZONTAL_ALIGNMENT_CENTER, w, px, maxi(1, roundi(px * 0.12)), dark)
	draw_string(font, Vector2(r.position.x + pad, y), label, HORIZONTAL_ALIGNMENT_CENTER, w, px, _color("text"))
	var dim := _color("ring")
	dim.a = 0.85
	draw_string_outline(font, Vector2(r.position.x + pad, y2), counter, HORIZONTAL_ALIGNMENT_CENTER, w, px2, maxi(1, roundi(px2 * 0.12)), dark)
	draw_string(font, Vector2(r.position.x + pad, y2), counter, HORIZONTAL_ALIGNMENT_CENTER, w, px2, dim)


# --- input -----------------------------------------------------------------------------------------------------------

## A press on Skip ends the sequence and is consumed (like the minimap's tap target). Releases, drags and presses
## anywhere else are left alone, so look drags and stick starts pass through the hint and its pointer.
func _input(event: InputEvent) -> void:
	if phase == PHASE_DONE or not skip_visible() or not is_visible_in_tree():
		return
	var pos := Vector2.ZERO
	if event is InputEventScreenTouch and event.pressed:
		pos = event.position
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT \
			and event.device != InputEvent.DEVICE_ID_EMULATION:
		pos = event.position
	else:
		return
	if skip_rect(_view()).has_point(pos - global_position):
		skip()
		get_viewport().set_input_as_handled()


func _exit_tree() -> void:
	if is_instance_valid(pawn) and pawn.fired.is_connected(_on_fired):
		pawn.fired.disconnect(_on_fired)
	if is_instance_valid(_provider_bound) and _provider_bound.action_triggered.is_connected(_on_action):
		_provider_bound.action_triggered.disconnect(_on_action)
