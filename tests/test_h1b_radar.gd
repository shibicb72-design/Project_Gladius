extends "res://tests/test_case.gd"

## M2 H1b commit 4: the radar (scripts/ui/hud_radar.gd, data/ui.json radar, OQ-RADAR). The rule is DESIGN.md:26 only:
## every other living pawn within range_m (inclusive, horizontal by default) is a blip; an enemy in the cover crouch is
## not (the enable_cover test seam, since bots and LAN pawns never get cover in M2); squad mates are mate marks in the
## squad colour; the local player, dead pawns, LAN-hidden pawns and pawns aboard the carrier are never blips; a downed
## enemy shows. Blip pixels match world positions (ahead = up, right = right) for several headings through the one
## pure mapping; at the edge a blip is wholly inside the circle. Passive: every Control IGNORE, a look drag through it
## turns the view, it is not a touch target. Blips update at update_hz, the heading turn every frame. radar.enabled
## false: no radar, the minimap frame alone.

const _H1a := preload("res://tests/test_h1a_layout.gd")
const _TouchHud := preload("res://scripts/ui/touch_hud.gd")
const _PawnScene := preload("res://scenes/player/pawn.tscn")
const SIZES := [Vector2(2520, 1080), Vector2(2176, 1812), Vector2(1512, 648), Vector2(1152, 959), Vector2(2340, 1080), Vector2(3120, 1440)]
const TOL := 1.0  # px

var _h1a: RefCounted
var _nodes: Array = []
var _saved_cfg: Dictionary = {}


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _begin() -> void:
	_h1a = _H1a.new()
	_h1a._begin()
	PlatformServices.dpi_override = 420.0
	_saved_cfg = HudArrangement.ui()["radar"].duplicate(true)


func _end() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()
	var live: Dictionary = HudArrangement.ui()["radar"]
	for k in _saved_cfg:
		live[k] = _saved_cfg[k]
	_h1a._end()


func _pawn(squad: int, id: int, at: Vector3, yaw: float = 0.0) -> Pawn:
	var p := Pawn.new()
	p.setup("hastati", squad)
	p.player_id = id
	p.position = at
	p.rotation.y = yaw
	_nodes.append(p)
	return p


func _director(players: Dictionary) -> MatchDirector:
	var d := MatchDirector.new()
	d._players = players
	_nodes.append(d)
	return d


func _radar(sz: Vector2, director: MatchDirector, me: Pawn) -> HudRadar:
	var r := HudRadar.new()
	_tree().root.add_child(r)
	r.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	r.size = sz
	r.bind(director, me)
	r.tick(0.0)
	r.update_blips()
	_nodes.push_front(r)
	return r


func _ids(r: HudRadar, kind: String) -> Array:
	var out: Array = []
	for b: Dictionary in r.blips:
		if b["kind"] == kind:
			out.append(int(b["id"]))
	out.sort()
	return out


func _near(a: Vector2, b: Vector2, what: String) -> void:
	assert_true(a.distance_to(b) <= TOL, "%s: %s within %.1f px of %s" % [what, a, TOL, b])


# --- the one mapping -------------------------------------------------------------------------------------------------

func test_to_px_is_one_pure_function_ahead_up_right_right() -> void:
	var c := Vector2(300, 200)
	for yaw in [0.0, 0.9, -2.3, PI, 2.0]:
		var fwd := Vector2(-sin(yaw), -cos(yaw))  # Godot: -Z forward, written out here (not taken from the code)
		var right := Vector2(cos(yaw), -sin(yaw))
		_near(HudRadar.to_px(fwd * 10.0, yaw, 25.0, 100.0, c), c + Vector2(0, -40), "yaw %.1f: 10 m ahead is 40 px up" % yaw)
		_near(HudRadar.to_px(right * 25.0, yaw, 25.0, 100.0, c), c + Vector2(100, 0), "yaw %.1f: 25 m right is the edge, right" % yaw)
		_near(HudRadar.to_px(-fwd * 5.0 - right * 5.0, yaw, 25.0, 100.0, c), c + Vector2(-20, 20), "yaw %.1f: behind-left is down-left" % yaw)
	_near(HudRadar.to_px(Vector2.ZERO, 1.0, 25.0, 100.0, c), c, "the player is the centre")


# --- the rule -----------------------------------------------------------------------------------------------------------

func test_range_rule_moving_standing_outside_and_edge() -> void:
	_begin()
	var sz := Vector2(2520, 1080)
	var me := _pawn(1, 0, Vector3(5, 0, 5), 0.4)
	var moving := _pawn(2, 1, Vector3(5 + 12, 0, 5))
	moving.velocity = Vector3(4, 0, 0)
	var standing := _pawn(3, 2, Vector3(5, 0, 5 - 20))
	var outside := _pawn(4, 3, Vector3(5 + 25.5, 0, 5))
	var edge := _pawn(5, 4, Vector3(5, 0, 5 + 25.0))
	var above := _pawn(6, 5, Vector3(5 - 20, 9, 5))  # 20 m away on the ground, 9 m up
	var r := _radar(sz, _director({0: me, 1: moving, 2: standing, 3: outside, 4: edge, 5: above}), me)
	assert_eq(float(HudArrangement.ui()["radar"]["range_m"]), 25.0, "range_m 25 (DESIGN.md:26)")
	assert_eq(_ids(r, HudRadar.ENEMY), [1, 2, 4, 5], "moving and standing inside, the edge (inclusive) and the one above show; 25.5 m does not")
	assert_true(r.blip_of(0).is_empty(), "the local player is not a blip")
	# The distance switch (radar.distance): 24 m on the ground and 9 m up is in under "flat", out under "3d".
	above.position = Vector3(5 - 24, 9, 5)  # flat 24 m, 3d 25.6 m
	r.update_blips()
	assert_true(not r.blip_of(5).is_empty(), "flat (default): 24 m on the ground shows whatever the height")
	HudArrangement.ui()["radar"]["distance"] = "3d"
	r.update_blips()
	assert_true(r.blip_of(5).is_empty(), "3d: 25.6 m straight-line is out of range")
	HudArrangement.ui()["radar"]["distance"] = "flat"
	_end()


func test_enemy_in_cover_crouch_hidden_shows_again_when_out() -> void:
	_begin()
	var sz := Vector2(2520, 1080)
	var me := _pawn(1, 0, Vector3.ZERO)
	# A real pawn with the real CoverController, through the enable_cover test seam (bots never take cover in M2).
	var enemy: Pawn = _PawnScene.instantiate()
	_tree().root.add_child(enemy)
	enemy.set_physics_process(false)
	enemy.setup("hastati", 2)
	enemy.player_id = 1
	enemy.global_position = Vector3(8, 0, -6)
	_nodes.append(enemy)
	var mate: Pawn = _PawnScene.instantiate()
	_tree().root.add_child(mate)
	mate.set_physics_process(false)
	mate.setup("hastati", 1)
	mate.player_id = 2
	mate.global_position = Vector3(-8, 0, 4)
	_nodes.append(mate)
	var cover_cfg := DataRegistry.new().load_file("res://data/cover.json")
	enemy.enable_cover(cover_cfg)
	mate.enable_cover(cover_cfg)
	assert_true(enemy.cover != null and mate.cover != null, "fixture: the cover seam gave both a controller")
	var r := _radar(sz, _director({0: me, 1: enemy, 2: mate}), me)
	assert_eq(_ids(r, HudRadar.ENEMY), [1], "free: the enemy shows")
	var min_crouch := float(HudArrangement.ui()["radar"]["cover_crouch_min"])
	enemy.cover.state = CoverController.State.IN_COVER
	enemy.cover.crouch_amount = 1.0
	mate.cover.state = CoverController.State.IN_COVER
	mate.cover.crouch_amount = 1.0
	r.update_blips()
	assert_true(enemy.in_cover(), "fixture: in cover")
	assert_eq(_ids(r, HudRadar.ENEMY), [], "in the cover crouch: the enemy is off the radar")
	assert_eq(_ids(r, HudRadar.MATE), [2], "a squad mate in the cover crouch still shows (the rule hides enemies)")
	enemy.cover.crouch_amount = min_crouch
	r.update_blips()
	assert_eq(_ids(r, HudRadar.ENEMY), [], "at cover_crouch_min (%.2f): hidden" % min_crouch)
	enemy.cover.crouch_amount = min_crouch - 0.01
	r.update_blips()
	assert_eq(_ids(r, HudRadar.ENEMY), [1], "below cover_crouch_min (risen over low cover, standing behind high): shows")
	enemy.cover.crouch_amount = 0.0
	r.update_blips()
	assert_eq(_ids(r, HudRadar.ENEMY), [1], "standing in cover (high cover): shows")
	enemy.cover.crouch_amount = 1.0
	r.update_blips()
	assert_eq(_ids(r, HudRadar.ENEMY), [], "crouched again: hidden")
	enemy.cover.reset()  # leaves cover: FREE, crouch 0
	r.update_blips()
	assert_true(not enemy.in_cover(), "fixture: out of cover")
	assert_eq(_ids(r, HudRadar.ENEMY), [1], "out of cover: the enemy shows again")
	_end()


func test_mate_in_squad_colour_never_an_enemy_and_shapes_differ() -> void:
	_begin()
	var sz := Vector2(2176, 1812)
	var me := _pawn(0, 0, Vector3(0, 0, 0))  # squad 0: its colour is the palette's red
	var mate := _pawn(0, 1, Vector3(6, 0, 6))
	var far_mate := _pawn(0, 2, Vector3(40, 0, 0))
	var enemy := _pawn(7, 3, Vector3(-6, 0, 6))
	var r := _radar(sz, _director({0: me, 1: mate, 2: far_mate, 3: enemy}), me)
	assert_eq(_ids(r, HudRadar.MATE), [1], "the mate in range is a mate mark; the one 40 m off is not shown")
	assert_eq(_ids(r, HudRadar.ENEMY), [3], "the mate is never an enemy")
	assert_eq(r.blip_of(1)["color"], SoldierSquadColour.paint(0), "the mate is in the squad colour")
	assert_true(r.blip_of(3)["color"] == MenuStyle.color(str(HudArrangement.ui()["radar"]["colors"]["enemy"])), "the enemy in the hostile colour")
	assert_true(r.blip_of(0).is_empty(), "the local player is not a blip")
	# Solo: everybody is their own squad, so the old mate is an enemy now.
	mate.squad_id = 11
	r.update_blips()
	assert_eq(_ids(r, HudRadar.ENEMY), [1, 3], "solo: every other soldier in range is an enemy")
	_end()


func test_dead_hidden_downed_enemy_shows_aboard_hidden_falling_shows() -> void:
	_begin()
	var me := _pawn(0, 0, Vector3.ZERO)
	var dead := _pawn(1, 1, Vector3(3, 0, 3))
	dead.life = Pawn.Life.DEAD
	var downed := _pawn(2, 2, Vector3(-3, 0, 3))
	downed.life = Pawn.Life.DOWNED
	var aboard := _pawn(3, 3, Vector3(3, 0, -3))
	aboard.drop_state = Pawn.Drop.ABOARD
	var falling := _pawn(4, 4, Vector3(-3, 6, -3))
	falling.drop_state = Pawn.Drop.FALLING
	var lan_hidden := _pawn(5, 5, Vector3(1, 0, 1))
	lan_hidden.visible = false  # what net_match_bridge.apply_replica's set_active(false) leaves on a client
	var dead_mate := _pawn(0, 6, Vector3(2, 0, 2))
	dead_mate.life = Pawn.Life.DEAD
	var r := _radar(Vector2(2520, 1080), _director({0: me, 1: dead, 2: downed, 3: aboard, 4: falling, 5: lan_hidden, 6: dead_mate}), me)
	assert_eq(_ids(r, HudRadar.ENEMY), [2, 4], "the downed enemy and the falling one show; dead, aboard and LAN-hidden do not")
	assert_eq(_ids(r, HudRadar.MATE), [], "a dead mate does not show")
	_end()


# --- pixels ------------------------------------------------------------------------------------------------------------

func test_blip_pixels_match_world_positions_for_several_headings() -> void:
	_begin()
	for sz in [Vector2(2520, 1080), Vector2(2176, 1812), Vector2(1512, 648)]:
		var me := _pawn(0, 0, Vector3(30, 0, -12))
		var ahead := _pawn(5, 1, Vector3.ZERO)
		var right := _pawn(6, 2, Vector3.ZERO)
		var mate := _pawn(0, 3, Vector3.ZERO)
		var r := _radar(sz, _director({0: me, 1: ahead, 2: right, 3: mate}), me)
		var c := HudRadar.disc_rect(sz).get_center()
		var k := HudRadar.blip_radius_px(sz) / 25.0
		assert_true(HudArrangement.radar_rect(sz).encloses(HudRadar.disc_rect(sz)), "%s: the disc is inside the reserved circle" % sz)
		for yaw in [0.0, 0.9, -2.3, PI]:
			me.rotation.y = yaw
			var fwd := Vector3(-sin(yaw), 0, -cos(yaw))
			var rt := Vector3(cos(yaw), 0, -sin(yaw))
			ahead.position = me.position + fwd * 12.0
			right.position = me.position + rt * 20.0
			mate.position = me.position - fwd * 8.0 - rt * 4.0
			r.update_blips()
			_near(r.blip_of(1)["px"], c + Vector2(0, -12.0 * k), "%s yaw %.1f: 12 m ahead is straight up" % [sz, yaw])
			_near(r.blip_of(2)["px"], c + Vector2(20.0 * k, 0), "%s yaw %.1f: 20 m right is right" % [sz, yaw])
			_near(r.blip_of(3)["px"], c + Vector2(-4.0 * k, 8.0 * k), "%s yaw %.1f: the mate behind-left is down-left" % [sz, yaw])
			_near(r.drawn_px(r.blip_of(1)), r.blip_of(1)["px"], "%s yaw %.1f: drawn where marked" % [sz, yaw])
		# A turn between updates: the blip layer turns with the heading at once (a transform), no rebuild.
		me.rotation.y = 0.0
		ahead.position = me.position + Vector3(0, 0, -12)
		r.update_blips()
		var before := r.blip_updates
		me.rotation.y = PI * 0.5  # turned left 90 deg: what was ahead is now on the right
		r.follow()
		assert_eq(r.blip_updates, before, "%s: no rebuild for a turn" % sz)
		_near(r.drawn_px(r.blip_of(1)), c + Vector2(12.0 * k, 0), "%s: after a 90 deg left turn the blip is drawn on the right" % sz)
		r.free()
		_nodes.erase(r)
	_end()


## A blip at exactly range_m is wholly inside the circle (no edge pinning: beyond range it is not drawn at all).
func test_edge_blip_inside_the_circle_on_six_sizes() -> void:
	_begin()
	for dpi in [420.0, 373.0]:
		PlatformServices.dpi_override = dpi
		for sz in SIZES:
			var disc := HudRadar.disc_rect(sz)
			var u := HudArrangement.unit(sz)
			var marks: Dictionary = HudArrangement.ui()["radar"]["marks"]
			var half := float(marks["enemy_units"]) * u + float(marks["outline_units"]) * u * 1.4
			var reach := HudRadar.blip_radius_px(sz) + half
			var rim_in := disc.size.x * 0.5 - float(marks["rim_width_units"]) * u
			assert_true(reach <= rim_in + 0.01, "%s dpi %d: an edge blip (out to %.1f px) inside the rim's inner edge (%.1f px)" % [sz, dpi, reach, rim_in])
			assert_true(HudRadar.blip_radius_px(sz) > disc.size.x * 0.25, "%s dpi %d: the blip area is most of the disc" % [sz, dpi])
	_end()


# --- passive -------------------------------------------------------------------------------------------------------------

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


func test_radar_is_passive_a_look_drag_through_it_turns_the_view() -> void:
	_begin()
	for stick in ["virtual", "custom"]:
		_TouchHud.move_stick_override = stick
		for sz in [Vector2(2520, 1080), Vector2(2176, 1812), Vector2(1512, 648)]:
			var touch: Control = _h1a._new_touch(sz)
			var me := _pawn(0, 0, Vector3.ZERO)
			var foe := _pawn(3, 1, Vector3(0, 0, -10))
			var r := _radar(sz, _director({0: me, 1: foe}), me)  # added after the touch HUD: on top, as in the match
			await _tree().process_frame
			var tag := "%s %s" % [stick, sz]
			assert_true(r.visible and not r.blips.is_empty(), "%s: fixture: the radar is drawn with a blip" % tag)
			for p: Vector2 in [HudRadar.disc_rect(sz).get_center(), r.blip_of(1)["px"]]:
				assert_true(touch.get_look_area_rect().has_point(p), "%s: fixture: %s on the radar is in the look area" % [tag, p])
				touch.provider.clear_look()
				_touch(4, p, true)
				_drag(4, p + Vector2(-80, 0), Vector2(-80, 0))
				assert_true(touch.provider.get_look() != Vector2.ZERO, "%s: a look drag starting on the radar at %s turns the view" % [tag, p])
				_touch(4, p + Vector2(-80, 0), false)
				touch._process(1.0 / 60.0)
			for c in [r] + r.find_children("*", "Control", true, false):
				assert_eq((c as Control).mouse_filter, Control.MOUSE_FILTER_IGNORE, "%s: %s ignores touches" % [tag, c.name])
			var own: Array = []
			for m: Dictionary in (r.get_script() as Script).get_script_method_list():
				own.append(String(m["name"]))
			assert_true(not own.has("_input") and not own.has("_gui_input") and not own.has("_unhandled_input"), "%s: the radar script reads no input" % tag)
			var pm: PauseMenu = _h1a._pause(sz)
			var ctrls: Dictionary = _h1a._controls(touch, pm, sz)
			for key in ctrls:
				assert_true(not String(key).contains("radar"), "%s: the radar is not a touch target (%s)" % [tag, key])
			pm.free()
			r.free()
			_nodes.erase(r)
			touch.free()
	_end()


# --- rate ----------------------------------------------------------------------------------------------------------------

func test_blips_update_at_the_data_rate_turn_every_frame() -> void:
	_begin()
	var sz := Vector2(2520, 1080)
	var me := _pawn(0, 0, Vector3.ZERO)
	var foe := _pawn(4, 1, Vector3(0, 0, -15))
	var r := _radar(sz, _director({0: me, 1: foe}), me)
	var hz := float(HudArrangement.ui()["radar"]["update_hz"])
	assert_true(hz > 0.0 and hz < 60.0, "update_hz %.1f is below the frame rate" % hz)
	r.tick(0.0)
	var before := r.blip_updates
	var turned := 0
	var last := r.drawn_px(r.blip_of(1))
	for i in 120:  # two seconds at 60 frames a second
		me.rotation.y += 0.01
		foe.position.x += 0.05
		r.tick(1.0 / 60.0)
		var now := r.drawn_px(r.blip_of(1))
		if now.distance_to(last) > 1e-4:
			turned += 1
		last = now
	var updates := r.blip_updates - before
	assert_true(absf(float(updates) - 2.0 * hz) <= 1.0, "%d blip updates in 2 s (want %.0f at update_hz)" % [updates, 2.0 * hz])
	assert_eq(turned, 120, "the blip followed the heading on every frame")
	_end()


# --- switch and HUD --------------------------------------------------------------------------------------------------------

func test_disabled_no_radar_minimap_frame_alone() -> void:
	_begin()
	var sz := Vector2(2520, 1080)
	var me := _pawn(0, 0, Vector3.ZERO)
	var foe := _pawn(4, 1, Vector3(0, 0, -15))
	var r := _radar(sz, _director({0: me, 1: foe}), me)
	assert_true(HudRadar.is_enabled() and r.visible, "data default: enabled and drawn")
	assert_eq(HudMinimap.frame_rect(sz), HudArrangement.panel_rect(sz), "on: the plate frames radar + minimap")
	HudArrangement.ui()["radar"]["enabled"] = false
	r.tick(1.0 / 60.0)
	assert_true(not r.visible, "off: the radar is hidden")
	assert_eq(HudMinimap.frame_rect(sz), HudArrangement.minimap_rect(sz), "off: the minimap frame alone (commit 3)")
	HudArrangement.ui()["radar"]["enabled"] = true
	r.tick(1.0 / 60.0)
	assert_true(r.visible, "on again: drawn")
	_end()


func test_game_hud_builds_the_radar_after_the_minimap() -> void:
	var director := MatchDirector.new()
	var pawn := Pawn.new()
	pawn.setup("hastati", 0)
	var hud := GameHud.new()
	hud.bind(director, pawn)
	assert_true(hud.radar != null and hud.radar.get_parent() == hud, "no touch HUD: the radar is the GameHud's child")
	assert_true(hud.radar.get_index() > hud.minimap.get_index(), "drawn after the minimap (over its plate)")
	assert_true(hud.radar.mouse_filter == Control.MOUSE_FILTER_IGNORE and hud.radar.z_index == hud.minimap.z_index, "passive, at the minimap's layer")
	assert_true(hud.radar.pawn == pawn and hud.radar.director == director, "bound to the local pawn and the director")
	hud.free()
	pawn.free()
	director.free()
