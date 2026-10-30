class_name CoverCrouchButton
extends Control
## Contextual controls share the fire-mode button's sibling input routing and dp/theme rules.
var pawn: Pawn
var touch_hud: Control
var pause_menu: PauseMenu
var label: Label
var cfg: Dictionary = {}
var config_key := "cover_crouch"
var ui_cfg: Dictionary = {}
var _crouch_index := -1
var _crouch_mouse := false

func _ready() -> void:
	name = "CoverCrouchButton" if config_key == "cover_crouch" else "CoverFireButton"
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme = preload("res://scenes/ui/theme.tres")
	ui_cfg = DataRegistry.new().load_file("res://data/ui.json")
	cfg = ui_cfg[config_key]
	set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	label = Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.text = cfg["label"]
	add_child(label)
	_place()
	refresh()

func bind(local_pawn: Pawn, touch: Control, menu: PauseMenu) -> void:
	pawn = local_pawn
	touch_hud = touch
	pause_menu = menu
	process_physics_priority = pawn.process_physics_priority - 1
	if is_node_ready():
		refresh()

func get_touch_rect() -> Rect2:
	if not is_instance_valid(touch_hud):
		return Rect2(Vector2.ZERO, Vector2.ONE * float(ui_cfg.get("min_touch_target_dp", 48.0)) * PlatformServices.new().get_dp_scale())
	return _slot_rects()[config_key]

func _slot_center(key: String) -> Vector2:
	var slot: String = ui_cfg[key]["slot"]
	var rect: Rect2 = touch_hud.get_lock_button_rect() if slot == touch_hud.LOCK_KEY else touch_hud.get_button_rect(slot)
	return rect.get_center()

## Maximal axis-aligned squares at the live slot centres. No other HUD element moves.
## Bounding squares are deliberately stricter than circle-only overlap checks.
func _slot_rects() -> Dictionary:
	var view: Vector2 = touch_hud._area()
	var origin: Vector2 = touch_hud.global_position
	var dp := PlatformServices.new().get_dp_scale()
	var shared: Dictionary = ui_cfg["cover_buttons"]
	var gap := float(shared["clearance_dp"]) * dp
	var occupied: Array[Rect2] = [FireModeButton.touch_rect(ui_cfg["fire_mode_button"], view), PauseMenu.gear_touch_rect(ui_cfg["pause_gear"], view)]
	var reserved: Dictionary = shared["reserved_top_row"]
	for anchor in reserved["anchors"]:
		occupied.append(FireModeButton.touch_rect({"anchor": anchor, "margin_dp": reserved["margin_dp"], "touch_dp": reserved["touch_dp"]}, view))
	for key in touch_hud.get_element_keys():
		if key not in shared["hidden_slots"]:
			occupied.append(touch_hud.get_element_rect(key))
	var result: Dictionary = {}
	var needs_move: Dictionary = {}
	for key in ["cover_fire", "cover_crouch"]:
		var center := _slot_center(key)
		var local := center - origin
		var side := minf(float(ui_cfg[key]["preferred_dp"]) * dp, 2.0 * minf(minf(local.x, view.x - local.x), minf(local.y, view.y - local.y)))
		for obstacle in occupied:
			var distance := (center - obstacle.get_center()).abs() - obstacle.size * 0.5
			side = minf(side, 2.0 * (maxf(distance.x, distance.y) - gap))
		var peer := _slot_center("cover_crouch" if key == "cover_fire" else "cover_fire")
		var separation := (center - peer).abs()
		side = minf(side, maxf(separation.x, separation.y) - gap)
		needs_move[key] = side < float(touch_hud._layout["button_min_dp"]) * dp
		side = maxf(side, float(touch_hud._layout["button_min_dp"]) * dp)
		result[key] = Rect2(center - Vector2.ONE * side * 0.5, Vector2.ONE * side)
	# Preserve every already-clear slot exactly. Resolve FIRE before Crouch.
	# If both move, Crouch avoids FIRE's final rect; its obsolete slot must not
	# exclude an otherwise nearer FIRE centre.
	for key in ["cover_fire", "cover_crouch"]:
		if not needs_move[key]:
			continue
		var obstacles: Array[Rect2] = occupied.duplicate()
		if key == "cover_crouch" or not needs_move["cover_crouch"]:
			obstacles.append(result["cover_crouch" if key == "cover_fire" else "cover_fire"])
		var minimum := float(touch_hud._layout["button_min_dp"]) * dp
		var centers := _nearest_free(_slot_center(key), view, origin, minimum, obstacles, gap)
		if centers.is_empty():
			continue # No free thumb-reachable spot: retain the existing floor.
		var center := centers[0]
		var side := maxf(minimum, _clear_side(center, view, origin, float(ui_cfg[key]["preferred_dp"]) * dp, obstacles, gap))
		result[key] = Rect2(center - Vector2.ONE * side * 0.5, Vector2.ONE * side)
	return result

## Largest clear square at any centre (HUD canvas pixels).
func _clear_side(center: Vector2, view: Vector2, origin: Vector2, preferred: float, occupied: Array[Rect2], gap: float) -> float:
	var local := center - origin
	var side := minf(preferred, 2.0 * minf(minf(local.x, view.x - local.x), minf(local.y, view.y - local.y)))
	for obstacle in occupied:
		var distance := (center - obstacle.get_center()).abs() - obstacle.size * 0.5
		side = minf(side, 2.0 * (maxf(distance.x, distance.y) - gap))
	return side

## Inflate obstacles by the minimum square's half-side and clearance. The nearest
## feasible point lies on a boundary or the slot's projection onto one. Enumerating
## those x/y coordinates is exact for axis-aligned rectangles (no grid budget).
## Ties use lower y, then lower x. An empty result keeps the legacy slot floor.
func _nearest_free(slot: Vector2, view: Vector2, origin: Vector2, minimum: float, occupied: Array[Rect2], gap: float) -> Array[Vector2]:
	var reach: Array = ui_cfg["cover_buttons"]["thumb_reach_min"]
	var lower := origin + Vector2(maxf(view.x * float(reach[0]), minimum * 0.5), maxf(view.y * float(reach[1]), minimum * 0.5))
	var upper := origin + view - Vector2.ONE * minimum * 0.5
	if lower.x > upper.x or lower.y > upper.y:
		return []
	var projected := slot.clamp(lower, upper)
	var xs: Array[float] = [lower.x, upper.x, projected.x]
	var ys: Array[float] = [lower.y, upper.y, projected.y]
	for obstacle in occupied:
		var expanded := obstacle.grow(minimum * 0.5 + gap)
		xs.append(clampf(expanded.position.x, lower.x, upper.x))
		xs.append(clampf(expanded.end.x, lower.x, upper.x))
		ys.append(clampf(expanded.position.y, lower.y, upper.y))
		ys.append(clampf(expanded.end.y, lower.y, upper.y))
	var best: Array[Vector2] = []
	var best_distance := INF
	for x in xs:
		for y in ys:
			var center := Vector2(x, y)
			var distance := center.distance_squared_to(slot)
			if distance > best_distance:
				continue
			# Small float-rounding slack only; no change to the configured clearance.
			if _clear_side(center, view, origin, minimum, occupied, gap) < minimum - 0.0001:
				continue
			if best.is_empty() or distance < best_distance or (distance == best_distance and (y < best[0].y or (y == best[0].y and x < best[0].x))):
				best = [center]
				best_distance = distance
	return best

func _place() -> void:
	if label == null:
		return
	var rect := get_touch_rect()
	global_position = rect.position
	size = rect.size
	label.position = Vector2.ZERO
	label.size = rect.size
	label.add_theme_font_size_override("font_size", int(float(cfg["font_dp"]) * PlatformServices.new().get_dp_scale()))
	queue_redraw()

func _is_pressed() -> bool:
	return _crouch_index != -1 or _crouch_mouse

func _draw() -> void:
	if ui_cfg.is_empty():
		return
	var style: Dictionary = ui_cfg["cover_buttons"]
	var tint: Color = label.self_modulate
	var color: Array = style["ring_color"]
	var ring := Color(color[0], color[1], color[2], color[3]) * tint
	var alpha := float(style["pressed_fill_alpha"] if _is_pressed() else style["fill_alpha"])
	if config_key == "cover_fire" and not enabled_for_drawing():
		alpha = float(style["disabled_fill_alpha"])
	var width := float(style["ring_dp"]) * PlatformServices.new().get_dp_scale()
	ring.a *= alpha
	draw_circle(size * 0.5, size.x * 0.5, Color(tint.r, tint.g, tint.b, alpha))
	draw_arc(size * 0.5, maxf(0.0, (size.x - width) * 0.5), 0.0, TAU, int(style["ring_points"]), ring, width, true)

func enabled_for_drawing() -> bool:
	return true

func _available() -> bool:
	if not is_instance_valid(pawn) or not pawn.is_alive() or pawn.cover == null:
		return false
	if is_instance_valid(pause_menu) and pause_menu.is_open:
		return false
	if is_instance_valid(touch_hud) and touch_hud.suspended:
		return false
	return pawn.cover.state == CoverController.State.IN_COVER or pawn.cover.state == CoverController.State.PEEK_LEFT or pawn.cover.state == CoverController.State.PEEK_RIGHT

func refresh() -> void:
	visible = _available()
	if is_instance_valid(touch_hud):
		touch_hud.set_cover_controls_active(visible)
	_place()
	if not visible:
		_crouch_index = -1
		_crouch_mouse = false

func _process(_delta: float) -> void:
	refresh()

func _physics_process(_delta: float) -> void:
	refresh()

func _accept_point(point: Vector2) -> bool:
	var rect := get_touch_rect()
	if not is_visible_in_tree() or not _available() or point.distance_squared_to(rect.get_center()) > pow(rect.size.x * 0.5, 2):
		return false
	if is_instance_valid(touch_hud):
		for key in touch_hud.get_button_actions():
			if not touch_hud.is_cover_slot_hidden(key) and touch_hud.get_element_rect(key).has_point(point):
				return false
		if not touch_hud.is_cover_slot_hidden(touch_hud.LOCK_KEY) and touch_hud.get_lock_button_rect().has_point(point):
			return false
	return true

func _input(event: InputEvent) -> void:
	var point: Vector2
	if event is InputEventScreenTouch and not event.pressed and event.index == _crouch_index:
		_crouch_index = -1
		queue_redraw()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and not event.pressed and _crouch_mouse:
		_crouch_mouse = false
		queue_redraw()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventScreenTouch and event.pressed:
		point = event.position
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT and event.device != InputEvent.DEVICE_ID_EMULATION:
		point = event.position
	else:
		return
	if _accept_point(point):
		if event is InputEventScreenTouch:
			_crouch_index = event.index
		else:
			_crouch_mouse = true
		pawn.cover.toggle_crouch()
		queue_redraw()
		get_viewport().set_input_as_handled()
