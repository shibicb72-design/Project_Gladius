class_name CameraRig
extends Node3D
## Third-person SpringArm3D + Camera3D. FOV comes from data/camera.json by viewport aspect ratio.

@onready var _arm: SpringArm3D = $SpringArm3D
@onready var _camera: Camera3D = $SpringArm3D/Camera3D

var _cfg: Dictionary = {}


## Picks the first table row (sorted by min_aspect descending) the aspect satisfies.
static func fov_for_aspect(cfg: Dictionary, aspect: float) -> float:
	var rows: Array = cfg.get("fov_table", []).duplicate()
	rows.sort_custom(func(a, b): return float(a["min_aspect"]) > float(b["min_aspect"]))
	for row in rows:
		if aspect >= float(row["min_aspect"]):
			return float(row["fov_deg"])
	return 75.0


func _ready() -> void:
	_cfg = DataRegistry.new().get_camera_cfg()
	_arm.spring_length = float(_cfg.get("arm_length_m", 3.5))
	position.y = float(_cfg.get("height_m", 1.6))
	_camera.position.x = float(_cfg.get("shoulder_offset_m", 0.0))
	get_viewport().size_changed.connect(apply_fov)
	apply_fov()


func apply_fov() -> void:
	var size := get_viewport().get_visible_rect().size
	if size.y <= 0.0:
		return
	_camera.fov = fov_for_aspect(_cfg, size.x / size.y)


## Orients the rig; pitch in radians, clamped by data.
func set_pitch(pitch: float) -> void:
	var lo := deg_to_rad(float(_cfg.get("pitch_min_deg", -70.0)))
	var hi := deg_to_rad(float(_cfg.get("pitch_max_deg", 70.0)))
	rotation.x = clampf(pitch, lo, hi)
