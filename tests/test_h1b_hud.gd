extends "res://tests/test_case.gd"

## M2 H1b commit 1: the in-match HUD arrangement (scripts/ui/hud_arrangement.gd, data/ui.json hud_arrangement, minimap,
## radar, OQ-HUD / OQ-MINIMAP / OQ-RADAR). On the six test sizes at 420 and 373 dpi, in both placements: the passive
## displays (weapon block, objective strip, kill banner, alive / zone chip) are on screen, apart and clear of every touch
## target and the move stick; the reserved minimap / radar panel sits top right with its tap target in the right-edge
## strip, clear of the gear, Aim and Fire; passive displays ignore touches (a look drag and a stick press work through
## them); the block shows the pawn's slots, ammo and bars; the objective line follows its rule with wording from data;
## saved layouts at the current layout_version load unchanged.

const _TouchScene := preload("res://scenes/ui/touch_hud.tscn")
const _HudScene := preload("res://scenes/ui/hud.tscn")
const _TouchHud := preload("res://scripts/ui/touch_hud.gd")
const _H1a := preload("res://tests/test_h1a_layout.gd")
const SIZES := [Vector2(2520, 1080), Vector2(2176, 1812), Vector2(1512, 648), Vector2(1152, 959), Vector2(2340, 1080), Vector2(3120, 1440)]
const DPIS := [420.0, 373.0]
const PLACEMENTS := [HudArrangement.ABOVE_ROW, HudArrangement.SPLIT_ROW]
const TMP := "user://test_h1b_hud_profile.json"

var _h1a: RefCounted


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _begin() -> void:
	_h1a = _H1a.new()
	_h1a._begin()


func _end() -> void:
	HudArrangement.placement_override = ""
	_h1a._end()
	if FileAccess.file_exists(TMP):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP))


func _new_game(sz: Vector2) -> GameHud:
	var game: GameHud = _HudScene.instantiate()
	_tree().root.add_child(game)
	game.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	game.size = sz
	# Longest sample texts the other layout tests use, and every display shown.
	game.alive_label.text = "Squad VIII: XXXVIII   Squad II: XXIX"
	game.zone_label.text = "10:00"
	game.weapon_label.text = "Gladius Rifle   Armor 3"
	game.ammo_label.text = "120 / 360"
	game.objective_label.text = "Zone closes in 10:00"
	game.objective_label.visible = true
	game.show_banner(String(game._banner_cfg["kill_text"]), true)
	return game


## The passive displays as the real GameHud nodes place them.
func _passive(game: GameHud) -> Dictionary:
	return {"weapon_block": game.weapon_block.get_global_rect(), "objective": game.objective_label.get_global_rect(),
		"status": game.downed_label.get_global_rect(), "banner": game.banner_label.get_global_rect(),
		"chip": game.chip.get_global_rect()}


func test_default_placement_is_above_row_and_layout_version_kept() -> void:
	var ui := DataRegistry.new().load_file("res://data/ui.json")
	assert_eq(str(ui["hud_arrangement"]["placement"]), HudArrangement.ABOVE_ROW, "data default placement")
	assert_eq(HudArrangement.placement(), HudArrangement.ABOVE_ROW, "no override: data placement")
	assert_eq(HudLayoutModel.current_version(), 2, "above_row moves no button default: layout_version stays 2")
	assert_true(not bool(ui["hud"]["roman_numerals"]), "OQ-38: no Roman numerals")
	assert_true(not bool(ui["minimap"]["enabled"]) and not bool(ui["radar"]["enabled"]), "minimap and radar reserved, not drawn yet")


## split_row is used only where the view is wide enough; the near-square sizes keep above_row.
func test_split_row_only_on_wide_views() -> void:
	HudArrangement.placement_override = HudArrangement.SPLIT_ROW
	for sz in SIZES:
		var wide: bool = sz.x / sz.y >= 2.0
		assert_eq(HudArrangement.placement_for(sz), HudArrangement.SPLIT_ROW if wide else HudArrangement.ABOVE_ROW, "%s" % sz)
	HudArrangement.placement_override = HudArrangement.ABOVE_ROW
	for sz in SIZES:
		assert_eq(HudArrangement.placement_for(sz), HudArrangement.ABOVE_ROW, "above_row forced at %s" % sz)
	HudArrangement.placement_override = ""


func test_passive_displays_on_screen_apart_and_clear_of_touch_targets() -> void:
	_begin()
	for placement in PLACEMENTS:
		HudArrangement.placement_override = placement
		for dpi in DPIS:
			PlatformServices.dpi_override = dpi
			for sz in SIZES:
				for mode in ["advanced", "simple"]:
					for lf in [false, true]:
						AppFlow.profile = {"shooting_mode": mode, "left_fire_enabled": lf}
						var touch: Control = _h1a._new_touch(sz)
						var pm: PauseMenu = _h1a._pause(sz)
						var game := _new_game(sz)
						for cover in [false, true]:
							touch.set_cover_slot(cover, cover, false)
							touch.relayout()
							var tag := "%s %s dpi %d %s lf=%s cover=%s" % [HudArrangement.placement_for(sz), sz, dpi, mode, lf, cover]
							_check_state(touch, pm, game, sz, tag)
						game.free()
						pm.free()
						touch.free()
	_end()


func _check_state(touch: Control, pm: PauseMenu, game: GameHud, sz: Vector2, tag: String) -> void:
	var view := Rect2(Vector2.ZERO, sz)
	var passive := _passive(game)
	var ctrls: Dictionary = _h1a._controls(touch, pm, sz)
	ctrls["move_stick"] = touch.get_move_visual_rect()
	assert_true(passive["status"].is_equal_approx(passive["objective"]), "%s: the status text takes the objective strip" % tag)
	for part: Control in [game.shield_bar, game.health_bar, game.ammo_label, game.weapon_label]:
		assert_true(passive["weapon_block"].grow(0.5).encloses(part.get_global_rect()), "%s: %s %s inside the block %s" % [tag, part.name, part.get_global_rect(), passive["weapon_block"]])
	for i in 3:
		var sr: Rect2 = game.weapon_block.get_slot_rect(i)
		assert_true(Rect2(Vector2.ZERO, passive["weapon_block"].size).grow(0.5).encloses(sr), "%s: slot %d inside the block" % [tag, i])
	for part: Control in [game.alive_label, game.zone_label]:
		assert_true(passive["chip"].grow(0.5).encloses(part.get_global_rect()), "%s: %s inside the chip" % [tag, part.name])
	var names: Array = ["weapon_block", "objective", "banner", "chip"]
	for i in names.size():
		var r: Rect2 = passive[names[i]]
		assert_true(r.size.x > 0.0 and r.size.y > 0.0 and view.encloses(r), "%s: %s %s on screen" % [tag, names[i], r])
		for j in range(i + 1, names.size()):
			assert_true(not r.intersects(passive[names[j]]), "%s: %s %s overlaps %s %s" % [tag, names[i], r, names[j], passive[names[j]]])
		for key in ctrls:
			assert_true(not r.intersects(ctrls[key]), "%s: %s %s covers touch target %s %s" % [tag, names[i], r, key, ctrls[key]])
	# The reserved panel: on screen, top right, clear of the displays; the tap target is inside the minimap picture.
	var mm := HudArrangement.minimap_rect(sz)
	var radar := HudArrangement.radar_rect(sz)
	var tap := HudArrangement.minimap_tap_rect(sz)
	assert_true(view.encloses(mm) and view.encloses(radar), "%s: panel on screen %s %s" % [tag, radar, mm])
	assert_true(radar.end.x <= mm.position.x and mm.get_center().x > 0.5 * sz.x and mm.get_center().y < 0.5 * sz.y, "%s: radar left of the minimap, top right" % tag)
	assert_true(mm.encloses(tap), "%s: tap target %s inside the minimap %s" % [tag, tap, mm])
	for n in names:
		assert_true(not mm.intersects(passive[n]) and not radar.intersects(passive[n]), "%s: panel clear of %s" % [tag, n])
	var gear: Rect2 = ctrls["gear"]
	assert_true(not gear.intersects(mm) and not gear.intersects(radar), "%s: gear %s not under the panel" % [tag, gear])


## The gear, the reserved minimap tap target, Aim and Fire never overlap; the tap target is >= 48 dp, outside the look
## area, inside the right-edge strip (1512x648 at 420 dpi is the tight one).
func test_gear_minimap_tap_aim_fire_apart() -> void:
	_begin()
	for placement in PLACEMENTS:
		HudArrangement.placement_override = placement
		for dpi in DPIS:
			PlatformServices.dpi_override = dpi
			var dp := PlatformServices.new().get_dp_scale()
			for sz in SIZES:
				AppFlow.profile = {"shooting_mode": "advanced"}
				var touch: Control = _h1a._new_touch(sz)
				var pm: PauseMenu = _h1a._pause(sz)
				var tag := "%s dpi %d" % [sz, dpi]
				var r := {"gear": pm.get_gear_touch_rect(), "minimap_tap": HudArrangement.minimap_tap_rect(sz),
					"aim": touch.get_button_rect("aim"), "fire_right": touch.get_button_rect("fire_right")}
				var keys: Array = r.keys()
				for i in keys.size():
					for j in range(i + 1, keys.size()):
						assert_true(not (r[keys[i]] as Rect2).intersects(r[keys[j]]), "%s: %s %s overlaps %s %s" % [tag, keys[i], r[keys[i]], keys[j], r[keys[j]]])
				var tap: Rect2 = r["minimap_tap"]
				var look: Rect2 = touch.get_look_area_rect()
				assert_true(tap.size.x / dp >= 48.0 - 1e-3 and tap.size.y / dp >= 48.0 - 1e-3, "%s: tap %.1f dp >= 48" % [tag, tap.size.x / dp])
				assert_true(not tap.intersects(look) and tap.position.x >= look.end.x, "%s: tap %s in the right-edge strip, outside %s" % [tag, tap, look])
				assert_true(r["gear"].position.x >= look.end.x, "%s: gear in the right-edge strip" % tag)
				pm.free()
				touch.free()
	_end()


func _all_controls(n: Node, out: Array) -> void:
	if n is Control:
		out.append(n)
	for c in n.get_children():
		_all_controls(c, out)


func test_every_passive_node_ignores_touches() -> void:
	var game := _new_game(Vector2(2520, 1080))
	var nodes: Array = []
	for root: Node in [game.weapon_block, game.chip, game.objective_label, game.downed_label, game.banner_label]:
		_all_controls(root, nodes)
	assert_true(nodes.size() >= 12, "the displays and their children were found (%d)" % nodes.size())
	for c: Control in nodes:
		assert_eq(c.mouse_filter, Control.MOUSE_FILTER_IGNORE, "%s ignores the mouse and touches" % c.get_path())
	assert_eq(game.mouse_filter, Control.MOUSE_FILTER_IGNORE, "GameHud itself")
	game.free()


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


## With the touch HUD and the GameHud live (the GameHud added last, so it is on top), a press that starts on a passive
## display still reaches the touch HUD: in the left half it starts the move stick, in the right half a drag turns the view.
func test_touches_pass_through_passive_displays() -> void:
	_begin()
	for stick in ["virtual", "custom"]:
		_TouchHud.move_stick_override = stick
		for placement in PLACEMENTS:
			HudArrangement.placement_override = placement
			for sz in [Vector2(2520, 1080), Vector2(2176, 1812)]:
				PlatformServices.dpi_override = 420.0
				var touch: Control = _h1a._new_touch(sz)
				var game := _new_game(sz)
				await _tree().process_frame
				var passive := _passive(game)
				for n in ["weapon_block", "objective", "banner", "chip"]:
					var r: Rect2 = passive[n]
					for fx in [0.25, 0.75]:
						var p := r.position + r.size * Vector2(fx, 0.5)
						var tag := "%s %s %s %s at %s" % [stick, HudArrangement.placement_for(sz), sz, n, p]
						if p.x < 0.5 * sz.x:
							touch.provider.move_value = Vector2.ZERO
							_touch(4, p, true)
							_drag(4, p + Vector2(0, -120), Vector2(0, -120))
							touch._process(1.0 / 60.0)
							assert_true(touch.provider.move_value.y < 0.0, "%s: a stick press on it moves (%s)" % [tag, touch.provider.move_value])
							_touch(4, p + Vector2(0, -120), false)
						else:
							touch.provider.clear_look()
							_touch(4, p, true)
							_drag(4, p + Vector2(-80, 0), Vector2(-80, 0))
							assert_true(touch.provider.get_look() != Vector2.ZERO, "%s: a look drag on it turns the view" % tag)
							_touch(4, p + Vector2(-80, 0), false)
						touch._process(1.0 / 60.0)
				game.free()
				touch.free()
	_end()


func _pawn() -> Pawn:
	var pawn := Pawn.new()
	pawn.setup("hastati", 0)
	return pawn


func test_block_shows_slots_ammo_and_bars_of_the_pawn() -> void:
	var director := MatchDirector.new()
	var pawn := _pawn()
	var hud := GameHud.new()
	hud.bind(director, pawn)
	hud.refresh_pawn()
	var lo := pawn.loadout
	assert_eq(hud.weapon_block.slots.size(), lo.slots.size(), "one drawn slot per loadout slot")
	var filled := 0
	for i in lo.slots.size():
		var e: Dictionary = hud.weapon_block.slots[i]
		assert_eq(e["kind"], HudWeaponBlock.kind_of(lo.slots[i], i), "slot %d kind" % i)
		assert_eq(e["held"], i == lo.active and lo.slots[i] != null, "slot %d held mark" % i)
		filled += 1 if lo.slots[i] != null else 0
	assert_true(filled >= 2, "fixture: the class has at least two weapons (%d)" % filled)
	var w := lo.get_active()
	assert_eq(hud.ammo_label.text, "-" if w.def.is_melee() else "%d / %d" % [w.ammo_in_mag, w.reserve], "magazine / reserve of the held weapon")
	assert_eq(hud.weapon_label.text, w.def.display_name, "held weapon name")
	assert_eq(hud.health_bar.value, pawn.bridge.state.health, "health")
	assert_eq(hud.shield_bar.value, pawn.bridge.state.shield, "shield")
	assert_true(hud.ammo_label.get_parent() == hud.weapon_block and hud.health_bar.get_parent() == hud.weapon_block, "all in the one block")
	# Swap: the mark follows the held slot, the ammo follows the held weapon.
	var before := lo.active
	assert_true(lo.swap(), "swap")
	hud.refresh_pawn()
	assert_true(lo.active != before and hud.weapon_block.slots[lo.active]["held"] and not hud.weapon_block.slots[before]["held"], "mark moved to slot %d" % lo.active)
	w = lo.get_active()
	assert_eq(hud.ammo_label.text, "-" if w.def.is_melee() else "%d / %d" % [w.ammo_in_mag, w.reserve], "ammo of the new weapon")
	# A shot changes the magazine count shown.
	if not w.def.is_melee() and w.ammo_in_mag > 0:
		w.ammo_in_mag -= 1
		hud.refresh_pawn()
		assert_eq(hud.ammo_label.text, "%d / %d" % [w.ammo_in_mag, w.reserve], "magazine after a shot")
	pawn.bridge.state.health = maxf(pawn.bridge.state.health - 10.0, 1.0)
	hud.refresh_pawn()
	assert_eq(hud.health_bar.value, pawn.bridge.state.health, "health after damage")
	hud.free()
	pawn.free()
	director.free()


func _rules(zstate: String) -> BrRules:
	var r := BrRules.new()
	r._zstate = zstate
	r._center = Vector2.ZERO
	r._radius = 200.0
	r._phase = 0
	var circles: Array[Dictionary] = [{"center": Vector2(100, 0), "radius": 50.0}]
	r._circles = circles
	r._zleft = 83.0
	return r


func test_objective_line_follows_its_rule_with_data_wording() -> void:
	var texts: Dictionary = HudArrangement.cfg()["objective"]["texts"]
	var director := MatchDirector.new()
	var pawn := _pawn()
	var hud := GameHud.new()
	hud.bind(director, pawn)
	assert_eq(GameHud.objective_key_for(pawn, director), "", "no rules yet: no line")
	director.rules = _rules("waiting")
	pawn.position = Vector3(100, 0, 0)  # inside the next circle
	var cases := [
		["inside", func() -> void: pass],
		["zone_closes", func() -> void: pawn.position = Vector3(0, 0, 0)],
		["zone_closing", func() -> void: director.rules._zstate = "shrinking"],
		["outside", func() -> void: pawn.position = Vector3(0, 0, 250)],
		["final", func() -> void:
			pawn.position = Vector3(0, 0, 0)
			director.rules._zstate = "final"],
		["loot", func() -> void:
			for i in pawn.loadout.slots.size():
				if pawn.loadout.slots[i] != null and not pawn.loadout.slots[i].def.is_melee():
					pawn.loadout.slots[i] = null],
		["falling", func() -> void: pawn.drop_state = Pawn.Drop.FALLING],
		["drop", func() -> void: pawn.drop_state = Pawn.Drop.ABOARD],
	]
	for c in cases:
		(c[1] as Callable).call()
		hud.refresh_pawn()
		var key: String = c[0]
		assert_eq(GameHud.objective_key_for(pawn, director), key, "rule -> %s" % key)
		assert_eq(hud.objective_key, key, "HUD shows %s" % key)
		var want := String(texts[key])
		if key.begins_with("zone_"):
			want = want % "1:23"
		assert_eq(hud.objective_label.text, want, "%s wording from data" % key)
		assert_true(hud.objective_label.visible and not hud.downed_label.visible, "%s: objective shown, no status" % key)
	assert_true(hud.downed_label.text == "Jump to drop", "aboard: the status text is still set (tests and Simple read it)")
	# Downed and dead: no objective; the status (DOWNED, spectating) takes the strip.
	pawn.drop_state = Pawn.Drop.NONE
	pawn.life = Pawn.Life.DEAD
	hud.spectate_text = "Spectating Squad 2"
	hud.refresh_pawn()
	assert_eq(hud.objective_key, "", "dead: no objective")
	assert_true(not hud.objective_label.visible and hud.downed_label.visible and hud.downed_label.text == "Spectating Squad 2", "spectating text shown in the strip")
	hud.free()
	pawn.free()
	director.free()


## A saved layout at the current layout_version (no H1b keys in it: H1b adds no editor element) loads unchanged, and a
## saved position wins over the split_row default.
func test_saved_layout_at_current_version_loads_unchanged() -> void:
	_begin()
	var m := HudLayoutModel.new()
	m.set_pos(0, "swap_weapon", Vector2(0.4, 0.9))
	m.set_pos(0, "reload", Vector2(0.9, 0.95))
	m.set_size_pct(1, "aim", 120.0)
	var save := SaveService.new(TMP)
	var prof := SaveService.defaults()
	prof["hud_layouts"] = m.to_dict()
	save.save_profile(prof)
	var p := save.load_profile()
	assert_eq(JSON.stringify(p["hud_layouts"]), JSON.stringify(m.to_dict()), "loaded unchanged")
	assert_true(not p["layout_notice_pending"], "no reset notice")
	AppFlow.profile = p
	for placement in PLACEMENTS:
		HudArrangement.placement_override = placement
		var sz := Vector2(2520, 1080)
		var touch: Control = _h1a._new_touch(sz)
		var c: Vector2 = touch.get_button_rect("swap_weapon").get_center()
		assert_true(c.distance_to(Vector2(0.4, 0.9) * sz) < 1.0, "%s: the saved Swap position stands (%s)" % [placement, c])
		touch.free()
	_end()
