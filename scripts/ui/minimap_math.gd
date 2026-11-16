class_name MinimapMath
extends RefCounted
## M2 H1b commit 3 (OQ-MINIMAP): the ONE world-to-minimap mapping. Every minimap drawing (the baked picture, the arrow,
## squad mates, circles, the line, landmark names) and the tests go through to_px(world, frame) with a frame from
## frame_for(). Pure and static: no node, no state.
## World points are ground (x, z) in metres; north = -z is up on the picture (as tools/render_layout.gd draws maps).
## Yaw is the pawn's global_rotation.y (Godot: forward = (-sin yaw, -cos yaw) in x, z).
## Modes:
##   SMALL_NORTH   the small window, centre = the player, north up
##   SMALL_ROTATE  the small window, centre = the player, the player's heading up (the view turns by the yaw)
##   EXPANDED      the whole extent fitted into the rect, centred, north up

const SMALL_NORTH := "small_north"
const SMALL_ROTATE := "small_rotate"
const EXPANDED := "expanded"


## A view frame: {"origin": the rect's centre (px), "centre": the world point drawn there (m), "k": px per metre,
## "angle": radians the picture turns (screen-clockwise, Vector2.rotated)}.
static func frame(origin: Vector2, centre_m: Vector2, px_per_m: float, angle: float) -> Dictionary:
	return {"origin": origin, "centre": centre_m, "k": px_per_m, "angle": angle}


## The frame of a mode. `rect` = the picture's rect in the caller's space; `extent` = the world rect of the map texture
## (m); `player` = the player's ground point; `yaw` = their heading; `radius_m` = the small window's half side (m).
static func frame_for(mode: String, rect: Rect2, extent: Rect2, player: Vector2, yaw: float, radius_m: float) -> Dictionary:
	if mode == EXPANDED:
		var k := minf(rect.size.x / maxf(extent.size.x, 1e-3), rect.size.y / maxf(extent.size.y, 1e-3))
		return frame(rect.get_center(), extent.get_center(), k, 0.0)
	var k2 := minf(rect.size.x, rect.size.y) * 0.5 / maxf(radius_m, 1e-3)
	return frame(rect.get_center(), player, k2, yaw if mode == SMALL_ROTATE else 0.0)


## World ground point (x, z) -> minimap pixel in the frame's space.
static func to_px(world: Vector2, f: Dictionary) -> Vector2:
	return (f["origin"] as Vector2) + ((world - (f["centre"] as Vector2)) * float(f["k"])).rotated(float(f["angle"]))


## The inverse of to_px (a pixel back to the ground point).
static func to_world(px: Vector2, f: Dictionary) -> Vector2:
	return (f["centre"] as Vector2) + (px - (f["origin"] as Vector2)).rotated(-float(f["angle"])) / float(f["k"])


## Convenience: to_px(world, frame_for(...)) in one call.
static func world_to_px(world: Vector2, mode: String, rect: Rect2, extent: Rect2, player: Vector2, yaw: float, radius_m: float) -> Vector2:
	return to_px(world, frame_for(mode, rect, extent, player, yaw, radius_m))


## A world length (m) in pixels (the frame has no shear: one scale).
static func length_px(metres: float, f: Dictionary) -> float:
	return metres * float(f["k"])


## The pawn's forward on the ground for a yaw (Godot: -Z forward).
static func forward(yaw: float) -> Vector2:
	return Vector2(-sin(yaw), -cos(yaw))


## The arrow's screen rotation (radians, for a shape that points up at 0) for a heading in a frame.
static func arrow_rotation(yaw: float, f: Dictionary) -> float:
	var d := forward(yaw).rotated(float(f["angle"]))
	return atan2(d.x, -d.y)
