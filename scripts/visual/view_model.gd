class_name ViewModel
extends Node3D
## M2 C1a stage 2: the first-person view model of the local player's pawn: forearms and the held weapon at the bottom
## right, riding on the CameraRig's Camera3D. Presentation only: no colliders, no gameplay reads back from it (the
## shot, Hitscan origin, recoil and get_aim_point never see it). Built from the existing procedural kit parts
## (data/art_astra.json soldier arms, rifle and blade); every number is data/camera.json first_person.view_model
## (OQ-FIRST-PERSON, guesses).
## Ownership: CameraRig calls ViewModel.attach every physics frame until one exists; attach only creates it for a rig
## under a Pawn with no "Brain" child (the local player), so bots, replicas and a rig without a pawn never get one.
## Clipping (fix 12, option a): the whole model is built at natural size and then scaled down toward the eye
## (scale), which keeps its screen image and keeps every vertex inside max_reach_m (less than the 0.4 m body capsule
## radius), so the capsule holds walls farther away than the model reaches. No second camera, no SubViewport.
## Seams: set_aim_blend (stage 3 raises the gun to the sight; SightAnchor marks the sight), and stage 4 hides the
## third-person body by layer; the view model itself stays on the default layer.

const NODE_NAME := "ViewModel"
const _ARM_PARTS: Array[String] = ["lower_arm", "vambrace", "glove"]

static var _mesh_cache := {}

var pawn: Pawn
var rig: CameraRig
var tracer: MeshInstance3D
var flash: MeshInstance3D

var _cfg: Dictionary = {}
var _shot_cfg: Dictionary = {}
var _pivot: Node3D
var _weapons := {}  # weapon id -> Node3D (mesh, arms, markers); built on first use
var _shown_id := ""
var _shown: Node3D
var _muzzle: Marker3D
var _fx: ShotFx
var _aim_blend := 0.0
var _rng := RandomNumberGenerator.new()

# Motions: seconds elapsed and total; total 0 = idle.
var _swap_t := 0.0
var _swap_total := 0.0
var _reload_t := 0.0
var _reload_total := 0.0
var _swing_t := 0.0
var _swing_total := 0.0
var _recoil_left := 0.0
var _tracer_left := 0.0
var _flash_left := 0.0
var _tracer_start := Vector3.ZERO
var _tracer_end := Vector3.ZERO

# Bob and sway state.
var _bob_phase := 0.0
var _bob_amount := 0.0
var _sway := Vector2.ZERO  # x = pitch lag, y = yaw lag (degrees)
var _last_look := Vector2.ZERO
var _look_seen := false


## Creates the view model under the rig's camera for the local player's pawn (a Pawn parent with no Brain), or returns
## the existing one; null for every other rig. Cheap enough to call every physics frame until it returns a node.
static func attach(camera_rig: CameraRig) -> ViewModel:
	var owner_pawn := camera_rig.get_parent() as Pawn
	if owner_pawn == null or owner_pawn.has_node("Brain"):
		return null
	var cam := camera_rig.get_camera()
	if cam == null:
		return null
	var existing := cam.get_node_or_null(NODE_NAME) as ViewModel
	if existing != null:
		return existing
	var vm := ViewModel.new()
	vm.name = NODE_NAME
	vm.pawn = owner_pawn
	vm.rig = camera_rig
	cam.add_child(vm)
	return vm


func _ready() -> void:
	_cfg = DataRegistry.new().get_camera_cfg()["first_person"]["view_model"]
	_shot_cfg = DataRegistry.new().load_file("res://data/ui.json")["shot_fx"]
	_rng.randomize()
	scale = Vector3.ONE * _f("scale")
	var cam := get_parent() as Camera3D
	if cam != null:
		cam.near = _f("camera_near_m")
	_pivot = Node3D.new()
	_pivot.name = "Pivot"
	add_child(_pivot)
	_build_fx()
	pawn.weapon_switched.connect(_on_weapon_switched)
	pawn.reload_started.connect(_on_reload_started)
	pawn.fired.connect(_on_fired)
	_bind_shot_fx()
	_update(0.0)


func _physics_process(delta: float) -> void:
	_update(delta)


## Stage 3 seam: ADS weight (0 hip .. 1 sight). Stored only; stage 3 moves the gun to SightAnchor with it.
func set_aim_blend(weight: float) -> void:
	_aim_blend = clampf(weight, 0.0, 1.0)


func get_aim_blend() -> float:
	return _aim_blend


## Weapon id whose model is shown ("" when none).
func get_shown_weapon_id() -> String:
	return _shown_id


func is_swapping() -> bool:
	return _swap_total > 0.0


func is_reloading() -> bool:
	return _reload_total > 0.0


func is_swinging() -> bool:
	return _swing_total > 0.0


func is_recoiling() -> bool:
	return _recoil_left > 0.0


## World position of the shown gun's muzzle (the pawn's muzzle height when a blade or nothing is shown).
func get_muzzle_position() -> Vector3:
	if _muzzle != null and _muzzle.is_visible_in_tree():
		return _muzzle.global_position
	return pawn.get_muzzle_position()


func get_tracer_endpoints() -> PackedVector3Array:
	return PackedVector3Array([_tracer_start, _tracer_end])


func is_tracer_visible() -> bool:
	return tracer.is_visible_in_tree()


func is_flash_visible() -> bool:
	return flash.is_visible_in_tree()


## Every MeshInstance3D of the view model (tests measure its reach and count its nodes).
func mesh_instances() -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for n in find_children("*", "MeshInstance3D", true, false):
		out.append(n as MeshInstance3D)
	return out


# --- data -------------------------------------------------------------------------------------------------------

func _entry(key: String) -> Variant:
	var e: Variant = _cfg[key]
	return (e as Dictionary)["value"] if e is Dictionary and (e as Dictionary).has("value") else e


func _f(key: String) -> float:
	return float(_entry(key))


func _v(key: String) -> Vector3:
	return LowpolyKit.vec(_entry(key))


func _weapon_cfg(id: String, melee: bool) -> Dictionary:
	var all: Dictionary = _cfg["weapons"]
	if all.has(id):
		return all[id]
	return all[String(_cfg["default_melee" if melee else "default_gun"])]


static func _deg(v: Vector3) -> Basis:
	return Basis.from_euler(Vector3(deg_to_rad(v.x), deg_to_rad(v.y), deg_to_rad(v.z)))


# --- per-frame ----------------------------------------------------------------------------------------------------

func _update(delta: float) -> void:
	if pawn == null or not is_instance_valid(pawn) or rig == null:
		return
	_bind_shot_fx()
	var weight := rig.get_first_person_weight()
	var show_from := _f("show_weight")
	var showing := weight >= show_from and weight > 0.0
	if visible != showing:
		visible = showing
	_tick_motions(delta)
	_sync_weapon()
	_tick_look(delta)
	_tick_fx(delta)
	var raise := smoothstep(show_from, 1.0, weight) if show_from < 1.0 else (1.0 if weight >= 1.0 else 0.0)
	_apply_pose(raise)


func _tick_motions(delta: float) -> void:
	if _swap_total > 0.0:
		_swap_t += delta
		if _swap_t >= _swap_total:
			_swap_total = 0.0
	if _reload_total > 0.0:
		_reload_t += delta
		if _reload_t >= _reload_total:
			_reload_total = 0.0
	if _swing_total > 0.0:
		_swing_t += delta
		if _swing_t >= _swing_total:
			_swing_total = 0.0
	_recoil_left = maxf(0.0, _recoil_left - delta)


## Shows the active weapon; during a swap the old one stays until the lowest point (half the swap).
func _sync_weapon() -> void:
	var w := pawn.loadout.get_active() if pawn.loadout != null else null
	var id := w.def.id if w != null and w.def != null else ""
	if id == _shown_id:
		return
	if _swap_total > 0.0 and _swap_t < _swap_total * 0.5:
		return
	_show_weapon(id, w != null and w.def.is_melee())


func _show_weapon(id: String, melee: bool) -> void:
	if _shown != null:
		_shown.visible = false
	_shown_id = id
	_shown = null
	_muzzle = null
	if id == "":
		return
	if not _weapons.has(id):
		_weapons[id] = _build_weapon(id, melee)
	_shown = _weapons[id]
	_shown.visible = true
	_muzzle = _shown.get_node_or_null("Muzzle") as Marker3D


## Look sway (the gun lags the turn) and the walk bob, from the pawn's real look and velocity.
func _tick_look(delta: float) -> void:
	var look := Vector2(pawn.pitch, pawn.global_rotation.y)
	var target := Vector2.ZERO
	if _look_seen and delta > 0.0:
		var rate := Vector2(look.x - _last_look.x, wrapf(look.y - _last_look.y, -PI, PI)) / delta
		var lim := _f("sway_max_deg")
		target = (-rad_to_deg(1.0) * rate * _f("sway_gain")).clamp(Vector2(-lim, -lim), Vector2(lim, lim))
	_last_look = look
	_look_seen = true
	var smooth := _f("sway_smooth_s")
	_sway = _sway.lerp(target, 1.0 - exp(-delta / smooth) if smooth > 0.0 else 1.0)
	var flat := Vector2(pawn.velocity.x, pawn.velocity.z).length()
	var top := maxf(pawn.get_move_speed(), 0.01)  # run speed = full bob; sprint stays at full
	var amount := clampf(flat / top, 0.0, 1.0)
	var bob_smooth := _f("bob_smooth_s")
	_bob_amount = lerpf(_bob_amount, amount, 1.0 - exp(-delta / bob_smooth) if bob_smooth > 0.0 else 1.0)
	if _bob_amount > 0.001:
		_bob_phase = fmod(_bob_phase + delta * TAU * _f("bob_hz"), TAU * 2.0)


## 0 at both ends, 1 in the middle, eased over `ease` of the duration at each end.
static func _plateau(p: float, edge: float) -> float:
	if edge <= 0.0:
		return 1.0 if p > 0.0 and p < 1.0 else 0.0
	return minf(smoothstep(0.0, edge, p), smoothstep(0.0, edge, 1.0 - p))


func _swing_rot() -> Vector3:
	if _swing_total <= 0.0:
		return Vector3.ZERO
	var p := _swing_t / _swing_total
	var wind := _f("swing_wind_fraction")
	var strike := _f("swing_strike_fraction")
	var from := _v("swing_from_deg")
	var to := _v("swing_to_deg")
	if p < wind:
		return from * smoothstep(0.0, wind, p)
	if p < wind + strike:
		return from.lerp(to, smoothstep(wind, wind + strike, p))
	return to * (1.0 - smoothstep(wind + strike, 1.0, p))


func _apply_pose(raise: float) -> void:
	# About the eye: raise from below, bob, look sway, the blade swing.
	var bob := _v("bob_m") * _bob_amount
	var pos := Vector3(sin(_bob_phase) * bob.x, (cos(_bob_phase * 2.0) - 1.0) * 0.5 * bob.y, 0.0)
	pos.y -= _f("raise_drop_m") * (1.0 - raise)
	var rot := Vector3(_sway.x, _sway.y, 0.0) + _swing_rot()
	_pivot.transform = Transform3D(_deg(rot), pos)
	if _shown == null:
		return
	# About the hand: swap, reload and the gun kick.
	var hand_pos := Vector3.ZERO
	var hand_rot := Vector3.ZERO
	if _swap_total > 0.0:
		var s := sin(PI * clampf(_swap_t / _swap_total, 0.0, 1.0))
		hand_pos.y -= _f("swap_drop_m") * s
		hand_rot += _v("swap_tilt_deg") * s
	if _reload_total > 0.0:
		var r := _plateau(_reload_t / _reload_total, _f("reload_ease_fraction"))
		hand_pos.y -= _f("reload_drop_m") * r
		hand_rot += _v("reload_tilt_deg") * r
	if _recoil_left > 0.0 and _f("recoil_s") > 0.0:
		var k := pow(_recoil_left / _f("recoil_s"), 2.0)
		hand_pos += _v("recoil_kick_m") * k
		hand_rot.x += _f("recoil_pitch_deg") * k
	var base: Transform3D = _shown.get_meta(&"hold")
	_shown.transform = base * Transform3D(_deg(hand_rot), hand_pos)
	if flash.visible and _muzzle != null:
		flash.global_transform = _muzzle.global_transform * Transform3D(Basis(Vector3.FORWARD, flash.get_meta(&"spin", 0.0)), Vector3.ZERO)


# --- signals ------------------------------------------------------------------------------------------------------

func _on_weapon_switched(_slot: int) -> void:
	_reload_total = 0.0
	_swing_total = 0.0
	_swap_t = 0.0
	_swap_total = maxf(0.0, _f("swap_s"))
	if _swap_total <= 0.0:
		_sync_weapon()  # no swap motion: show the new weapon now


func _on_reload_started() -> void:
	var w := pawn.loadout.get_active() if pawn.loadout != null else null
	if w == null or w.def.is_melee() or w.def.reload_s <= 0.0:
		return
	_reload_t = 0.0
	_reload_total = w.def.reload_s  # the weapon's real reload time (data/stats.json reload_s)


func _on_fired() -> void:
	var w := pawn.loadout.get_active() if pawn.loadout != null else null
	if w == null:
		return
	if w.def.is_melee():
		_swing_t = 0.0
		_swing_total = maxf(0.0, _f("swing_s"))
	else:
		_recoil_left = _f("recoil_s")


## pawn.shot_fx is made in Pawn._ready, but bind whenever it appears or changes.
func _bind_shot_fx() -> void:
	var fx := pawn.shot_fx
	if fx == _fx:
		return
	if _fx != null and is_instance_valid(_fx) and _fx.shot_shown.is_connected(_on_shot_shown):
		_fx.shot_shown.disconnect(_on_shot_shown)
	_fx = fx
	if _fx != null and is_instance_valid(_fx):
		_fx.shot_shown.connect(_on_shot_shown)


## Fix 1: the first-person tracer and flash start at the VIEW-MODEL muzzle and end at the shot's real end point.
func _on_shot_shown(_origin: Vector3, end: Vector3) -> void:
	if not visible or _muzzle == null:
		return
	var start := _muzzle.global_position
	var to_end := end - start
	var length := minf(to_end.length(), float(_shot_cfg["tracer_max_length_m"]))
	_tracer_start = start
	_tracer_end = start
	if length > 0.001:
		var dir := to_end.normalized()
		var up := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
		var width := _f("tracer_width_m")
		(tracer.mesh as BoxMesh).size = Vector3(width, width, length)
		tracer.global_transform = Transform3D(Basis.looking_at(dir, up), start + dir * length * 0.5)
		_tracer_end = start + dir * length
		tracer.visible = true
		_tracer_left = _f("tracer_s")
	var spin := deg_to_rad(float(_shot_cfg.get("flash_spin_deg", 45.0)))
	flash.set_meta(&"spin", _rng.randf_range(-spin, spin))
	flash.visible = true
	_flash_left = _f("flash_s")
	flash.global_transform = _muzzle.global_transform


func _tick_fx(delta: float) -> void:
	if _tracer_left > 0.0:
		_tracer_left -= delta
		var color := _color(_shot_cfg["tracer_color"])
		color.a *= clampf(_tracer_left / maxf(_f("tracer_s"), 0.0001), 0.0, 1.0)
		((tracer.mesh as BoxMesh).material as StandardMaterial3D).albedo_color = color
		if _tracer_left <= 0.0:
			tracer.visible = false
	if _flash_left > 0.0:
		_flash_left -= delta
		if _flash_left <= 0.0:
			flash.visible = false


# --- building -----------------------------------------------------------------------------------------------------

static func _color(c: Array) -> Color:
	return Color(c[0], c[1], c[2], c[3])


func _fx_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = bool(_shot_cfg["tracer_draw_on_top"])
	mat.render_priority = int(_shot_cfg["tracer_render_priority"])
	return mat


func _build_fx() -> void:
	var box := BoxMesh.new()
	box.material = _fx_material(_color(_shot_cfg["tracer_color"]))
	tracer = _mesh_node("Tracer", box, self)
	tracer.top_level = true
	tracer.visible = false
	# The flash: crossed planes like ShotFx's, sized in view-model metres.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var size := _f("flash_size_m")
	var narrow := size * float(_shot_cfg["flash_arm_fraction"])
	var planes := int(_shot_cfg["flash_planes"])
	# Unlike ShotFx (seen from the side), the arms lie across the muzzle axis, so the eye behind it sees a star.
	for i in planes:
		var angle := PI * i / planes
		var axis := Vector3(cos(angle), sin(angle), 0.0)
		var side := Vector3(-sin(angle), cos(angle), 0.0)
		var points: Array[Vector3] = [axis * size * 0.5, side * narrow, -axis * size * 0.5, -side * narrow]
		for index in [0, 1, 2, 0, 2, 3]:
			st.add_vertex(points[index])
	var star := st.commit()
	var fmat := _fx_material(_color(_shot_cfg["flash_color"]))
	fmat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	fmat.cull_mode = BaseMaterial3D.CULL_DISABLED
	star.surface_set_material(0, fmat)
	flash = _mesh_node("Flash", star, self)
	flash.top_level = true
	flash.visible = false


func _mesh_node(node_name: String, mesh: Mesh, parent: Node) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	m.name = node_name
	m.mesh = mesh
	m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	m.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	parent.add_child(m)
	return m


static func _cached(key: String, parts: Array) -> ArrayMesh:
	if not _mesh_cache.has(key):
		_mesh_cache[key] = LowpolyKit.merge(parts)
	return _mesh_cache[key]


static func _part(parts: Array, part_name: String) -> Dictionary:
	for p: Dictionary in parts:
		if p["name"] == part_name:
			return p
	return {}


## The soldier's forearm (data/art_astra.json soldier parts), moved so the glove sits at the origin; +y runs up the arm.
static func _forearm_mesh(side: String) -> ArrayMesh:
	var key := "forearm_" + side
	if not _mesh_cache.has(key):
		var soldier: Array = LowpolyKit.config()["soldier"]["parts"]
		var glove := LowpolyKit.vec(_part(soldier, "glove_" + side)["at"])
		var parts: Array = []
		for base in _ARM_PARTS:
			var p: Dictionary = _part(soldier, base + "_" + side).duplicate(true)
			var at := LowpolyKit.vec(p["at"]) - glove
			p["at"] = [at.x, at.y, at.z]
			parts.append(p)
		_mesh_cache[key] = LowpolyKit.merge(parts)
	return _mesh_cache[key]


## Basis whose +y points along `dir` (the forearm from the hand toward the elbow).
static func _along_y(dir: Vector3) -> Basis:
	var y := dir.normalized()
	var x := Vector3.UP.cross(y)
	if x.length_squared() < 0.000001:
		x = Vector3.RIGHT
	x = x.normalized()
	return Basis(x, y, x.cross(y))


func _add_arm(parent: Node3D, side: String, hand: Vector3, elbow: Vector3) -> void:
	var arm := _mesh_node("RightArm" if side == "r" else "LeftArm", _forearm_mesh(side), parent)
	arm.transform = Transform3D(_along_y(elbow - hand), hand)


## One weapon's node: hold pose (meta "hold"), the weapon mesh with the hand at the origin, the forearms, and for
## guns a Muzzle and a SightAnchor marker.
func _build_weapon(id: String, melee: bool) -> Node3D:
	var wc := _weapon_cfg(id, melee)
	var node := Node3D.new()
	node.name = "Weapon_" + id
	_pivot.add_child(node)
	var hold := Transform3D(_deg(LowpolyKit.vec(wc["hold_rot_deg"])), LowpolyKit.vec(wc["hold_m"]))
	node.set_meta(&"hold", hold)
	node.transform = hold
	var model := String(wc["model"])
	if model == "blade":
		var blade_parts: Array = LowpolyKit.config()["soldier"]["blade"]["parts"]
		var blade := _mesh_node("Mesh", _cached("blade", blade_parts), node)
		blade.scale = Vector3.ONE * float(wc.get("size_mult", 1.0))
	else:
		var parts: Array = (LowpolyKit.config()["rifle"]["parts"] as Array).duplicate(true)
		var extra := float(wc.get("barrel_extra_m", 0.0))
		var barrel := _part(parts, "barrel")
		barrel["size"][2] = float(barrel["size"][2]) + extra
		barrel["at"][2] = float(barrel["at"][2]) - extra * 0.5
		parts.append_array((wc.get("extra_parts", []) as Array).duplicate(true))
		var grip := LowpolyKit.vec(_part(parts, "grip")["at"])
		var gun := _mesh_node("Mesh", _cached("rifle_" + id, parts), node)
		gun.position = -grip
		var muzzle := Marker3D.new()
		muzzle.name = "Muzzle"
		muzzle.position = LowpolyKit.vec(barrel["at"]) - grip + Vector3.FORWARD * float(barrel["size"][2]) * 0.5
		node.add_child(muzzle)
		var sight := _part(parts, "sight")
		var anchor := Marker3D.new()
		anchor.name = "SightAnchor"
		anchor.position = LowpolyKit.vec(sight["at"]) - grip + Vector3.UP * float(sight["size"][1]) * 0.5
		node.add_child(anchor)
		_add_arm(node, "l", LowpolyKit.vec(wc["left_hand_m"]), LowpolyKit.vec(wc["left_elbow_m"]))
	_add_arm(node, "r", LowpolyKit.vec(wc["right_hand_m"]), LowpolyKit.vec(wc["right_elbow_m"]))
	node.visible = false
	return node
