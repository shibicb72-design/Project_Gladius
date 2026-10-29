class_name SoldierHandSync
extends SkeletonModifier3D
## Before built-in IK: expose the current RightHand pose to the rifle's foregrip target.
var model: SoldierModel

func _process_modification_with_delta(_delta: float) -> void:
	if model == null or model.hand_attachment == null:
		return
	var skeleton := get_skeleton()
	model.hand_attachment.transform = skeleton.get_bone_global_pose(model.right_hand_bone)
	model.left_ik.active = not bool(model.animation_tree.get("parameters/reload/active"))
