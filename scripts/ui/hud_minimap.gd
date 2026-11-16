class_name HudMinimap
extends Control
## M2 H1b commit 3 (OQ-MINIMAP): the in-match minimap, in the reserved minimap rect of HudArrangement (radar left,
## minimap right, top-right corner). Data: data/ui.json "minimap" (every number a placeholder).
## - The picture is the map's baked texture (tools/render_layout.gd --minimap; minimap.maps.<map id> holds the texture
##   and the world rect it covers). A map without an entry or a missing texture shows a plain panel; circles and arrows
##   still draw.
## - Small view: a window of small_radius_m around the player, the player's heading up (profile minimap_rotate, default
##   true, Settings "Minimap: Rotates / North up") or north up. Expanded view: the whole map, north up, large and centred,
##   with landmark names drawn at runtime from the map's landmarks json.
## - Marks: the player's arrow, squad mates (squad colour), the current circle, the next circle and, while the player is
##   outside the next circle, the line to its nearest edge point. NO enemies.
## - Every position goes through MinimapMath.to_px (the one world-to-minimap mapping).
## - Cheap: the texture is static; the overlays redraw update_hz times a second (the "rotor" node); the view's pan, turn and
##   the arrow follow every frame as node transforms (no redraw).
## - Input: the ONLY touch target is HudArrangement.minimap_tap_rect (right-edge strip, outside the look area). A press
##   there toggles the expanded map and is consumed like the pause gear's (this node sits after the touch HUD in the tree,
##   so its _input runs first). While expanded the same square is the close control. Everything else ignores touches
##   (mouse_filter IGNORE, no _input consumption): look drags and stick starts pass through the small and the expanded
##   picture. Never pauses the match.
## - Positions come from what the local peer has: the local pawn, MatchDirector.all_players() for squad mates and
##   director.rules for the circles (the same zone state the HUD chip shows). No protocol change.

const _Theme := preload("res://scenes/ui/theme.tres")
const NODE_NAME := "HudMinimap"

var director: MatchDirector
var pawn: Pawn
var pause_menu: PauseMenu
## The GameHud whose visibility the minimap follows (null: always shown when enabled).
var game_hud: Control
var map_id: String = ""
var texture: Texture2D
## World rect (m) the texture covers, from data; zero size when the map has no entry.
var extent := Rect2()
var landmarks: Array = []  # [{"id", "name", "at": Vector2}]
var expanded: bool = false
## The marks of the last overlay update, HUD space: [{"kind", "id", "world": Vector2, "px": Vector2, ...}]. Kinds:
## player, mate, current_circle, next_circle (with "radius_px"), line (with "to_world", "to_px"), landmark (with "label_rect").
var marks: Array = []
var overlay_updates: int = 0
var rotor_draws: int = 0
## Script time spent in this node (usec), for tools/minimap_cost.gd.
var cost_usec: int = 0

var _cfg: Dictionary = {}
var _accum: float = 0.0
var _snap: Dictionary = {}  # the HUD-space frame of the last overlay update
var _rotor_frame: Dictionary = {}  # the rotor's own frame: origin 0, same centre and scale, no turn
var _snap_mode: String = ""
var _view: Control
var _rotor: Node2D
var _arrow: Node2D
var _fg: Control
var _last_size := Vector2.ZERO
var _label_key: String = ""
var _vr := Rect2()
var _vr_size := Vector2(-1, -1)
var _vr_expanded := false
var _u := 1.0
var _label_marks: Array = []


class _Painter extends Control:
	var paint: Callable

	func _draw() -> void:
		paint.call(self)


class _Painter2D extends Node2D:
	var paint: Callable

	func _draw() -> void:
		paint.call(self)


func _init() -> void:
	name = NODE_NAME
	theme = _Theme
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = -1  # under the touch HUD's buttons and the GameHud's displays: the expanded map never hides a control
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_cfg = HudArrangement.ui().get("minimap", {})
	_view = _Painter.new()
	_view.name = "View"
	_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_view.clip_contents = true
	_view.paint = _draw_view
	add_child(_view)
	_rotor = _Painter2D.new()
	_rotor.name = "Rotor"
	_rotor.paint = _draw_rotor
	_view.add_child(_rotor)
	_arrow = _Painter2D.new()
	_arrow.name = "Arrow"
	_arrow.paint = _draw_arrow
	_view.add_child(_arrow)
	_fg = _Painter.new()
	_fg.name = "Frame"
	_fg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fg.paint = _draw_fg
	add_child(_fg)
	resized.connect(_on_resized)


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_on_resized()


## Connects the minimap to the match. `map_def` = the map json (MatchRoot.map_def); {} = no map (plain panel).
func bind(match_director: MatchDirector, local_pawn: Pawn, menu: PauseMenu, map_def: Dictionary, hud: Control = null) -> void:
	director = match_director
	pawn = local_pawn
	pause_menu = menu
	game_hud = hud
	set_map(map_def)


## Picks the map's texture, extent and landmarks. Quiet: a missing entry or texture gives the plain panel (one print).
func set_map(map_def: Dictionary) -> void:
	map_id = str(map_def.get("id", ""))
	texture = null
	extent = Rect2()
	landmarks = []
	var entry: Dictionary = (_cfg.get("maps", {}) as Dictionary).get(map_id, {}) if map_id != "" else {}
	if not entry.is_empty():
		var e: Array = entry.get("extent_m", [])
		if e.size() == 4:
			extent = Rect2(float(e[0]), float(e[1]), float(e[2]), float(e[3]))
		var path := str(entry.get("texture", ""))
		if path != "" and ResourceLoader.exists(path):
			texture = load(path) as Texture2D
	if map_id != "" and texture == null:
		print("HudMinimap: no minimap picture for map '%s'; plain panel (tools/render_layout.gd --minimap)" % map_id)
	var lm_path := str(map_def.get("landmarks", ""))
	if lm_path != "" and FileAccess.file_exists(lm_path):
		for lm: Dictionary in DataRegistry.new().load_file(lm_path).get("landmarks", []):
			landmarks.append({"id": str(lm.get("id", "")), "name": str(lm.get("name", "")), "at": Vector2(float(lm["at"][0]), float(lm["at"][1]))})
	_snap_mode = ""
	_label_key = ""


static func is_enabled() -> bool:
	return bool(HudArrangement.ui().get("minimap", {}).get("enabled", false))


## Profile key minimap_rotate (SaveService, default true): the small view turns with the player's heading.
static func rotating() -> bool:
	return SaveService.minimap_rotate(AppFlow.profile.get("minimap_rotate", null))


func mode() -> String:
	if expanded:
		return MinimapMath.EXPANDED
	return MinimapMath.SMALL_ROTATE if rotating() else MinimapMath.SMALL_NORTH


func _unit() -> float:
	view_rect()  # refreshes the cached unit with the rect
	return _u


## The expanded map's square: centred across, size_frac_of_height of the height but at most max_frac_of_width of the
## width, and kept between the objective strip and the weapon block (gap_units from each) so no HUD display covers it.
static func expanded_rect(view: Vector2) -> Rect2:
	var e: Dictionary = HudArrangement.ui()["minimap"]["expanded"]
	var gap := float(e.get("gap_units", 0.3)) * HudArrangement.unit(view)
	var top := HudArrangement.objective_rect(view).end.y + gap
	var bottom := HudArrangement.weapon_block_rect(view).position.y - gap
	var side := minf(float(e["size_frac_of_height"]) * view.y, float(e["max_frac_of_width"]) * view.x)
	side = maxf(minf(side, bottom - top), 0.0)
	return Rect2(Vector2(view.x * 0.5 - side * 0.5, (top + bottom) * 0.5 - side * 0.5), Vector2(side, side))


## The touch target that expands the map (small view) and closes it (expanded): the same square, so the close control
## sits where the player tapped, in the right-edge strip, outside the look area.
static func tap_rect(view: Vector2) -> Rect2:
	return HudArrangement.minimap_tap_rect(view)


static func close_rect(view: Vector2) -> Rect2:
	return HudArrangement.minimap_tap_rect(view)


## The plate around the small view: the minimap square, or the whole radar + minimap panel once the radar is drawn.
static func frame_rect(view: Vector2) -> Rect2:
	if bool(HudArrangement.ui().get("radar", {}).get("enabled", false)):
		return HudArrangement.panel_rect(view)
	return HudArrangement.minimap_rect(view)


static func _inset(view: Vector2) -> float:
	return float(HudArrangement.ui()["minimap"].get("inset_units", 0.2)) * HudArrangement.unit(view)


## The picture's rect (HUD space): the small minimap square or the expanded square, inset by inset_units.
static func picture_rect(view: Vector2, is_expanded: bool) -> Rect2:
	var r := expanded_rect(view) if is_expanded else HudArrangement.minimap_rect(view)
	return r.grow(-_inset(view))


## Cached per view size and state (the arrangement's rects read data and the density on every call; the view asks for it
## every frame). The density is read once per size: a DPI change comes with a resize.
func view_rect() -> Rect2:
	if size != _vr_size or expanded != _vr_expanded:
		_vr = picture_rect(size, expanded)
		_u = HudArrangement.unit(size)
		_vr_size = size
		_vr_expanded = expanded
	return _vr


## The world rect the views fit: the texture's extent, or (no entry) a square around the zone's start circle, or around
## the player.
func map_extent() -> Rect2:
	if extent.size.x > 0.0:
		return extent
	var r := float(_cfg.get("small_radius_m", 100.0)) * 2.0
	var c := player_xz()
	if director != null and director.rules != null and director.rules.zone_radius() > 0.0:
		c = director.rules.zone_center()
		r = maxf(r, director.rules.zone_radius() * 1.1)
	return Rect2(c - Vector2(r, r), Vector2(r, r) * 2.0)


func player_xz() -> Vector2:
	if pawn == null or not is_instance_valid(pawn):
		return Vector2.ZERO
	var p := pawn.global_position if pawn.is_inside_tree() else pawn.position
	return Vector2(p.x, p.z)


func player_yaw() -> float:
	if pawn == null or not is_instance_valid(pawn):
		return 0.0
	return pawn.global_rotation.y if pawn.is_inside_tree() else pawn.rotation.y


## The frame of the view right now (HUD space).
func current_frame() -> Dictionary:
	return MinimapMath.frame_for(mode(), view_rect(), map_extent(), player_xz(), player_yaw(), float(_cfg.get("small_radius_m", 100.0)))


func _active() -> bool:
	if not is_enabled() or pawn == null or not is_instance_valid(pawn):
		return false
	return game_hud == null or game_hud.is_visible_in_tree()


func set_expanded(on: bool) -> void:
	if expanded == on:
		return
	expanded = on
	_on_resized()


func toggle() -> void:
	set_expanded(not expanded)


func _on_resized() -> void:
	if _view == null:
		return
	_last_size = size
	var r := view_rect()
	_view.position = r.position
	_view.size = r.size
	queue_redraw()
	_fg.queue_redraw()
	_view.queue_redraw()
	if _active():
		update_overlays()
		follow()


func _process(delta: float) -> void:
	tick(delta)


## One frame: the overlays at update_hz, the view's transforms every frame.
func tick(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	var on := _active()
	if visible != on:
		visible = on
	if not on:
		return
	if size != _last_size:
		_on_resized()
	_accum += delta
	var period := 1.0 / maxf(float(_cfg.get("update_hz", 10.0)), 0.1)
	if _accum >= period or _snap_mode != mode():
		_accum = fmod(_accum, period) if _accum >= period else _accum
		update_overlays()
	follow()
	cost_usec += Time.get_ticks_usec() - t0


## Moves the rotor (map + world overlays) and the arrow to the current frame; no redraw. The rotor was drawn in its own
## frame (origin 0, the snapshot's centre and scale, no turn), so placing it at to_px(snapshot centre) and turning it by
## the frame's angle puts every point it drew at to_px(point, current frame).
func follow() -> void:
	if _snap.is_empty():
		return
	var f := current_frame()
	var origin := view_rect().position
	_rotor.position = MinimapMath.to_px(_snap["centre"], f) - origin
	_rotor.rotation = float(f["angle"])
	_arrow.position = MinimapMath.to_px(player_xz(), f) - origin
	_arrow.rotation = MinimapMath.arrow_rotation(player_yaw(), f)


## Where the rotor's drawing of `world` is on screen now (HUD space), through the node transforms (tests).
func drawn_px(world: Vector2) -> Vector2:
	return view_rect().position + _rotor.transform * MinimapMath.to_px(world, _rotor_frame)


func arrow_px() -> Vector2:
	return view_rect().position + _arrow.position


func arrow_rotation() -> float:
	return _arrow.rotation


## Rebuilds the marks and redraws the overlays (update_hz; also on a mode or size change).
func update_overlays() -> void:
	overlay_updates += 1
	_snap_mode = mode()
	_snap = current_frame()
	_rotor_frame = MinimapMath.frame(Vector2.ZERO, _snap["centre"], float(_snap["k"]), 0.0)
	marks = []
	var me := player_xz()
	marks.append({"kind": "player", "id": _player_id(), "world": me, "px": MinimapMath.to_px(me, _snap)})
	for m in squad_mates():
		var w := Vector2((m as Pawn).global_position.x, (m as Pawn).global_position.z) if (m as Pawn).is_inside_tree() else Vector2((m as Pawn).position.x, (m as Pawn).position.z)
		marks.append({"kind": "mate", "id": int((m as Pawn).player_id), "world": w, "px": MinimapMath.to_px(w, _snap),
			"color": SoldierSquadColour.paint((m as Pawn).squad_id)})
	var circles := zone_circles()
	if circles.has("current"):
		var c: Dictionary = circles["current"]
		marks.append({"kind": "current_circle", "id": "current", "world": c["center"], "radius_m": c["radius"],
			"px": MinimapMath.to_px(c["center"], _snap), "radius_px": MinimapMath.length_px(c["radius"], _snap)})
	if circles.has("next"):
		var nx: Dictionary = circles["next"]
		marks.append({"kind": "next_circle", "id": "next", "world": nx["center"], "radius_m": nx["radius"],
			"px": MinimapMath.to_px(nx["center"], _snap), "radius_px": MinimapMath.length_px(nx["radius"], _snap)})
		var d := me.distance_to(nx["center"])
		if d > float(nx["radius"]):
			var edge: Vector2 = (nx["center"] as Vector2) + (me - (nx["center"] as Vector2)).normalized() * float(nx["radius"])
			marks.append({"kind": "line", "id": "to_next", "world": me, "px": MinimapMath.to_px(me, _snap), "to_world": edge,
				"to_px": MinimapMath.to_px(edge, _snap)})
	if expanded:
		_layout_landmarks()
	_rotor.queue_redraw()
	_arrow.queue_redraw()


func _player_id() -> int:
	return int(pawn.player_id) if pawn != null and is_instance_valid(pawn) else -1


## Squad mates the local peer has: pawns in the director's player list with the local pawn's squad id, not dead, not
## the local pawn. Enemies are never listed.
func squad_mates() -> Array:
	var out: Array = []
	if director == null or pawn == null or not is_instance_valid(pawn):
		return out
	var players: Dictionary = director.all_players()
	for id in players:
		var p: Pawn = players[id]
		if p == null or not is_instance_valid(p) or p == pawn or p.squad_id != pawn.squad_id or p.life == Pawn.Life.DEAD:
			continue
		out.append(p)
	return out


## The circles from the zone state the HUD already shows (director.rules): {"current": {center, radius}, "next": {...}}.
## No zone, no circles; the next circle is left out when final or equal to the current one.
func zone_circles() -> Dictionary:
	var out := {}
	if director == null or director.rules == null or director.rules.zone_state() == "":
		return out
	var rules := director.rules
	out["current"] = {"center": rules.zone_center(), "radius": rules.zone_radius()}
	if rules.zone_state() != "final":
		var tc := rules.zone_target_center()
		var tr := rules.zone_target_radius()
		if tc.distance_to(rules.zone_center()) > 0.01 or absf(tr - rules.zone_radius()) > 0.01:
			out["next"] = {"center": tc, "radius": tr}
	return out


## Landmark names for the expanded map: a dot at the landmark and its name below it (else above, right, left), skipped
## places that would cover another name or leave the picture; a name with no free place is drawn below anyway.
func _layout_landmarks() -> void:
	# The expanded view does not move, so the names are placed once per view size and map (font measuring is the
	# expensive part) and reused by every overlay update.
	var key := "%s|%.3f|%s|%d" % [size, _unit(), map_id, landmarks.size()]
	if key == _label_key:
		marks.append_array(_label_marks)
		return
	var first := marks.size()
	_layout_landmarks_now()
	_label_key = key
	_label_marks = marks.slice(first)


func _layout_landmarks_now() -> void:
	var e: Dictionary = _cfg["expanded"]
	var u := _unit()
	var font := get_theme_default_font()
	var fs := maxi(8, roundi(float(e["label_font_units"]) * u))
	var gap := float(e["label_gap_units"]) * u
	var bounds := view_rect()
	var taken: Array[Rect2] = []
	for lm: Dictionary in landmarks:
		var p := MinimapMath.to_px(lm["at"], _snap)
		if not bounds.has_point(p):
			continue
		var ts := font.get_string_size(String(lm["name"]), HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
		var cands := [Rect2(p + Vector2(-ts.x * 0.5, gap), ts), Rect2(p + Vector2(-ts.x * 0.5, -gap - ts.y), ts),
			Rect2(p + Vector2(gap * 1.5, -ts.y * 0.5), ts), Rect2(p + Vector2(-gap * 1.5 - ts.x, -ts.y * 0.5), ts)]
		var pick: Rect2 = cands[0]
		for r: Rect2 in cands:
			var free := bounds.encloses(r)
			for t in taken:
				if t.intersects(r):
					free = false
					break
			if free:
				pick = r
				break
		taken.append(pick)
		marks.append({"kind": "landmark", "id": lm["id"], "name": lm["name"], "world": lm["at"], "px": p, "label_rect": pick, "font_size": fs})


func _color(key: String) -> Color:
	return MenuStyle.color(str((_cfg.get("colors", {}) as Dictionary).get(key, "marble")))


func _mk(key: String) -> float:
	return float(_cfg["marks"][key]) * _unit()


# --- drawing ------------------------------------------------------------------------------------------------------

func _draw() -> void:
	if not _active():
		return
	var u := _unit()
	var line := maxf(1.0, u * 0.06)
	var r := expanded_rect(size) if expanded else frame_rect(size)
	var bg := HudStyle.plate(_inset(size) * 2.0, line)
	bg.set_border_width_all(0)
	draw_style_box(bg, r.grow(0.0))


func _draw_view(ci: Control) -> void:
	ci.draw_rect(Rect2(Vector2.ZERO, ci.size), _color("off_map"), true)


## The map texture and the world overlays, in the rotor's frame (origin 0, north up, the snapshot's centre and scale).
func _draw_rotor(ci: Node2D) -> void:
	if _rotor_frame.is_empty():
		return
	rotor_draws += 1
	var t0 := Time.get_ticks_usec()
	_paint_rotor(ci)
	cost_usec += Time.get_ticks_usec() - t0


func _paint_rotor(ci: Node2D) -> void:
	var f := _rotor_frame
	if texture != null and extent.size.x > 0.0:
		var a := MinimapMath.to_px(extent.position, f)
		var b := MinimapMath.to_px(extent.end, f)
		ci.draw_texture_rect(texture, Rect2(a, b - a), false)
	var vr := view_rect()
	var reach := vr.size.length() + 4.0
	var dash := _mk("dash_units")
	for m: Dictionary in marks:
		match String(m["kind"]):
			"current_circle":
				var c := MinimapMath.to_px(m["world"], f)
				var rp := MinimapMath.length_px(float(m["radius_m"]), f)
				var far := c.length() + reach  # the rotor origin is the view's centre at the snapshot
				var tint := _color("outside")
				tint.a = float(_cfg["marks"]["outside_alpha"])
				if far > rp:
					ci.draw_arc(c, rp + (far - rp) * 0.5, 0.0, TAU, clampi(_segments(rp), 32, 96), tint, far - rp, false)
				ci.draw_arc(c, rp, 0.0, TAU, _segments(rp), _color("outline"), _mk("circle_width_units") * 2.2, true)
				ci.draw_arc(c, rp, 0.0, TAU, _segments(rp), _color("current_circle"), _mk("circle_width_units"), true)
			"next_circle":
				var c2 := MinimapMath.to_px(m["world"], f)
				var rp2 := MinimapMath.length_px(float(m["radius_m"]), f)
				var pts := _dashed_circle(c2, rp2, dash)
				if pts.size() >= 2:
					ci.draw_multiline(pts, _color("outline"), _mk("next_width_units") * 2.4)
					ci.draw_multiline(pts, _color("next_circle"), _mk("next_width_units"))
			"line":
				var a2 := MinimapMath.to_px(m["world"], f)
				var b2 := MinimapMath.to_px(m["to_world"], f)
				# Solid (the next circle is the dashed one), so even a short line reads past the arrow.
				ci.draw_line(a2, b2, _color("outline"), _mk("line_width_units") * 2.6, true)
				ci.draw_line(a2, b2, _color("line"), _mk("line_width_units"), true)
	for m: Dictionary in marks:
		if m["kind"] == "mate":
			var p := MinimapMath.to_px(m["world"], f)
			var rr := _mk("mate_units")
			ci.draw_circle(p, rr * 1.35, _color("outline"))
			ci.draw_circle(p, rr * 1.15, _color("mate_ring"))
			ci.draw_circle(p, rr * 0.85, m["color"])
	if expanded:
		var e: Dictionary = _cfg["expanded"]
		var font := get_theme_default_font()
		var dot := float(e["landmark_dot_units"]) * _unit()
		var origin := (_snap["origin"] as Vector2)
		for m: Dictionary in marks:
			if m["kind"] != "landmark":
				continue
			var p := MinimapMath.to_px(m["world"], f)
			ci.draw_circle(p, dot * 1.5, _color("outline"))
			ci.draw_circle(p, dot, _color("landmark_dot"))
			var lr: Rect2 = m["label_rect"]
			var fs := int(m["font_size"])
			var at := lr.position - origin + Vector2(0, font.get_ascent(fs))
			ci.draw_string_outline(font, at, String(m["name"]), HORIZONTAL_ALIGNMENT_LEFT, -1, fs, maxi(2, roundi(fs * 0.22)), _color("outline"))
			ci.draw_string(font, at, String(m["name"]), HORIZONTAL_ALIGNMENT_LEFT, -1, fs, _color("landmark"))


func _segments(radius_px: float) -> int:
	return clampi(int(radius_px * 0.35), 32, 192)


## Dash pairs along a circle for draw_multiline.
func _dashed_circle(c: Vector2, r: float, dash: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	if r <= 0.5:
		return pts
	var n := clampi(int(TAU * r / maxf(dash * 2.0, 1.0)), 12, 160)
	var step := TAU / float(n)
	for i in n:
		var a0 := step * float(i)
		var a1 := a0 + step * 0.55
		var sub := 3
		for s in sub:
			pts.append(c + Vector2.from_angle(lerpf(a0, a1, float(s) / sub)) * r)
			pts.append(c + Vector2.from_angle(lerpf(a0, a1, float(s + 1) / sub)) * r)
	return pts


## The player's arrow (our own shape): a gold chevron pointing up at the node's origin, dark outline.
func _draw_arrow(ci: Node2D) -> void:
	var s := _mk("arrow_units")
	var pts := PackedVector2Array([Vector2(0, -s * 0.62), Vector2(s * 0.42, s * 0.4), Vector2(0, s * 0.18), Vector2(-s * 0.42, s * 0.4)])
	var outline := PackedVector2Array()
	for p in pts:
		outline.append(p * 1.32 + Vector2(0, s * 0.02))
	ci.draw_colored_polygon(outline, _color("outline"))
	ci.draw_colored_polygon(pts, _color("arrow"))


## On top of the picture: the plate's hairline, and the tap target's icon (expand) or the close control.
func _draw_fg(ci: Control) -> void:
	if not _active():
		return
	var u := _unit()
	var line := maxf(1.0, u * 0.06)
	var r := expanded_rect(size) if expanded else frame_rect(size)
	var border := HudStyle.plate(_inset(size) * 2.0, line)
	border.draw_center = false
	ci.draw_style_box(border, r)
	var tap := tap_rect(size)
	var icon := _mk("icon_units")
	var lw := maxf(1.5, _mk("icon_line_units"))
	var col := _color("icon")
	if expanded:
		var plate := HudStyle.plate(u * 0.3, line, 0.92)
		ci.draw_style_box(plate, tap.grow(-maxf(2.0, u * 0.08)))
		var c := tap.get_center()
		var h := icon * 0.5
		ci.draw_line(c + Vector2(-h, -h), c + Vector2(h, h), col, lw * 1.4, true)
		ci.draw_line(c + Vector2(-h, h), c + Vector2(h, -h), col, lw * 1.4, true)
		return
	# Expand icon: a small dark disc with four corner ticks, at the tap target's top-right (over the map's corner).
	var ic := Vector2(tap.end.x - _inset(size) - icon * 0.75, tap.position.y + _inset(size) + icon * 0.75)
	ci.draw_circle(ic, icon * 0.72, Color(MenuStyle.color("night"), 0.75))
	var k := icon * 0.42
	var t := icon * 0.2
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			var corner := ic + Vector2(sx * k, sy * k)
			ci.draw_line(corner, corner - Vector2(sx * t, 0), col, lw, true)
			ci.draw_line(corner, corner - Vector2(0, sy * t), col, lw, true)


# --- input --------------------------------------------------------------------------------------------------------

## A press on the tap target toggles the expanded map and is consumed (like the pause gear), so it never also becomes a
## look touch or a stick start. Releases, drags and presses anywhere else are left alone.
func _input(event: InputEvent) -> void:
	if not _active() or (pause_menu != null and is_instance_valid(pause_menu) and pause_menu.is_open):
		return
	var pos := Vector2.ZERO
	if event is InputEventScreenTouch and event.pressed:
		pos = event.position
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT \
			and event.device != InputEvent.DEVICE_ID_EMULATION:
		pos = event.position
	else:
		return
	if tap_rect(size).has_point(pos - global_position):
		toggle()
		get_viewport().set_input_as_handled()
