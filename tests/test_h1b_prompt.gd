extends "res://tests/test_case.gd"

## M2 H1b commit 2: the prompt at the object (scripts/ui/interact_prompt.gd, data/ui.json interact_prompt, OQ-HUD) in the
## real match scene. For every kind (pickup, chest, door open / close, revive) it shows exactly the Interact button's
## target with the data text at the projected screen point, clamped on screen when the target is off screen or behind the
## camera; a TAP on it does what the button does (through the same InputRouter path); revive is a HOLD; a drag that
## starts on it turns the view (or moves the stick) exactly as if it were not there and does not interact; it and the
## button never both press; it releases on hide; a LAN client shows none; its tap target is at least 48 dp and on screen
## on the six sizes at 420 and 373 dpi; there is only ever one. Touches are pushed through the viewport in its own
## coordinates, as tests/test_h1b_hud.gd does.

const _MatchScene := preload("res://scenes/match/match.tscn")
const _TouchHud := preload("res://scripts/ui/touch_hud.gd")
const _H1a := preload("res://tests/test_h1a_layout.gd")
const SIZES := [Vector2(2520, 1080), Vector2(2176, 1812), Vector2(1512, 648), Vector2(1152, 959), Vector2(2340, 1080), Vector2(3120, 1440)]
const DPIS := [420.0, 373.0]
const REVIVE_S := 0.5
const PX_TOL := 2.0

var m: MatchRoot
var prompt: InteractPrompt
var button: InteractButton
var touch: Control
var routed: Array = []
var old_size: Vector2i
var old_profile: Dictionary


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func frames(n: int) -> void:
	for i in n:
		await _tree().physics_frame
		await _tree().process_frame


func _setup(mode := "solo", stick := "") -> void:
	old_size = _tree().root.size
	old_profile = AppFlow.profile
	AppFlow.profile = {}
	_TouchHud.move_stick_override = stick
	_tree().root.size = Vector2i(2520, 1080)
	m = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.seed_override = 31337
	m.ground_loot = true
	_tree().root.add_child(m)
	await _tree().process_frame
	m.director.load_config()
	m.director.mode_cfg["zone"] = {"start_center": [0, 0], "start_radius_m": 5000.0, "damage_skips_shield": false,
			"phases": [{"wait_s": 1000.0, "shrink_s": 10.0, "radius_m": 2500.0, "damage_per_s": 0.0}]}
	m.director.mode_cfg["teams"]["mode"]["value"] = mode
	m.director.mode_cfg["downed"]["revive_s"] = REVIVE_S
	assert_true(m.begin(), "match begins")
	for b in m.bots:
		var brain := b.get_node_or_null("Brain")
		if brain != null:
			brain.set_physics_process(false)
	touch = m.get_node("Hud/TouchHud")
	touch.cfg["force_touch_hud"] = true
	touch.refresh_visibility()
	routed = []
	m.router.action_triggered.connect(func(a: String) -> void: routed.append(["press", a]))
	m.router.action_released.connect(func(a: String, c: bool) -> void: routed.append(["release", a, c]))
	await frames(3)
	button = m.hud.interact_button
	prompt = m.hud.interact_prompt
	_clear_near(m.local_player.global_position)
	await frames(2)


func _cleanup() -> void:
	m.queue_free()
	await _tree().process_frame
	_tree().root.size = old_size
	AppFlow.profile = old_profile
	_TouchHud.move_stick_override = ""
	_tree().paused = false


func _clear_near(pos: Vector3) -> void:
	for id in m.loot.items.keys():
		if Vector2(m.loot.items[id]["pos"].x - pos.x, m.loot.items[id]["pos"].z - pos.z).length() < 8.0:
			m.loot.take(id)


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


func _presses() -> int:
	return routed.count(["press", "interact"])


func _door_ahead(pawn: Pawn, id: String, ahead_m: float, start := "closed") -> Door:
	var basis := pawn.global_transform.basis
	var at := pawn.global_position - basis.z * ahead_m + Vector3(0, 1.15, 0)
	var entry := {"id": id, "kind": Door.KIND_DOOR, "at": [at.x, at.y, at.z], "yaw": rad_to_deg(pawn.global_rotation.y),
		"size": [2.0, 2.3, 0.12], "slide": "right", "start": start}
	var d := Door.make(entry, WorldProps.door_cfg(WorldProps.config(), Door.KIND_DOOR))
	m.map.add_child(d)
	m.world_props.register_door(d)
	return d


func _chest_at(pawn: Pawn, id: String, side_m: float, ahead_m := 0.0) -> LootChest:
	var at := pawn.global_position + pawn.global_transform.basis.x * side_m - pawn.global_transform.basis.z * ahead_m + Vector3(0, 0.45, 0)
	var c := LootChest.make({"id": id, "at": [at.x, at.y, at.z], "size": [1.4, 0.9, 0.9], "yaw": 0.0}, "camp")
	m.map.add_child(c)
	m.world_props.register_chest(c)
	return c


func _down_mate() -> Pawn:
	var local := m.local_player
	var mate: Pawn = null
	var enemy: Pawn = null
	for id in m.director.all_players():
		var p: Pawn = m.director.player(id)
		if p == local:
			continue
		if p.squad_id == local.squad_id and mate == null:
			mate = p
		elif p.squad_id != local.squad_id and enemy == null:
			enemy = p
	mate.global_position = local.global_position + local.global_transform.basis.x * 1.0 - local.global_transform.basis.z * 1.0
	mate.bridge.state.shield = 0.0
	mate.bridge.state.health = 1.0
	mate.receive_hit(DataRegistry.new().get_weapon_def("sagittarii_rifle"), false, enemy.squad_id, enemy.player_id)
	await frames(2)
	return mate


## The button's target as MatchRoot acts on it (revive > pickup > chest > door), as [kind, id].
func _button_target() -> Array:
	var d := m.director
	var id := m.local_player.player_id
	if d.revive_target_for(id) >= 0:
		return ["revive", d.revive_target_for(id)]
	if d.pickup_target_for(id) >= 0:
		return ["pickup", d.pickup_target_for(id)]
	if d.chest_target_for(id) != "":
		return ["chest", d.chest_target_for(id)]
	if d.door_target_for(id) != "":
		return ["door", d.door_target_for(id)]
	return ["", null]


## The prompt shows the button's target, with the text that matches the button's label, at the projected point.
func _check_same(tag: String, want_text: String, button_label: String) -> void:
	assert_true(button.visible and prompt.visible, "%s: the button and the prompt both show" % tag)
	var bt := _button_target()
	var pid: Variant = prompt.target_int if prompt.kind in ["revive", "pickup"] else prompt.target_str
	assert_eq([prompt.kind, pid], bt, "%s: the prompt's target is the button's" % tag)
	assert_eq(prompt.text, want_text, "%s: prompt text" % tag)
	assert_eq(button.label.text, button_label, "%s: the button reads the same target" % tag)
	var cam := m.get_viewport().get_camera_3d()
	# unproject_position is in viewport pixels; the HUD canvas is stretched (project canvas_items stretch).
	var p := m.get_viewport().get_final_transform().affine_inverse() * cam.unproject_position(prompt.target_world)
	assert_true(not cam.is_position_behind(prompt.target_world), "%s: nonvacuous: target in front" % tag)
	assert_true(not prompt.clamped, "%s: on screen, not clamped" % tag)
	assert_true(prompt.anchor.distance_to(p) <= PX_TOL, "%s: anchor %s at the projected point %s" % [tag, prompt.anchor, p])
	var view := Vector2(m.get_viewport().get_visible_rect().size)
	assert_true(Rect2(Vector2.ZERO, view).encloses(prompt.get_global_rect()), "%s: prompt on screen" % tag)


func _tap_prompt() -> void:
	var c := prompt.get_global_rect().get_center()
	_touch(6, c, true)
	await frames(2)
	_touch(6, c, false)
	await frames(2)


func test_pickup_chest_door_same_target_text_place_and_tap_acts() -> void:
	await _setup()
	var me := m.local_player
	me.apply_start_kit({"secondary": "gladius_lux"})
	assert_true(not prompt.visible and not button.visible, "nothing in range: no prompt")
	var door := _door_ahead(me, "Door_980", 1.4)
	_chest_at(me, "Chest_980", 1.2, 0.8)  # ahead right, in view (first or third person)
	m.loot.drop({"item_id": "pilum_br"}, me.global_position - me.global_transform.basis.z * 1.2 + me.global_transform.basis.x * 0.5)
	await frames(2)
	assert_eq(_tree().root.find_children("*", "InteractPrompt", true, false).size(), 1, "one prompt in the tree")
	# Pickup first (priority), with the item's display name.
	_check_same("pickup", "Pick up Pilum BR", "Pick up\nPilum BR")
	var item_world: Vector3 = m.loot.items[prompt.target_int]["pos"]
	assert_true(prompt.target_world.distance_to(item_world + Vector3(0, 0.35, 0)) < 1e-3, "anchored above the item")
	var n := _presses()
	await _tap_prompt()
	assert_eq(_presses(), n + 1, "the tap pressed interact once through the router")
	assert_true(["release", "interact", false] in routed, "and released it")
	assert_true(me.loadout.slots[0] != null and me.loadout.slots[0].def.id == "pilum_br", "the tap picked the gun up")
	# Chest next.
	await frames(1)
	_check_same("chest", "Open chest", "Open chest")
	await _tap_prompt()
	assert_eq(m.world_props.state_of("Chest_980"), WorldProps.OPEN, "the tap opened the chest")
	# The chest spills loot: clear it so the door is the target.
	_clear_near(me.global_position)
	await frames(2)
	_check_same("door open", "Open door", "Open door")
	await _tap_prompt()
	assert_eq(m.world_props.state_of("Door_980"), WorldProps.OPEN, "the tap opened the door")
	await frames(2)
	_check_same("door close", "Close door", "Close door")
	assert_true(door.global_position.distance_to(prompt.target_world) < 1e-3, "anchored at the door's centre")
	await _tap_prompt()
	assert_eq(m.world_props.state_of("Door_980"), WorldProps.CLOSED, "the next tap closed it")
	# A long still press is no tap.
	await frames(2)
	var c := prompt.get_global_rect().get_center()
	_touch(6, c, true)
	await frames(int(float(prompt.cfg["tap_max_s"]) * 60.0) + 6)
	_touch(6, c, false)
	await frames(2)
	assert_eq(m.world_props.state_of("Door_980"), WorldProps.CLOSED, "a press held past tap_max_s does nothing")
	await _cleanup()


func test_revive_is_a_hold_short_tap_does_nothing_early_release_cancels() -> void:
	await _setup("squads")
	var mate := await _down_mate()
	await frames(1)
	_check_same("revive", "Hold to revive", "Revive")
	assert_eq(prompt.target_world, mate.global_position + Vector3(0, 0.6, 0), "anchored above the downed mate")
	var c := prompt.get_global_rect().get_center()
	# A short tap does not even press.
	var n := _presses()
	_touch(6, c, true)
	await frames(2)
	_touch(6, c, false)
	await frames(int(REVIVE_S * 60.0) + 10)
	assert_eq(_presses(), n, "a short tap presses nothing")
	assert_true(mate.is_downed(), "a short tap does not revive")
	# An early release cancels, and the next hold starts from zero.
	_touch(6, c, true)
	await frames(int(REVIVE_S * 60.0 * 0.6))
	assert_true(m.director.is_reviving(m.local_player.player_id), "holding the prompt holds the revive")
	_touch(6, c, false)
	await frames(2)
	assert_true(["release", "interact", false] in routed, "release routed")
	assert_true(not m.director.is_reviving(m.local_player.player_id), "released early: the pair ends")
	await frames(int(REVIVE_S * 60.0))
	assert_true(mate.is_downed(), "still downed after an early release")
	# A full hold revives.
	_touch(6, c, true)
	var k := 0
	while mate.is_downed() and k < 120:
		await frames(1)
		k += 1
	assert_eq(mate.life, Pawn.Life.ALIVE, "a hold for the revive time revives")
	await frames(2)
	assert_true(not prompt.visible, "hidden once revived")
	_touch(6, c, false)
	await frames(1)
	await _cleanup()


## A drag that starts on the prompt turns the view exactly as the same drag with the prompt switched off, and does not
## interact (door: no toggle; revive: no press).
func test_drag_on_prompt_turns_the_view_and_does_not_interact() -> void:
	await _setup("squads")
	var me := m.local_player
	_door_ahead(me, "Door_981", 1.4)
	await frames(2)
	assert_eq(prompt.kind, "door", "nonvacuous: a door prompt")
	var view := Vector2(m.get_viewport().get_visible_rect().size)
	var tries := 0
	while prompt.visible and prompt.get_global_rect().get_center().x <= 0.6 * view.x and tries < 20:
		me.rotation.y += 0.08  # turn left: the door ahead drifts right on screen, into the look half
		await frames(2)
		tries += 1
	assert_true(touch._zone_hit_rect("look_zone").has_point(prompt.get_global_rect().get_center()), "nonvacuous: the prompt is in the look area")
	var accum := []
	for on in [true, false]:
		prompt.enabled = on
		await frames(2)
		assert_eq(prompt.visible, on, "prompt shown: %s" % on)
		var c: Vector2 = prompt.get_global_rect().get_center() if on else accum[0][1]
		var n := _presses()
		touch.provider.clear_look()
		_touch(6, c, true)
		for i in 6:
			_drag(6, c + Vector2(-15.0 * (i + 1), -4.0 * (i + 1)), Vector2(-15.0, -4.0))
		var got: Vector2 = touch.provider._drag_accum
		_touch(6, c + Vector2(-90.0, -24.0), false)
		await frames(2)
		accum.append([got, c])
		assert_true(got != Vector2.ZERO, "a drag from %s turns the view (prompt %s)" % [c, on])
		assert_eq(_presses(), n, "the drag pressed nothing (prompt %s)" % on)
		assert_eq(m.world_props.state_of("Door_981"), WorldProps.CLOSED, "the door is untouched")
	assert_eq(accum[0][0], accum[1][0], "the same look delta with and without the prompt (none lost)")
	prompt.enabled = true
	# Revive: a drag never presses interact.
	m.world_props.doors["Door_981"].position.y += 100.0
	await _down_mate()
	await frames(2)
	assert_eq(prompt.kind, "revive", "nonvacuous: a revive prompt")
	var c2 := prompt.get_global_rect().get_center()
	var n2 := _presses()
	_touch(6, c2, true)
	_drag(6, c2 + Vector2(-60, 0), Vector2(-60, 0))
	await frames(int(REVIVE_S * 60.0) + 5)
	assert_eq(_presses(), n2, "a revive drag presses nothing")
	assert_true(not m.director.is_reviving(me.player_id), "and holds no revive")
	_touch(6, c2 + Vector2(-60, 0), false)
	await frames(1)
	await _cleanup()


## In the left half a press on the prompt starts the move stick as if the prompt were not there (both stick types).
func test_left_half_drag_on_prompt_moves_the_stick() -> void:
	for stick in ["custom", "virtual"]:
		await _setup("solo", stick)
		var me := m.local_player
		_chest_at(me, "Chest_982", -1.6, 0.6)
		await frames(2)
		var view := Vector2(m.get_viewport().get_visible_rect().size)
		var tries := 0
		while prompt.visible and prompt.get_global_rect().get_center().x >= 0.4 * view.x and tries < 20:
			me.rotation.y -= 0.08  # turn right: the chest on the left drifts further left on screen
			await frames(2)
			tries += 1
		assert_true(prompt.visible and prompt.kind == "chest", "%s: nonvacuous: a chest prompt" % stick)
		var c := prompt.get_global_rect().get_center()
		assert_true(c.x < 0.5 * view.x, "%s: nonvacuous: the prompt is in the left half (%s)" % [stick, c])
		var moves := []
		for on in [true, false]:
			prompt.enabled = on
			await frames(2)
			touch.provider.move_value = Vector2.ZERO
			_touch(4, c, true)
			_drag(4, c + Vector2(0, -120), Vector2(0, -120))
			touch._process(1.0 / 60.0)
			moves.append(touch.provider.move_value)
			assert_true(touch.provider.move_value.y < 0.0, "%s prompt %s: the stick moves (%s)" % [stick, on, touch.provider.move_value])
			_touch(4, c + Vector2(0, -120), false)
			touch._process(1.0 / 60.0)
			await frames(2)
			assert_eq(m.world_props.state_of("Chest_982"), WorldProps.INTACT, "%s: the chest stays closed" % stick)
		assert_true(moves[0].distance_to(moves[1]) < 1e-4, "%s: the same stick value with and without the prompt" % stick)
		prompt.enabled = true
		await _cleanup()


func test_prompt_and_button_never_both_press_and_release_on_hide() -> void:
	await _setup("squads")
	await _down_mate()
	await frames(1)
	var pc := prompt.get_global_rect().get_center()
	var bc := button.get_touch_rect().get_center()
	assert_true(not prompt.get_global_rect().intersects(button.get_touch_rect()), "the prompt keeps off the button")
	# Button held: a press on the prompt is not taken.
	var n := _presses()
	_touch(3, bc, true)
	await frames(2)
	assert_true(button._is_pressed(), "the button is held")
	_touch(6, pc, true)
	await frames(int(REVIVE_S * 60.0 * 0.5))
	assert_eq(_presses(), n + 1, "only the button pressed")
	assert_eq(prompt._track, -1, "the prompt did not take the press")
	_touch(6, pc, false)
	_touch(3, bc, false)
	await frames(2)
	# Prompt holding: a press on the button is swallowed.
	n = _presses()
	_touch(6, pc, true)
	await frames(int(REVIVE_S * 60.0 * 0.4))
	assert_true(prompt._holding, "the prompt holds interact")
	_touch(3, bc, true)
	await frames(2)
	assert_true(not button._is_pressed(), "the button did not press while the prompt holds")
	assert_eq(_presses(), n + 1, "one press only")
	_touch(3, bc, false)
	# Release on hide.
	var before := routed.size()
	touch.visible = false
	await frames(2)
	assert_true(not prompt.visible, "hidden with the touch HUD")
	assert_true(["release", "interact", true] in routed.slice(before), "hiding sends the cancel release")
	assert_true(not m.director.is_reviving(m.local_player.player_id), "the revive ended")
	assert_true(not prompt._holding and prompt._track == -1, "the prompt let go")
	_touch(6, pc, false)
	touch.visible = true
	await frames(2)
	await _cleanup()


func test_lan_client_shows_no_prompt() -> void:
	await _setup()
	var me := m.local_player
	_chest_at(me, "Chest_983", 1.6)
	await frames(2)
	assert_true(prompt.visible, "nonvacuous: the host shows the chest prompt")
	m.director.authoritative = false
	await frames(2)
	assert_true(not button.visible, "a client hides Interact")
	assert_true(not prompt.visible, "and shows no prompt")
	m.director.authoritative = true
	await _cleanup()


func test_off_screen_and_behind_are_clamped_on_screen() -> void:
	await _setup()
	var me := m.local_player
	m.loot.drop({"item_id": "ammo"}, me.global_position - me.global_transform.basis.z * 0.8)
	me.apply_start_kit({"primary": "pilum_br", "secondary": "gladius_lux"})
	await frames(2)
	assert_eq(prompt.kind, "pickup", "nonvacuous: a pickup prompt")
	var view := Vector2(m.get_viewport().get_visible_rect().size)
	var margin := float(prompt.cfg["screen_margin_dp"]) * HudArrangement.dp()
	me.pitch = 1.3  # look up: the item on the ground leaves the bottom of the screen
	await frames(10)
	var cam := m.get_viewport().get_camera_3d()
	var p := m.get_viewport().get_final_transform().affine_inverse() * cam.unproject_position(prompt.target_world)
	assert_true(cam.is_position_behind(prompt.target_world) or not Rect2(Vector2.ZERO, view).has_point(p), "nonvacuous: off screen (%s)" % p)
	assert_true(prompt.visible and prompt.clamped, "shown, clamped")
	assert_true(absf(prompt.anchor.y - (view.y - margin)) < 1.0, "on the bottom edge (%s)" % prompt.anchor)
	assert_true(Rect2(Vector2.ZERO, view).encloses(prompt.get_global_rect()), "the prompt is fully on screen")
	me.pitch = 0.0
	await frames(4)
	# Behind the camera: a point behind and to the right of it clamps to the right edge.
	var behind := cam.global_position + cam.global_transform.basis.z * 3.0 + cam.global_transform.basis.x * 2.0
	assert_true(cam.is_position_behind(behind), "nonvacuous: behind the camera")
	prompt.screen_anchor(cam, behind, view, margin)
	assert_true(prompt.clamped, "behind: clamped")
	assert_true(absf(prompt.anchor.x - (view.x - margin)) < 1.0, "behind right: on the right edge (%s)" % prompt.anchor)
	var r := prompt.plate_rect(view)
	assert_true(Rect2(Vector2.ZERO, view).encloses(r), "behind: plate on screen %s" % r)
	await _cleanup()


## Tap target >= 48 dp and fully on screen on the six sizes at 420 and 373 dpi, for the longest text, anchored on screen
## (centre and corners) and clamped toward every side.
func test_tap_target_48dp_and_on_screen_on_all_sizes() -> void:
	var h1a: RefCounted = _H1a.new()
	h1a._begin()
	var longest := ""
	var loot_cfg := DataRegistry.new().load_file("res://data/loot.json")
	var texts: Dictionary = DataRegistry.new().load_file("res://data/ui.json")["interact_prompt"]["texts"]
	for id in loot_cfg["items"]:
		var t := str(texts["pickup"]) % str(loot_cfg["items"][id].get("display", id))
		if t.length() > longest.length():
			longest = t
	for t in texts.values():
		if str(t).length() > longest.length():
			longest = str(t)
	for dpi in DPIS:
		PlatformServices.dpi_override = dpi
		for sz in SIZES:
			var t_hud: Control = h1a._new_touch(sz)
			var p := InteractPrompt.new()
			_tree().root.add_child(p)
			p.touch_hud = t_hud
			p.kind = "pickup"
			p.text = longest
			p.label.text = longest
			p._text_px = -1.0
			var min_px: float = 48.0 * float(dpi) / 160.0 - 0.01
			for case in [[sz * 0.5, Vector2.ZERO], [Vector2(2, 2), Vector2.ZERO], [sz - Vector2(2, 2), Vector2.ZERO],
					[Vector2(0, sz.y * 0.5), Vector2.LEFT], [Vector2(sz.x, sz.y * 0.5), Vector2.RIGHT],
					[Vector2(sz.x * 0.5, 0), Vector2.UP], [Vector2(sz.x * 0.5, sz.y), Vector2.DOWN]]:
				p.anchor = case[0]
				p.clamped = case[1] != Vector2.ZERO
				p._dir = case[1]
				var r := p.plate_rect(sz)
				var tag := "%s dpi %d anchor %s dir %s: %s" % [sz, dpi, case[0], case[1], r]
				assert_true(r.size.x >= min_px and r.size.y >= min_px, "%s: at least 48 dp" % tag)
				assert_true(Rect2(Vector2.ZERO, sz).encloses(r), "%s: on screen" % tag)
			p.free()
			t_hud.free()
	h1a._end()
