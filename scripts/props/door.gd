class_name Door
extends StaticBody3D
## M2 L1c: a door (barracks doorway, one leaf) or a gate (wall gate, two leaves) that Interact opens and closes
## (data/props.json "door" and its "gate" variant, OQ-PROPS-DOOR). Placement, box size, slide direction and the
## seeded start state live in the map's cover file ("doors", tools/gen_alesia.gd from generator.doors), so host and
## client build the same doors in the same state. The map builder makes it under ArtBuilder/Props, OUTSIDE Nav: the
## bake never parses it, so paths are planned as if every door were open.
## Not cover: never in group cover_wall, never in the builder's cover_bodies, not counted in max_cover_walls.
## State: `open` is the target (WorldProps keeps it as OPEN / CLOSED); `phase` is the leaves' pose (0 closed, 1 open).
## Collision: one box "Shape" (the closed leaves: width x height x thickness) on layer 1 (Hitscan.MASK_WORLD, the
## mask of shots, bot sight and pawn movement). It is ON only while the door stands closed; it is OFF while the
## leaves move and while the door stands open, so a door body never pushes, crushes or traps a pawn and an open
## doorway blocks nothing.
## Motion: both kinds SLIDE (pocket doors): over move_time_s each leaf slides its own width along local x into the
## wall beside the opening (slide "left" = towards -x, "right" = +x; "apart" = two half leaves, one each way; the
## generator checks that the pocket lies inside the piece's wall colliders). Its path is the doorway plus the pocket,
## so only a pawn standing in the doorway is ever in the way (a pawn cannot stand inside a wall). Before any move the
## door asks the physics space for pawn bodies (layer 2) in that path; one there: the door does not move, waits
## blocked_retry_s and asks again, until it is clear. After a close the collider switches on only when the doorway
## box is clear of pawns (asked again every blocked_retry_s); until then the door looks closed but stops nothing.

const GROUP := &"door"
const KIND_DOOR := "door"
const KIND_GATE := "gate"
const SLIDES: Array[String] = ["left", "right", "apart"]
const STARTS: Array[String] = ["open", "closed"]
## Pawn bodies (CharacterBody3D, layer 2: scenes/player/pawn.tscn, Hitscan.MASK_BODY); a dead pawn has layer 0.
const PAWN_MASK := 2
## Every query box is this much larger on each side (a pawn touching a leaf counts as in the way).
const MARGIN_M := 0.05

var prop_id := ""
var kind := KIND_DOOR
## Opening width (x), height (y), leaf thickness (z), in the door's frame (its yaw).
var size := Vector3.ONE
## "left": one leaf sliding to local -x; "right": one leaf to +x; "apart": two half leaves, the -x one to -x and the
## +x one to +x.
var slide := "right"
var move_time_s := 1.0
var blocked_retry_s := 0.5
var interact_range_m := 2.0
var height_limit_m := 2.0
## The target: true = OPEN. Changed only through set_open (WorldProps on the authority, apply_state on a client).
var open := false
## The leaves' pose: 0 = closed, 1 = open.
var phase := 0.0
var moving := false
## > 0: a pawn was in the way; the next try comes when this reaches 0.
var waiting_s := 0.0
## How many tries found a pawn in the way (tests and sims read it).
var waits := 0
## The leaves (one Node3D per leaf, its look a "Look" child), each one's closed x and slide direction (+1 / -1).
var leaves: Array[Node3D] = []
var _leaf_x: Array[float] = []
var _leaf_dirs: Array[float] = []
var _shape: CollisionShape3D
var _query_box := BoxShape3D.new()
## Built leaf meshes by kind and leaf size (one mesh per distinct leaf).
static var _meshes := {}


## A body for one cover-file "doors" entry {id, kind, at, yaw, size, slide, start} with the kind's behaviour
## (WorldProps.door_cfg). The position is the file's `at` (the opening's centre); the builder lifts it onto the
## terrain. It starts in the entry's start state, settled (no motion, the collider on when closed).
static func make(entry: Dictionary, kind_cfg: Dictionary) -> Door:
	var body := Door.new()
	body.name = String(entry["id"])
	body.prop_id = String(entry["id"])
	body.kind = String(entry.get("kind", KIND_DOOR))
	body.size = LowpolyKit.vec(entry["size"])
	body.slide = String(entry.get("slide", "right"))
	body.move_time_s = float(kind_cfg.get("move_time_s", 1.0))
	body.blocked_retry_s = float(kind_cfg.get("blocked_retry_s", 0.5))
	body.interact_range_m = float(kind_cfg.get("interact_range_m", 2.0))
	body.height_limit_m = float(kind_cfg.get("height_limit_m", 2.0))
	body.set_meta(&"cover_palette", String(kind_cfg.get("palette", "door")))
	body.collision_layer = 1
	body.collision_mask = 0
	body.add_to_group(GROUP)
	body.position = LowpolyKit.vec(entry["at"])
	body.rotation.y = deg_to_rad(float(entry.get("yaw", 0.0)))
	body._shape = CollisionShape3D.new()
	body._shape.name = "Shape"
	var box := BoxShape3D.new()
	box.size = body.size
	body._shape.shape = box
	body.add_child(body._shape)
	body._build_leaves(kind_cfg)
	body.open = String(entry.get("start", "closed")) == "open"
	body.phase = 1.0 if body.open else 0.0
	body._shape.disabled = body.open
	body._pose()
	return body


func _ready() -> void:
	set_physics_process(not settled())


func leaf_count() -> int:
	return 2 if slide == "apart" else 1


## Leaf width (one leaf of an "apart" door is half the opening); each leaf slides this far.
func leaf_width() -> float:
	return size.x / float(leaf_count())


## True when the leaves rest in the target pose and the collider matches it (nothing left to do).
func settled() -> bool:
	return not moving and phase == (1.0 if open else 0.0) and _shape.disabled == open


## True while the closed collider stops movement, shots and sight.
func blocks() -> bool:
	return not _shape.disabled


## Sets the target (absolute: OPEN true / CLOSED false). The door moves there by itself (physics ticks); a pending
## wait is dropped, so the next tick asks the space again.
func set_open(value: bool) -> void:
	open = value
	waiting_s = 0.0
	if is_inside_tree():
		set_physics_process(true)


func _physics_process(delta: float) -> void:
	step(delta)


## One tick of the door (see the class note). Public so tests can drive it.
func step(delta: float) -> void:
	if waiting_s > 0.0:
		waiting_s = maxf(waiting_s - delta, 0.0)
		if waiting_s > 0.0:
			return
	var want := 1.0 if open else 0.0
	if not moving and phase != want:
		if pawn_in_path():
			_wait()
			return
		moving = true
		_shape.disabled = true
		_play_sound()
	if moving:
		phase = move_toward(phase, want, delta / maxf(move_time_s, 0.01))
		_pose()
		if phase != want:
			return
		moving = false
	# Resting in the target pose: a closed door switches its collider on once no pawn stands in the doorway box.
	if not open and _shape.disabled:
		if pawn_in_closed():
			_wait()
			return
		_shape.disabled = false
	set_physics_process(false)


func _wait() -> void:
	waiting_s = maxf(blocked_retry_s, 0.01)
	waits += 1


## A pawn body in the leaves' path: the doorway and the pocket(s) the leaves slide into (full height, the leaf
## thickness).
func pawn_in_path() -> bool:
	var centre_x := 0.0
	if slide == "left":
		centre_x = -size.x * 0.5
	elif slide == "right":
		centre_x = size.x * 0.5
	return _pawn_in(Vector3(centre_x, 0.0, 0.0), Vector3(size.x * 2.0, size.y, size.z))


## A pawn body in the closed leaves' box (the doorway).
func pawn_in_closed() -> bool:
	return _pawn_in(Vector3.ZERO, size)


func _pawn_in(local_centre: Vector3, box_size: Vector3) -> bool:
	if not is_inside_tree():
		return false
	_query_box.size = box_size + Vector3.ONE * MARGIN_M * 2.0
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = _query_box
	q.transform = global_transform * Transform3D(Basis.IDENTITY, local_centre)
	q.collision_mask = PAWN_MASK
	q.collide_with_bodies = true
	q.collide_with_areas = false
	return not get_world_3d().direct_space_state.intersect_shape(q, 1).is_empty()


## Flat distance from `p` to the closed leaves' footprint (0 inside it); Interact's range counts from here.
func distance_to(p: Vector3) -> float:
	var local := _xform().affine_inverse() * p
	var half := size * 0.5
	return Vector2(local.x - clampf(local.x, -half.x, half.x), local.z - clampf(local.z, -half.z, half.z)).length()


## The world height of the opening's bottom (the threshold).
func bottom_y() -> float:
	return _xform().origin.y - size.y * 0.5


func _xform() -> Transform3D:
	return global_transform if is_inside_tree() else transform


func _build_leaves(kind_cfg: Dictionary) -> void:
	var w := leaf_width()
	var mesh := _leaf_mesh(kind, Vector3(w, size.y, size.z), kind_cfg)
	var material := WorldSurface.palette_material(String(kind_cfg.get("palette", "door")))
	var xs: Array[float] = []
	var dirs: Array[float] = []
	if slide == "apart":
		xs.append_array([-w * 0.5, w * 0.5])
		dirs.append_array([-1.0, 1.0])
	else:
		xs.append(0.0)
		dirs.append(-1.0 if slide == "left" else 1.0)
	for i in xs.size():
		var leaf := Node3D.new()
		leaf.name = "Leaf%d" % i
		add_child(leaf)
		var look := MeshInstance3D.new()
		look.name = "Look"
		look.mesh = mesh
		look.material_override = material
		if dirs[i] < 0.0:
			look.rotation.y = PI  # the authored +x (towards the pocket) points along the slide
		leaf.add_child(look)
		leaves.append(leaf)
		_leaf_x.append(xs[i])
		_leaf_dirs.append(dirs[i])


## The leaves at `phase`: each slid phase x its own width along its direction.
func _pose() -> void:
	var w := leaf_width()
	for i in leaves.size():
		leaves[i].position = Vector3(_leaf_x[i] + _leaf_dirs[i] * w * phase, 0.0, 0.0)


## A leaf mesh from the kind's look (LowpolyKit parts authored for look_size, scaled to `leaf`), built once per kind
## and leaf size.
static func _leaf_mesh(leaf_kind: String, leaf: Vector3, kind_cfg: Dictionary) -> Mesh:
	var key := leaf_kind + str(leaf)
	if not _meshes.has(key):
		var look_size := LowpolyKit.vec(kind_cfg.get("look_size", [leaf.x, leaf.y, leaf.z]))
		var k := leaf / look_size
		var parts: Array = []
		for part: Dictionary in (kind_cfg.get("look", {}) as Dictionary).get("parts", []):
			var p := part.duplicate(true)
			var s := LowpolyKit.vec(p["size"]) * k
			var a := LowpolyKit.vec(p["at"]) * k
			p["size"] = [s.x, s.y, s.z]
			p["at"] = [a.x, a.y, a.z]
			parts.append(p)
		_meshes[key] = LowpolyKit.build_cover({"parts": parts}) if not parts.is_empty() else BoxMesh.new()
	return _meshes[key]


## The existing impact sound of this body's material (data/audio.json "impacts", PawnAudio.material_of: the meta
## cover_palette, an unlisted palette such as "door" gives by_palette.default, wood) when the leaves start to move;
## nothing without Sfx or a tree (the Breakable rule).
func _play_sound() -> void:
	if not is_inside_tree():
		return
	var sfx := get_node_or_null("/root/Sfx")
	if sfx == null:
		return
	var impacts: Dictionary = sfx.cfg.get("impacts", {})
	var id := String((impacts.get("by_material", {}) as Dictionary).get(PawnAudio.material_of(self, impacts), ""))
	if id == "" or (sfx.sound(id) as Dictionary).is_empty():
		id = String((sfx.cfg.get("hooks", {}) as Dictionary).get("impact_world", ""))
	if id != "":
		sfx.play_at(id, _xform().origin)
