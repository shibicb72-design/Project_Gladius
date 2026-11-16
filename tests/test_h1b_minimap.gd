extends "res://tests/test_case.gd"

## M2 H1b commit 3: the in-match minimap (scripts/ui/hud_minimap.gd, scripts/ui/minimap_math.gd, data/ui.json minimap,
## OQ-MINIMAP). Marks sit where the one world-to-minimap mapping puts their world points, in north-up, rotating and
## expanded views; no enemy is ever drawn; a tap on the tap target expands and closes the map without turning the view,
## while look drags and stick starts pass through the small and the expanded picture; a missing texture gives a plain
## panel; the minimap_rotate profile key and its Settings row; the baked textures exist, are hashed and cover the map
## data's bounds; the overlays redraw at the data rate, the view follows every frame.

const _H1a := preload("res://tests/test_h1a_layout.gd")
const _TouchHud := preload("res://scripts/ui/touch_hud.gd")
const RenderLayout := preload("res://tools/render_layout.gd")
const SIZES := [Vector2(2520, 1080), Vector2(2176, 1812), Vector2(1512, 648), Vector2(1152, 959), Vector2(2340, 1080), Vector2(3120, 1440)]
const MAPS := ["alesia_1km", "test_300", "alesia_section"]
const TMP := "user://test_h1b_minimap_profile.json"
const TOL := 1.0  # px

var _h1a: RefCounted
var _nodes: Array = []


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _begin() -> void:
	_h1a = _H1a.new()
	_h1a._begin()
	PlatformServices.dpi_override = 420.0


func _end() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()
	_h1a._end()
	if FileAccess.file_exists(TMP):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP))


func _pawn(squad: int, id: int, at: Vector3, yaw: float = 0.0) -> Pawn:
	var p := Pawn.new()
	p.setup("hastati", squad)
	p.player_id = id
	p.position = at
	p.rotation.y = yaw
	_nodes.append(p)
	return p


## A director with a zone (current circle (0, 0) r 60, next circle (40, 30) r 15) and the given players.
func _director(players: Dictionary) -> MatchDirector:
	var d := MatchDirector.new()
	var r := BrRules.new()
	r._zstate = "waiting"
	r._center = Vector2.ZERO
	r._radius = 60.0
	r._phase = 0
	var circles: Array[Dictionary] = [{"center": Vector2(40, 30), "radius": 15.0}]
	r._circles = circles
	r._zleft = 50.0
	d.rules = r
	d._players = players
	_nodes.append(d)
	return d


func _minimap(sz: Vector2, director: MatchDirector, me: Pawn, map_id: String = "alesia_section") -> HudMinimap:
	var mm := HudMinimap.new()
	_tree().root.add_child(mm)
	mm.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	mm.size = sz
	var def: Dictionary = DataRegistry.new().load_file(RenderLayout.minimap_map_path(map_id)) if map_id != "" and FileAccess.file_exists(RenderLayout.minimap_map_path(map_id)) else {"id": map_id}
	mm.bind(director, me, null, def)
	_nodes.push_front(mm)
	return mm


func _near(a: Vector2, b: Vector2, what: String) -> void:
	assert_true(a.distance_to(b) <= TOL, "%s: %s within %.1f px of %s" % [what, a, TOL, b])


func _mark(mm: HudMinimap, kind: String, id: Variant = null) -> Dictionary:
	for m: Dictionary in mm.marks:
		if m["kind"] == kind and (id == null or m["id"] == id):
			return m
	return {}


# --- the one mapping ----------------------------------------------------------------------------------------------

func test_mapping_is_one_pure_function() -> void:
	var rect := Rect2(100, 50, 200, 200)
	var ext := Rect2(-80, -80, 160, 160)
	var p := Vector2(10, -5)
	var north := MinimapMath.frame_for(MinimapMath.SMALL_NORTH, rect, ext, p, 0.9, 100.0)
	_near(MinimapMath.to_px(p, north), rect.get_center(), "north: the player at the centre")
	_near(MinimapMath.to_px(p + Vector2(10, 0), north), rect.get_center() + Vector2(10, 0), "north: 10 m east is 10 px right (1 px/m)")
	_near(MinimapMath.to_px(p + Vector2(0, -10), north), rect.get_center() + Vector2(0, -10), "north: 10 m north (-z) is up")
	for yaw in [0.0, 0.9, -2.3, PI]:
		var rot := MinimapMath.frame_for(MinimapMath.SMALL_ROTATE, rect, ext, p, yaw, 100.0)
		_near(MinimapMath.to_px(p + MinimapMath.forward(yaw) * 20.0, rot), rect.get_center() + Vector2(0, -20), "rotate yaw %.1f: ahead is straight up" % yaw)
		assert_true(absf(MinimapMath.arrow_rotation(yaw, rot)) < 1e-4, "rotate: the arrow points up")
		var nf := MinimapMath.frame_for(MinimapMath.SMALL_NORTH, rect, ext, p, yaw, 100.0)
		assert_true(absf(wrapf(MinimapMath.arrow_rotation(yaw, nf) + yaw, -PI, PI)) < 1e-4, "north: the arrow turns by -yaw")
		var w := Vector2(33, -21)
		_near(MinimapMath.to_world(MinimapMath.to_px(w, rot), rot) * 1.0, w, "to_world inverts to_px")
	var ex := MinimapMath.frame_for(MinimapMath.EXPANDED, rect, ext, p, 1.0, 100.0)
	_near(MinimapMath.to_px(ext.position, ex), rect.position, "expanded: the extent's north-west corner at the rect's top-left")
	_near(MinimapMath.to_px(ext.end, ex), rect.end, "expanded: south-east corner at bottom-right")


# --- marks match world positions -----------------------------------------------------------------------------------

func test_marks_match_world_positions_in_each_view() -> void:
	_begin()
	var sz := Vector2(2520, 1080)
	var yaw := 0.7
	var me := _pawn(2, 0, Vector3(10, 0, -5), yaw)
	var mate := _pawn(2, 1, Vector3(30, 0, 10))
	var enemy := _pawn(5, 2, Vector3(12, 0, -3))
	var d := _director({0: me, 1: mate, 2: enemy})
	var mm := _minimap(sz, d, me)
	assert_true(mm.texture != null and mm.extent == Rect2(-80, -80, 160, 160), "alesia_section: texture and extent from data")
	var radius := float(HudArrangement.ui()["minimap"]["small_radius_m"])
	for view in ["north", "rotate", "expanded"]:
		AppFlow.profile = {"minimap_rotate": view != "north"}
		mm.set_expanded(view == "expanded")
		mm.update_overlays()
		mm.follow()
		var rect := HudMinimap.picture_rect(sz, view == "expanded")
		assert_true(view == "expanded" or HudArrangement.minimap_rect(sz).encloses(rect), "%s: picture inside the minimap rect" % view)
		var c := rect.get_center()
		var expect := func(w: Vector2) -> Vector2:  # written out here, independent of MinimapMath
			if view == "expanded":
				return c + w * (rect.size.x / 160.0)
			var k := rect.size.x * 0.5 / radius
			var v := (w - Vector2(10, -5)) * k
			return c + (v.rotated(yaw) if view == "rotate" else v)
		var k_px := rect.size.x / 160.0 if view == "expanded" else rect.size.x * 0.5 / radius
		for pair in [["player", 0, Vector2(10, -5)], ["mate", 1, Vector2(30, 10)]]:
			var m := _mark(mm, pair[0], pair[1])
			assert_true(not m.is_empty(), "%s: %s drawn" % [view, pair[0]])
			if m.is_empty():
				continue
			_near(m["px"], expect.call(pair[2]), "%s: %s mark" % [view, pair[0]])
			_near(mm.drawn_px(pair[2]), expect.call(pair[2]), "%s: %s where the rotor draws it" % [view, pair[0]])
		_near(mm.arrow_px(), expect.call(Vector2(10, -5)), "%s: the arrow at the player" % view)
		var want_rot := 0.0 if view == "rotate" else -yaw
		assert_true(absf(wrapf(mm.arrow_rotation() - want_rot, -PI, PI)) < 1e-3, "%s: arrow heading %.3f (want %.3f)" % [view, mm.arrow_rotation(), want_rot])
		var cur := _mark(mm, "current_circle")
		var nxt := _mark(mm, "next_circle")
		assert_true(not cur.is_empty() and not nxt.is_empty(), "%s: both circles drawn" % view)
		if not cur.is_empty() and not nxt.is_empty():
			_near(cur["px"], expect.call(Vector2.ZERO), "%s: current circle centre" % view)
			assert_true(absf(float(cur["radius_px"]) - 60.0 * k_px) <= TOL, "%s: current circle radius %.1f px (want %.1f)" % [view, cur["radius_px"], 60.0 * k_px])
			_near(mm.drawn_px(Vector2.ZERO), expect.call(Vector2.ZERO), "%s: current circle where the rotor draws it" % view)
			_near(nxt["px"], expect.call(Vector2(40, 30)), "%s: next circle centre" % view)
			assert_true(absf(float(nxt["radius_px"]) - 15.0 * k_px) <= TOL, "%s: next circle radius" % view)
		var line := _mark(mm, "line")
		assert_true(not line.is_empty(), "%s: outside the next circle, the line to it is drawn" % view)
		if not line.is_empty():
			var edge := Vector2(40, 30) + (Vector2(10, -5) - Vector2(40, 30)).normalized() * 15.0
			_near(line["px"], expect.call(Vector2(10, -5)), "%s: the line starts at the player" % view)
			_near(line["to_px"], expect.call(edge), "%s: the line ends on the next circle's edge" % view)
		# The view follows the player every frame: move them, follow() only (no overlay update), the rotor keeps every
		# drawn point at its world place.
		me.position = Vector3(14, 0, -2)
		me.rotation.y = yaw + 0.3
		mm.follow()
		var moved := func(w: Vector2) -> Vector2:
			if view == "expanded":
				return c + w * (rect.size.x / 160.0)
			var v := (w - Vector2(14, -2)) * k_px
			return c + (v.rotated(yaw + 0.3) if view == "rotate" else v)
		_near(mm.drawn_px(Vector2(30, 10)), moved.call(Vector2(30, 10)), "%s: after a move, the mate drawn at its world place" % view)
		_near(mm.arrow_px(), moved.call(Vector2(14, -2)), "%s: after a move, the arrow at the player" % view)
		me.position = Vector3(10, 0, -5)
		me.rotation.y = yaw
	# Inside the next circle: no line.
	me.position = Vector3(40, 0, 32)
	mm.update_overlays()
	assert_true(_mark(mm, "line").is_empty(), "inside the next circle: no line")
	_end()


func test_no_enemy_is_ever_drawn() -> void:
	_begin()
	var sz := Vector2(2176, 1812)
	var me := _pawn(3, 0, Vector3(0, 0, 0))
	var players := {0: me}
	for i in range(1, 9):
		players[i] = _pawn(3 if i <= 2 else 10 + i, i, Vector3(5.0 * i, 0, 3.0))
	players[2].life = Pawn.Life.DEAD
	var d := _director(players)
	var mm := _minimap(sz, d, me)
	for view in ["north", "rotate", "expanded"]:
		AppFlow.profile = {"minimap_rotate": view != "north"}
		mm.set_expanded(view == "expanded")
		mm.update_overlays()
		var ids: Array = []
		for m: Dictionary in mm.marks:
			assert_true(["player", "mate", "current_circle", "next_circle", "line", "landmark"].has(m["kind"]), "%s: only known kinds (%s)" % [view, m["kind"]])
			if m["kind"] == "mate":
				ids.append(m["id"])
				assert_eq(players[m["id"]].squad_id, me.squad_id, "%s: a drawn mate is in the player's squad" % view)
		assert_eq(ids, [1], "%s: only the living squad mate is drawn (no enemies, no dead)" % view)
	# Solo: everyone is their own squad, so nobody but the player.
	for i in range(1, 9):
		players[i].squad_id = 100 + i
	mm.update_overlays()
	assert_true(_mark(mm, "mate").is_empty(), "solo: no mates, no enemies")
	_end()


# --- input ---------------------------------------------------------------------------------------------------------

func _touch(idx: int, pos: Vector2, down: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = idx
	e.position = pos
	e.pressed = down
	_tree().root.push_input(e, true)


func _drag(idx: int, pos: Vector2, rel: Vector2) -> void:
	var e := InputEventScreenDrag.new()
	e.index = idx
	e.position = pos
	e.relative = rel
	_tree().root.push_input(e, true)


func test_tap_expands_and_closes_and_touches_pass_through() -> void:
	_begin()
	for stick in ["virtual", "custom"]:
		_TouchHud.move_stick_override = stick
		for sz in [Vector2(2520, 1080), Vector2(2176, 1812)]:
			var touch: Control = _h1a._new_touch(sz)
			var me := _pawn(0, 0, Vector3.ZERO)
			var mm := _minimap(sz, _director({0: me}), me)  # added after the touch HUD: its _input runs first
			await _tree().process_frame
			var tag := "%s %s" % [stick, sz]
			var tap := HudMinimap.tap_rect(sz)
			# Tap: expands, consumed (no look touch, no turn).
			touch.provider.clear_look()
			_touch(4, tap.get_center(), true)
			_drag(4, tap.get_center() + Vector2(-30, 10), Vector2(-30, 10))
			assert_true(mm.expanded, "%s: a tap on the tap target expands the map" % tag)
			assert_eq(touch._look_touch, -1, "%s: the tap is not a look touch" % tag)
			assert_eq(touch.provider.get_look(), Vector2.ZERO, "%s: the tap does not turn the view" % tag)
			_touch(4, tap.get_center() + Vector2(-30, 10), false)
			touch._process(1.0 / 60.0)
			# Expanded: a look drag and a stick start through the expanded picture.
			var big := HudMinimap.expanded_rect(sz)
			var right := Vector2(big.position.x + big.size.x * 0.8, big.get_center().y)
			assert_true(right.x > 0.5 * sz.x and touch.get_look_area_rect().has_point(right), "%s: fixture: a look-area point on the expanded map" % tag)
			touch.provider.clear_look()
			_touch(5, right, true)
			_drag(5, right + Vector2(-80, 0), Vector2(-80, 0))
			assert_true(touch.provider.get_look() != Vector2.ZERO, "%s: a look drag on the expanded map turns the view" % tag)
			_touch(5, right + Vector2(-80, 0), false)
			touch._process(1.0 / 60.0)
			var left := Vector2(big.position.x + big.size.x * 0.15, big.get_center().y + big.size.y * 0.3)
			assert_true(left.x < 0.5 * sz.x, "%s: fixture: a left-half point on the expanded map" % tag)
			touch.provider.move_value = Vector2.ZERO
			_touch(6, left, true)
			_drag(6, left + Vector2(0, -120), Vector2(0, -120))
			touch._process(1.0 / 60.0)
			assert_true(touch.provider.move_value.y < 0.0, "%s: a stick start on the expanded map moves (%s)" % [tag, touch.provider.move_value])
			_touch(6, left + Vector2(0, -120), false)
			touch._process(1.0 / 60.0)
			assert_true(mm.expanded, "%s: touches on the expanded picture do not close it" % tag)
			# Close: the same square, consumed.
			touch.provider.clear_look()
			_touch(4, HudMinimap.close_rect(sz).get_center(), true)
			assert_true(not mm.expanded, "%s: a tap on the close control closes the map" % tag)
			assert_eq(touch._look_touch, -1, "%s: the close tap is not a look touch" % tag)
			_touch(4, HudMinimap.close_rect(sz).get_center(), false)
			touch._process(1.0 / 60.0)
			# Small picture outside the tap target: a look drag passes through.
			var mmr := HudArrangement.minimap_rect(sz)
			var p := mmr.position + mmr.size * Vector2(0.2, 0.85)
			assert_true(not tap.has_point(p) and touch.get_look_area_rect().has_point(p), "%s: fixture: %s on the small picture, off the tap target, in the look area" % [tag, p])
			touch.provider.clear_look()
			_touch(7, p, true)
			_drag(7, p + Vector2(-80, 0), Vector2(-80, 0))
			assert_true(touch.provider.get_look() != Vector2.ZERO, "%s: a look drag on the small picture turns the view" % tag)
			assert_true(not mm.expanded, "%s: and does not expand the map" % tag)
			_touch(7, p + Vector2(-80, 0), false)
			touch._process(1.0 / 60.0)
			# Every node of the minimap ignores the mouse / touch GUI path.
			for c in [mm] + mm.find_children("*", "Control", true, false):
				assert_eq((c as Control).mouse_filter, Control.MOUSE_FILTER_IGNORE, "%s: %s ignores touches" % [tag, c.name])
			mm.free()
			_nodes.erase(mm)
			touch.free()
	_end()


## The close control never sits under the expanded picture, and the expanded picture stays on screen (six sizes x two
## densities; the 48 dp / on-screen / look-area / apart rules are tests/test_h1a_layout.gd's, minimap_close included).
func test_close_control_beside_the_expanded_map() -> void:
	_begin()
	for dpi in [420.0, 373.0]:
		PlatformServices.dpi_override = dpi
		for sz in SIZES:
			var big := HudMinimap.expanded_rect(sz)
			assert_true(Rect2(Vector2.ZERO, sz).encloses(big), "%s dpi %d: expanded map on screen %s" % [sz, dpi, big])
			assert_true(not big.intersects(HudMinimap.close_rect(sz)), "%s dpi %d: close control %s beside the map %s" % [sz, dpi, HudMinimap.close_rect(sz), big])
			assert_eq(HudMinimap.close_rect(sz), HudMinimap.tap_rect(sz), "%s: the close control is the tap target's square" % sz)
	_end()


# --- missing texture --------------------------------------------------------------------------------------------------

func test_missing_texture_gives_a_plain_panel() -> void:
	_begin()
	var sz := Vector2(2520, 1080)
	var me := _pawn(0, 0, Vector3(3, 0, 4))
	var d := _director({0: me})
	for id in ["no_such_map", ""]:
		var mm := _minimap(sz, d, me, id)
		assert_true(mm.texture == null, "'%s': no texture" % id)
		for view in ["small", "expanded"]:
			mm.set_expanded(view == "expanded")
			for i in 3:
				mm.tick(0.2)
			await _tree().process_frame
			await _tree().process_frame
			assert_true(mm.visible, "'%s' %s: the panel shows" % [id, view])
			assert_true(not _mark(mm, "player").is_empty() and not _mark(mm, "current_circle").is_empty() and not _mark(mm, "next_circle").is_empty(),
				"'%s' %s: the arrow and both circles still draw" % [id, view])
			var ext := mm.map_extent()
			assert_true(ext.size.x > 0.0 and ext.has_point(Vector2.ZERO), "'%s' %s: a fallback extent around the zone %s" % [id, view, ext])
		mm.free()
		_nodes.erase(mm)
	_end()


# --- profile key and Settings row -----------------------------------------------------------------------------------

func test_minimap_rotate_profile_key_and_settings_row() -> void:
	_begin()
	assert_eq(SaveService.defaults()["minimap_rotate"], true, "default true")
	var save := SaveService.new(TMP)
	assert_eq(save.load_profile()["minimap_rotate"], true, "no file: true")
	var f := FileAccess.open(TMP, FileAccess.WRITE)
	f.store_string(JSON.stringify({"version": 1, "gamertag": "X"}))
	f.close()
	assert_eq(save.load_profile()["minimap_rotate"], true, "a profile without the key loads as true")
	f = FileAccess.open(TMP, FileAccess.WRITE)
	f.store_string(JSON.stringify({"version": 1, "minimap_rotate": "no"}))
	f.close()
	assert_eq(save.load_profile()["minimap_rotate"], true, "a non-bool value loads as true")
	var p := save.load_profile()
	p["minimap_rotate"] = false
	assert_true(save.save_profile(p), "saved")
	assert_eq(save.load_profile()["minimap_rotate"], false, "false is saved and loaded")
	assert_eq(JSON.parse_string(FileAccess.get_file_as_string(TMP))["minimap_rotate"], false, "written to the file")
	p["minimap_rotate"] = true
	save.save_profile(p)
	var panel := SettingsPanel.new()
	panel.save = save
	_tree().root.add_child(panel)
	assert_eq(panel.minimap_button.text, "Minimap: Rotates", "the row shows Rotates")
	panel.toggle_minimap_rotate()
	assert_eq(panel.minimap_button.text, "Minimap: North up", "the row shows North up")
	assert_eq(save.load_profile()["minimap_rotate"], false, "the row stores false")
	assert_eq(AppFlow.profile["minimap_rotate"], false, "AppFlow.profile follows")
	assert_true(not HudMinimap.rotating(), "the minimap reads north up")
	panel.toggle_minimap_rotate()
	assert_eq(save.load_profile()["minimap_rotate"], true, "back to true")
	assert_true(HudMinimap.rotating(), "the minimap reads rotating")
	panel.free()
	AppFlow.profile = {}
	assert_true(HudMinimap.rotating(), "an empty profile (tests) reads rotating")
	_end()


# --- the baked textures ---------------------------------------------------------------------------------------------

func test_textures_exist_are_hashed_and_cover_the_map_bounds() -> void:
	var maps: Dictionary = HudArrangement.ui()["minimap"]["maps"]
	var bake: Dictionary = HudArrangement.ui()["minimap"]["bake"]
	var catalog: Dictionary = DataRegistry.new().load_file("res://data/asset_catalog.json")
	var listed := {}
	for entry: Dictionary in catalog.get("generated", []):
		listed[String(entry["path"])] = entry
	for id: String in MAPS:
		assert_true(maps.has(id), "data minimap.maps has %s" % id)
		if not maps.has(id):
			continue
		var path := String(maps[id]["texture"])
		assert_eq(path, RenderLayout.minimap_texture_path(id), "%s: the texture path the tool writes" % id)
		assert_true(FileAccess.file_exists(path), "%s: %s committed" % [id, path])
		var tex := load(path) as Texture2D
		var def := DataRegistry.new().load_file(RenderLayout.minimap_map_path(id))
		var ext := RenderLayout.minimap_extent(def)
		var e: Array = maps[id]["extent_m"]
		var data_ext := Rect2(float(e[0]), float(e[1]), float(e[2]), float(e[3]))
		assert_true(ext.size.x > 0.0, "%s: the map data gives a ground size" % id)
		assert_true(data_ext.position.distance_to(ext.position) < 1e-3 and data_ext.size.distance_to(ext.size) < 1e-3,
			"%s: data extent %s matches the map data's bounds %s" % [id, data_ext, ext])
		assert_true(tex != null, "%s: imports as a texture" % id)
		if tex != null:
			var px := RenderLayout.minimap_px(ext.size.x, bake)
			assert_eq(Vector2i(tex.get_width(), tex.get_height()), Vector2i(px, px), "%s: %d px square as the tool bakes it" % [id, px])
		assert_true(listed.has(path), "%s: hashed in asset_catalog.json generated" % id)
		if listed.has(path):
			assert_eq(String(listed[path]["sha256"]), FileAccess.get_sha256(path), "%s: hash of the committed file" % id)
			assert_eq(String(listed[path]["made_by"]), "tools/render_layout.gd", "%s: made by the render tool" % id)


# --- update rate ----------------------------------------------------------------------------------------------------

func test_overlays_update_at_the_data_rate_view_every_frame() -> void:
	_begin()
	var sz := Vector2(2520, 1080)
	var me := _pawn(0, 0, Vector3.ZERO)
	var mate := _pawn(0, 1, Vector3(20, 0, 0))
	var mm := _minimap(sz, _director({0: me, 1: mate}), me)
	var hz := float(HudArrangement.ui()["minimap"]["update_hz"])
	assert_true(hz > 0.0 and hz < 60.0, "update_hz %.1f is below the frame rate" % hz)
	mm.tick(0.0)
	var before := mm.overlay_updates
	var moved := 0
	var last := mm.drawn_px(Vector2(20, 0))
	for i in 120:  # two seconds at 60 frames a second
		me.position.x += 0.25
		mm.tick(1.0 / 60.0)
		var now := mm.drawn_px(Vector2(20, 0))
		if now.distance_to(last) > 1e-4:
			moved += 1
		last = now
	var updates := mm.overlay_updates - before
	assert_true(absf(float(updates) - 2.0 * hz) <= 1.0, "%d overlay updates in 2 s (want %.0f at update_hz)" % [updates, 2.0 * hz])
	assert_eq(moved, 120, "the view followed the player on every frame")
	_end()


# --- in the HUD -----------------------------------------------------------------------------------------------------

func test_game_hud_builds_the_minimap() -> void:
	var director := MatchDirector.new()
	var pawn := Pawn.new()
	pawn.setup("hastati", 0)
	var hud := GameHud.new()
	hud.bind(director, pawn)
	assert_true(hud.minimap != null and hud.minimap.get_parent() == hud, "no touch HUD: the minimap is the GameHud's child")
	assert_eq(hud.minimap.map_id, "", "outside a match: no map (plain panel)")
	assert_true(hud.minimap.mouse_filter == Control.MOUSE_FILTER_IGNORE and hud.minimap.z_index < 0, "passive, under the HUD")
	hud.free()
	pawn.free()
	director.free()
