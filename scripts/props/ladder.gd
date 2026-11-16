class_name Ladder
extends Area3D
## M2 L1c commit 5: a ladder up to a ledge (the 1 km map: one per barracks block, on an end wall, up to the roof;
## OQ-PROPS-LADDER). Placement lives in the map's cover file ("ladders", tools/gen_alesia.gd from generator.ladders):
## {id, piece, at (the foot: on the ground, on the ladder plane, at the ladder's middle), yaw (the direction a climber
## faces = into the wall, Godot's: a node with this rotation.y looks along it), height (foot to the ledge top), width,
## top (the top-step point: where the feet are set on the ledge)}. Behaviour and looks: data/props.json "ladder".
## NON-BLOCKING: an Area3D on collision layer 0 (no shot, sight, movement or shape query ever meets it; Hitscan's
## MASK_WORLD is layer 1) whose mask 2 (pawn bodies) only lets it notice touching pawns. The map builder makes it under
## ArtBuilder/Props, OUTSIDE Nav: the bake never parses it (and an area is no static collider anyway).
## Not cover: never in group cover_wall, in no body list, not counted in max_cover_walls.
## The climbing itself is the pawn's (scripts/classes/pawn.gd, the "M2 L1c ladder" block): the state (climbing,
## ladder_id) is plain on the pawn; this node only answers geometry: who touches it, whether a move grabs it, where
## the climb line and the top step are.
## Frame: origin = the foot; -Z = into the wall (the climber's facing); +Y up; X along the width. The trigger box spans
## the width, y 0 .. height + rail_above_m, z -top_reach_m (onto the ledge) .. +reach_m (out in front).

const GROUP := &"ladder"
const PAWN_MASK := 2
## A pawn's body radius (scenes/player/pawn.tscn capsule): the climb line clears an eave at the plane by
## climb_offset_m minus this.
const PAWN_RADIUS_M := 0.4
## The feet are set this far above the top point on the top step (no start inside the ledge).
const TOP_LIFT_M := 0.02
enum Grab { NONE, BOTTOM, TOP }

var prop_id := ""
var piece_id := ""
var height := 3.0
var width := 0.6
## data/props.json "ladder" (behaviour numbers; the pawn's ladder block reads them from here).
var cfg: Dictionary = {}
## The top-step point in this node's frame (from the cover file's `top`, relative to `at`).
var top_local := Vector3.ZERO
var _shape: CollisionShape3D
## Built look meshes by size (one mesh per distinct ladder size).
static var _meshes := {}


## A trigger for one cover-file "ladders" entry with data/props.json "ladder" as `ladder_cfg`. The position is the
## file's `at` (the foot); the builder lifts it onto the terrain (the top point keeps its offset to the foot).
static func make(entry: Dictionary, ladder_cfg: Dictionary) -> Ladder:
	var l := Ladder.new()
	l.name = String(entry["id"])
	l.prop_id = String(entry["id"])
	l.piece_id = String(entry.get("piece", ""))
	l.height = float(entry["height"])
	l.width = float(entry["width"])
	l.cfg = ladder_cfg
	l.collision_layer = 0
	l.collision_mask = PAWN_MASK
	l.monitorable = false
	l.monitoring = true
	l.add_to_group(GROUP)
	var at := LowpolyKit.vec(entry["at"])
	l.position = at
	l.rotation.y = deg_to_rad(float(entry.get("yaw", 0.0)))
	l.top_local = Basis(Vector3.UP, l.rotation.y).inverse() * (LowpolyKit.vec(entry["top"]) - at)
	var reach := float(ladder_cfg.get("reach_m", 0.5))
	var onto := float(ladder_cfg.get("top_reach_m", 1.0))
	var tall := l.height + float(ladder_cfg.get("rail_above_m", 0.9))
	l._shape = CollisionShape3D.new()
	l._shape.name = "Shape"
	var box := BoxShape3D.new()
	box.size = Vector3(l.width, tall, reach + onto)
	l._shape.shape = box
	l._shape.position = Vector3(0.0, tall * 0.5, (reach - onto) * 0.5)
	l.add_child(l._shape)
	var look := MeshInstance3D.new()
	look.name = "Look"
	look.mesh = _look_mesh(Vector3(l.width, tall, LowpolyKit.vec(ladder_cfg.get("look_size", [0.6, 4.2, 0.08])).z), ladder_cfg)
	look.material_override = WorldSurface.palette_material(String(ladder_cfg.get("palette", "door")))
	look.position = Vector3(0.0, tall * 0.5, look.mesh.get_aabb().size.z * 0.5)  # the rails stand in front of the plane
	l.add_child(look)
	return l


func _xform() -> Transform3D:
	return global_transform if is_inside_tree() else transform


## The horizontal unit direction into the wall (the climber's facing).
func into_dir() -> Vector3:
	var d := -_xform().basis.z
	d.y = 0.0
	return d.normalized()


## The foot (world): on the ground, on the ladder plane.
func foot() -> Vector3:
	return _xform().origin


## The ledge top's world height.
func top_y() -> float:
	return foot().y + height


## The top-step point (world): where the feet are set on the ledge.
func top_point() -> Vector3:
	return _xform() * top_local + Vector3.UP * TOP_LIFT_M


## Where a climber's feet are held at height `feet_y`: on the climb line, climb_offset_m out from the plane.
func climb_point(feet_y: float) -> Vector3:
	var p := foot() - into_dir() * float(cfg.get("climb_offset_m", 0.5))
	p.y = feet_y
	return p


## `p` in this ladder's frame.
func local_of(p: Vector3) -> Vector3:
	return _xform().affine_inverse() * p


## The climb rate for a world move vector (the stick turned by the pawn's yaw, its length the stick's): the share
## pointing into the ladder, -1 (down) .. 1 (up).
func climb_rate(move_world: Vector3) -> float:
	return clampf(Vector3(move_world.x, 0.0, move_world.z).dot(into_dir()), -1.0, 1.0)


## Whether a pawn whose feet stand at `feet`, on the floor or not, moving by `move_world`, grabs this ladder now:
## it must touch the trigger (`touching`), stand on the floor, push the stick at least grab_min_input, and
## - BOTTOM: the feet at most bottom_grab_height_m above the foot, its centre in front of the ladder plane, the move
##   direction within acos(grab_min_dot) of into the ladder;
## - TOP: the feet within top_grab_height_m of the ledge top, the move direction within acos(grab_min_dot) of out over
##   the edge (away from the wall).
func grab_kind(feet: Vector3, on_floor: bool, move_world: Vector3, touching: bool) -> Grab:
	var flat := Vector3(move_world.x, 0.0, move_world.z)
	if not touching or not on_floor or flat.length() < float(cfg.get("grab_min_input", 0.3)):
		return Grab.NONE
	var along := flat.normalized().dot(into_dir())
	var min_dot := float(cfg.get("grab_min_dot", 0.6))
	if feet.y - foot().y <= float(cfg.get("bottom_grab_height_m", 0.5)) and local_of(feet).z >= 0.0 and along >= min_dot:
		return Grab.BOTTOM
	if absf(feet.y - top_y()) <= float(cfg.get("top_grab_height_m", 0.3)) and -along >= min_dot:
		return Grab.TOP
	return Grab.NONE


static func _look_mesh(size: Vector3, ladder_cfg: Dictionary) -> Mesh:
	var key := str(size)
	if not _meshes.has(key):
		var look_size := LowpolyKit.vec(ladder_cfg.get("look_size", [size.x, size.y, size.z]))
		var k := size / look_size
		var parts: Array = []
		for part: Dictionary in (ladder_cfg.get("look", {}) as Dictionary).get("parts", []):
			var p := part.duplicate(true)
			var s := LowpolyKit.vec(p["size"]) * k
			var a := LowpolyKit.vec(p["at"]) * k
			p["size"] = [s.x, s.y, s.z]
			p["at"] = [a.x, a.y, a.z]
			parts.append(p)
		_meshes[key] = LowpolyKit.build_cover({"parts": parts}) if not parts.is_empty() else BoxMesh.new()
	return _meshes[key]
