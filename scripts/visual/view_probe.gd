class_name ViewProbe
extends RefCounted
## M2 AN1: measurements of the first-person view model as drawn now (skinned arms posed on the CPU), in the camera's
## frame: farthest and nearest vertex, nearest in-view depth and triangles cut by the near plane inside the view, per
## mesh. Used by tests (rest, ADS and every motion) and by tools; reads only, changes nothing.


## {"far", "nearest", "min_depth", "cuts", "per_mesh": {path: {"cuts", "nearest", "far"}}} for the visible model meshes
## of `vm` seen by `cam` at `aspect` (width / height).
static func measure(vm: ViewModel, cam: Camera3D, aspect: float) -> Dictionary:
	var to_cam := cam.global_transform.affine_inverse()
	var near := cam.near
	var tan_h := tan(deg_to_rad(cam.fov) * 0.5)
	var tan_w := tan_h * aspect
	var out := {"far": 0.0, "nearest": INF, "min_depth": INF, "cuts": 0, "per_mesh": {}}
	for mi in vm.model_meshes():
		var xf := to_cam * mi.global_transform
		var faces := vm.posed_faces(mi)
		var mine := {"cuts": 0, "nearest": INF, "far": 0.0}
		for t in range(0, faces.size(), 3):
			var tri: Array[Vector3] = [xf * faces[t], xf * faces[t + 1], xf * faces[t + 2]]
			var cut := false
			for v in tri:
				var length := v.length()
				mine["far"] = maxf(mine["far"], length)
				mine["nearest"] = minf(mine["nearest"], length)
				var d := -v.z
				if d > 0.0 and absf(v.x) <= d * tan_w and absf(v.y) <= d * tan_h:
					out["min_depth"] = minf(out["min_depth"], d)
					if d < near:
						cut = true
			if cut or crosses_near_rect(tri, near, near * tan_w, near * tan_h):
				mine["cuts"] += 1
		out["far"] = maxf(out["far"], mine["far"])
		out["nearest"] = minf(out["nearest"], mine["nearest"])
		out["cuts"] += mine["cuts"]
		out["per_mesh"][String(vm.get_path_to(mi))] = mine
	return out


## How many posed vertices of the visible model (0 when the view model is hidden) project inside the view, in front of
## the near plane: > 0 means the arms or the weapon are on screen this frame.
## With `weapon_only` only the shown weapon's own meshes count (not the arms).
static func on_screen_vertices(vm: ViewModel, cam: Camera3D, aspect: float, weapon_only: bool = false) -> int:
	if not vm.is_visible_in_tree():
		return 0
	var to_cam := cam.global_transform.affine_inverse()
	var tan_h := tan(deg_to_rad(cam.fov) * 0.5)
	var tan_w := tan_h * aspect
	var n := 0
	var weapon := vm.get_shown_weapon()
	for mi in vm.model_meshes():
		if weapon_only and (weapon == null or mi.get_parent() != weapon and mi.get_parent().get_parent() != weapon):
			continue
		var xf := to_cam * mi.global_transform
		for v in vm.posed_faces(mi):
			var p := xf * v
			var d := -p.z
			if d > cam.near and absf(p.x) <= d * tan_w and absf(p.y) <= d * tan_h:
				n += 1
	return n


## The meshes with cuts, as "path(n)" text (empty when none).
static func cut_report(m: Dictionary) -> String:
	var parts: PackedStringArray = []
	for path: String in m["per_mesh"]:
		var mine: Dictionary = m["per_mesh"][path]
		if int(mine["cuts"]) > 0:
			parts.append("%s(%d, nearest %.4f)" % [path, mine["cuts"], mine["nearest"]])
	return ", ".join(parts)


## True iff the triangle (camera space) crosses the plane at depth `near` inside the near rectangle.
static func crosses_near_rect(tri: Array[Vector3], near: float, half_w: float, half_h: float) -> bool:
	var pts: Array[Vector2] = []
	for i in 3:
		var a := tri[i]
		var b := tri[(i + 1) % 3]
		var da := -a.z - near
		var db := -b.z - near
		if (da < 0.0) != (db < 0.0):
			var q := a.lerp(b, da / (da - db))
			pts.append(Vector2(q.x, q.y))
	if pts.size() < 2:
		return false
	var d := pts[1] - pts[0]
	var p := [-d.x, d.x, -d.y, d.y]
	var q := [pts[0].x + half_w, half_w - pts[0].x, pts[0].y + half_h, half_h - pts[0].y]
	var t0 := 0.0
	var t1 := 1.0
	for i in 4:
		if absf(p[i]) < 1e-12:
			if q[i] < 0.0:
				return false
		else:
			var r: float = q[i] / p[i]
			if p[i] < 0.0:
				t0 = maxf(t0, r)
			else:
				t1 = minf(t1, r)
			if t0 > t1:
				return false
	return true
