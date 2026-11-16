class_name HudRadar
extends Control
## M2 H1b commit 4 (OQ-RADAR): the round radar in HudArrangement.radar_rect (left of the minimap, inside its panel plate).
## Data: data/ui.json "radar" (every number a placeholder). The rule is DESIGN.md:26 only (see should_show):
## - every other pawn the local peer has within range_m (horizontal by default, radar.distance) is a blip;
## - an ENEMY in the cover crouch (pawn.in_cover() and its crouch_amount >= cover_crouch_min) does not show;
## - squad mates show in the squad colour, as a ringed dot; enemies as a solid diamond in a hostile colour (shape AND
##   colour differ, since a squad colour can itself be red);
## - dead pawns, pawns the LAN snapshot hides, pawns aboard the carrier and the local player are never blips.
## Heading up, always (forward = up), whatever the minimap's north-up setting. Blip positions all go through to_px (the
## one pure world-offset-to-radar-pixel function). Blips are rebuilt at update_hz; the blip layer turns with the heading
## every frame as a transform; the sweep (data switch) is drawn once and only turned.
## PASSIVE: mouse_filter IGNORE on every node and no _input: look drags and stick starts pass through. Not a touch
## target. Bots get no radar: this is a HUD display for the local player only. Reads only what the peer already has
## (the local pawn, MatchDirector.all_players()); no protocol change.

const NODE_NAME := "HudRadar"
const ENEMY := "enemy"
const MATE := "mate"

var director: MatchDirector
var pawn: Pawn
## The GameHud whose visibility the radar follows (null: always shown when enabled).
var game_hud: Control
## The blips of the last update: [{"kind": ENEMY|MATE, "id", "world": Vector2, "offset": Vector2 (m, from the player),
## "dist_m", "px": Vector2 (HUD space, at the update's heading), "color"}].
var blips: Array = []
var blip_updates: int = 0
var blip_draws: int = 0
## Script time spent in this node (usec), for tools/minimap_cost.gd --radar.
var cost_usec: int = 0

var _cfg: Dictionary = {}
var _accum: float = 0.0
var _sweep_t: float = 0.0
var _snap_yaw: float = 0.0
var _disc: _Painter2D
var _sweep: _Painter2D
var _blips: _Painter2D
var _last_size := Vector2(-1, -1)
var _u := 1.0
var _rect := Rect2()
var _rad := 1.0  # blip_radius_px(size), cached per size


class _Painter2D extends Node2D:
	var paint: Callable

	func _draw() -> void:
		paint.call(self)


func _init() -> void:
	name = NODE_NAME
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = -1  # with the minimap, under the touch HUD's buttons and the GameHud's displays
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_cfg = HudArrangement.ui().get("radar", {})
	_disc = _painter("Disc", _draw_disc)
	_sweep = _painter("Sweep", _draw_sweep)
	_blips = _painter("Blips", _draw_blips)


func _painter(n: String, f: Callable) -> _Painter2D:
	var p := _Painter2D.new()
	p.name = n
	p.paint = f
	add_child(p)
	return p


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_relayout()


func bind(match_director: MatchDirector, local_pawn: Pawn, hud: Control = null) -> void:
	director = match_director
	pawn = local_pawn
	game_hud = hud
	_accum = 0.0
	blips = []


static func is_enabled() -> bool:
	return bool(HudArrangement.ui().get("radar", {}).get("enabled", false))


static func cfg() -> Dictionary:
	return HudArrangement.ui().get("radar", {})


static func range_m() -> float:
	return float(cfg().get("range_m", 25.0))


## The radar disc (HUD space): the reserved circle of HudArrangement, inset like the minimap picture (minimap.inset_units)
## so the panel plate's hairline runs clear of it.
static func disc_rect(view: Vector2) -> Rect2:
	var inset := float(HudArrangement.ui()["minimap"].get("inset_units", 0.2)) * HudArrangement.unit(view)
	return HudArrangement.radar_rect(view).grow(-inset)


static func _mu(key: String, view: Vector2) -> float:
	return float(cfg()["marks"][key]) * HudArrangement.unit(view)


## Radius (px) at which a blip at exactly range_m is drawn: the disc's radius less the rim and an enemy blip's half
## size (and its outline), so a blip at the edge is wholly inside the circle.
static func blip_radius_px(view: Vector2) -> float:
	var r := disc_rect(view).size.x * 0.5
	return maxf(r - _mu("rim_width_units", view) * 1.5 - _mu("enemy_units", view) - _mu("outline_units", view) * 1.4, 1.0)


## THE mapping: a ground offset from the player (m, x/z) and the player's heading -> radar pixel, relative to `centre`.
## Heading up: the point straight ahead is straight up, the point to the player's right is to the right; range_m maps
## to radius_px. Pure: no node, no state. (The same rotation as MinimapMath's rotating frame.)
static func to_px(offset_m: Vector2, yaw: float, range_metres: float, radius_px: float, centre := Vector2.ZERO) -> Vector2:
	return centre + (offset_m * (radius_px / maxf(range_metres, 1e-3))).rotated(yaw)


## Horizontal (x, z) offset of `other` from `me`.
static func ground_offset(me: Vector3, other: Vector3) -> Vector2:
	return Vector2(other.x - me.x, other.z - me.z)


## The distance the rule uses: radar.distance "flat" (horizontal, the default) or "3d".
static func distance_m(me: Vector3, other: Vector3) -> float:
	if str(cfg().get("distance", "flat")) == "3d":
		return me.distance_to(other)
	return ground_offset(me, other).length()


## In the cover crouch: in cover (any cover state but FREE) and crouched at least cover_crouch_min. Standing behind high
## cover, or risen over low cover to shoot, is not the crouch and shows.
static func in_cover_crouch(p: Pawn) -> bool:
	return p.in_cover() and p.cover.crouch_amount >= float(cfg().get("cover_crouch_min", 0.5))


static func _pos(p: Node3D) -> Vector3:
	return p.global_position if p.is_inside_tree() else p.position


static func _yaw(p: Node3D) -> float:
	return p.global_rotation.y if p.is_inside_tree() else p.rotation.y


## The rule (DESIGN.md:26): "" = not on the radar, else ENEMY or MATE. Reads radar.range_m, distance, cover_crouch_min.
static func classify(me: Pawn, p: Pawn) -> String:
	var c := cfg()
	return classify_with(me, p, float(c.get("range_m", 25.0)), str(c.get("distance", "flat")) != "3d", float(c.get("cover_crouch_min", 0.5)))


## classify() with the data already read (the radar reads it once per update).
static func classify_with(me: Pawn, p: Pawn, rng: float, flat: bool, crouch_min: float) -> String:
	if me == null or p == null or not is_instance_valid(p) or p == me:
		return ""
	if p.life == Pawn.Life.DEAD or (p.bridge != null and p.bridge.state.is_dead()):
		return ""
	if not p.visible:  # a LAN replica the host's snapshot reports not alive (set_active(false))
		return ""
	if p.drop_state == Pawn.Drop.ABOARD:  # riding the carrier: everyone is at one spot, nobody is on the ground
		return ""
	var a := _pos(me)
	var b := _pos(p)
	var d := ground_offset(a, b).length() if flat else a.distance_to(b)
	if d > rng:
		return ""
	if p.squad_id == me.squad_id:
		return MATE
	if p.in_cover() and p.cover.crouch_amount >= crouch_min:  # in_cover_crouch, with the threshold read once
		return ""
	return ENEMY


func _active() -> bool:
	if not bool(_cfg.get("enabled", false)) or pawn == null or not is_instance_valid(pawn):
		return false
	return game_hud == null or game_hud.is_visible_in_tree()


func _relayout() -> void:
	_last_size = size
	_rect = disc_rect(size)
	_u = HudArrangement.unit(size)
	_rad = blip_radius_px(size)
	var c := _rect.get_center()
	for n: Node2D in [_disc, _sweep, _blips]:
		n.position = c
	_disc.queue_redraw()
	_sweep.queue_redraw()
	if _active():
		update_blips()


func _process(delta: float) -> void:
	tick(delta)


## One frame: blips at update_hz; the blip layer's turn and the sweep every frame (transforms only).
func tick(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	var on := _active()
	if visible != on:
		visible = on
	if not on:
		return
	if size != _last_size:
		_relayout()
	_accum += delta
	var period := 1.0 / maxf(float(_cfg.get("update_hz", 10.0)), 0.1)
	if _accum >= period:
		_accum = fmod(_accum, period)
		update_blips()
	follow(delta)
	cost_usec += Time.get_ticks_usec() - t0


## Turns the blip layer by the heading change since the last update (blips drawn at the update's heading land where
## to_px puts them at the current heading), and the sweep by its period.
func follow(delta: float = 0.0) -> void:
	_blips.rotation = _yaw(pawn) - _snap_yaw
	var sw: Dictionary = _cfg.get("sweep", {})
	_sweep.visible = bool(sw.get("enabled", false))
	if _sweep.visible:
		_sweep_t = fmod(_sweep_t + delta / maxf(float(sw.get("period_s", 2.5)), 0.1), 1.0)
		_sweep.rotation = _sweep_t * TAU


## Rebuilds the blip list from the pawns the peer has and redraws the blip layer.
func update_blips() -> void:
	blip_updates += 1
	blips = []
	if pawn == null or not is_instance_valid(pawn):
		_blips.queue_redraw()
		return
	var me := _pos(pawn)
	_snap_yaw = _yaw(pawn)
	_blips.rotation = 0.0
	var c := _rect.get_center()
	# Data read once per update (cheap per pawn).
	var rng := float(_cfg.get("range_m", 25.0))
	var flat := str(_cfg.get("distance", "flat")) != "3d"
	var crouch_min := float(_cfg.get("cover_crouch_min", 0.5))
	var enemy_col := _color("enemy")
	if director != null:
		var players: Dictionary = director.all_players()
		for id in players:
			var p: Pawn = players[id]
			var kind := classify_with(pawn, p, rng, flat, crouch_min)
			if kind == "":
				continue
			# The drawn offset is the ground offset in both distance modes (under "3d" it is never longer than the 3d
			# distance, so an admitted blip is still inside the circle).
			var pp := _pos(p)
			var off := ground_offset(me, pp)
			blips.append({"kind": kind, "id": int(p.player_id), "world": Vector2(pp.x, pp.z), "offset": off,
				"dist_m": off.length() if flat else me.distance_to(pp), "px": to_px(off, _snap_yaw, rng, _rad, c),
				"color": SoldierSquadColour.paint(p.squad_id) if kind == MATE else enemy_col})
	_blips.queue_redraw()


## Where a blip of the last update is drawn now (HUD space), through the blip layer's transform (tests).
func drawn_px(blip: Dictionary) -> Vector2:
	var c := _rect.get_center()
	return c + _blips.transform.basis_xform((blip["px"] as Vector2) - c)


func blip_of(id: int) -> Dictionary:
	for b: Dictionary in blips:
		if int(b["id"]) == id:
			return b
	return {}


func _color(key: String) -> Color:
	return MenuStyle.color(str((_cfg.get("colors", {}) as Dictionary).get(key, "marble")))


func _mk(key: String) -> float:
	return float(_cfg["marks"][key]) * _u


# --- drawing (all in the radar's own frame: origin = the disc's centre, up = the player's heading) --------------------

## The disc: dark field, range rings, the gold rim, the forward tick at the top and the player's mark at the centre.
## Redrawn only on a resize.
func _draw_disc(ci: Node2D) -> void:
	var r := _rect.size.x * 0.5
	if r <= 1.0:
		return
	var disc := _color("disc")
	disc.a = float(_cfg.get("disc_alpha", 0.78))
	ci.draw_circle(Vector2.ZERO, r, disc)
	var ring := _color("ring")
	ring.a = 0.35
	var rr := _rad
	for f in _cfg.get("rings", []):
		ci.draw_arc(Vector2.ZERO, rr * float(f), 0.0, TAU, 64, ring, maxf(1.0, _mk("ring_width_units")), true)
	# Faint cross hairs (ahead / right), so bearings read at a glance.
	var hair := ring
	hair.a = 0.18
	ci.draw_line(Vector2(0, -rr), Vector2(0, rr), hair, maxf(1.0, _mk("ring_width_units")), true)
	ci.draw_line(Vector2(-rr, 0), Vector2(rr, 0), hair, maxf(1.0, _mk("ring_width_units")), true)
	var rim_w := maxf(1.0, _mk("rim_width_units"))
	var rim := _color("rim")
	rim.a = 0.85
	ci.draw_arc(Vector2.ZERO, r - rim_w * 0.5, 0.0, TAU, 96, rim, rim_w, true)
	# Forward tick: a small gold wedge on the rim, pointing in (forward = up).
	var t := _mk("tick_units")
	var top := -r + rim_w * 0.5
	ci.draw_colored_polygon(PackedVector2Array([Vector2(-t * 0.6, top - t * 0.15), Vector2(t * 0.6, top - t * 0.15), Vector2(0, top + t * 0.85)]), _color("outline"))
	ci.draw_colored_polygon(PackedVector2Array([Vector2(-t * 0.42, top), Vector2(t * 0.42, top), Vector2(0, top + t * 0.62)]), _color("tick"))
	# The player: a small gold chevron pointing ahead.
	var s := _mk("self_units")
	var pts := PackedVector2Array([Vector2(0, -s * 0.62), Vector2(s * 0.42, s * 0.4), Vector2(0, s * 0.18), Vector2(-s * 0.42, s * 0.4)])
	var outline := PackedVector2Array()
	for p in pts:
		outline.append(p * 1.35 + Vector2(0, s * 0.02))
	ci.draw_colored_polygon(outline, _color("outline"))
	ci.draw_colored_polygon(pts, _color("self"))


## The sweep: a faint line from the centre to the rim with a fading trail behind it, drawn once pointing up and turned.
func _draw_sweep(ci: Node2D) -> void:
	var sw: Dictionary = _cfg.get("sweep", {})
	var r := _rad
	if r <= 1.0:
		return
	var col := _color("sweep")
	var a := float(sw.get("alpha", 0.2))
	var trail := deg_to_rad(float(sw.get("trail_deg", 50.0)))
	var r0 := _mk("self_units") * 0.9
	# The trail: ONE polygon (outer arc out, inner arc back) whose vertex alpha fades away from the line: one draw call.
	var n := 12
	var pts := PackedVector2Array()
	var cols := PackedColorArray()
	for i in n + 1:
		var ang := -PI * 0.5 - trail * float(i) / n
		pts.append(Vector2.from_angle(ang) * r)
		cols.append(Color(col, a * 0.6 * (1.0 - float(i) / n)))
	for i in range(n, -1, -1):
		var ang := -PI * 0.5 - trail * float(i) / n
		pts.append(Vector2.from_angle(ang) * r0)
		cols.append(Color(col, a * 0.6 * (1.0 - float(i) / n)))
	ci.draw_polygon(pts, cols)
	var line := col
	line.a = minf(1.0, a * 2.5)
	# The line starts clear of the player's chevron, so the sweep never crosses the centre mark.
	ci.draw_line(Vector2(0, -_mk("self_units") * 0.9), Vector2(0, -r), line, maxf(1.0, _mk("ring_width_units") * 1.5), true)


## Mates first, enemies on top. Enemy: a solid diamond in the hostile colour, dark outline. Mate: a dot in the squad
## colour inside a marble ring, dark outline (as on the minimap).
func _draw_blips(ci: Node2D) -> void:
	blip_draws += 1
	var t0 := Time.get_ticks_usec()
	var c := _rect.get_center()
	var o := _mk("outline_units")
	for b: Dictionary in blips:
		if b["kind"] != MATE:
			continue
		var p: Vector2 = (b["px"] as Vector2) - c
		var rr := _mk("mate_units")
		ci.draw_circle(p, rr * 1.15 + o, _color("outline"))
		ci.draw_circle(p, rr * 1.15, _color("mate_ring"))
		ci.draw_circle(p, rr * 0.8, b["color"])
	var s := _mk("enemy_units")
	for b: Dictionary in blips:
		if b["kind"] != ENEMY:
			continue
		var p2: Vector2 = (b["px"] as Vector2) - c
		var w := s * 0.82
		ci.draw_colored_polygon(PackedVector2Array([p2 + Vector2(0, -s - o * 1.4), p2 + Vector2(w + o * 1.2, 0), p2 + Vector2(0, s + o * 1.4), p2 + Vector2(-w - o * 1.2, 0)]), _color("outline"))
		ci.draw_colored_polygon(PackedVector2Array([p2 + Vector2(0, -s), p2 + Vector2(w, 0), p2 + Vector2(0, s), p2 + Vector2(-w, 0)]), b["color"])
	cost_usec += Time.get_ticks_usec() - t0
