extends SceneTree
## Prints where the shoulder offset really lands (GBTN4): camera local x relative to the SpringArm3D and the rig.
##   godot --headless --path . --script res://tools/measure_shoulder.gd

const _RigScene := preload("res://scenes/player/camera_rig.tscn")


func _initialize() -> void:
	var rig: Node3D = _RigScene.instantiate()
	root.add_child(rig)
	for i in 5:
		await physics_frame
	var arm: SpringArm3D = rig.get_node("SpringArm3D")
	var cam: Camera3D = rig.get_node("SpringArm3D/Camera3D")
	var in_rig := rig.global_transform.affine_inverse() * cam.global_position
	print("[measure_shoulder] arm.position=%s cam.position(local to arm)=%s cam_in_rig=%s" % [
			arm.position, cam.position, in_rig])
	quit()
