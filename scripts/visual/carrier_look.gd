class_name CarrierLook
extends Node3D
## S6: the drop carrier's model. It is drawn at MatchDirector.carrier_position() while director.drop_active,
## facing along the carrier line, and flies on and away once the last rider has jumped. Read-only: the path,
## the speed and who is aboard are the director's. Data: data/art_carrier.json (placeholders,
## OQ-GFX-CARRIER). No collider; the riders' pawns are hidden by gameplay while aboard.

const PATH := "res://data/art_carrier.json"
static var _registry := DataRegistry.new()
static var _mesh: ArrayMesh

var director: MatchDirector
var model: MeshInstance3D
var _cfg: Dictionary = {}
var _was_active := false
var _leaving_s := -1.0
var _clock := 0.0
var _forward := Vector3.FORWARD
var _at := Vector3.ZERO


static func config() -> Dictionary:
	return _registry.load_file(PATH)


static func mesh() -> ArrayMesh:
	if _mesh == null:
		var parts: Array = []
		for part: Dictionary in config()["parts"]:
			parts.append(WorldKit._kit_part(part))
		_mesh = LowpolyKit.merge(parts)
	return _mesh


func _ready() -> void:
	_cfg = config()
	var world := get_parent()
	director = world.get_parent().get_node_or_null("Director") as MatchDirector if world != null and world.get_parent() != null else null
	model = MeshInstance3D.new()
	model.name = "Aquila"
	model.mesh = mesh()
	model.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if bool(_cfg["cast_shadows"]) else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	model.visible = false
	add_child(model)


## Places the model for a carrier position and a flight direction (also used by the capture tool).
func show_at(carrier_at: Vector3, forward: Vector3) -> void:
	var flat := Vector3(forward.x, 0.0, forward.z)
	if flat.length() < 0.001:
		flat = Vector3.FORWARD
	var basis := Basis.looking_at(flat.normalized())
	var bob := sin(TAU * float(_cfg["bob_hz"]) * _clock)
	basis = basis * Basis(Vector3.FORWARD, deg_to_rad(float(_cfg["bank_deg"])) * bob)
	model.global_transform = Transform3D(basis, carrier_at + basis * LowpolyKit.vec(_cfg["offset_m"]) + Vector3.UP * float(_cfg["bob_m"]) * bob)
	model.visible = true


func _process(delta: float) -> void:
	if director == null:
		return
	_clock += delta
	var leave: Dictionary = _cfg["leave"]
	if director.drop_active:
		_forward = (director.carrier_to - director.carrier_from).normalized()
		_at = director.carrier_position()
		_leaving_s = -1.0
		show_at(_at, _forward)
	elif _was_active:
		_leaving_s = 0.0
	if not director.drop_active and _leaving_s >= 0.0:
		_leaving_s += delta
		_at += (_forward * float(leave["speed_mps"]) + Vector3.UP * float(leave["climb_mps"])) * delta
		show_at(_at, _forward)
		if _leaving_s >= float(leave["leave_s"]) or not director.running:
			_leaving_s = -1.0
			model.visible = false
	_was_active = director.drop_active
