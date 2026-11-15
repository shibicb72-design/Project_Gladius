class_name ViewModel
extends Node3D
## M2 C1a stage 2: the first-person view model of the local player's pawn: two gloved arms and the held weapon,
## riding on the CameraRig's Camera3D. Presentation only: no colliders, no gameplay reads back from it (the shot,
## Hitscan origin, recoil and get_aim_point never see it). M2 AN1: the hands (ViewHands: one skinned mesh per arm on
## a code-built skeleton, finger poses as data) and the weapons (ViewWeapons) are built from data/art_soldier.json
## (OQ-ART-SOLDIER); hold, ADS and motion numbers are data/camera.json first_person.view_model (OQ-FIRST-PERSON).
## Ownership: CameraRig calls ViewModel.attach every physics frame until one exists; attach only creates it for a rig
## under a Pawn with no "Brain" child (the local player), so bots, replicas and a rig without a pawn never get one.
## Clipping (fix 12, option a): the whole model is built at natural size and then scaled down toward the eye
## (scale), which keeps its screen image and keeps every vertex inside max_reach_m (less than the 0.4 m body capsule
## radius), so the capsule holds walls farther away than the model reaches. No second camera, no SubViewport.
## ADS (stage 3): set_aim_blend raises a gun from its hold pose to its ADS pose, where the RedDot (under SightAnchor)
## sits on the camera's centre ray; bob, sway and kick are damped. Stage 4 hides the third-person body by layer; the
## view model itself stays on the default layer.

const NODE_NAME := "ViewModel"

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
	if rig != null:
		_aim_blend = rig.get_aim_blend()
	_update(0.0)


func _physics_process(delta: float) -> void:
	_update(delta)


## ADS weight (0 hip .. 1 sight), the pawn's aim_blend, forwarded by CameraRig.set_aim_blend every physics frame. A gun
## with an ADS pose (camera.json weapons.<id>.ads_dot_m) moves from its hold pose to it: at 1 its red dot sits on the
## camera's centre ray, the gun pointing straight ahead. The blade has no ADS pose and keeps its hold pose.
func set_aim_blend(weight: float) -> void:
	_aim_blend = clampf(weight, 0.0, 1.0)


func get_aim_blend() -> float:
	return _aim_blend


## 0..1: how far the shown gun is toward its ADS pose (smoothstep of the aim blend; 0 for the blade or no weapon).
func get_ads_weight() -> float:
	if _shown == null or not _shown.has_meta(&"ads"):
		return 0.0
	return smoothstep(0.0, 1.0, _aim_blend)


## The shown gun's red dot (fix 8), or null for the blade or no weapon.
func get_red_dot() -> MeshInstance3D:
	if _shown == null:
		return null
	return _shown.get_node_or_null("SightAnchor/RedDot") as MeshInstance3D


## Weapon id whose model is shown ("" when none).
func get_shown_weapon_id() -> String:
	return _shown_id


## The shown weapon's node (null when none): tests read its Cell, Charge and arms.
func get_shown_weapon() -> Node3D:
	return _shown


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


## The visible model meshes (the tracer and flash left out): what the budget counts.
func model_meshes() -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for mi in mesh_instances():
		if mi != tracer and mi != flash and mi.is_visible_in_tree():
			out.append(mi)
	return out


## Triangle corners of `mi` as drawn now, in its own space: a skinned arm is posed on the CPU (ViewHands), so reach
## and near-plane checks see the curled fingers and the turned forearm, not the bind pose.
func posed_faces(mi: MeshInstance3D) -> PackedVector3Array:
	if mi.has_meta(&"skinned_arm"):
		var arm := mi.get_parent().get_parent() as Node3D
		return ViewHands.posed_vertices(arm)
	return mi.mesh.get_faces()


## Triangles and draw calls (one per mesh surface) of the visible model meshes.
func view_triangle_count() -> int:
	var n := 0
	for mi in model_meshes():
		n += ViewMesh.triangle_count(mi.mesh)
	return n


func view_draw_calls() -> int:
	var n := 0
	for mi in model_meshes():
		n += mi.mesh.get_surface_count()
	return n


# --- data -------------------------------------------------------------------------------------------------------

func _entry(key: String) -> Variant:
	var e: Variant = _cfg[key]
	return (e as Dictionary)["value"] if e is Dictionary and (e as Dictionary).has("value") else e


func _f(key: String) -> float:
	return float(_entry(key))


func _v(key: String) -> Vector3:
	return ViewMesh.vec(_entry(key))


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
	# ADS damps the bob, the look sway and the gun kick (ads_motion_mult, ads_kick_mult).
	var ads := get_ads_weight()
	var calm := lerpf(1.0, _f("ads_motion_mult"), ads)
	# About the eye: raise from below, bob, look sway, the blade swing.
	var bob := _v("bob_m") * _bob_amount * calm
	var pos := Vector3(sin(_bob_phase) * bob.x, (cos(_bob_phase * 2.0) - 1.0) * 0.5 * bob.y, 0.0)
	pos.y -= _f("raise_drop_m") * (1.0 - raise)
	var rot := Vector3(_sway.x, _sway.y, 0.0) * calm + _swing_rot()
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
		var k := pow(_recoil_left / _f("recoil_s"), 2.0) * lerpf(1.0, _f("ads_kick_mult"), ads)
		hand_pos += _v("recoil_kick_m") * k
		hand_rot.x += _f("recoil_pitch_deg") * k
	var base: Transform3D = _shown.get_meta(&"hold")
	if ads > 0.0:
		base = base.interpolate_with(_shown.get_meta(&"ads"), ads)
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


## A small unshaded, glowing disc (a low sphere, the same from every side) for the sight; colour and size are data.
func _add_red_dot(anchor: Node3D, at: Vector3) -> void:
	var sphere := SphereMesh.new()
	var r := _f("dot_radius_m")
	sphere.radius = r
	sphere.height = r * 2.0
	sphere.radial_segments = 10
	sphere.rings = 5
	var mat := StandardMaterial3D.new()
	var color := _color(_entry("dot_color"))
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	sphere.material = mat
	var dot := _mesh_node("RedDot", sphere, anchor)
	dot.position = at


## One weapon's node (ViewWeapons): hold pose (meta "hold", camera.json), for guns the red dot and the ADS pose (meta
## "ads"), and the two arms placed by art_soldier.json weapons.<id>.hands (meta "rest" = the placed transform).
func _build_weapon(id: String, melee: bool) -> Node3D:
	var wc := _weapon_cfg(id, melee)
	var node := ViewWeapons.build(id, String(_cfg["default_melee" if melee else "default_gun"]))
	_pivot.add_child(node)
	var hold := Transform3D(_deg(ViewMesh.vec(wc["hold_rot_deg"])), ViewMesh.vec(wc["hold_m"]))
	node.set_meta(&"hold", hold)
	node.transform = hold
	var art_id := String(node.get_meta(&"art_id"))
	var anchor := node.get_node_or_null("SightAnchor") as Marker3D
	if anchor != null:
		# Fix 8: the red dot in the sight window (art dot_m), and the ADS pose that puts it on the camera's centre ray
		# at ads_dot_m (camera frame) with the gun turned by ads_rot_deg (0 = straight ahead).
		var dot_at := ViewWeapons.dot_position(art_id)
		_add_red_dot(anchor, dot_at - anchor.position)
		if wc.has("ads_dot_m"):
			var ads_basis := _deg(ViewMesh.vec(wc.get("ads_rot_deg", [0.0, 0.0, 0.0])))
			node.set_meta(&"ads", Transform3D(ads_basis, ViewMesh.vec(wc["ads_dot_m"]) - ads_basis * dot_at))
	for side in ["r", "l"]:
		var h := ViewWeapons.hand(art_id, side)
		if h.is_empty():
			continue
		var arm := ViewHands.build_arm(side)
		node.add_child(arm)
		var xf := Transform3D(ViewHands.placement_basis(h), ViewMesh.vec(h["at"]))
		if String(h.get("frame", "weapon")) == "view":
			xf = hold.affine_inverse() * xf  # placed in the camera frame, carried by the weapon node
		arm.transform = xf
		arm.set_meta(&"rest", xf)
		var elbow := ViewMesh.vec(h["elbow"])
		if String(h.get("frame", "weapon")) == "view":
			elbow = hold.affine_inverse() * elbow
		arm.set_meta(&"elbow", elbow)
		arm.set_meta(&"pose", String(h.get("pose", "grip")))
		ViewHands.apply_pose(arm, ViewHands.pose(String(h.get("pose", "grip"))))
		ViewHands.aim_forearm(arm, xf.affine_inverse() * elbow)
	node.visible = false
	return node
