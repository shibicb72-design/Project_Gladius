extends RefCounted
## Shared reads for the soldier tests after D1 (Shibi, Nov 9 2026): the yellow head sphere is a debug overlay, so
## "clear of the yellow shell" became "body parts stay clear of the head hitbox" and "the helmet contains it".
## The hitbox is the pawn scene's own Area3D "Head" sphere; margins come from data/art_astra.json soldier.helmet.


static func helmet_cfg() -> Dictionary:
	return LowpolyKit.config()["soldier"]["helmet"]


## Largest distance a helmet part may reach past the hitbox box (the crest is exempt).
static func helmet_margin() -> float:
	return float(helmet_cfg()["margin_m"])


## Gap every body part keeps from the hitbox box, in every pose.
static func body_clearance() -> float:
	return float(helmet_cfg()["body_clearance_m"])


static func head_radius(pawn: Node) -> float:
	return ((pawn.get_node("Head/CollisionShape3D") as CollisionShape3D).shape as SphereShape3D).radius


## The head hitbox as a box around the Head node's own origin (also the Head bone's origin).
static func head_box_local(pawn: Node) -> AABB:
	var r := head_radius(pawn)
	return AABB(Vector3(-r, -r, -r), Vector3(r, r, r) * 2.0)


## The head hitbox box in the pawn's space.
static func head_box(pawn: Node) -> AABB:
	return (pawn.get_node("Head") as Node3D).transform * head_box_local(pawn)


static func head_bone(model: SoldierModel) -> int:
	return model.skeleton.find_bone("Head")


## Helmet parts are the parts skinned to the Head bone.
static func is_helmet(model: SoldierModel, part: int) -> bool:
	return model.part_bones[part] == head_bone(model)


static func is_crest(model: SoldierModel, part: int) -> bool:
	return (helmet_cfg()["crest_parts"] as Array).has(model.get_meta("parts")[part])
