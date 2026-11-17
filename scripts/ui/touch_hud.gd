extends Control
## Touch HUD: move stick (bottom-left, re-centres under the thumb; not drawn by default, M2 H1c OQ-STICK-VISIBLE) and look stick (bottom
## centre-right, drag to turn; M2 H1a: a look touch never fires), plus action buttons.
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
var _look_moved: bool = false
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
## M2 H1c (OQ-STICK-VISIBLE): the layout editor sets this on its preview so the (normally undrawn) move stick shows.
var show_move_stick_for_editing: bool = false:
	set(v):
		show_move_stick_for_editing = v
		_apply_move_stick_drawn()
## M2 H1c (OQ-SPRINT-LOCK): the layout editor sets this on its preview so the Sprint lock button (normally shown only
## while sprint is locked) can be selected and dragged there.
var show_sprint_lock_for_editing: bool = false:
	set(v):
		show_sprint_lock_for_editing = v
		_refresh_button_visibility()
const LOCK_KEY := "sprint_lock"

## M2 H1c (OQ-SPRINT-LOCK): the ONE rule for the Sprint lock button. It does something only while sprint is locked
## (TouchProvider.sprint_locked, the single source of truth: a tap releases it), so only then is it drawn and only then
## does it catch a tap. Every path that clears the lock (a tap, a new move touch, the in-match menu) hides it on the next
## frame (_place_sprint_elements, every _process) and at once for hit-testing (lock_button_hit reads the provider).
func sprint_lock_button_active() -> bool:
	return provider != null and provider.sprint_locked

func lock_button_shown() -> bool:
	return show_sprint_lock_for_editing or sprint_lock_button_active()

## A press at p (viewport space) belongs to the Sprint lock button. A hidden button catches nothing: the touch then does
## what a touch at that point would otherwise do (a move-stick touch in the move zone).
func lock_button_hit(p: Vector2) -> bool:
	return sprint_lock_button_active() and get_lock_button_rect().has_point(p)

## M2 C1b stage 4 (decision 3, fix 4): no slot is hidden in cover any more (the old cover FIRE / Crouch slot swaps and
## data/ui.json cover_buttons are gone); only C1a's first-person Shoulder rule hides a button.
func _refresh_button_visibility() -> void:
	for key in _buttons:
		_buttons[key].visible = not is_first_person_slot_hidden(key)
	if lock_button != null:
		lock_button.visible = lock_button_shown()

## M2 C1a stage 4 (spec item 5, fix 2): true while the local pawn's CameraRig wants first person
## (CameraRig.is_first_person). The Shoulder button is then hidden (data/ui.json first_person_touch.shoulder_visible,
## OQ-FIRST-PERSON) and its slot stays reserved and swallows taps (no swap, no look) until C1b puts the
## Cover button there. Third person (cover, carrier, falling, downed, no rig) keeps today's Shoulder button.
const SHOULDER_KEY := "swap_shoulder"
var first_person_active := false
var _fp_shoulder_visible: Variant = null  # read once from data/ui.json

## Driven from _process and _on_down by _refresh_first_person; callable directly where there is no GameHud sibling.
func set_first_person_active(active: bool) -> void:
	if first_person_active == active:
		return
	first_person_active = active
	if is_first_person_slot_hidden(SHOULDER_KEY):
		for idx in _button_touch.keys():
			if _button_touch[idx] == SHOULDER_KEY:
				_button_touch.erase(idx)
				Input.action_release(SHOULDER_KEY)
				_style_button(_buttons[SHOULDER_KEY], false)
		_shoulder_pulse_left_s = 0.0
		_apply_shoulder_pulse()
	_refresh_button_visibility()

func is_first_person_slot_hidden(key: String) -> bool:
	if not first_person_active or key != SHOULDER_KEY or cover_slot_active:
		return false
	if _fp_shoulder_visible == null:
		_fp_shoulder_visible = bool(_DataRegistry.new().load_file("res://data/ui.json").get("first_person_touch", {}).get("shoulder_visible", true))
	return not bool(_fp_shoulder_visible)

## The mode comes from the local pawn the sibling GameHud is bound to (hud.gd bind, from MatchRoot) and that pawn's
## CameraRig; no GameHud, no pawn or no rig = third person. No raw input is read.
func _refresh_first_person() -> void:
	var game_hud := get_node_or_null("../GameHud")
	var pawn: Variant = game_hud.get("pawn") if game_hud != null else null
	var rig: CameraRig = null
	if is_instance_valid(pawn) and pawn is Pawn:
		rig = (pawn as Pawn).get_node_or_null("CameraRig") as CameraRig
	set_first_person_active(rig != null and rig.is_first_person())

## M2 C1b stage 1 (fixes 8, 23, 26, 30): the Shoulder slot is the Cover button while the local pawn offers it
## (Pawn.cover_button_available: offline, ALIVE, no drop; FREE or in cover). It then presses the InputMap action
## "cover" (Input.action_press/release like the other held buttons) AND provider.trigger_action("cover"), which the
## router re-emits (NON_FRAME_ACTIONS) and MatchRoot forwards to Pawn.handle_action_press. The UI never calls the
## controller. Carrier, falling and downed keep Shoulder swap; with no Cover button (LAN) the slot is C1a's.
const COVER_ACTION := "cover"
var cover_slot_active := false
## Highlight: a press would enter (Pawn.cover_button_valid). Engaged: in cover (Pawn.in_cover).
var cover_slot_valid := false
var cover_slot_engaged := false
var _cover_button_cfg: Dictionary = {}  # data/ui.json cover_button, read once
var _shoulder_label := ""

## The pawn the sibling GameHud is bound to, or null (no GameHud, unbound, freed).
func _hud_pawn() -> Pawn:
	var game_hud := get_node_or_null("../GameHud")
	var pawn: Variant = game_hud.get("pawn") if game_hud != null else null
	return pawn as Pawn if is_instance_valid(pawn) and pawn is Pawn else null

func _refresh_cover_slot() -> void:
	var pawn := _hud_pawn()
	var active := pawn != null and pawn.cover_button_available()
	set_cover_slot(active, active and pawn.cover_button_valid(), active and pawn.in_cover())
	# M2 C1b stage 3 (fixes 3, 24): in cover (any non-FREE state, read-only) the stick's forward extreme does not sprint;
	# the Sprint lock button and target stay as they are.
	if provider != null:
		provider.cover_suppress_sprint = pawn != null and pawn.in_cover()
	set_fire_dimmed(pawn != null and pawn.in_cover() and not pawn.cover_fire_available())

## M2 C1b stage 4 (fix 7, [Shibi default]): the right Fire and Left Fire buttons dim behind HIGH cover away from an
## edge, where no lean or rise is possible and Fire does nothing (Pawn.cover_fire_available). Style: data/ui.json
## cover_fire_dim. They stay pressable; the pawn ignores the press there. Callable directly in tests.
var fire_dimmed := false
var _fire_dim_cfg: Dictionary = {}

func set_fire_dimmed(dimmed: bool) -> void:
	if dimmed == fire_dimmed:
		return
	fire_dimmed = dimmed
	for key in [RIGHT_FIRE_KEY, LEFT_FIRE_KEY]:
		if _buttons.has(key):
			_style_button(_buttons[key], _button_touch.values().has(key))

func _style_dimmed_fire(b: Button) -> void:
	if _fire_dim_cfg.is_empty():
		_fire_dim_cfg = _DataRegistry.new().load_file("res://data/ui.json")["cover_fire_dim"]
	var c := _fire_dim_cfg
	var border: Array = c["border_color"]
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, float(c["bg_alpha"]))
	sb.border_color = Color(float(border[0]), float(border[1]), float(border[2]), float(border[3]))
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(int(ceil(maxf(b.size.x, 1.0) * 0.5)))
	for state in ["normal", "hover", "pressed", "disabled"]:
		b.add_theme_stylebox_override(state, sb)
	b.add_theme_color_override("font_color", Color(1, 1, 1, float(c["font_alpha"])))

## Callable directly where there is no GameHud sibling (tests). A touch held on the slot when it changes meaning is
## released under the action it pressed.
func set_cover_slot(active: bool, valid: bool, engaged: bool) -> void:
	if not _buttons.has(SHOULDER_KEY) or (not active and not cover_slot_active):
		return  # nothing to change; no data read on a HUD that never shows the Cover button
	if _cover_button_cfg.is_empty():
		_cover_button_cfg = _DataRegistry.new().load_file("res://data/ui.json")["cover_button"]
		_shoulder_label = (_buttons[SHOULDER_KEY] as Button).text
	var b: Button = _buttons[SHOULDER_KEY]
	if active != cover_slot_active:
		for idx in _button_touch.keys():
			if _button_touch[idx] == SHOULDER_KEY:
				_button_touch.erase(idx)
				Input.action_release(_action_of(SHOULDER_KEY))
		cover_slot_active = active
		b.text = str(_cover_button_cfg["label"]) if active else _shoulder_label
		_shoulder_pulse_left_s = 0.0
		_apply_shoulder_pulse()
		cover_slot_valid = valid
		cover_slot_engaged = engaged
		_style_button(b, false)
		_refresh_button_visibility()
	elif active and (valid != cover_slot_valid or engaged != cover_slot_engaged):
		cover_slot_valid = valid
		cover_slot_engaged = engaged
		_style_button(b, _button_touch.values().has(SHOULDER_KEY))

func _style_cover_button(b: Button, held: bool) -> void:
	var c := _cover_button_cfg
	var alpha := float(c["active_alpha"] if cover_slot_engaged else (c["valid_alpha"] if cover_slot_valid else c["idle_alpha"]))
	if held:
		alpha = maxf(alpha, float(_layout["button_held_alpha"]))
	var border: Array = c["active_border_color"] if cover_slot_engaged else (c["valid_border_color"] if cover_slot_valid else c["idle_border_color"])
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, alpha)
	sb.border_color = Color(float(border[0]), float(border[1]), float(border[2]), float(border[3]))
	sb.set_border_width_all(int(c["border_px"]))
	sb.set_corner_radius_all(int(ceil(maxf(b.size.x, 1.0) * 0.5)))
	for state in ["normal", "hover", "pressed", "disabled"]:
		b.add_theme_stylebox_override(state, sb)
## G3e: element key of the optional left Fire button (not an InputMap action: it presses "fire").
const LEFT_FIRE_KEY := "fire_left"
## Step 3 (Shibi, Nov 9 2026): the right-side Fire button (data/input.json touch_layout.buttons.fire_right). It holds
## "fire" and its drag also aims (TouchProvider.add_drag), so one thumb fires and tracks a moving target.
const RIGHT_FIRE_KEY := "fire_right"
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
		if action == RIGHT_FIRE_KEY and shooting_mode() == SIMPLE_MODE:
			continue  # M2 H1a: no right Fire button in Simple (refresh_shooting_mode)
		_add_button(action, String(_layout["buttons"][action].get("label", action)))
	_applied_shooting_mode = shooting_mode()
	if left_fire_enabled():
		_add_button(LEFT_FIRE_KEY, LEFT_FIRE_LABEL)
	if bool(_DataRegistry.new().load_file("res://data/ui.json")["touch_debug_overlay"]["enabled"]):
		debug_label = Label.new()
		debug_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		debug_label.position = Vector2(8, 8)
		add_child(debug_label)
	refresh_look_stick()
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
	if key == SHOULDER_KEY and cover_slot_active:
		return COVER_ACTION
	return "fire" if key == LEFT_FIRE_KEY or key == RIGHT_FIRE_KEY else key


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


## M2 H1a: the touch shooting mode (data/input.json shooting, OQ-SHOOT-MODE). The profile's shooting_mode ("advanced" |
## "simple", Settings "Shooting mode") wins; a missing or unknown value is the data default_mode.
const ADVANCED_MODE := "advanced"
const SIMPLE_MODE := "simple"


func shooting_mode() -> String:
	var shooting: Dictionary = cfg["shooting"]
	var m: Variant = AppFlow.profile.get("shooting_mode", null)
	return str(m) if m is String and (shooting["modes"] as Array).has(m) else str(shooting["default_mode"])


## M2 H1a: Simple has no right Fire button: it is removed (not drawn, not hit-tested, so its rect is look area) and comes
## back in Advanced. A touch held on it is dropped, and "fire" stays down only while another source holds it. A mode
## change also drops the hold-to-ADS and Simple auto-fire state. Live toggle (Settings) and tests.
func refresh_shooting_mode() -> void:
	var simple := shooting_mode() == SIMPLE_MODE
	if simple and _buttons.has(RIGHT_FIRE_KEY):
		for idx in _button_touch.keys():
			if _button_touch[idx] == RIGHT_FIRE_KEY:
				_button_touch.erase(idx)
		var b: Button = _buttons[RIGHT_FIRE_KEY]
		_buttons.erase(RIGHT_FIRE_KEY)
		remove_child(b)
		b.free()
	elif not simple and not _buttons.has(RIGHT_FIRE_KEY):
		_add_button(RIGHT_FIRE_KEY, String(_layout["buttons"][RIGHT_FIRE_KEY].get("label", RIGHT_FIRE_KEY)))
	if shooting_mode() != _applied_shooting_mode:
		_applied_shooting_mode = shooting_mode()
		_reset_shooting_state()
	_sync_fire_action()
	if is_inside_tree() and move_stick != null:
		relayout()


## G2e: applies the profile's active layout slot over the data defaults.
func reload_profile_layout() -> void:
	apply_slot_layout(HudLayoutModel.from_dict(AppFlow.profile.get("hud_layouts", null)).active_slot())
	if move_stick != null:
		refresh_left_fire()  # G3e: a Settings toggle made while the HUD is live
		refresh_shooting_mode()  # M2 H1a: likewise for the Shooting mode row


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


## Element keys the layout editor can edit: the move stick, the look stick (only in look mode "stick", M2 H1a), the
## Sprint lock button and every action button.
func get_element_keys() -> Array:
	var keys: Array = ["move_stick"]
	if look_stick != null:
		keys.append("look_stick")
	keys.append(LOCK_KEY)
	keys.append_array(_buttons.keys())
	return keys


## M2 H1a: the drawn look stick exists only in look mode "stick" (data/input.json look.mode, TouchProvider.look_mode).
## In "drag" (the default) a look touch turns the view anywhere in the look zone and nothing is drawn for it.
func look_stick_wanted() -> bool:
	return provider.look_mode == "stick"


## Builds or removes the look stick to match the look mode (also the hook for tests that change provider.look_mode).
func refresh_look_stick() -> void:
	if look_stick_wanted() and look_stick == null:
		look_stick = _make_stick_visual("look_stick")
		add_child(look_stick)
	elif not look_stick_wanted() and look_stick != null:
		remove_child(look_stick)
		look_stick.free()
		look_stick = null
	if is_inside_tree() and move_stick != null:
		relayout()


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
		return float(_layout["button_size_frac_of_height"]) * _area().y * _ring_factor(key)
	return 2.0 * maxf(1.0, float(_layout.get("stick_radius_frac_of_height", 0.12)) * _area().y)


## Screen rect of an element as drawn (sticks at rest), for editing and layout checks.
func get_element_rect(key: String) -> Rect2:
	if key == LOCK_KEY:
		return get_lock_button_rect()
	if _buttons.has(key):
		return get_button_rect(key)
	if key == "move_stick":
		return get_move_visual_rect()
	if key == "look_stick" and look_stick == null:
		return Rect2()  # M2 H1a: no look stick element in look mode "drag"
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
	lock_button.visible = lock_button_shown()  # M2 H1c (OQ-SPRINT-LOCK): hidden at rest
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
## (which the editor mirrors from the slot), which wins over the data default.
func _lock_button_center() -> Vector2:
	var p: Array = AppFlow.profile.get("sprint_lock_pos", []) if use_profile_lock_fallback else []
	var default_c := _lock_default_center()
	if p.size() == 2:
		default_c = Vector2(float(p[0]) * _area().x, float(p[1]) * _area().y)
	return _center_px(LOCK_KEY, default_c)


## M2 H1a data default of the lock button (touch_layout.sprint_lock_offset, OQ-H1A-LAYOUT): above the move stick, next
## to its lock target: the target's rest centre (above the move stick rest, as get_lock_target_rect) plus an offset in
## lock button sides at 100 % (so it keeps its place where the 48 dp floor makes the buttons relatively big).
func _lock_default_center() -> Vector2:
	var o: Array = _layout["sprint_lock_offset"]
	var target_c := get_move_rest() - Vector2(0.0, float(cfg["sprint"]["lock_target"]["distance_radii"]) * _radius())
	var side := maxf(float(cfg["sprint"]["lock_button"]["size_frac_of_height"]) * _area().y, float(cfg["sprint"]["lock_button"]["min_dp"]) * _Platform.new().get_dp_scale())
	return target_c + Vector2(float(o[0]), float(o[1])) * side


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
	lock_button.visible = lock_button_shown()  # M2 H1c (OQ-SPRINT-LOCK): the one rule, every frame
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
	_reset_shooting_state()
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


## M2 H1a layout migration notice (data/ui.json layout_reset_notice): when SaveService reset a saved layout made for the
## old placement, the profile carries layout_notice_pending. The first time this HUD is shown and live (not the layout
## editor preview or its checkers, which are suspended) it shows the data text for duration_s and clears the flag in
## the profile file, so the notice appears once. `save` is the profile it clears (tests point it at a temp file).
var save := SaveService.new()
var notice_label: Label
var _notice_left_s := 0.0


func _update_layout_notice(delta: float) -> void:
	if notice_label != null:
		_notice_left_s -= delta
		if _notice_left_s <= 0.0:
			notice_label.queue_free()
			notice_label = null
		return
	if not visible or suspended or not bool(AppFlow.profile.get("layout_notice_pending", false)):
		return
	var c: Dictionary = _DataRegistry.new().load_file("res://data/ui.json")["layout_reset_notice"]
	notice_label = Label.new()
	notice_label.name = "LayoutNotice"
	notice_label.text = str(c["text"])
	notice_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	notice_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	notice_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	notice_label.add_theme_font_size_override("font_size", int(float(c["font_dp"]) * _Platform.new().get_dp_scale()))
	notice_label.position = Vector2(0.25 * _area().x, float(c["y_frac"]) * _area().y)
	notice_label.size = Vector2(0.5 * _area().x, 0.0)
	add_child(notice_label)
	_notice_left_s = float(c["duration_s"])
	AppFlow.profile["layout_notice_pending"] = false
	var p := save.load_profile()
	p["layout_notice_pending"] = false
	save.save_profile(p)


func _process(delta: float) -> void:
	_update_layout_notice(delta)
	_refresh_first_person()
	_refresh_cover_slot()
	if move_mode == "virtual":
		provider.move_value = Input.get_vector(_VJOY_ACTIONS[0], _VJOY_ACTIONS[1], _VJOY_ACTIONS[2], _VJOY_ACTIONS[3], 0.0)
	_place_sprint_elements()
	_update_hold_to_ads(delta)
	_update_simple_fire(delta)
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
	if look_stick != null:
		look_stick.place(get_look_rest(), _radius("look_stick"))
		look_stick.modulate.a = _alpha("look_stick")
		look_stick.set_knob_offset((_look_pos - _look_origin) if _look_touch != -1 else Vector2.ZERO)
	move_stick.modulate.a = _alpha("move_stick")
	_apply_move_stick_drawn()
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


## M2 H1c (OQ-STICK-VISIBLE): data/input.json touch_layout.move_stick_visible (default false) hides the move stick's
## drawing for both kinds; the layout editor's preview shows it anyway (show_move_stick_for_editing) so there is
## something to drag. Never visible = false: the VirtualJoystick takes its touches through the GUI.
func move_stick_drawn() -> bool:
	return show_move_stick_for_editing or bool(_layout.get("move_stick_visible", false))


## Drawing only: VirtualJoystick self_modulate alpha (modulate.a stays the layout alpha_pct); StickVisual skips _draw.
func _apply_move_stick_drawn() -> void:
	if move_stick == null:
		return
	var on := move_stick_drawn()
	if move_stick is StickVisual:
		(move_stick as StickVisual).drawn = on
	else:
		move_stick.self_modulate.a = 1.0 if on else 0.0


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


## Primary button side in px: its data fraction of the HUD height, never below button_min_dp (touch target floor).
## Also the unit of the button offsets, the look-area insets and the Interact button (data/ui.json interact_button).
func _button_size() -> float:
	return maxf(float(_layout["button_size_frac_of_height"]) * _area().y, float(_layout["button_min_dp"]) * _Platform.new().get_dp_scale())


## M2 H1a: size factor of a button at 100 %: ring_size_ratio for the outer-ring buttons (data buttons.<key>.ring), 1 for
## the primary ones (Aim, Fire, Reload) and Left Fire. OQ-H1A-LAYOUT.
func _ring_factor(action: String) -> float:
	var spec: Dictionary = _layout["buttons"].get(action, {})
	return float(_layout["ring_size_ratio"]) if bool(spec.get("ring", false)) else 1.0


## Side of a button in px: its slot scale on its default size (ring buttons smaller), never below button_min_dp.
func _button_side(action: String) -> float:
	return maxf(float(_layout["button_size_frac_of_height"]) * _area().y * _ring_factor(action) * _scale(action), float(_layout["button_min_dp"]) * _Platform.new().get_dp_scale())


## A button's rect: its slot position, else its data offset (in primary button sizes, _button_size) from its anchor:
## a screen point named by buttons.<key>.anchor, default button_anchor (M2 H1a: the bottom-right corner; buttons no
## longer hang off the look stick rest).
func _cell_rect(action: String) -> Rect2:
	var s := _button_size()
	var default_c: Vector2
	if action == LEFT_FIRE_KEY:
		var lp: Array = _layout["left_fire"]["pos"]
		default_c = Vector2(float(lp[0]) * _area().x, float(lp[1]) * _area().y)
	else:
		var spec: Dictionary = _layout["buttons"][action]
		var o: Array = spec["offset"]
		default_c = _rest_center(str(spec.get("anchor", "button_anchor"))) + Vector2(float(o[0]), float(o[1])) * s
		# M2 H1b (OQ-HUD): in the "split_row" HUD arrangement Swap and Cover / Shoulder default to either side of the
		# weapon block (HudArrangement.split_center); "above_row" (the default) leaves every data offset as it is.
		if HudArrangement.SPLIT_KEYS.has(action):
			var split: Variant = HudArrangement.split_center(action, _area())
			if split != null:
				default_c = split
	var c := _center_px(action, default_c)
	var side := _button_side(action)
	return Rect2(c - Vector2.ONE * side * 0.5, Vector2.ONE * side)


## M2 H1a: the main look area (data touch_layout.look_area, OQ-H1A-LAYOUT), viewport space: the part of the screen where
## the right thumb turns the view and where no control sits by default. Edges are fractions of the HUD, each moved in
## by an inset in primary button sizes (_button_size, so the 48 dp floor on small screens is followed). A saved layout
## may put a control into it: the layout editor warns (layout_editor.overlap_policy), nothing blocks it.
func get_look_area_rect() -> Rect2:
	var la: Dictionary = _layout["look_area"]
	var ins: Dictionary = la["inset_buttons"]
	var s := _button_size()
	var a := _area()
	var l := float(la["left_frac"]) * a.x + float(ins["left"]) * s
	var t := float(la["top_frac"]) * a.y + float(ins["top"]) * s
	var r := float(la["right_frac"]) * a.x - float(ins["right"]) * s
	var b := float(la["bottom_frac"]) * a.y - float(ins["bottom"]) * s
	return _to_global_rect(Rect2(l, t, maxf(0.0, r - l), maxf(0.0, b - t)))


## A point where a touch only turns the view (the look area centre); tests and capture tools use it instead of pixels.
func get_look_point() -> Vector2:
	return get_look_area_rect().get_center()


## Screen rect of the button for an action (the HUD is full-screen, so this is viewport space).
func get_button_rect(action: String) -> Rect2:
	return _to_global_rect(_cell_rect(action))


func get_button_label(action: String) -> String:
	return (_buttons[action] as Button).text


func get_button_actions() -> Array:
	return _buttons.keys()


func _style_button(b: Button, held: bool) -> void:
	if cover_slot_active and _buttons.get(SHOULDER_KEY) == b:
		_style_cover_button(b, held)
		return
	var is_fire: bool = _buttons.get(RIGHT_FIRE_KEY) == b or _buttons.get(LEFT_FIRE_KEY) == b
	if is_fire and fire_dimmed:
		_style_dimmed_fire(b)
		return
	if is_fire:
		b.remove_theme_color_override("font_color")
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, float(_layout["button_held_alpha"]) if held else float(_layout["button_idle_alpha"]))
	sb.border_color = Color(1, 1, 1, 0.6)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(int(ceil(maxf(b.size.x, 1.0) * 0.5)))
	for state in ["normal", "hover", "pressed", "disabled"]:
		b.add_theme_stylebox_override(state, sb)


func _button_at(pos: Vector2) -> String:
	for action in _buttons:
		if get_button_rect(action).has_point(pos):
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
## fire, sprint lock), so nothing is left pressed behind the menu.
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
	_hud_fire_down = false
	_reset_shooting_state()  # M2 H1a: no hold-to-ADS and no Simple auto-fire behind the menu
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
			# M2 H1a: a press that hit a button or the Sprint lock button is consumed, so it never also reaches the GUI,
			# where the floating VirtualJoystick (the whole move zone, left half) would spawn under it: Swap, the fire-mode
			# and Interact neighbours, Left Fire and the lock button sit in that half.
			if _button_touch.has(event.index) or event.index == _lock_btn_touch:
				get_viewport().set_input_as_handled()
		else:
			_on_up(event.index)
		_debug_touch(event.index, event.pressed, event.position)
	elif event is InputEventScreenDrag:
		_on_drag(event.index, event.position, event.relative)


func _on_down(idx: int, pos: Vector2) -> void:
	# M2 C1a stage 4: the hidden first-person Shoulder slot swallows the tap: it still hit-tests as the Shoulder button
	# and presses swap_shoulder (tests/test_fold_window_coords.gd), which the CameraRig ignores in first person, so the
	# tap never reaches the look area or fires; no press pulse is drawn. M2 C1b stage 1: on the ground the slot is the
	# visible Cover button instead (no swallowing); C1a's swallowing remains only where no Cover button is offered (LAN).
	_refresh_first_person()
	_refresh_cover_slot()
	var action := _button_at(pos)
	if lock_button_hit(pos):
		# M2 H1c (OQ-SPRINT-LOCK): the button exists only while locked and a tap releases the lock (was a toggle that also
		# locked while moving forward; locking is now only the lift on the Lock target, _on_up).
		_lock_btn_touch = idx
		provider.cancel_sprint_lock()
	elif action != "":
		_button_touch[idx] = action  # the element key; _action_of(key) is the InputMap action it presses
		if _action_of(action) == "fire":
			_sync_fire_action()
		else:
			Input.action_press(_action_of(action))
		if _action_of(action) == COVER_ACTION:
			provider.trigger_action(COVER_ACTION)
		_style_button(_buttons[action], true)
		if _action_of(action) == "swap_shoulder" and not is_first_person_slot_hidden(action):
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
		_look_touch = -1
		provider.clear_look()
		_update_sticks()


## The general fire action is the union of the Fire buttons (right Fire and the optional Left Fire) and, in the Simple
## shooting mode, the HUD's auto-fire (_update_simple_fire). Every touch shot goes through this one "fire" action, so it
## reaches the InputFrame and the normal fire path (ammo, spread, recoil, host checks).
## M2 H1a: a look-area touch only turns the view, in and out of cover; it never presses "fire" (was: a look tap sent a
## short fire pulse and a still look hold latched fire, outside cover only).
func _sync_fire_action() -> void:
	var held := _fire_button_held()
	if not held:
		_fire_hold_s = 0.0  # hold-to-ADS: a release lowers the sight at once (the Aim toggle latch is separate)
		provider.hold_ads = false
	if (held or _simple_fire_down) and not suspended:
		Input.action_press("fire")
		_hud_fire_down = true
	elif _hud_fire_down:
		Input.action_release("fire")
		_hud_fire_down = false


# ---- M2 H1a: shooting modes (data/input.json shooting, OQ-SHOOT-MODE) --------------------------------------------------

## Hold-to-ADS: seconds the Fire buttons have been held without a break.
var _fire_hold_s: float = 0.0
## Simple auto-fire: its share of the fire union, the target it waits on, how long the crosshair has stayed on it, and
## the pawn clock (one step per physics tick) of its last semi press and release.
var _simple_fire_down := false
var _simple_target_id: int = 0  # instance id, so a freed target is never touched
var _simple_on_target_s: float = 0.0
var _simple_press_clock: float = -INF
var _simple_release_clock: float = -INF
var _applied_shooting_mode := ""


func _fire_button_held() -> bool:
	for key in _button_touch.values():
		if _action_of(key) == "fire":
			return true
	return false


func _reset_shooting_state() -> void:
	_fire_hold_s = 0.0
	provider.hold_ads = false
	_simple_fire_down = false
	_simple_target_id = 0
	_simple_on_target_s = 0.0


## Advanced only, off unless shooting.hold_to_ads.enabled: a Fire button (right or Left Fire) held for hold_s sets
## TouchProvider.hold_ads, which InputRouter ORs into aim_pressed after the Aim toggle; any release clears it
## (_sync_fire_action). The Aim toggle latch is never touched, so with Aim on a release keeps the sight up.
func _update_hold_to_ads(delta: float) -> void:
	var h: Dictionary = cfg["shooting"]["hold_to_ads"]
	if suspended or not bool(h["enabled"]) or shooting_mode() != ADVANCED_MODE or not _fire_button_held():
		_fire_hold_s = 0.0
		provider.hold_ads = false
		return
	_fire_hold_s += delta
	provider.hold_ads = _fire_hold_s >= float(h["hold_s"])


## Why Simple auto-fire is off right now, "" when it may fire. All read-only facts, checked in this order:
## "mode" (not Simple), "hidden" (HUD not shown: not a touch device), "suspended" (in-match menu open), "no_pawn" (no
## GameHud sibling or it has no live pawn), "spectating" (the local pawn is DEAD, or GameHud.spectate_text is set by
## MatchRoot), "drop" (Pawn.drop_state ABOARD or FALLING), "downed" (not Pawn.is_alive: DOWNED or 0 health),
## "lan" (Pawn.in_lan_session: MatchRoot.networked_match), "sight_down" (Pawn.aiming false: the sight is not up).
func simple_fire_block_reason() -> String:
	if shooting_mode() != SIMPLE_MODE:
		return "mode"
	if not visible:
		return "hidden"
	if suspended:
		return "suspended"
	var pawn := _hud_pawn()
	if pawn == null:
		return "no_pawn"
	var game_hud := get_node_or_null("../GameHud")
	var spectate: Variant = game_hud.get("spectate_text") if game_hud != null else null
	if pawn.life == Pawn.Life.DEAD or (spectate is String and spectate != ""):
		return "spectating"
	if pawn.drop_state != Pawn.Drop.NONE:
		return "drop"
	if not pawn.is_alive():
		return "downed"
	if pawn.in_lan_session():
		return "lan"
	if not pawn.aiming:
		return "sight_down"
	return ""


## Simple: decides only WHEN the HUD presses "fire", never where the gun points (no aim change anywhere). While
## simple_fire_block_reason() is "" and Pawn.simple_fire_target() names the same enemy for shooting.simple.first_shot_delay_s,
## fire is held (auto and the legacy burst repeat on their own); a semi weapon gets one press per round: pressed when the
## weapon can take its next round on the coming physics tick (pawn clock + one tick >= its next fire time), released once
## a physics tick has seen the press (the pawn clock moved), so every round is a new edge at the weapon's own interval
## and no round is armed more than one tick ahead. Off target, reloading or empty: not pressed.
func _update_simple_fire(delta: float) -> void:
	var was_down := _simple_fire_down
	var pawn := _hud_pawn()
	var target: Pawn = pawn.simple_fire_target() if simple_fire_block_reason() == "" else null
	if target == null:
		_simple_target_id = 0
		_simple_on_target_s = 0.0
		_simple_fire_down = false
	else:
		if target.get_instance_id() != _simple_target_id:
			_simple_target_id = target.get_instance_id()
			_simple_on_target_s = 0.0
		else:
			_simple_on_target_s += delta
		var w := pawn.loadout.get_active()
		if _simple_on_target_s < float(cfg["shooting"]["simple"]["first_shot_delay_s"]) or w == null or w.reloading or not w.has_ammo():
			_simple_fire_down = false
		elif w.fire_mode != "semi":
			_simple_fire_down = true
		elif _simple_fire_down:
			if pawn.get_clock() > _simple_press_clock:
				_simple_fire_down = false
		elif pawn.get_clock() > _simple_release_clock and pawn.get_clock() + _physics_tick_s() >= w._next_fire_time - 0.0001:
			_simple_fire_down = true
			_simple_press_clock = pawn.get_clock()
	if was_down and not _simple_fire_down and pawn != null:
		_simple_release_clock = pawn.get_clock()


## One physics tick in seconds: the next tick's weapon update sees a press made now, so a semi press goes in one tick
## before the weapon's next fire time (the round then fires exactly on its interval, never armed earlier than that).
func _physics_tick_s() -> float:
	return 1.0 / float(maxi(Engine.physics_ticks_per_second, 1))


func _on_drag(idx: int, pos: Vector2, relative: Vector2) -> void:
	var dz: Dictionary = cfg.get("dead_zones", {})
	if _button_touch.get(idx, "") == RIGHT_FIRE_KEY:
		provider.add_drag(relative, _area().y)  # the Fire thumb aims while it fires
		return
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
