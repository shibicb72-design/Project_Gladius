class_name SwingVisual
extends Node3D
## Placeholder blade swing: a thin glowing bar sweeping across the arc, freed after the swing.
## Presentation only; hit detection is Melee.

const BLADE_THICKNESS_M := 0.05  # visual only


## Adds a swing visual under `pawn`, sweeping the weapon's arc in front of `direction`.
static func spawn(pawn: Pawn, def: WeaponDef, direction: Vector3) -> SwingVisual:
	var v := SwingVisual.new()
	pawn.add_child(v)
	v.global_position = pawn.get_muzzle_position()
	var flat := Vector3(direction.x, 0.0, direction.z)
	if flat.length_squared() > 0.0001:
		v.look_at(v.global_position + flat, Vector3.UP)
	v.play(def)
	return v


func play(def: WeaponDef) -> void:
	var blade := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(BLADE_THICKNESS_M, BLADE_THICKNESS_M, def.melee_range_m)
	blade.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.4, 0.9, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(0.4, 0.9, 1.0)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	box.material = mat
	# The bar's pivot is the wielder; the mesh sits half a range ahead (-Z is forward).
	blade.position = Vector3(0.0, 0.0, -def.melee_range_m * 0.5)
	add_child(blade)
	var half := deg_to_rad(def.melee_arc_deg) * 0.5
	rotation.y += half
	var tw := create_tween()
	tw.tween_property(self, "rotation:y", rotation.y - 2.0 * half, maxf(def.swing_duration_s, 0.01))
	tw.tween_callback(queue_free)
