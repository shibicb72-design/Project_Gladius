class_name Breakable
extends StaticBody3D
## M2 L1b: a crate or barrel that is cover until it breaks (data/props.json "breakables", OQ-PROPS-BREAK). It keeps
## the cover contract of scripts/systems/cover_probe.gd (group "cover_wall", a "Shape" child holding a box, layer 1)
## and is also in group "breakable" so the hit hooks and other code can tell it apart from static cover. The map
## builder makes it outside Nav (the bake never sees it: bots path as if it were not there).
## Only the authority damages it (Hitscan.fire / Melee.swing call take_hit inside their `authority.is_valid()`
## branch); a client learns about a break from WorldProps.apply_state, which calls break_now(false).
## Breaking: the look is hidden at once (MapChunks), `broken` is emitted (WorldProps rolls the loot), the effect and
## the impact sound play, and the body leaves the tree DEFERRED, so the shot that broke it still finds it with the
## impact probe of scripts/audio/pawn_audio.gd in the same frame. The cover index sees the removal by itself
## (cover_index.gd tree signals).

signal broken(prop_id: String)

const GROUP := &"breakable"

var prop_id := ""
var prop_type := ""
var size := Vector3.ONE
var health := 1.0
var max_health := 1.0
var melee_damage := 0.0
var palette := ""
var is_broken := false
## The batches drawing the look (MapChunks: hide_piece(prop_id)); null = no look (tests, tools).
var chunks: Node
## Called once with this body when it leaves the world (the builder takes it out of cover_bodies); may be invalid.
var on_removed: Callable = Callable()
## Where the break effect goes (the ArtBuilder); null = no effect.
var fx_parent: Node
## data/props.json "break_fx".
var fx_cfg: Dictionary = {}


## A body for one cover-file entry {id, type, at, size} with the type's behaviour from data/props.json
## "breakables". The position is the file's `at`; the builder lifts it onto the terrain.
static func make(entry: Dictionary, type_cfg: Dictionary) -> Breakable:
	var body := Breakable.new()
	body.name = String(entry["id"])
	body.prop_id = String(entry["id"])
	body.prop_type = String(entry.get("type", ""))
	body.size = LowpolyKit.vec(entry["size"])
	body.max_health = float(type_cfg.get("health", 1.0))
	body.health = body.max_health
	body.melee_damage = float(type_cfg.get("melee_damage", 0.0))
	body.palette = String(type_cfg.get("palette", "citadel"))
	body.set_meta(&"cover_palette", body.palette)
	body.collision_layer = 1
	body.collision_mask = 0
	body.add_to_group(&"cover_wall")
	body.add_to_group(GROUP)
	body.position = LowpolyKit.vec(entry["at"])
	var shape := CollisionShape3D.new()
	shape.name = "Shape"
	var box := BoxShape3D.new()
	box.size = body.size
	shape.shape = box
	body.add_child(shape)
	return body


## One hit from the authority: a gun ray's `damage`, or (is_melee) this type's melee_damage. Returns true when the
## hit counted (false once broken or for a hit of no damage).
func take_hit(damage: float, is_melee := false) -> bool:
	if is_broken:
		return false
	var amount := melee_damage if is_melee else damage
	if amount <= 0.0:
		return false
	health = maxf(health - amount, 0.0)
	if health <= 0.0:
		break_now()
	return true


## Breaks it now (once). `emit` false: a state applied from the host (no `broken` signal, so no loot roll here).
func break_now(emit := true) -> void:
	if is_broken:
		return
	is_broken = true
	health = 0.0
	if chunks != null and chunks.has_method(&"hide_piece"):
		chunks.call(&"hide_piece", prop_id)
	if emit:
		broken.emit(prop_id)
	_spawn_fx()
	_play_sound()
	_leave.call_deferred()


## The ground point under the body's centre (where loot lands).
func ground_point() -> Vector3:
	return _xform().origin - Vector3(0.0, size.y * 0.5, 0.0)


## The point of the box nearest `p` (world space): the melee swing tests its arc and reach on it.
func closest_point(p: Vector3) -> Vector3:
	var xform := _xform()
	var local := xform.affine_inverse() * p
	var half := size * 0.5
	return xform * local.clamp(-half, half)


func _xform() -> Transform3D:
	return global_transform if is_inside_tree() else transform


func _leave() -> void:
	if on_removed.is_valid():
		on_removed.call(self)
	var parent := get_parent()
	if parent != null:
		parent.remove_child(self)
	queue_free()


## The existing impact sound of this body's material (data/audio.json "impacts", the rule of
## PawnAudio.material_of), through the Sfx autoload; nothing without Sfx or a tree.
func _play_sound() -> void:
	if not is_inside_tree():
		return
	var sfx := get_node_or_null("/root/Sfx")
	if sfx == null:
		return
	var impacts: Dictionary = sfx.cfg.get("impacts", {})
	var material := PawnAudio.material_of(self, impacts)
	var id := String((impacts.get("by_material", {}) as Dictionary).get(material, ""))
	if id == "" or (sfx.sound(id) as Dictionary).is_empty():
		id = String((sfx.cfg.get("hooks", {}) as Dictionary).get("impact_world", ""))
	if id != "":
		sfx.play_at(id, _xform().origin)


## A one-shot debris burst (data/props.json "break_fx"); a no-op headless, without a parent or with 0 pieces.
func _spawn_fx() -> void:
	if fx_parent == null or not is_instance_valid(fx_parent) or not fx_parent.is_inside_tree():
		return
	if DisplayServer.get_name() == "headless" or int(fx_cfg.get("pieces", 0)) <= 0:
		return
	var fx := CPUParticles3D.new()
	fx.name = "BreakFx_" + prop_id
	fx.one_shot = true
	fx.explosiveness = 1.0
	fx.amount = int(fx_cfg["pieces"])
	fx.lifetime = maxf(float(fx_cfg.get("life_s", 0.6)), 0.05)
	fx.direction = Vector3.UP
	fx.spread = float(fx_cfg.get("spread_deg", 60.0))
	fx.initial_velocity_min = float(fx_cfg.get("speed_mps", 3.0)) * 0.5
	fx.initial_velocity_max = float(fx_cfg.get("speed_mps", 3.0))
	var piece := BoxMesh.new()
	var m := float(fx_cfg.get("piece_m", 0.25))
	piece.size = Vector3(m, m, m)
	piece.material = WorldSurface.palette_material(palette)
	fx.mesh = piece
	fx_parent.add_child(fx)
	fx.global_position = _xform().origin
	fx.emitting = true
	fx.get_tree().create_timer(fx.lifetime + 0.5).timeout.connect(fx.queue_free)
