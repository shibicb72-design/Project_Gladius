extends RefCounted
## C0: 3D proof shots for tools/touch_capture.gd (--scene-shot=<name>|all). Starts an offline match without bots,
## hides the HUD and the local pawn, places inert pawns / loot and its own camera, and saves one PNG per shot.
## Framing numbers: data/capture_shots.json (placeholders, OQ-3D-CAPTURE). Presentation only: nothing here feeds
## back into the match. World colliders pick a stage with a clear lane, so cover never hides the subject.

const SHOTS: Array[String] = ["soldier_turntable", "soldier_50m", "soldier_50m_zoom", "map_overview", "loot_lineup", "wall_closeup", "kit_lineup", "ground_views"]
const _PawnScene := preload("res://scenes/player/pawn.tscn")
const _MatchScene := preload("res://scenes/match/match.tscn")

var _tool: Node  # tools/touch_capture.gd (log, frames, output folder, overlay label, offscreen viewport)
var _cfg: Dictionary
var _match: MatchRoot
var _view: SubViewport  # null = the window
var _camera: Camera3D
var _props: Array[Node] = []
var _stage := Vector3.ZERO
var _lane := Vector3.FORWARD  # unit direction from the stage to the camera


func run(tool: Node, which: String) -> bool:
	_tool = tool
	_cfg = DataRegistry.new().load_file("res://data/capture_shots.json")
	var names: Array[String] = SHOTS.duplicate() if which == "all" else ([which] as Array[String])
	for n in names:
		if not SHOTS.has(n):
			_tool._log("RESULT scene_shot_known=false (%s; known: %s, all)" % [n, ", ".join(SHOTS)])
			return false
	var host: Node = _tool
	if _tool._offscreen.x > 0 and _tool._offscreen.y > 0:
		_view = _tool._offscreen_viewport()
		host = _view
		_tool._layer.reparent(_view)  # keep the "desktop render" overlay in the saved image
	_match = _MatchScene.instantiate()
	_match.auto_start = false
	_match.bake_navmesh = false
	_match.fill_bots = false
	_match.seed_override = int(_cfg["match_seed"])  # same zone circles in every run, so shots compare
	host.add_child(_match)
	await _tool._frames(2)
	if not _match.begin():
		_tool._log("RESULT scene_match_started=false")
		return false
	(_match.get_node("Hud") as CanvasLayer).visible = false
	_match.local_player.set_physics_process(false)
	_match.local_player.visible = false
	_camera = Camera3D.new()
	_camera.name = "CaptureCamera"
	_match.add_child(_camera)
	_camera.make_current()
	await _tool.get_tree().physics_frame
	await _tool.get_tree().physics_frame  # world colliders are in the space before the lane rays
	_pick_lane(float(_cfg["soldier_50m"]["distance_m"]))
	for n in names:
		match n:
			"soldier_turntable":
				await _soldier_turntable()
			"soldier_50m":
				await _soldier_50m(false)
			"soldier_50m_zoom":
				await _soldier_50m(true)
			"map_overview":
				await _map_overview()
			"loot_lineup":
				await _loot_lineup()
			"wall_closeup":
				await _wall_closeup()
			"kit_lineup":
				await _kit_lineup()
			"ground_views":
				await _ground_views()
	return true


func _space() -> PhysicsDirectSpaceState3D:
	return _match.get_world_3d().direct_space_state


## Walkable ground under (x, z), or {} (no hit, a wall top or roof, or a slope).
func _ground(x: float, z: float) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(Vector3(x, float(_cfg["ground_ray_top_m"]), z),
			Vector3(x, float(_cfg["ground_ray_bottom_m"]), z), Hitscan.MASK_WORLD)
	var hit := _space().intersect_ray(q)
	if hit.is_empty() or float(hit["position"].y) > float(_cfg["ground_max_y_m"]) \
			or (hit["normal"] as Vector3).y < float(_cfg["ground_min_normal_y"]):
		return {}
	return hit


func _clear(from: Vector3, to: Vector3) -> bool:
	return _space().intersect_ray(PhysicsRayQueryParameters3D.create(from, to, Hitscan.MASK_WORLD)).is_empty()


## First candidate stage with level ground and clear sight over `length` metres at every probe height.
func _pick_lane(length: float) -> void:
	var step := float(_cfg["lane_step_deg"])
	for xz: Array in _cfg["stage_candidates_xz"]:
		var g := _ground(float(xz[0]), float(xz[1]))
		if g.is_empty():
			continue
		var stage: Vector3 = g["position"]
		var a := 0.0
		while a < 360.0:
			var d := Vector3.FORWARD.rotated(Vector3.UP, deg_to_rad(a))
			var far := _ground(stage.x + d.x * length, stage.z + d.z * length)
			if not far.is_empty() and absf(float(far["position"].y) - stage.y) <= float(_cfg["lane_max_ground_step_m"]):
				var open := true
				for h in _cfg["lane_clear_heights_m"]:
					open = open and _clear(stage + Vector3.UP * float(h), (far["position"] as Vector3) + Vector3.UP * float(h))
				if open:
					_stage = stage
					_lane = d
					_tool._log("RESULT scene_lane_found=true stage=%s dir=%s length=%.0f m" % [str(stage), str(d), length])
					return
			a += step
	_tool._log("RESULT scene_lane_found=false (no candidate in data/capture_shots.json has a clear %.0f m lane)" % length)


func _aspect() -> float:
	var size := Vector2(_view.size) if _view != null else _tool.get_viewport().get_visible_rect().size
	return size.x / size.y


func _aim(from: Vector3, to: Vector3, fov_deg: float) -> void:
	_camera.fov = fov_deg
	_camera.global_position = from
	_camera.look_at(to, Vector3.UP)
	_camera.make_current()


## An inert pawn (no physics step) at `at`; yaw 0 faces `facing`.
func _pawn(at: Vector3, facing: Vector3, yaw_deg: float, squad: int) -> Pawn:
	var pawn: Pawn = _PawnScene.instantiate()
	pawn.squad_id = squad
	_match.add_child(pawn)
	pawn.set_physics_process(false)
	pawn.global_transform = Transform3D(Basis.looking_at(facing).rotated(Vector3.UP, deg_to_rad(yaw_deg)), at)
	_props.append(pawn)
	return pawn


func _finish(shot: String, caption: String) -> void:
	_tool._label.text = "desktop render, not device - %s %s: %s" % [_tool._tag, shot, caption]
	await _tool._frames(int(_cfg["settle_frames"]))
	await RenderingServer.frame_post_draw
	var img: Image = (_view.get_texture() if _view != null else _tool.get_viewport().get_texture()).get_image()
	var path: String = _tool._out.path_join("%s_%s.png" % [_tool._tag, shot])
	var err := img.save_png(path)
	_tool._log("saved %s (%dx%d) err=%d" % [path, img.get_width(), img.get_height(), err])
	for p in _props:
		p.queue_free()
	_props.clear()
	await _tool._frames(2)


## Camera-right for a camera that stands down the lane and looks back at the stage.
func _right() -> Vector3:
	return Vector3.UP.cross(_lane).normalized()


## Camera distance that keeps a row `row_m` wide and `frame_height_m` tall in frame at this aspect.
func _fit_distance(c: Dictionary, row_m: float) -> float:
	var half_tan := tan(deg_to_rad(float(c["fov_deg"])) * 0.5)
	var half_width := row_m * 0.5 + float(c["frame_margin_m"])
	return maxf(half_width / (half_tan * _aspect()), float(c["frame_height_m"]) * 0.5 / half_tan)


func _soldier_turntable() -> void:
	var c: Dictionary = _cfg["soldier_turntable"]
	var yaws: Array = c["yaws_deg"]
	for i in yaws.size():
		_pawn(_stage + _right() * float(c["spacing_m"]) * (i - (yaws.size() - 1) * 0.5), _lane, float(yaws[i]), 0)
	_aim(_stage + _lane * _fit_distance(c, float(c["spacing_m"]) * (yaws.size() - 1)) + Vector3.UP * float(c["camera_height_m"]),
			_stage + Vector3.UP * float(c["look_height_m"]), float(c["fov_deg"]))
	await _finish("soldier_turntable", str(c["labels"]))


## One soldier per squad at range, with the field of view the game camera uses at this aspect. The zoom
## variant is the same scene through a narrow lens: a magnifier for the reviewer, not a player's view.
func _soldier_50m(zoom: bool) -> void:
	var c: Dictionary = _cfg["soldier_50m"]
	var count := int(c["count"])
	for i in count:
		_pawn(_stage + _right() * float(c["spacing_m"]) * (i - (count - 1) * 0.5), _lane, 0.0, i)
	var fov := float(c["zoom_fov_deg"]) if zoom else CameraRig.fov_for_aspect(DataRegistry.new().get_camera_cfg(), _aspect())
	_aim(_stage + _lane * float(c["distance_m"]) + Vector3.UP * float(c["eye_height_m"]),
			_stage + Vector3.UP * float(c["look_height_m"]), fov)
	await _finish("soldier_50m_zoom" if zoom else "soldier_50m", "%d soldiers (squads 0-%d) at %.0f m, %s FOV %.0f" % [
			count, count - 1, float(c["distance_m"]), "magnifier" if zoom else "game", fov])


func _map_overview() -> void:
	var c: Dictionary = _cfg["map_overview"]
	_aim(LowpolyKit.vec(c["camera_at"]), LowpolyKit.vec(c["look_at"]), float(c["fov_deg"]))
	await _finish("map_overview", "camera at %s" % str(c["camera_at"]))


## One of every item in data/loot.json, dropped in a row by the real LootField, with a soldier for scale.
func _loot_lineup() -> void:
	var c: Dictionary = _cfg["loot_lineup"]
	var loot_cfg: Dictionary = DataRegistry.new().load_file("res://data/loot.json")
	var loot := LootField.new()
	loot.name = "CaptureLoot"
	loot.setup(loot_cfg, 1)
	loot.placed = true  # no seeded scatter: the line-up drops exactly one of each item
	_match.add_child(loot)
	_props.append(loot)
	var ids: Array = (loot_cfg["items"] as Dictionary).keys()
	ids.sort()
	for i in ids.size():
		loot.drop({"item_id": ids[i]}, _stage + _right() * float(c["spacing_m"]) * (i - ids.size() * 0.5))
	_pawn(_stage + _right() * float(c["spacing_m"]) * (ids.size() * 0.5), _lane, 0.0, 0)
	_aim(_stage + _lane * _fit_distance(c, float(c["spacing_m"]) * ids.size()) + Vector3.UP * float(c["camera_height_m"]),
			_stage + Vector3.UP * float(c["look_height_m"]), float(c["fov_deg"]))
	await _finish("loot_lineup", ", ".join(PackedStringArray(ids)) + ", soldier")


## W1: the world kit, one row of piece types per image, each row from the front and from the back, on a bare
## stage beside the map. A soldier stands in front of every piece, and on its first walk surface if it has one.
## Saves <tag>_kit_lineup_<row>_<view>.png. The stage has no colliders: the pawns are inert props.
func _kit_lineup() -> void:
	var c: Dictionary = _cfg["kit_lineup"]
	var stage := LowpolyKit.vec(c["stage_at"])
	var types: Dictionary = WorldKit.config()["types"]
	var gap := float(c["gap_m"])
	var rows: Array = c["rows"]
	var views: Array = c["views"]
	for r in rows.size():
		var width := -gap
		var depth := 0.0
		for type: String in rows[r]:
			var rect := WorldKit.footprint(types[type], Vector3.ZERO, 0.0)
			width += rect.size.x + gap
			depth = maxf(depth, maxf(absf(rect.position.y), absf(rect.end.y)))
		for view: Dictionary in views:
			var yaw := deg_to_rad(float(view["yaw_deg"]))
			var to_camera := Vector3(sin(yaw), 0.0, -cos(yaw))  # yaw 0 looks at the fronts (-Z side)
			var ground := MeshInstance3D.new()
			var plane := PlaneMesh.new()
			plane.size = Vector2(width, depth * 2.0) + Vector2.ONE * float(c["ground_margin_m"]) * 2.0
			plane.material = GreyboxArt.material_for("ground")
			ground.mesh = plane
			_match.add_child(ground)
			ground.global_position = stage
			_props.append(ground)
			var cursor := -width * 0.5
			for type: String in rows[r]:
				var rect := WorldKit.footprint(types[type], Vector3.ZERO, 0.0)
				var origin := stage + Vector3(cursor - rect.position.x, 0.0, 0.0)
				cursor += rect.size.x + gap
				var piece := WorldKit.display(type)
				_match.add_child(piece)
				piece.global_position = origin
				_props.append(piece)
				var side := 1.0 if to_camera.z > 0.0 else -1.0
				_pawn(origin + Vector3(rect.position.x + 0.5, 0.0, (rect.end.y if side > 0.0 else rect.position.y) + side), to_camera, 0.0, 0)
				var walk: Array = types[type].get("walk", [])
				if not walk.is_empty():
					_pawn(origin + LowpolyKit.vec(walk[0]["at"]), to_camera, 0.0, 1)
			var target := stage + Vector3.UP * float(c["look_height_m"])
			_aim(target + to_camera * _fit_distance(c, width) + Vector3.UP * float(c["camera_height_m"]), target, float(c["fov_deg"]))
			await _finish("kit_lineup_%d_%s" % [r + 1, view["name"]], ", ".join(PackedStringArray(rows[r])))


## W3: ground-level views of the outer ring from a soldier's eye height (framing: capture_shots.json
## "ground_views"). A view looks at a landmark of the map's landmark file (a soldier stands on the landmark's
## anchor for scale) or at a fixed "look_at" point. Saves <tag>_ground_<name>.png.
func _ground_views() -> void:
	var c: Dictionary = _cfg["ground_views"]
	var landmarks := {}
	var path := String(_match.map_def.get("landmarks", ""))
	if path != "":
		for landmark: Dictionary in DataRegistry.new().load_file(path)["landmarks"]:
			landmarks[landmark["id"]] = landmark
	for view: Dictionary in c["views"]:
		var g := _ground(float(view["from"][0]), float(view["from"][1]))
		if g.is_empty():
			_tool._log("RESULT scene_ground_view=false (%s: no open ground at %s)" % [view["name"], str(view["from"])])
			continue
		var eye: Vector3 = (g["position"] as Vector3) + Vector3.UP * float(c["eye_height_m"])
		var target := Vector3.ZERO
		var label := ""
		if view.has("landmark"):
			if not landmarks.has(view["landmark"]):
				_tool._log("RESULT scene_ground_view=false (%s: the map has no landmark %s)" % [view["name"], view["landmark"]])
				continue
			var landmark: Dictionary = landmarks[view["landmark"]]
			target = Vector3(float(landmark["at"][0]), float(c["look_height_m"]), float(landmark["at"][1]))
			var anchor := LowpolyKit.vec(landmark["anchor"])
			_pawn(anchor, (eye - anchor) * Vector3(1, 0, 1), 0.0, 0)
			label = String(landmark["name"])
		else:
			target = LowpolyKit.vec(view["look_at"])
			label = "looking at " + str(view["look_at"])
		_aim(eye, target, float(c["fov_deg"]))
		await _finish("ground_" + String(view["name"]), "%s, from (%s, %s) at eye height %s m" % [label, view["from"][0], view["from"][1], c["eye_height_m"]])


## From inside the zone, looking out at the wall with a soldier standing in front of it.
func _wall_closeup() -> void:
	var c: Dictionary = _cfg["wall_closeup"]
	var rules: BrRules = _match.director.rules
	if rules == null:
		_tool._log("RESULT scene_wall_found=false (no zone rules)")
		return
	var center := Vector3(rules.zone_center().x, 0.0, rules.zone_center().y)
	var radius := rules.zone_radius()
	var a := float(c["bearing_start_deg"])  # start between the rim pieces (solid since W2; the clear-sight rays below see them)
	while a < 360.0:
		var out := Vector3.FORWARD.rotated(Vector3.UP, deg_to_rad(a))
		var wall_at := center + out * radius
		var cam_xz := wall_at - out * float(c["camera_from_wall_m"]) + Vector3.UP.cross(out) * float(c["camera_side_m"])
		var pawn_xz := wall_at - out * float(c["pawn_from_wall_m"])
		var g_cam := _ground(cam_xz.x, cam_xz.z)
		var g_pawn := _ground(pawn_xz.x, pawn_xz.z)
		if not g_cam.is_empty() and not g_pawn.is_empty():
			var eye: Vector3 = (g_cam["position"] as Vector3) + Vector3.UP * float(c["camera_height_m"])
			var target: Vector3 = (g_pawn["position"] as Vector3) + Vector3.UP * float(c["look_height_m"])
			var open := _clear(eye, target)
			for side: float in [-1.0, 1.0]:  # no map piece between the camera and this stretch of wall
				open = open and _clear(eye, wall_at + Vector3.UP.cross(out) * side * float(c["clear_half_width_m"]) + Vector3.UP * float(c["look_height_m"]))
			if open:
				_pawn(g_pawn["position"], -out, 0.0, 0)
				_aim(eye, target, float(c["fov_deg"]))
				await _finish("wall_closeup", "zone radius %.0f m, camera %.0f m inside" % [radius, float(c["camera_from_wall_m"])])
				return
		a += float(c["bearing_step_deg"])
	_tool._log("RESULT scene_wall_found=false (no clear bearing)")
