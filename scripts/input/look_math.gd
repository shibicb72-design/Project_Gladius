extends RefCounted
## Pure look-unit helpers shared by all providers. One contract: results are RADIANS PER PHYSICS
## TICK (what InputFrame.look and Pawn._apply_look expect), clamped to look.max_turn_rate_deg_s.
## Values come from data/input.json "look" (placeholders, OQ-36 / OQ-53).

const DEFAULT_MAX_TURN_DEG_S := 360.0
const DEFAULT_STICK_DEG_S := 180.0
const DEFAULT_DRAG_RAD_PER_HEIGHT := 3.14159


static func tick_hz() -> float:
	return maxf(1.0, float(Engine.physics_ticks_per_second))


## Per-axis cap in radians per tick for the configured max turn rate.
static func max_turn_per_tick(cfg: Dictionary, hz: float) -> float:
	var look: Dictionary = cfg.get("look", {})
	return deg_to_rad(float(look.get("max_turn_rate_deg_s", DEFAULT_MAX_TURN_DEG_S))) / maxf(1.0, hz)


static func clamp_turn(v: Vector2, cfg: Dictionary, hz: float) -> Vector2:
	var m := max_turn_per_tick(cfg, hz)
	return Vector2(clampf(v.x, -m, m), clampf(v.y, -m, m))


## Rate source (right stick, touch stick mode): full deflection gives look.stick_rate_deg_s.
static func look_from_stick(v: Vector2, cfg: Dictionary, hz: float) -> Vector2:
	var look: Dictionary = cfg.get("look", {})
	var rate := deg_to_rad(float(look.get("stick_rate_deg_s", DEFAULT_STICK_DEG_S)))
	return clamp_turn(v * rate / maxf(1.0, hz), cfg, hz)


## Camera-relative source: pixels dragged since the last tick, DPI-independent via viewport height.
static func look_from_drag(relative: Vector2, viewport_h: float, cfg: Dictionary) -> Vector2:
	var look: Dictionary = cfg.get("look", {})
	var k := float(look.get("drag_rad_per_screen_height", DEFAULT_DRAG_RAD_PER_HEIGHT))
	var v := relative / maxf(1.0, viewport_h) * k
	return clamp_turn(v, cfg, tick_hz())
