class_name ViewModel
extends Node3D
## M2 C1a stage 2: the first-person view model of the local player's pawn: two gloved arms and the held weapon,
## riding on the CameraRig's Camera3D. Presentation only: no colliders, no gameplay reads back from it (the shot,
## Hitscan origin, recoil and get_aim_point never see it). M2 AN1: the hands (ViewHands: one skinned mesh per arm on
## a code-built skeleton, finger poses as data) and the weapons (ViewWeapons) are built from data/art_soldier.json
## (OQ-ART-SOLDIER) and assembled by ViewRig; hold, ADS and durations are data/camera.json first_person.view_model
## (OQ-FIRST-PERSON); the layered motion is ViewMotion, data/anim.json first_person (OQ-FP-ANIM).
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
var _view_fx: ViewFx  # the first-person tracer and flash

# M2 AN1 commit 3: the layered motion (breathing, walk bob, sprint, ADS settle, kick, staged reload, switch, pickup,
# swing, landing): scripts/visual/view_motion.gd, numbers in data/anim.json first_person.
var _motion: ViewMotion
var _recoil_left := 0.0  # the kick timer (camera.json recoil_s) behind is_recoiling
var _slots: Array = []  # the loadout's Weapon objects last seen: a slot whose object changed was picked up
var _slots_of: Loadout  # the Loadout object _slots was read from

# M2 AN1 commit 5: the spent energy cell (art_soldier.json fx.spent_cell): a copy of the Cell dropped when the reload
# goes from cell_out to cell_in (the hand now holds the fresh one); it falls in world space, tumbles and shrinks away.
var _spent: Node3D
var _spent_t := 0.0
var _spent_vel := Vector3.ZERO
var _spent_spin := Vector3.ZERO
var _spent_scale := Vector3.ONE
var _last_stage := ""
var _dt := 0.0

# M2 AN2 item 4b: the clip layer's part driver and its fade (see _start_fade).
var _clip_drive := ""
var _clip_d := Transform3D.IDENTITY
var _fade_d := Transform3D.IDENTITY
var _fade_parts := {}
var _fade_left := 0.0
var _posed: Node3D

# Look sway state.
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
	scale = Vector3.ONE * _f("scale")
	var cam := get_parent() as Camera3D
	if cam != null:
		cam.near = _f("camera_near_m")
	_pivot = Node3D.new()
	_pivot.name = "Pivot"
	add_child(_pivot)
	_build_fx()
	_motion = ViewMotion.new(DataRegistry.new().load_file("res://data/anim.json")["first_person"])
	_remember_slots()
	pawn.weapon_switched.connect(_on_weapon_switched)
	pawn.reload_started.connect(_on_reload_started)
	pawn.fired.connect(_on_fired)
	pawn.landed.connect(_on_landed)
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
	return _motion.switch_total > 0.0


func is_reloading() -> bool:
	return _motion.reload_total > 0.0


func is_swinging() -> bool:
	return _motion.swing_total > 0.0


func is_picking_up() -> bool:
	return _motion.pickup_total > 0.0


## The running reload's length in seconds (the weapon's WeaponDef.reload_s; 0 when not reloading) and stage name.
func get_reload_length() -> float:
	return _motion.reload_total


func get_reload_stage() -> String:
	return _motion.reload_stage()


## Names of the motions running now: idle, walk, sprint, ads, fire, reload:<stage>, switch, pickup, swing, land.
func get_motion_names() -> Array[String]:
	return _motion.active()


## The layered motion (tests and tools read its state).
func get_motion() -> ViewMotion:
	return _motion


func is_recoiling() -> bool:
	return _recoil_left > 0.0


## World position of the shown gun's muzzle (the pawn's muzzle height when a blade or nothing is shown).
func get_muzzle_position() -> Vector3:
	if _muzzle != null and _muzzle.is_visible_in_tree():
		return _muzzle.global_position
	return pawn.get_muzzle_position()


func get_tracer_endpoints() -> PackedVector3Array:
	return PackedVector3Array([_view_fx.tracer_start, _view_fx.tracer_end])


func is_tracer_visible() -> bool:
	return tracer.is_visible_in_tree()


func is_flash_visible() -> bool:
	return flash.is_visible_in_tree()


## The muzzle light (M2 AN1 commit 5): an OmniLight3D without shadows on the flash, lit only while the flash shows.
func get_muzzle_light() -> OmniLight3D:
	return _view_fx.light


func is_muzzle_light_on() -> bool:
	return _view_fx.is_light_on()


## Measuring hook: holds the shown gun's flash and muzzle light on (true) or off (false); no effect without a muzzle.
func hold_muzzle_flash(on: bool) -> void:
	if _muzzle != null:
		_view_fx.hold(_muzzle, on)


## The falling spent cell of the last reload (null when none is falling).
func get_spent_cell() -> Node3D:
	return _spent if _spent != null and is_instance_valid(_spent) else null


## Every MeshInstance3D of the view model (tests measure its reach and count its nodes).
func mesh_instances() -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for n in find_children("*", "MeshInstance3D", true, false):
		out.append(n as MeshInstance3D)
	return out


## The visible model meshes (the tracer, the flash and a falling spent cell left out): what reach and near-plane
## checks measure. The budget (view_triangle_count, view_draw_calls) also counts the flash, its light and the spent
## cell while they show.
func model_meshes() -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for mi in mesh_instances():
		if mi != tracer and mi != flash and mi.is_visible_in_tree() and not _is_spent(mi):
			out.append(mi)
	return out


func _is_spent(mi: Node) -> bool:
	return _spent != null and is_instance_valid(_spent) and (mi == _spent or _spent.is_ancestor_of(mi))


## Every visible mesh the budget counts: the model, the flash and the spent cell.
func _budget_meshes() -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for mi in mesh_instances():
		if mi != tracer and mi.is_visible_in_tree():
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
	for mi in _budget_meshes():
		n += ViewMesh.triangle_count(mi.mesh)
	return n


## One per mesh surface, plus one for the muzzle light while it is lit (counted as a pass against the budget).
func view_draw_calls() -> int:
	var n := 1 if is_muzzle_light_on() else 0
	for mi in _budget_meshes():
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
	_dt = delta
	var weight := rig.get_first_person_weight()
	var show_from := _f("show_weight")
	var showing := weight >= show_from and weight > 0.0
	if visible != showing:
		visible = showing
	_tick_motions(delta)
	_sync_weapon()
	_tick_look(delta)
	_view_fx.tick(delta)
	_apply_pose(_raise(weight, show_from))
	_remember_slots()


## 0 (just shown) .. 1 (full first person): how far the model has risen into its pose. M2 AN1 (cover-exit fix): the
## rise starts at raise_start, not 0, so on the frame the body leaves the view (the same show_weight) the arms and gun
## are already on screen instead of raise_drop_m below it.
func _raise(weight: float, show_from: float) -> float:
	var r := smoothstep(show_from, 1.0, weight) if show_from < 1.0 else (1.0 if weight >= 1.0 else 0.0)
	return lerpf(clampf(_f("raise_start"), 0.0, 1.0), 1.0, r)


func _tick_motions(delta: float) -> void:
	var flat := Vector2(pawn.velocity.x, pawn.velocity.z).length()
	var run := maxf(pawn.get_move_speed(), 0.01)
	# Sprint weight from the pawn's sprint_factor (1 run .. sprint_speed_multiplier). The multiplier is read from
	# stats.json here, not via Pawn.get_max_move_speed, which fails on pawns whose movement config omits it.
	var sprint := clampf((pawn.sprint_factor - 1.0) / (_sprint_mult() - 1.0), 0.0, 1.0)
	_motion.tick(delta, flat, run, sprint, get_ads_weight(), pawn.is_on_floor(), pawn.velocity.y)
	_recoil_left = maxf(0.0, _recoil_left - delta)


var _sprint_mult_cache := -1.0


func _sprint_mult() -> float:
	if _sprint_mult_cache < 0.0:
		var entry: Variant = DataRegistry.new().get_movement_cfg().get("sprint_speed_multiplier", 1.0)
		var v := float((entry as Dictionary).get("value", 1.0)) if entry is Dictionary else float(entry)
		_sprint_mult_cache = maxf(v, 1.0001)
	return _sprint_mult_cache


## Shows the active weapon; during a switch the old one stays until the lowest point (half the switch), during a
## pickup until the pickup's swap point.
func _sync_weapon() -> void:
	var w := pawn.loadout.get_active() if pawn.loadout != null else null
	var id := w.def.id if w != null and w.def != null else ""
	if id == _shown_id:
		return
	if _motion.switch_total > 0.0 and _motion.switch_t < _motion.switch_total * 0.5:
		return
	if _motion.pickup_total > 0.0 and not _motion.pickup_swapped():
		return
	_show_weapon(id, w != null and w.def.is_melee())


func _show_weapon(id: String, melee: bool) -> void:
	_view_fx.park()  # the flash rides the old gun's muzzle: take it off before that gun hides
	if _shown != null:
		_shown.visible = false
	_shown_id = id
	_motion.weapon_id = id  # M2 AN2 item 4b: whose clips play
	_shown = null
	_muzzle = null
	if id == "":
		return
	if not _weapons.has(id):
		_weapons[id] = _build_weapon(id, melee)
	_shown = _weapons[id]
	_shown.visible = true
	_muzzle = _shown.get_node_or_null("Muzzle") as Marker3D


## Look sway (the gun lags the turn), from the pawn's real look. The walk bob is ViewMotion's (step phase, real speed).
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


func _apply_pose(raise: float) -> void:
	# ADS damps the bob, the breathing, the look sway and the gun kick (ads_motion_mult, ads_kick_mult).
	var ads := get_ads_weight()
	var calm := lerpf(1.0, _f("ads_motion_mult"), ads)
	# About the eye: the rise from below, look sway, then ViewMotion's breathing, bob, landing and swing.
	var rise := Transform3D(Basis.IDENTITY, Vector3(0.0, -_f("raise_drop_m") * (1.0 - raise), 0.0))
	_pivot.transform = rise * Transform3D(_deg(Vector3(_sway.x, _sway.y, 0.0) * calm), Vector3.ZERO) * _motion.pivot_xf(calm)
	if _shown == null:
		return
	# About the grip: the hold / ADS base (its path shaped by the ADS clip when enabled), the one-shot clip's weapon
	# delta (M2 AN2 item 4b), the looping clips, then the procedural sprint pose, ADS settle, kick, reload tilt, switch
	# and pickup (each procedural term steps aside when its clip plays).
	var kick := lerpf(1.0, _f("ads_kick_mult"), ads)
	var hold: Transform3D = _shown.get_meta(&"hold")
	var base := hold
	if ads > 0.0:
		var ads_xf: Transform3D = _shown.get_meta(&"ads")
		base = hold.interpolate_with(ads_xf, ads) * _motion.clip_ads_offset(hold, ads_xf, ads)
	var clip := _motion.clip_frame()
	var drive := String(clip.get("name", ""))
	if drive != _clip_drive:
		_start_fade()
		_clip_drive = drive
	var fw := smoothstep(0.0, 1.0, 1.0 - _fade_left / _fade_s()) if _fade_left > 0.0 else 1.0
	var d := ViewMotion.clip_delta(clip)
	if fw < 1.0:
		d = _fade_d.interpolate_with(d, fw)
	_clip_d = d
	_shown.transform = base * d * _motion.clip_loop_delta(calm, ads, kick) * _motion.weapon_xf(kick, not _shown.has_node("Muzzle"))
	if clip.is_empty():
		ViewRig.apply_parts(_shown, _motion, _pivot.transform)  # cell, charging handle, left-hand reach
	else:
		ViewRig.apply_clip(_shown, clip["bones"], clip["set"])
	if fw < 1.0:
		ViewRig.blend_parts(_shown, _fade_parts, fw)
	_fade_left = maxf(0.0, _fade_left - _dt)
	_posed = _shown
	_tick_spent_cell()


## M2 AN2 item 4b: when the part driver changes (a clip starts or stops, or one interrupts another, e.g. a switch
## during a reload), the cell, charging handle, arms and fingers blend from where they were over clips.fade_s instead of
## popping; not across a weapon change (the newly shown weapon's nodes hold an old pose).
func _start_fade() -> void:
	_fade_left = 0.0
	if _shown == null or _shown != _posed:
		return
	_fade_parts = ViewRig.capture_parts(_shown)
	_fade_d = _clip_d
	_fade_left = _fade_s()


func _fade_s() -> float:
	return maxf(float((_motion.cfg.get("clips", {}) as Dictionary).get("fade_s", 0.1)), 0.001)


## The one-shot clip driving the weapon's parts now ("" = the procedural curves): tests and tools.
func get_clip_motion() -> String:
	return _clip_drive


## Drops a spent cell when the reload passes from cell_out to cell_in, and moves a falling one (presentation only).
func _tick_spent_cell() -> void:
	var stage := _motion.reload_stage()
	if _last_stage == "cell_out" and stage == "cell_in" and _shown != null and visible:
		_drop_spent_cell(_shown.get_node_or_null("Cell") as Node3D)
	_last_stage = stage
	if _spent == null or not is_instance_valid(_spent):
		return
	var c: Dictionary = (ViewMesh.config().get("fx", {}) as Dictionary).get("spent_cell", {})
	var life := maxf(float(c.get("life_s", 0.6)), 0.01)
	_spent_t += _dt
	if _spent_t >= life:
		_spent.queue_free()
		_spent = null
		return
	_spent_vel += ViewMesh.vec(c.get("gravity_mps2", [0.0, -9.8, 0.0])) * _dt
	var xf := _spent.global_transform
	var b := Basis.from_euler(_spent_spin * _dt) * xf.basis.orthonormalized()
	var shrink := 1.0 - smoothstep(float(c.get("shrink_from", 0.55)), 1.0, _spent_t / life)
	_spent.global_transform = Transform3D(b.scaled(_spent_scale * maxf(shrink, 0.01)), xf.origin + _spent_vel * _dt)


func _drop_spent_cell(cell: Node3D) -> void:
	if cell == null:
		return
	var c: Dictionary = (ViewMesh.config().get("fx", {}) as Dictionary).get("spent_cell", {})
	if not bool(c.get("enabled", true)):
		return
	if _spent != null and is_instance_valid(_spent):
		_spent.queue_free()
	var mesh := cell.get_node_or_null("Mesh") as MeshInstance3D
	if mesh == null:
		return
	_spent = Node3D.new()
	_spent.name = "SpentCell"
	add_child(_spent)
	_spent.top_level = true
	var copy := MeshInstance3D.new()
	copy.name = "Mesh"
	copy.mesh = mesh.mesh
	copy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	copy.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_spent.add_child(copy)
	var g := cell.global_transform
	_spent_scale = g.basis.get_scale()
	_spent.global_transform = g
	# Out of the well (the cell's own -y), a little toward the left of the view, then gravity.
	var cam := get_parent() as Node3D
	var left := -cam.global_transform.basis.x if cam != null else Vector3.LEFT
	_spent_vel = (-g.basis.y.normalized() * float(c.get("speed_mps", 0.8)) + left * float(c.get("side_mps", 0.4)))
	var spin := deg_to_rad(float(c.get("spin_deg_s", 400.0)))
	_spent_spin = Vector3(spin, spin * 0.4, spin * 0.7)
	_spent_t = 0.0


# --- signals ------------------------------------------------------------------------------------------------------

## weapon_switched: a PICKUP when the Weapon object in that slot is a new one and every other slot is unchanged (a loot
## gun went into the slot: Pawn.take_item); otherwise a switch (Loadout.swap, a new loadout from setup). Derived here
## from the loadout's state; pawn.gd is not touched.
func _on_weapon_switched(slot: int) -> void:
	if _is_pickup(slot):
		_motion.start_pickup()
	else:
		_motion.start_switch(maxf(0.0, _f("swap_s")))
	_remember_slots()
	if _motion.switch_total <= 0.0 and _motion.pickup_total <= 0.0:
		_sync_weapon()  # no motion: show the new weapon now


## Snapshot of the loadout (its object and its slots' Weapon objects), refreshed every frame and after every switch,
## so a loadout replaced without a signal (Pawn.setup) is not mistaken for a pickup later.
func _remember_slots() -> void:
	_slots_of = pawn.loadout if pawn != null else null
	_slots = pawn.loadout.slots.duplicate() if pawn != null and pawn.loadout != null else []


func _is_pickup(slot: int) -> bool:
	if pawn.loadout == null or pawn.loadout != _slots_of or _slots.size() != pawn.loadout.slots.size() or slot < 0 or slot >= _slots.size():
		return false
	for i in _slots.size():
		var same: bool = _slots[i] == pawn.loadout.slots[i]
		if i == slot and (same or pawn.loadout.slots[i] == null):
			return false
		if i != slot and not same:
			return false
	return true


func _on_reload_started() -> void:
	var w := pawn.loadout.get_active() if pawn.loadout != null else null
	if w == null or w.def.is_melee() or w.def.reload_s <= 0.0:
		return
	_motion.start_reload(w.def.reload_s)  # the weapon's real reload time (data/stats.json reload_s)


func _on_fired() -> void:
	var w := pawn.loadout.get_active() if pawn.loadout != null else null
	if w == null:
		return
	if w.def.is_melee():
		_motion.start_swing(maxf(0.0, _f("swing_s")))
	else:
		_recoil_left = _f("recoil_s")
		_motion.kick(1.0)  # damped by ads_kick_mult where it is drawn (_apply_pose), so an ADS change mid-kick follows


## Pawn.landed (the carrier drop touching down): a landing dip at the fall's top speed if ViewMotion did not already
## see the touchdown on its own (it also dips after any fall from is_on_floor and the vertical speed).
func _on_landed() -> void:
	if not _motion.is_landing():
		_motion.land(pawn.drop_max_fall_mps)


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


## Fix 1: the first-person tracer and flash start at the VIEW-MODEL muzzle and end at the shot's real end point (ViewFx).
func _on_shot_shown(_origin: Vector3, end: Vector3) -> void:
	if not visible or _muzzle == null:
		return
	_view_fx.show_shot(_muzzle, end)


# --- building -----------------------------------------------------------------------------------------------------

func _build_fx() -> void:
	_view_fx = ViewFx.new(self, _shot_cfg, _f("tracer_s"), _f("tracer_width_m"), _f("flash_s"), _f("flash_size_m"))
	tracer = _view_fx.tracer
	flash = _view_fx.flash


## One weapon's node with its arms, red dot and hold / ADS poses (ViewRig.build_weapon), hidden until shown.
func _build_weapon(id: String, melee: bool) -> Node3D:
	var node := ViewRig.build_weapon(id, _weapon_cfg(id, melee), String(_cfg["default_melee" if melee else "default_gun"]),
			_f("dot_radius_m"), ViewFx.color_of(_entry("dot_color")))
	_pivot.add_child(node)
	node.visible = false
	return node
