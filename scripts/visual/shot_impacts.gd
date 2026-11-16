class_name ShotImpacts
extends Node3D
## M2 AN1 commit 5: impact bursts by surface, shared by every pawn's ShotFx (third and first person). Presentation only:
## nothing here touches the shot, its ray, its timing or its signals.
## Kinds (data/art_soldier.json fx.impacts): "sparks" (stone, metal), "dust" (the ground, wood) and "energy" (a
## soldier). The surface is classified like the impact sounds (PawnAudio.material_of with data/audio.json "impacts",
## read only) from a short visual probe through the shot's end point; the ground and a soldier (a CharacterBody3D) are
## told apart first. One pool per world (a child of the pawns' parent), at most fx.impact_cap bursts alive at once
## (18 players firing): a new burst past the cap restarts the oldest one. Each burst is one one-shot CPUParticles3D.

const NODE_NAME := "ShotImpacts"

var _cfg: Dictionary = {}
var _audio_impacts: Dictionary = {}
var _pool: Array[CPUParticles3D] = []
var _born: Array[float] = []
var _life: Array[float] = []
var _kind: Array[String] = []
var _clock := 0.0
var _meshes := {}  # kind -> Mesh (shared)


## The pool for `near`'s world: under the parent of `near`'s pawn (or `near`'s parent), made on first use.
static func for_node(near: Node) -> ShotImpacts:
	if near == null or not near.is_inside_tree():
		return null
	var host := near.get_parent()
	if host != null and host.get_parent() != null:
		host = host.get_parent()  # ShotFx -> Pawn -> the pawns' parent
	if host == null:
		return null
	var existing := host.get_node_or_null(NODE_NAME) as ShotImpacts
	if existing != null:
		return existing
	var pool := ShotImpacts.new()
	pool.name = NODE_NAME
	host.add_child(pool)
	return pool


## The impact flash colour for a burst kind (fx.impacts.<kind>.flash_color), `fallback` when the kind has none.
static func flash_color(kind: String, fallback: Color) -> Color:
	var k: Dictionary = ((ViewMesh.config().get("fx", {}) as Dictionary).get("impacts", {}) as Dictionary).get(kind, {})
	return ViewFx.color_of(k["flash_color"]) if k.has("flash_color") else fallback


func _init() -> void:
	_cfg = ViewMesh.config().get("fx", {})
	_audio_impacts = DataRegistry.new().load_file("res://data/audio.json").get("impacts", {})


func _process(delta: float) -> void:
	_clock += delta


func cap() -> int:
	return maxi(int(_cfg.get("impact_cap", 12)), 1)


## Bursts still playing (born less than their lifetime ago).
func alive_count() -> int:
	var n := 0
	for i in _pool.size():
		if _clock - _born[i] < _life[i]:
			n += 1
	return n


func pool_size() -> int:
	return _pool.size()


## The kind of burst for a shot from `origin` ending at `end` in `world`: probes 5 cm before to 10 cm past the end
## point (the sound probe's span, data/audio.json impacts), then {"kind", "normal"}.
func classify(world: World3D, origin: Vector3, end: Vector3) -> Dictionary:
	var dir := end - origin
	var by: Dictionary = _cfg.get("impact_by_material", {})
	var fallback := String(by.get(String(_audio_impacts.get("default", "stone")), "sparks"))
	if dir.is_zero_approx() or world == null:
		return {"kind": fallback, "normal": -dir.normalized() if not dir.is_zero_approx() else Vector3.UP}
	dir = dir.normalized()
	var query := PhysicsRayQueryParameters3D.create(end - dir * float(_audio_impacts.get("probe_back_m", 0.05)),
			end + dir * float(_audio_impacts.get("probe_ahead_m", 0.1)), 1)
	query.collide_with_areas = false
	var found := world.direct_space_state.intersect_ray(query)
	if found.is_empty():
		return {"kind": fallback, "normal": -dir}
	var body: Object = found["collider"]
	var material := "soldier" if body is CharacterBody3D else ("ground" if body is Node and (body as Node).name == &"Ground" else PawnAudio.material_of(body, _audio_impacts))
	return {"kind": String(by.get(material, fallback)), "normal": found.get("normal", -dir)}


## Starts one burst of `kind` at `at`, thrown along `normal`. Returns the particle node used.
func spawn(kind: String, at: Vector3, normal: Vector3) -> CPUParticles3D:
	var kinds: Dictionary = _cfg.get("impacts", {})
	if not kinds.has(kind):
		return null
	var k: Dictionary = kinds[kind]
	var i := _free_slot()
	var p := _pool[i]
	_configure(p, kind, k)
	var n := normal.normalized() if not normal.is_zero_approx() else Vector3.UP
	var up := Vector3.UP if absf(n.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	p.global_transform = Transform3D(Basis.looking_at(-n, up), at + n * 0.02)  # the burst's +z (its direction) = n
	p.restart()
	p.emitting = true
	_born[i] = _clock
	_life[i] = p.lifetime
	_kind[i] = kind
	return p


## A free pooled burst, a new one while under the cap, else the oldest (restarted: the cap holds).
func _free_slot() -> int:
	var oldest := -1
	for i in _pool.size():
		if _clock - _born[i] >= _life[i]:
			return i
		if oldest < 0 or _born[i] < _born[oldest]:
			oldest = i
	if _pool.size() < cap():
		var p := CPUParticles3D.new()
		p.name = "Burst%d" % _pool.size()
		p.one_shot = true
		p.emitting = false
		p.explosiveness = 1.0
		p.local_coords = false
		p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		p.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		p.direction = Vector3.BACK  # +z of the burst = along the surface normal (see spawn)
		add_child(p)
		p.top_level = true
		_pool.append(p)
		_born.append(-INF)
		_life.append(0.0)
		_kind.append("")
		return _pool.size() - 1
	return oldest


func _configure(p: CPUParticles3D, kind: String, k: Dictionary) -> void:
	p.amount = maxi(int(k.get("amount", 8)), 1)
	p.lifetime = maxf(float(k.get("lifetime_s", 0.3)), 0.01)
	p.spread = float(k.get("spread_deg", 60.0))
	var v: Array = k.get("velocity_mps", [1.0, 3.0])
	p.initial_velocity_min = float(v[0])
	p.initial_velocity_max = float(v[1])
	p.gravity = ViewMesh.vec(k.get("gravity_mps2", [0.0, -9.8, 0.0]))
	p.damping_min = float(k.get("damping", 0.0))
	p.damping_max = float(k.get("damping", 0.0))
	p.particle_flag_align_y = bool(k.get("streak", false))
	var sc: Array = k.get("scale", [1.0, 1.0])
	p.scale_amount_min = float(sc[0])
	p.scale_amount_max = float(sc[1])
	var grow := float(k.get("grow", 1.0))
	if not is_equal_approx(grow, 1.0):
		var curve := Curve.new()
		curve.max_value = maxf(grow, 1.0)
		curve.add_point(Vector2(0.0, 1.0))
		curve.add_point(Vector2(1.0, grow))
		p.scale_amount_curve = curve
	else:
		p.scale_amount_curve = null
	var ramp := Gradient.new()
	ramp.set_color(0, Color.WHITE)
	ramp.set_color(1, Color(1, 1, 1, 0))
	p.color_ramp = ramp
	p.mesh = _mesh(kind, k)


func _mesh(kind: String, k: Dictionary) -> Mesh:
	if _meshes.has(kind):
		return _meshes[kind]
	var box := BoxMesh.new()
	box.size = ViewMesh.vec(k.get("size_m", [0.03, 0.03, 0.03]))
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if bool(k.get("additive", false)):
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	var c := ViewFx.color_of(k.get("color", [1, 1, 1, 1]))
	mat.albedo_color = c
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES if bool(k.get("billboard", false)) else BaseMaterial3D.BILLBOARD_DISABLED
	box.material = mat
	_meshes[kind] = box
	return box
