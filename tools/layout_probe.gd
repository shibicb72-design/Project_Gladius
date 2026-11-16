extends SceneTree
## M2 H1a: prints every in-match touch control's rect on every test size and dpi, the main look area and its share of
## the screen, the OLD (pre-H1a) rect of each control for comparison, and every overlap / off-screen / under-48-dp
## problem. Builds the real nodes the match uses (TouchHud, GameHud, PauseMenu, InteractButton rect, FireModeButton rect).
##   godot --headless --path . --log-file <log> --script res://tools/layout_probe.gd
## Options after `--`: --dpi=420,373 (default 420,373,160), --left_fire=1 (default both off and on).
## One PROBE_CTRL line per control, one PROBE_AREA line per size and dpi, PROBE_PROBLEM lines; exit 1 on a problem.

const SIZES := [Vector2(2520, 1080), Vector2(2176, 1812), Vector2(1512, 648), Vector2(1152, 959), Vector2(2340, 1080), Vector2(3120, 1440)]
const _TouchScene := preload("res://scenes/ui/touch_hud.tscn")
const _HudScene := preload("res://scenes/ui/hud.tscn")
const _PauseScene := preload("res://scenes/ui/pause_menu.tscn")

## The placement before M2 H1a (data at 69441fe), to print OLD -> NEW.
const OLD_LOOK_REST := Vector2(0.88, 0.78)
const OLD_OFFSETS := {"jump": [-0.6, -2.4], "swap_weapon": [-2.8, -1.25], "reload": [-2.8, -0.1], "aim": [-1.7, -1.25],
	"swap_shoulder": [-0.6, -3.5], "fire_right": [-1.65, -0.15]}
const OLD_LOCK := Vector2(0.56, 0.42)
const OLD_GEAR_MARGIN_DP := Vector2(8, 56)
const OLD_MODE_ANCHOR := Vector2(0.8, 0.04)
const OLD_INTERACT_OFFSET := Vector2(-5.0, -1.2)

var problems := 0


func _initialize() -> void:
	_run.call_deferred()


func _arg(key: String, def: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % key):
			return a.split("=", true, 1)[1]
	return def


func _fmt(r: Rect2, sz: Vector2, dp: float) -> String:
	if r.size == Vector2.ZERO:
		return "(none)"
	var c := r.get_center()
	return "[%d,%d %dx%d] c=(%.3f,%.3f) %.0fdp" % [r.position.x, r.position.y, r.size.x, r.size.y, c.x / sz.x, c.y / sz.y, r.size.x / dp]


func _sq(c: Vector2, side: float) -> Rect2:
	return Rect2(c - Vector2.ONE * side * 0.5, Vector2.ONE * side)


## Old rect of a control from the pre-H1a data (same formulas as the old code).
func _old_rect(key: String, sz: Vector2, dp: float, tl: Dictionary, ui: Dictionary) -> Rect2:
	var s := maxf(0.12 * sz.y, 48.0 * dp)
	var look := OLD_LOOK_REST * sz
	if OLD_OFFSETS.has(key):
		var o: Array = OLD_OFFSETS[key]
		return _sq(look + Vector2(o[0], o[1]) * s, s)
	match key:
		"sprint_lock":
			return _sq(OLD_LOCK * sz, maxf(0.12 * sz.y, 48.0 * dp))
		"fire_left":
			var lp: Array = tl["left_fire"]["pos"]
			return _sq(Vector2(lp[0], lp[1]) * sz, s)
		"gear":
			var side := 48.0 * dp
			return Rect2(Vector2(sz.x - OLD_GEAR_MARGIN_DP.x * dp - side, OLD_GEAR_MARGIN_DP.y * dp), Vector2.ONE * side)
		"fire_mode":
			var side := 48.0 * dp
			return Rect2(Vector2(OLD_MODE_ANCHOR.x * sz.x - 8.0 * dp - side, OLD_MODE_ANCHOR.y * sz.y + 20.0 * dp), Vector2.ONE * side)
		"interact":
			return _sq(look + OLD_INTERACT_OFFSET * s, s)
		"look_stick":
			var r := maxf(0.12 * sz.y, 24.0 * dp)
			return _sq(look, 2.0 * r)
	return Rect2()


func _run() -> void:
	var ui := DataRegistry.new().load_file("res://data/ui.json")
	var dpis: Array = []
	for d in _arg("dpi", "420,373,160").split(","):
		dpis.append(float(d))
	var lf_modes: Array = [false, true] if _arg("left_fire", "") == "" else [_arg("left_fire", "0") == "1"]
	var saved_profile := AppFlow.profile
	# M2 H1b: both HUD arrangements (--placement=above_row or split_row for one).
	var placements: Array = ["above_row", "split_row"] if _arg("placement", "") == "" else [_arg("placement", "")]
	for placement in placements:
		HudArrangement.placement_override = placement
		for dpi in dpis:
			PlatformServices.dpi_override = dpi
			var dp := PlatformServices.new().get_dp_scale()
			for sz in SIZES:
				for lf in lf_modes:
					AppFlow.profile = {"left_fire_enabled": lf, "shooting_mode": "advanced"}
					await _probe(sz, dpi, dp, lf, ui)
	HudArrangement.placement_override = ""
	AppFlow.profile = saved_profile
	PlatformServices.dpi_override = 0.0
	print("PROBE_DONE problems=%d" % problems)
	quit(1 if problems > 0 else 0)


func _probe(sz: Vector2, dpi: float, dp: float, lf: bool, ui: Dictionary) -> void:
	var touch: Control = _TouchScene.instantiate()
	root.add_child(touch)
	touch.cfg["force_touch_hud"] = true
	touch.refresh_visibility()
	touch.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	touch.size = sz
	touch.relayout()
	var game: GameHud = _HudScene.instantiate()
	root.add_child(game)
	game.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	game.size = sz
	game.alive_label.text = "Squad VIII: XXXVIII   Squad II: XXIX"
	game.zone_label.text = "10:00"
	game.downed_label.text = "DOWNED 0:24"
	game.weapon_label.text = "Gladius Rifle"
	game.ammo_label.text = "120 / 360"
	var pm: PauseMenu = _PauseScene.instantiate()
	root.add_child(pm)
	pm.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	pm.size = sz
	await process_frame
	await process_frame
	var tl: Dictionary = touch.cfg["touch_layout"]
	var ctrls := {"move_stick": touch.get_move_visual_rect(), "sprint_lock": touch.get_lock_button_rect(),
		"lock_target": touch.get_lock_target_rect(), "gear": pm.get_gear_touch_rect(),
		"fire_mode": FireModeButton.touch_rect(ui["fire_mode_button"], sz)}
	for key in touch.get_button_actions():
		ctrls[key] = touch.get_button_rect(key)
	var interact := InteractButton.new()
	interact.cfg = ui["interact_button"]
	interact.touch_hud = touch
	ctrls["interact"] = interact.get_touch_rect()
	interact.free()
	ctrls["minimap_tap"] = HudArrangement.minimap_tap_rect(sz)  # M2 H1b: the reserved minimap's touch target
	var look: Rect2 = touch.get_look_area_rect()
	var view := Rect2(Vector2.ZERO, sz)
	var tag := "%dx%d dpi=%d left_fire=%s %s(%s)" % [sz.x, sz.y, dpi, lf, HudArrangement.placement(), HudArrangement.placement_for(sz)]
	print("PROBE_AREA %s look_area=[%d,%d %dx%d] = %.1f%% of screen (%.1f%% of the right half) button=%.0fpx" % [tag,
		look.position.x, look.position.y, look.size.x, look.size.y, 100.0 * look.get_area() / view.get_area(),
		200.0 * look.get_area() / view.get_area(), touch._button_size()])
	for key in ctrls:
		var r: Rect2 = ctrls[key]
		print("PROBE_CTRL %s %-14s OLD %s -> NEW %s" % [tag, key, _fmt(_old_rect(key, sz, dp, tl, ui), sz, dp), _fmt(r, sz, dp)])
	var hud_rects := {}
	for n in ["shield_bar", "health_bar", "weapon_label", "ammo_label", "alive_label", "zone_label", "downed_label"]:
		hud_rects[n] = (game.get(n) as Control).get_global_rect()
		print("PROBE_HUD %s %-14s %s" % [tag, n, _fmt(hud_rects[n], sz, dp)])
	# M2 H1b: the passive displays (and the reserved, not yet drawn, radar / minimap pictures).
	var passive := {"weapon_block": game.weapon_block.get_global_rect(), "chip": game.chip.get_global_rect(),
		"objective": game.objective_label.get_global_rect(), "banner": game.banner_label.get_global_rect(),
		"radar": HudArrangement.radar_rect(sz), "minimap": HudArrangement.minimap_rect(sz)}
	var move_vis: Rect2 = touch.get_move_visual_rect()
	for n in passive:
		print("PROBE_PASSIVE %s %-14s %s" % [tag, n, _fmt(passive[n], sz, dp)])
		if not view.encloses(passive[n]):
			_problem("%s passive %s off-screen %s" % [tag, n, passive[n]])
		if passive[n].intersects(move_vis):
			_problem("%s passive %s %s covers the move stick %s" % [tag, n, passive[n], move_vis])
	var pnames: Array = passive.keys()
	for i in pnames.size():
		for j in range(i + 1, pnames.size()):
			if passive[pnames[i]].intersects(passive[pnames[j]]):
				_problem("%s passive %s overlaps passive %s" % [tag, pnames[i], pnames[j]])
	for n in ["weapon_block", "chip", "objective", "banner"]:
		hud_rects[n] = passive[n]
	var names: Array = ctrls.keys()
	for i in names.size():
		var a: Rect2 = ctrls[names[i]]
		if not view.encloses(a):
			_problem("%s %s off-screen %s" % [tag, names[i], a])
		if a.size.x / dp < 48.0 - 1e-3:
			_problem("%s %s %.1f dp < 48" % [tag, names[i], a.size.x / dp])
		if a.intersects(look):
			_problem("%s %s %s in the look area %s" % [tag, names[i], a, look])
		for j in range(i + 1, names.size()):
			if a.intersects(ctrls[names[j]]):
				_problem("%s %s %s overlaps %s %s" % [tag, names[i], a, names[j], ctrls[names[j]]])
		for h in hud_rects:
			if a.intersects(hud_rects[h]):
				_problem("%s %s %s overlaps HUD %s %s" % [tag, names[i], a, h, hud_rects[h]])
	pm.free()
	game.free()
	touch.free()


func _problem(text: String) -> void:
	problems += 1
	print("PROBE_PROBLEM ", text)
