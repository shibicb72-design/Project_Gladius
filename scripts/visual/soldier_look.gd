class_name SoldierLook
extends RefCounted
## M2 AN1 commit 6: the third-person soldier's look layer, data in data/art_soldier.json "soldier" (OQ-ART-SOLDIER
## placeholders). Presentation only: nothing here is read by a shot, a hit, the capsule or the network.
##  - parts(): data/art_astra.json soldier.parts (read-only, hashed into saved navigation) with per-part overrides
##    ("part_overrides", by name, keys replaced) and extra parts ("parts_add") laid over it. Every soldier, corpse and
##    the clip measurer build from this list.
##  - apply_materials(): per-surface material classes (metallic, roughness, texture contrast, glow) written into the
##    soldier material's own copy of the surface arrays, so steel, bronze, leather and cloth shade apart without a
##    second surface and without touching the world's surfaces.
##  - gun_mesh(): the third-person gun, built from the first-person weapon part lists (ViewWeapons / ViewMesh) at
##    reduced detail (named parts only, no chamfers, fewer lathe sides), scaled to rifle size, one surface on the
##    soldier material. "near" and "far" are two detail levels (the far one is shown past gun.far_m).

static var _parts: Array = []
static var _guns := {}


static func config() -> Dictionary:
	return ViewMesh.config().get("soldier", {})


static func _copy(value: Variant) -> Variant:
	return (value as Variant).duplicate(true) if value is Dictionary or value is Array else value


static func parts() -> Array:
	if _parts.is_empty():
		var over: Dictionary = config().get("part_overrides", {})
		for part: Dictionary in LowpolyKit.config()["soldier"]["parts"]:
			var merged := part.duplicate(true)
			var name := String(part["name"])
			if over.has(name):
				for key: String in (over[name] as Dictionary).keys():
					if not key.begins_with("_"):
						merged[key] = _copy(over[name][key])
			if not bool(merged.get("hidden", false)):
				_parts.append(merged)
		for part: Dictionary in config().get("parts_add", []):
			var added := part.duplicate(true)
			for key: String in part.keys():
				if key.begins_with("_"):
					added.erase(key)
			_parts.append(added)
	return _parts


## Writes the soldier's material classes into `material` (the one soldier material, after WorldSurface.adopt).
static func apply_materials(material: ShaderMaterial) -> void:
	var classes: Dictionary = config().get("surfaces", {})
	if classes.is_empty():
		return
	var a: PackedVector4Array = material.get_shader_parameter("surf_a")
	var b: PackedVector4Array = material.get_shader_parameter("surf_b")
	for surface: String in classes.keys():
		if surface.begins_with("_"):
			continue
		var c: Dictionary = classes[surface]
		var id := WorldSurface.surface_id(surface)
		if id <= 0 and surface != "plain":
			continue
		var sa := a[id]
		var sb := b[id]
		a[id] = Vector4(sa.x, sa.y, float(c.get("contrast", sa.z)), float(c.get("bump", sa.w)))
		b[id] = Vector4(float(c.get("rough_scale", sb.x)), float(c.get("rough_bias", sb.y)), float(c.get("metallic", sb.z)), float(c.get("glow", sb.w)))
	material.set_shader_parameter("surf_a", a)
	material.set_shader_parameter("surf_b", b)


## The gun config of a first-person weapon art id; unknown ids use gun.default.
static func gun_cfg(id: String) -> Dictionary:
	var g: Dictionary = config()["gun"]
	var weapons: Dictionary = g["weapons"]
	return weapons[id] if weapons.has(id) else weapons[String(g["default"])]


static func gun_id(id: String) -> String:
	var g: Dictionary = config()["gun"]
	return id if (g["weapons"] as Dictionary).has(id) else String(g["default"])


static func gun_scale(id: String) -> float:
	return float(gun_cfg(id)["scale"])


## A point of the gun (gun.weapons.<id>.<key>, first-person units) in the gun mesh's frame.
static func gun_point(id: String, key: String) -> Vector3:
	var g := gun_cfg(id)
	var value: Array = g[key] if g.has(key) else ViewWeapons.art(gun_id(id))[key]
	return ViewMesh.vec(value) * gun_scale(id)


static func _reduced(part: Dictionary, detail: Dictionary) -> Dictionary:
	var p := part.duplicate(true)
	if p.has("chamfer") and not bool(detail.get("chamfer", true)):
		p["chamfer"] = 0.0
	if String(p.get("shape", "box")) == "lathe":
		p["sides"] = mini(int(p.get("sides", 8)), int(detail.get("max_sides", 8)))
	return p


## The gun mesh of weapon art `id` at detail `lod` ("near" or "far"); cached per id and lod.
static func gun_mesh(id: String, lod: String) -> ArrayMesh:
	var key := gun_id(id)
	var cache_key := key + "/" + lod
	if _guns.has(cache_key):
		return _guns[cache_key]
	var glb := _glb_gun(key, lod)
	if glb != null:
		_guns[cache_key] = glb
		return glb
	var g: Dictionary = config()["gun"]
	var art := ViewWeapons.art(key)
	var keep: Array = gun_cfg(key)[lod]
	var detail: Dictionary = g["detail"]
	var mats: Dictionary = g["surface_of_mat"]
	var base := Transform3D(Basis.from_scale(Vector3.ONE * gun_scale(key)), Vector3.ZERO)
	var groups: Array = [[art["parts"], Transform3D.IDENTITY]]
	for sub: String in ["cell", "charge"]:
		if art.has(sub):
			groups.append([art[sub]["parts"], ViewMesh.part_transform(art[sub])])
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for group: Array in groups:
		for part: Dictionary in group[0]:
			if not keep.has(part["name"]):
				continue
			var b := ViewMesh.Builder.new()
			ViewMesh.add_part(b, _reduced(part, detail), base * (group[1] as Transform3D))
			var mat := String(part.get("mat", "gunmetal"))
			_emit(st, b, WorldSurface.surface_id(String(mats.get(mat, "steel"))))
	var mesh := st.commit()
	mesh.surface_set_material(0, SoldierSquadColour.material())
	_guns[cache_key] = mesh
	return mesh


## M2 AN2 item 4a: the third-person gun from the weapon's Blender-built .glb (weapons.<id>.mesh_source, objects
## ThirdNear / ThirdFar: already in the soldier stream and at gun scale, tools/blender/build_weapons.py), copied into a
## new mesh with the one soldier material; null when the switch is unset or the object is missing (the part path).
static func _glb_gun(key: String, lod: String) -> ArrayMesh:
	var src := ViewWeapons.mesh_source(key)
	if src == "":
		return null
	var node := "ThirdNear" if lod == "near" else "ThirdFar"
	var source: Mesh = (ViewMesh.glb_nodes(src).get(node, {}) as Dictionary).get("mesh", null)
	if source == null or source.get_surface_count() != 1:
		push_error("SoldierLook: %s has no one-surface %s" % [src, node])
		return null
	var mesh := ArrayMesh.new()
	mesh.resource_name = node
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, source.surface_get_arrays(0))
	mesh.surface_set_material(0, SoldierSquadColour.material())
	return mesh


## The builder's opaque and glow triangles into the soldier vertex stream: sRGB paint with alpha 1 (alpha 0 would
## take the squad colour), UV in metres, UV2 = (surface id, neutral shade). Glass (lenses) is left out.
static func _emit(st: SurfaceTool, b: ViewMesh.Builder, surface: int) -> void:
	for pass_name: String in ["opaque", "glow"]:
		if not b.tris.has(pass_name):
			continue
		for t: Array in b.tris[pass_name]:
			var a: Vector3 = t[0]
			var bb: Vector3 = t[1]
			var c: Vector3 = t[2]
			var n := (bb - a).cross(c - a).normalized()
			var helper := Vector3.UP if absf(n.y) < 0.9 else Vector3.RIGHT
			var tangent := helper.cross(n).normalized()
			var paint := (t[3] as Color).linear_to_srgb()
			paint.a = 1.0
			for v: Vector3 in [a, c, bb]:
				st.set_normal(n)
				st.set_tangent(Plane(tangent, 1.0))
				st.set_color(paint)
				st.set_uv(Vector2(v.x + v.z, v.y))
				st.set_uv2(Vector2(float(surface), 0.5))
				st.add_vertex(v)
