extends Node
## M2 H1b: desktop-render proof of the in-match HUD. Run windowed (needs a display), ONE process:
##   godot.cmd --path . --log-file <log> res://tools/h1b_capture.tscn -- --out=<dir> [--kinds=a,b] [--sizes=2176x1812,...]
## For each size it renders a real local match with the touch HUD forced on inside a SubViewport and saves, per shot kind
## (KINDS, in order), <kind>_<WxH>.png into <dir>, then sheet_<WxH>.png (every shot of that size in a 3-column grid).
## Shot kinds of commit 1 (the HUD arrangement):
##   above_advanced / above_simple   placement "above_row", shooting mode Advanced / Simple
##   split_advanced / split_simple   placement "split_row" (a near-square size has no room for it and shows above_row;
##                                   the log line says which placement was used)
##   cover                           above_row, the pawn in real cover (Cover button pressed through the touch HUD)
##   overlay                         above_row with the look area, the stick start zone (left half), every touch target,
##                                   the passive displays and the reserved minimap / radar panel outlined
## Shot kinds of commit 2 (PROMPT_KINDS, the prompt at the object, in a second match per size; sheet_prompt_<WxH>.png):
##   prompt_pickup, prompt_chest, prompt_door_open, prompt_door_close, prompt_revive (a downed squad mate) and
##   prompt_offscreen (a gun beside the pawn, outside the view: the prompt clamps to the edge with an arrow)
## Later commits add kinds by adding a KINDS entry and a _shot_<kind>(ctx) method (prompts, minimap, radar, coach).
## In the match shots the local kill banner is shown on purpose (show_banner) so its place can be judged; the objective
## line and the chip show the real match state. Placement and shooting mode are set in memory only and restored.
## Presentation only: nothing here feeds back into the game.

const _MatchScene := preload("res://scenes/match/match.tscn")
const _TouchHud := preload("res://scripts/ui/touch_hud.gd")
const DEFAULT_SIZES: Array = [Vector2i(2176, 1812), Vector2i(2520, 1080), Vector2i(3120, 1440)]
const KINDS: Array = ["above_advanced", "above_simple", "split_advanced", "split_simple", "overlay", "cover"]
## Commit 2 (prompts at the object): shot in a second match per size (squads, idle bots, ground loot), saved as
## prompt_<kind>_<WxH>.png and put on their own sheet, sheet_prompt_<WxH>.png. The commit-1 kinds and sheet are unchanged.
const PROMPT_KINDS: Array = ["prompt_pickup", "prompt_chest", "prompt_door_open", "prompt_door_close", "prompt_revive", "prompt_offscreen"]
## Commit 3 (the minimap): shot in a third match per size ON alesia_1km (squads, idle bots), the local pawn placed 45 m
## inside the current circle and 35 m outside the next one with a squad mate beside it, so both circles, the line and the
## mate are in the small view; saved as minimap_<kind>_<WxH>.png, sheet_minimap_<WxH>.png. minimap_zoom is no render: the
## panels of the rotating and the north-up shots cropped and enlarged side by side, to judge the small view.
## Each baked texture is also copied to minimap_tex_<map>.png.
const MINIMAP_KINDS: Array = ["minimap_small_rotate", "minimap_small_north", "minimap_expanded", "minimap_zoom"]
const MINIMAP_MAP := "res://data/maps/alesia_1km.json"
## Commit 4 (the radar): shot in a fourth match per size, set up as the minimap match (alesia_1km, squads, idle bots,
## the same player place), with enemy bots moved to several bearings and distances inside 25 m (and one at 31 m, which
## must not show) and one squad mate 12 m behind-right; saved as radar_<kind>_<WxH>.png, sheet_radar_<WxH>.png.
##   radar_blips  the whole HUD with the blips
##   radar_cover  no render of its own: the panel cropped and enlarged twice side by side, LEFT the scene with one enemy
##                standing (shown), RIGHT the same enemy in the cover crouch (hidden). The cover state is set through
##                the enable_cover test seam (bots never take cover in M2), as tests/test_h1b_radar.gd does.
##   panel_zoom   no render: the whole radar + minimap panel of radar_blips cropped and enlarged
const RADAR_KINDS: Array = ["radar_blips", "radar_cover", "panel_zoom"]
## Commit 5 (the first-play coach): shot in a fifth match per size, set up as the prompt match (squads, idle bots, ground
## loot). The coach never shows in a match here by itself (no AppFlow.coach_route); these kinds build one on purpose,
## after the radar as GameHud does, saving to a scratch profile (never the player's), and force each step into view:
## coach_<step>_<WxH>.png (fire twice: coach_fire_advanced / coach_fire_simple; pick up with a gun dropped in reach), and
## editor_<WxH>.png (the HUD layout editor with the fixed elements); sheet_coach_<WxH>.png.
const COACH_KINDS: Array = ["coach_move", "coach_look", "coach_aim", "coach_fire_advanced", "coach_fire_simple", "coach_cover",
	"coach_pickup", "coach_map", "editor"]
const COACH_PROFILE := "user://h1b_capture_coach_profile.json"
## Radar layout around the player, relative to its heading: [right m, ahead m]. The last is out of range.
const RADAR_ENEMIES: Array = [Vector2(0, 9), Vector2(11, 12), Vector2(-15, -14), Vector2(-23, 3), Vector2(16, -6), Vector2(0, -31)]
const RADAR_MATE := Vector2(9, -8)
const DPI := 420.0
const SHEET_CELL_W := 900
const ARENA_X := 1000.0

var _out: String = "build/shots"
var _kinds: Array = KINDS + PROMPT_KINDS + MINIMAP_KINDS + RADAR_KINDS + COACH_KINDS
var _sizes: Array = DEFAULT_SIZES


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--kinds="):
			_kinds = Array(a.substr(8).split(","))
		elif a.begins_with("--sizes="):
			_sizes = []
			for s in a.substr(8).split(","):
				var wh := s.split("x")
				_sizes.append(Vector2i(int(wh[0]), int(wh[1])))
	if not _out.is_absolute_path():
		_out = ProjectSettings.globalize_path("res://").path_join(_out)
	DirAccess.make_dir_recursive_absolute(_out)
	_run.call_deferred()


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame
	await get_tree().process_frame
	await get_tree().process_frame


func _tag(size: Vector2i) -> String:
	return "%dx%d" % [size.x, size.y]


func _run() -> void:
	var failed := 0
	var saved_profile: Dictionary = AppFlow.profile
	var saved_dpi: float = PlatformServices.dpi_override
	PlatformServices.dpi_override = DPI
	_TouchHud.move_stick_override = "custom"
	var c1: Array = _kinds.filter(func(k: String) -> bool: return not PROMPT_KINDS.has(k) and not MINIMAP_KINDS.has(k) and not RADAR_KINDS.has(k) and not COACH_KINDS.has(k))
	var c2: Array = _kinds.filter(func(k: String) -> bool: return PROMPT_KINDS.has(k))
	var c3: Array = _kinds.filter(func(k: String) -> bool: return MINIMAP_KINDS.has(k))
	var c4: Array = _kinds.filter(func(k: String) -> bool: return RADAR_KINDS.has(k))
	var c5: Array = _kinds.filter(func(k: String) -> bool: return COACH_KINDS.has(k))
	AppFlow.coach_route = false  # never the real-match flag here: the coach kinds build their coach on purpose
	for size in _sizes:
		for group in [[c1, "sheet", false, false], [c2, "sheet_prompt", true, false], [c3, "sheet_minimap", false, true], [c4, "sheet_radar", false, true],
				[c5, "sheet_coach", true, false]]:
			if (group[0] as Array).is_empty():
				continue
			AppFlow.profile = {}
			var done: Array = await _match_shots(size, group[0], group[2], group[3])
			if done.size() != (group[0] as Array).size():
				failed += 1
			if done.is_empty() or not _sheet(size, done, group[1]):
				failed += 1
	if not c3.is_empty() and not _copy_minimap_textures():
		failed += 1
	AppFlow.profile = saved_profile
	if FileAccess.file_exists(COACH_PROFILE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(COACH_PROFILE))
	PlatformServices.dpi_override = saved_dpi
	HudArrangement.placement_override = ""
	_TouchHud.move_stick_override = ""
	print("[h1b_capture] done failed=%d" % failed)
	get_tree().quit(1 if failed > 0 else 0)


func _save(svp: SubViewport, name: String) -> bool:
	await RenderingServer.frame_post_draw
	var err := svp.get_texture().get_image().save_png(_out.path_join("%s.png" % name))
	print("[h1b_capture] %s %s -> %s" % [name, str(svp.size), error_string(err)])
	return err == OK


func _tap(svp: SubViewport, point: Vector2, down: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = 5
	e.position = point
	e.pressed = down
	svp.push_input(e, true)


func _box(m: Node, at: Vector3, size: Vector3, color: Color, tagged: bool) -> void:
	var body := StaticBody3D.new()
	body.position = at
	var shape := CollisionShape3D.new()
	shape.name = "Shape"
	var b := BoxShape3D.new()
	b.size = size
	shape.shape = b
	body.add_child(shape)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 0.35
	mi.material_override = mat
	body.add_child(mi)
	if tagged:
		body.add_to_group(&"cover_wall")
	m.add_child(body)


## Outlines drawn on top of the HUD; capture only. Look area green, stick start zone blue, touch targets yellow,
## passive displays cyan, the reserved panel magenta.
class Overlay extends Control:
	var look := Rect2()
	var stick_zone := Rect2()
	var targets: Dictionary = {}
	var passive: Dictionary = {}
	var radar := Rect2()
	var minimap := Rect2()

	func _label(at: Vector2, text: String, c: Color) -> void:
		draw_string(ThemeDB.fallback_font, at + Vector2(6, 24), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 20, c)

	func _draw() -> void:
		draw_rect(stick_zone, Color(0.2, 0.45, 1.0, 0.16), true)
		draw_rect(stick_zone, Color(0.3, 0.55, 1.0, 0.9), false, 4.0)
		_label(stick_zone.position + Vector2(0, stick_zone.size.y * 0.5), "stick start zone", Color(0.5, 0.7, 1.0))
		draw_rect(look, Color(0.1, 0.8, 0.3, 0.22), true)
		draw_rect(look, Color(0.1, 1.0, 0.3, 0.9), false, 4.0)
		_label(look.position + Vector2(0, look.size.y * 0.5), "look area", Color(0.3, 1.0, 0.4))
		var magenta := Color(1.0, 0.3, 0.9, 0.95)
		draw_arc(radar.get_center(), radar.size.x * 0.5, 0.0, TAU, 64, magenta, 3.0, true)
		draw_rect(minimap, magenta, false, 3.0)
		_label(radar.position, "radar (passive)", magenta)
		_label(minimap.position + Vector2(0, minimap.size.y - 30), "minimap", magenta)
		for k in passive:
			draw_rect(passive[k], Color(0.2, 0.95, 1.0, 0.95), false, 3.0)
			_label(Rect2(passive[k]).position, String(k), Color(0.4, 1.0, 1.0))
		for k in targets:
			var r: Rect2 = targets[k]
			draw_rect(r, Color(1.0, 0.85, 0.1, 0.95), false, 3.0)
			_label(r.position, String(k), Color(1, 1, 0.3))


## One match per size; every requested kind is shot from it. Returns the kinds saved (empty = the match failed).
## `prompts`: the commit-2 match (squads with idle bots, so a squad mate can be downed; ground loot on).
func _match_shots(size: Vector2i, kinds: Array, prompts: bool = false, minimap: bool = false) -> Array:
	var tag := _tag(size)
	var svp := SubViewport.new()
	svp.size = size
	svp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(svp)
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.fill_bots = prompts or minimap
	if prompts:
		m.ground_loot = true
		m.seed_override = 31337
	if minimap:
		m.map_path_override = MINIMAP_MAP
		m.seed_override = 4242
	svp.add_child(m)
	await get_tree().physics_frame
	if minimap:
		m.director.load_config(MINIMAP_MAP)  # the 1 km map's own overrides (play circle, zone schedule)
	else:
		m.director.load_config()
	if prompts or minimap:
		m.director.mode_cfg["teams"]["mode"]["value"] = "squads"
	if not m.begin():
		push_error("[h1b_capture] match did not start")
		return []
	if prompts or minimap:
		for b in m.bots:
			var brain := b.get_node_or_null("Brain")
			if brain != null:
				brain.set_physics_process(false)
	await _frames(25)
	var touch: Control = m.get_node("Hud/TouchHud")
	touch.cfg["force_touch_hud"] = true
	touch.refresh_visibility()
	await _frames(5)
	var ctx := {"svp": svp, "m": m, "touch": touch, "game": m.get_node("Hud/GameHud"), "pm": m.get_node("Hud/PauseMenu"),
		"size": Vector2(size), "tag": tag}
	var done: Array = []
	for kind in kinds:
		if not has_method("_shot_" + kind):
			push_error("[h1b_capture] unknown shot kind %s" % kind)
			continue
		var ok: bool = await call("_shot_" + kind, ctx)
		if ok:
			done.append(kind)
	svp.queue_free()
	await _frames(2)
	return done


## Applies a placement and shooting mode to the live HUD (in memory only).
func _setup(ctx: Dictionary, placement: String, mode: String) -> void:
	HudArrangement.placement_override = placement
	AppFlow.profile = {"shooting_mode": mode}
	var touch: Control = ctx["touch"]
	touch.refresh_shooting_mode()
	touch.relayout()
	(ctx["game"] as GameHud)._arrange()
	# The fire-mode label re-places only on resize; the placement changes here at runtime (never in a match).
	var fm: FireModeButton = (ctx["game"] as GameHud).fire_mode_button
	if is_instance_valid(fm):
		fm._place()
	await _frames(4)
	(ctx["game"] as GameHud).show_banner(String((ctx["game"] as GameHud)._banner_cfg["kill_text"]), true)
	await _frames(2)
	print("[h1b_capture] %s placement=%s used=%s mode=%s objective=%s buttons=%s" % [ctx["tag"], placement,
		HudArrangement.placement_for(ctx["size"]), mode, (ctx["game"] as GameHud).objective_key, str(touch.get_button_actions())])


func _shot_above_advanced(ctx: Dictionary) -> bool:
	await _setup(ctx, HudArrangement.ABOVE_ROW, "advanced")
	return await _save(ctx["svp"], "above_advanced_" + ctx["tag"])


func _shot_above_simple(ctx: Dictionary) -> bool:
	await _setup(ctx, HudArrangement.ABOVE_ROW, "simple")
	return await _save(ctx["svp"], "above_simple_" + ctx["tag"])


func _shot_split_advanced(ctx: Dictionary) -> bool:
	await _setup(ctx, HudArrangement.SPLIT_ROW, "advanced")
	return await _save(ctx["svp"], "split_advanced_" + ctx["tag"])


func _shot_split_simple(ctx: Dictionary) -> bool:
	await _setup(ctx, HudArrangement.SPLIT_ROW, "simple")
	return await _save(ctx["svp"], "split_simple_" + ctx["tag"])


func _shot_overlay(ctx: Dictionary) -> bool:
	await _setup(ctx, HudArrangement.ABOVE_ROW, "advanced")
	var touch: Control = ctx["touch"]
	var game: GameHud = ctx["game"]
	var sz: Vector2 = ctx["size"]
	var ui := DataRegistry.new().load_file("res://data/ui.json")
	var ov := Overlay.new()
	ov.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ov.set_anchors_preset(Control.PRESET_FULL_RECT)
	ov.look = touch.get_look_area_rect()
	ov.stick_zone = touch._zone_hit_rect("move_zone")
	for k in touch.get_element_keys():
		var r: Rect2 = touch.get_element_rect(k)
		if r.size != Vector2.ZERO and k != "move_stick":
			ov.targets[k] = r
	ov.targets["move_stick (rest)"] = touch.get_move_visual_rect()
	ov.targets["gear"] = (ctx["pm"] as PauseMenu).get_gear_touch_rect()
	ov.targets["fire_mode"] = FireModeButton.touch_rect(ui["fire_mode_button"], sz)
	var interact := InteractButton.new()
	interact.cfg = ui["interact_button"]
	interact.touch_hud = touch
	ov.targets["interact"] = interact.get_touch_rect()
	interact.free()
	ov.targets["minimap tap"] = HudArrangement.minimap_tap_rect(sz)
	ov.passive = {"weapon block": game.weapon_block.get_global_rect(), "chip": game.chip.get_global_rect(),
		"objective": game.objective_label.get_global_rect(), "banner": game.banner_label.get_global_rect()}
	ov.radar = HudArrangement.radar_rect(sz)
	ov.minimap = HudArrangement.minimap_rect(sz)
	(ctx["svp"] as SubViewport).add_child(ov)
	await _frames(2)
	var ok := await _save(ctx["svp"], "overlay_" + ctx["tag"])
	ov.queue_free()
	return ok


## Real cover: a wall in a flat arena far from the map, the Cover button pressed through the touch HUD (as H1a).
func _shot_cover(ctx: Dictionary) -> bool:
	await _setup(ctx, HudArrangement.ABOVE_ROW, "advanced")
	var m: MatchRoot = ctx["m"]
	var touch: Control = ctx["touch"]
	var svp: SubViewport = ctx["svp"]
	var pawn: Pawn = m.local_player
	_box(m, Vector3(ARENA_X, -0.1, 0), Vector3(160, 0.2, 80), Color(0.42, 0.45, 0.36), false)
	_box(m, Vector3(ARENA_X, 1.1, -0.5), Vector3(6, 2.2, 1), Color(0.62, 0.5, 0.38), true)
	_box(m, Vector3(ARENA_X + 14.0, 0.9, -6.0), Vector3(0.6, 1.8, 0.6), Color(0.8, 0.2, 0.18), false)
	var cfg := DataRegistry.new().load_file("res://data/cover.json")
	pawn.position = Vector3(ARENA_X, 0, 0.6)
	pawn.rotation = Vector3.ZERO
	pawn.pitch = 0.0
	pawn.velocity = Vector3.ZERO
	pawn.enable_cover(cfg)
	await _frames(40)
	var w := pawn.loadout.get_active()
	if w != null and w.def.is_melee():
		pawn.loadout.swap()
	var p: Vector2 = touch.get_button_rect(touch.SHOULDER_KEY).get_center()
	_tap(svp, p, true)
	await _frames(2)
	_tap(svp, p, false)
	var settled := false
	for i in 200:
		await get_tree().physics_frame
		if pawn.cover.state == CoverController.State.IN_COVER and not pawn.is_cover_turning():
			settled = true
			break
	await _frames(30)
	print("[h1b_capture] cover state=%s settled=%s" % [CoverController.State.keys()[pawn.cover.state], settled])
	return await _save(svp, "cover_" + ctx["tag"]) and settled


# --- commit 2: prompts at the object ------------------------------------------------------------------------------

## Clears what the previous prompt shot placed (props lifted away, loot near the pawn taken, the downed mate sent off),
## above_row / Advanced, level view.
func _prompt_prep(ctx: Dictionary) -> void:
	HudArrangement.placement_override = HudArrangement.ABOVE_ROW
	AppFlow.profile = {"shooting_mode": "advanced"}
	var touch: Control = ctx["touch"]
	touch.refresh_shooting_mode()
	touch.relayout()
	(ctx["game"] as GameHud)._arrange()
	var m: MatchRoot = ctx["m"]
	var pawn: Pawn = m.local_player
	for n: Node3D in ctx.get("placed", []):
		n.position.y += 1000.0
	ctx["placed"] = []
	for id in m.loot.items.keys():
		var p: Vector3 = m.loot.items[id]["pos"]
		if Vector2(p.x - pawn.global_position.x, p.z - pawn.global_position.z).length() < 10.0:
			m.loot.take(id)
	# Idle bots still pick up loot and open chests through the director (_bot_pickups / _bot_chests): keep them away.
	var k := 0
	for b: Pawn in m.bots:
		if b.global_position.distance_to(pawn.global_position) < 30.0:
			b.global_position = pawn.global_position + Vector3(40.0 + 3.0 * k, 0.0, 40.0)
			k += 1
	pawn.pitch = 0.0
	pawn.apply_start_kit({"secondary": "gladius_lux"})  # empty gun slot: a dropped gun is a usable pickup
	await _frames(3)


## A point `side_m` right of and `ahead_m` in front of the local pawn, `up_m` above its feet.
func _rel(ctx: Dictionary, side_m: float, ahead_m: float, up_m: float) -> Vector3:
	var pawn: Pawn = (ctx["m"] as MatchRoot).local_player
	var b := pawn.global_transform.basis
	return pawn.global_position + b.x * side_m - b.z * ahead_m + Vector3(0.0, up_m, 0.0)


func _prompt_save(ctx: Dictionary, kind: String) -> bool:
	await _frames(4)
	var prompt: InteractPrompt = (ctx["game"] as GameHud).interact_prompt
	var interact: InteractButton = (ctx["game"] as GameHud).interact_button
	print("[h1b_capture] %s %s visible=%s button_visible=%s kind=%s text=\"%s\" anchor=%s clamped=%s rect=%s button=\"%s\"" % [ctx["tag"], kind,
		prompt.visible, interact.visible, prompt.kind, prompt.text, prompt.anchor, prompt.clamped, prompt.get_global_rect(),
		interact.label.text.replace("\n", " ")])
	var ok: bool = await _save(ctx["svp"], "%s_%s" % [kind, ctx["tag"]])
	return ok and prompt.visible


func _drop_gun(ctx: Dictionary, at: Vector3) -> void:
	(ctx["m"] as MatchRoot).loot.drop({"item_id": "pilum_br"}, at)


func _add_chest(ctx: Dictionary, at: Vector3) -> void:
	var m: MatchRoot = ctx["m"]
	var c := LootChest.make({"id": "Chest_cap", "at": [at.x, at.y, at.z], "size": [1.4, 0.9, 0.9], "yaw": rad_to_deg(m.local_player.global_rotation.y)}, "camp")
	m.map.add_child(c)
	m.world_props.register_chest(c)
	_box(m, at, Vector3(1.4, 0.9, 0.9), Color(0.55, 0.36, 0.2), false)  # a visible stand-in: the chest look lives in the map chunks
	(ctx["placed"] as Array).append(c)
	(ctx["placed"] as Array).append(m.get_child(m.get_child_count() - 1))


func _add_door(ctx: Dictionary, id: String, start: String) -> void:
	var m: MatchRoot = ctx["m"]
	var at := _rel(ctx, 0.0, 1.6, 1.15)
	var entry := {"id": id, "kind": Door.KIND_DOOR, "at": [at.x, at.y, at.z], "yaw": rad_to_deg(m.local_player.global_rotation.y),
		"size": [2.0, 2.3, 0.12], "slide": "right", "start": start}
	var d := Door.make(entry, WorldProps.door_cfg(WorldProps.config(), Door.KIND_DOOR))
	m.map.add_child(d)
	m.world_props.register_door(d)
	(ctx["placed"] as Array).append(d)


func _shot_prompt_pickup(ctx: Dictionary) -> bool:
	await _prompt_prep(ctx)
	_drop_gun(ctx, _rel(ctx, 0.5, 1.4, 0.15))
	return await _prompt_save(ctx, "prompt_pickup")


func _shot_prompt_chest(ctx: Dictionary) -> bool:
	await _prompt_prep(ctx)
	_add_chest(ctx, _rel(ctx, 0.9, 1.6, 0.45))
	return await _prompt_save(ctx, "prompt_chest")


func _shot_prompt_door_open(ctx: Dictionary) -> bool:
	await _prompt_prep(ctx)
	_add_door(ctx, "Door_cap_a", "closed")
	return await _prompt_save(ctx, "prompt_door_open")


func _shot_prompt_door_close(ctx: Dictionary) -> bool:
	await _prompt_prep(ctx)
	_add_door(ctx, "Door_cap_b", "open")
	await _frames(30)  # the leaves slide into the wall
	return await _prompt_save(ctx, "prompt_door_close")


func _shot_prompt_revive(ctx: Dictionary) -> bool:
	await _prompt_prep(ctx)
	var m: MatchRoot = ctx["m"]
	var me := m.local_player
	var mate: Pawn = null
	var enemy: Pawn = null
	for id in m.director.all_players():
		var p: Pawn = m.director.player(id)
		if p == me:
			continue
		if p.squad_id == me.squad_id and mate == null:
			mate = p
		elif p.squad_id != me.squad_id and enemy == null:
			enemy = p
	if mate == null or enemy == null:
		push_error("[h1b_capture] no squad mate / enemy for the revive shot")
		return false
	ctx["mate"] = mate
	mate.global_position = _rel(ctx, -0.6, 1.8, 0.0)
	mate.bridge.state.shield = 0.0
	mate.bridge.state.health = 1.0
	mate.receive_hit(DataRegistry.new().get_weapon_def("sagittarii_rifle"), false, enemy.squad_id, enemy.player_id)
	await _frames(20)
	return await _prompt_save(ctx, "prompt_revive")


## Off screen: a gun 1.6 m to the pawn's right (outside the first-person view) clamps to the right edge with an arrow.
func _shot_prompt_offscreen(ctx: Dictionary) -> bool:
	await _prompt_prep(ctx)
	_drop_gun(ctx, _rel(ctx, 1.6, -0.2, 0.15))
	var ok: bool = await _prompt_save(ctx, "prompt_offscreen")
	return ok and (ctx["game"] as GameHud).interact_prompt.clamped


# --- commit 3: the minimap ----------------------------------------------------------------------------------------

## A ground point `d1` from c and `d2` from cn (the two circles' crossing), else on the line between them.
static func _between(c: Vector2, d1: float, cn: Vector2, d2: float) -> Vector2:
	var v := cn - c
	var dist := v.length()
	if dist < 1e-3:
		return c + Vector2(0.6, -0.8) * minf(d1, d2)
	var a := (d1 * d1 - d2 * d2 + dist * dist) / (2.0 * dist)
	var h2 := d1 * d1 - a * a
	var dir := v / dist
	if h2 < 0.0:
		return c + dir * clampf(a, 0.0, d1)
	return c + dir * a + Vector2(-dir.y, dir.x) * sqrt(h2)


## Once per match: the local pawn 45 m inside the current circle and 35 m outside the next one (both circles and the
## line in the small view), facing yaw 0.6, a squad mate 34 m away; above_row, the minimap closed.
func _minimap_prep(ctx: Dictionary) -> void:
	HudArrangement.placement_override = HudArrangement.ABOVE_ROW
	var m: MatchRoot = ctx["m"]
	var me := m.local_player
	var mm: HudMinimap = (ctx["game"] as GameHud).minimap
	if mm.expanded:
		mm.set_expanded(false)
	if not ctx.has("mm_placed"):
		var rules := m.director.rules
		var p := _between(rules.zone_center(), rules.zone_radius() - 45.0, rules.zone_target_center(), rules.zone_target_radius() + 35.0)
		var terrain := MapTerrain.for_map(m.map_def)
		var ground := func(q: Vector2) -> float: return terrain.height_at(q.x, q.y) if terrain != null else 0.0
		me.global_position = Vector3(p.x, ground.call(p) + 0.05, p.y)
		me.rotation.y = 0.6
		var mate: Pawn = null
		for id in m.director.all_players():
			var o: Pawn = m.director.player(id)
			if o != me and o.squad_id == me.squad_id:
				mate = o
				break
		if mate != null:
			var q := p + Vector2(-26.0, 22.0)
			mate.global_position = Vector3(q.x, ground.call(q) + 0.05, q.y)
		print("[h1b_capture] %s minimap prep: map=%s player=(%.1f, %.1f) circle c=%s r=%.0f next c=%s r=%.0f mate=%s" % [ctx["tag"], mm.map_id, p.x, p.y,
			rules.zone_center(), rules.zone_radius(), rules.zone_target_center(), rules.zone_target_radius(), mate != null])
		ctx["mm_placed"] = true
	await _frames(6)


func _minimap_save(ctx: Dictionary, kind: String) -> bool:
	await _frames(8)  # at least one overlay update (update_hz) after the change
	var mm: HudMinimap = (ctx["game"] as GameHud).minimap
	var kinds := {}
	for mk: Dictionary in mm.marks:
		kinds[mk["kind"]] = int(kinds.get(mk["kind"], 0)) + 1
	print("[h1b_capture] %s %s visible=%s expanded=%s mode=%s texture=%s marks=%s arrow=%s" % [ctx["tag"], kind, mm.visible, mm.expanded,
		mm.mode(), mm.texture != null, str(kinds), mm.arrow_px()])
	var ok: bool = await _save(ctx["svp"], "%s_%s" % [kind, ctx["tag"]])
	return ok and mm.visible and mm.texture != null


func _shot_minimap_small_rotate(ctx: Dictionary) -> bool:
	await _minimap_prep(ctx)
	AppFlow.profile = {"minimap_rotate": true}
	return await _minimap_save(ctx, "minimap_small_rotate")


func _shot_minimap_small_north(ctx: Dictionary) -> bool:
	await _minimap_prep(ctx)
	AppFlow.profile = {"minimap_rotate": false}
	return await _minimap_save(ctx, "minimap_small_north")


## Expanded through a real tap on the tap target; closed again by a tap on the close control after the shot.
func _shot_minimap_expanded(ctx: Dictionary) -> bool:
	await _minimap_prep(ctx)
	AppFlow.profile = {"minimap_rotate": true}
	var mm: HudMinimap = (ctx["game"] as GameHud).minimap
	var tap := HudMinimap.tap_rect(ctx["size"]).get_center()
	_tap(ctx["svp"], tap, true)
	_tap(ctx["svp"], tap, false)
	var ok: bool = await _minimap_save(ctx, "minimap_expanded")
	ok = ok and mm.expanded
	_tap(ctx["svp"], HudMinimap.close_rect(ctx["size"]).get_center(), true)
	_tap(ctx["svp"], HudMinimap.close_rect(ctx["size"]).get_center(), false)
	await _frames(2)
	print("[h1b_capture] %s minimap closed by the close control: %s" % [ctx["tag"], not mm.expanded])
	return ok and not mm.expanded


## No render: the minimap panels of the rotating and north-up shots, cropped and enlarged side by side (the same size as
## a shot, so it sits on the sheet).
func _shot_minimap_zoom(ctx: Dictionary) -> bool:
	var size: Vector2 = ctx["size"]
	var u := HudArrangement.unit(size)
	var crop := Rect2i(HudMinimap.frame_rect(size).grow(u * 0.6).intersection(Rect2(Vector2.ZERO, size)))
	var out := Image.create_empty(int(size.x), int(size.y), false, Image.FORMAT_RGB8)
	out.fill(Color(0.08, 0.08, 0.1))
	var half := Vector2(size.x * 0.5, size.y)
	var scale := minf((half.x - 24.0) / crop.size.x, (half.y - 24.0) / crop.size.y)
	var i := 0
	for kind in ["minimap_small_rotate", "minimap_small_north"]:
		var img := Image.load_from_file(_out.path_join("%s_%s.png" % [kind, ctx["tag"]]))
		if img == null:
			push_error("[h1b_capture] minimap_zoom needs %s_%s.png" % [kind, ctx["tag"]])
			return false
		img.convert(Image.FORMAT_RGB8)
		var part := img.get_region(crop)
		part.resize(int(crop.size.x * scale), int(crop.size.y * scale), Image.INTERPOLATE_LANCZOS)
		out.blit_rect(part, Rect2i(Vector2i.ZERO, part.get_size()), Vector2i(int(half.x * i + (half.x - part.get_width()) * 0.5), int((half.y - part.get_height()) * 0.5)))
		i += 1
	var err := out.save_png(_out.path_join("minimap_zoom_%s.png" % ctx["tag"]))
	print("[h1b_capture] minimap_zoom_%s (rotating left, north up right, x%.2f) -> %s" % [ctx["tag"], scale, error_string(err)])
	return err == OK


## Each baked minimap texture, as committed, copied to minimap_tex_<map>.png.
func _copy_minimap_textures() -> bool:
	var ok := true
	for id: String in (HudArrangement.ui()["minimap"]["maps"] as Dictionary).keys():
		if id.begins_with("_"):
			continue
		var src := String(HudArrangement.ui()["minimap"]["maps"][id]["texture"])
		var img := Image.load_from_file(ProjectSettings.globalize_path(src))
		var err := img.save_png(_out.path_join("minimap_tex_%s.png" % id)) if img != null else FAILED
		print("[h1b_capture] minimap_tex_%s %s -> %s" % [id, str(img.get_size()) if img != null else "missing", error_string(err)])
		ok = ok and err == OK
	return ok


# --- commit 4: the radar ---------------------------------------------------------------------------------------------

## Once per match: the minimap placement, then enemies at RADAR_ENEMIES and a squad mate at RADAR_MATE around the player
## (relative to its heading, on the ground). Returns the enemies placed, in RADAR_ENEMIES order.
func _radar_prep(ctx: Dictionary) -> Array:
	await _minimap_prep(ctx)
	if ctx.has("radar_enemies"):
		return ctx["radar_enemies"]
	var m: MatchRoot = ctx["m"]
	var me := m.local_player
	var terrain := MapTerrain.for_map(m.map_def)
	var yaw := me.rotation.y
	var fwd := Vector2(-sin(yaw), -cos(yaw))
	var right := Vector2(cos(yaw), -sin(yaw))
	var at := Vector2(me.global_position.x, me.global_position.z)
	var place := func(p: Pawn, rel: Vector2) -> void:
		var q: Vector2 = at + right * rel.x + fwd * rel.y
		p.global_position = Vector3(q.x, (terrain.height_at(q.x, q.y) if terrain != null else 0.0) + 0.05, q.y)
		p.velocity = Vector3.ZERO
	var enemies: Array = []
	var mate_done := false
	for id in m.director.all_players():
		var o: Pawn = m.director.player(id)
		if o == me:
			continue
		if o.squad_id == me.squad_id:
			if not mate_done:
				place.call(o, RADAR_MATE)
				mate_done = true
			continue
		if enemies.size() < RADAR_ENEMIES.size():
			place.call(o, RADAR_ENEMIES[enemies.size()])
			enemies.append(o)
	ctx["radar_enemies"] = enemies
	await _frames(8)
	return enemies


func _radar_log(ctx: Dictionary, what: String) -> HudRadar:
	var radar: HudRadar = (ctx["game"] as GameHud).radar
	var kinds := {}
	for b: Dictionary in radar.blips:
		kinds[b["kind"]] = int(kinds.get(b["kind"], 0)) + 1
	print("[h1b_capture] %s %s radar visible=%s blips=%s disc=%s" % [ctx["tag"], what, radar.visible, str(kinds), HudRadar.disc_rect(ctx["size"])])
	return radar


func _shot_radar_blips(ctx: Dictionary) -> bool:
	AppFlow.profile = {"minimap_rotate": true}
	var enemies: Array = await _radar_prep(ctx)
	await _frames(8)  # at least one blip update after the placement
	var radar := _radar_log(ctx, "radar_blips")
	var ok: bool = await _save(ctx["svp"], "radar_blips_" + ctx["tag"])
	# Every enemy inside 25 m and the mate shown; the one at 31 m not.
	var want_enemies := RADAR_ENEMIES.filter(func(v: Vector2) -> bool: return v.length() <= HudRadar.range_m()).size()
	var got := radar.blips.filter(func(b: Dictionary) -> bool: return b["kind"] == HudRadar.ENEMY).size()
	var mates := radar.blips.filter(func(b: Dictionary) -> bool: return b["kind"] == HudRadar.MATE).size()
	print("[h1b_capture] %s radar_blips enemies %d of %d placed (want %d), mates %d" % [ctx["tag"], got, enemies.size(), want_enemies, mates])
	return ok and radar.visible and got == want_enemies and mates == 1


## Two renders (the first enemy standing, then in the cover crouch through the enable_cover seam), saved as
## radar_cover_shown_ / radar_cover_hidden_<WxH>.png, and their panels side by side as radar_cover_<WxH>.png.
func _shot_radar_cover(ctx: Dictionary) -> bool:
	AppFlow.profile = {"minimap_rotate": true}
	var enemies: Array = await _radar_prep(ctx)
	if enemies.is_empty():
		return false
	var foe: Pawn = enemies[0]
	foe.set_physics_process(false)  # hold the cover state still for the shot (its controller would re-probe the wall)
	foe.enable_cover(DataRegistry.new().load_file("res://data/cover.json"))
	if foe.cover == null:
		push_error("[h1b_capture] radar_cover: the cover seam gave no controller")
		return false
	foe.cover.state = CoverController.State.FREE
	foe.cover.crouch_amount = 0.0
	await _frames(8)
	var radar := _radar_log(ctx, "radar_cover shown")
	var shown := not radar.blip_of(int(foe.player_id)).is_empty()
	var ok: bool = await _save(ctx["svp"], "radar_cover_shown_" + ctx["tag"])
	foe.cover.state = CoverController.State.IN_COVER
	foe.cover.crouch_amount = 1.0
	await _frames(8)
	_radar_log(ctx, "radar_cover hidden")
	var hidden := radar.blip_of(int(foe.player_id)).is_empty()
	var ok2: bool = await _save(ctx["svp"], "radar_cover_hidden_" + ctx["tag"])
	ok = ok and ok2
	foe.cover.reset()
	foe.set_physics_process(true)
	print("[h1b_capture] %s radar_cover enemy %d: standing shown=%s, cover crouch hidden=%s" % [ctx["tag"], foe.player_id, shown, hidden])
	ok = ok and _zoom_pair(ctx, ["radar_cover_shown", "radar_cover_hidden"], "radar_cover")
	return ok and shown and hidden


func _shot_panel_zoom(ctx: Dictionary) -> bool:
	return _zoom_pair(ctx, ["radar_blips"], "panel_zoom")


## No render: the radar + minimap panel of each source shot cropped and enlarged, side by side (one source: centred).
func _zoom_pair(ctx: Dictionary, sources: Array, kind: String) -> bool:
	var size: Vector2 = ctx["size"]
	var u := HudArrangement.unit(size)
	var crop := Rect2i(HudMinimap.frame_rect(size).grow(u * 0.6).intersection(Rect2(Vector2.ZERO, size)))
	var out := Image.create_empty(int(size.x), int(size.y), false, Image.FORMAT_RGB8)
	out.fill(Color(0.08, 0.08, 0.1))
	var cell := Vector2(size.x / sources.size(), size.y)
	var scale := minf((cell.x - 24.0) / crop.size.x, (cell.y - 24.0) / crop.size.y)
	for i in sources.size():
		var img := Image.load_from_file(_out.path_join("%s_%s.png" % [sources[i], ctx["tag"]]))
		if img == null:
			push_error("[h1b_capture] %s needs %s_%s.png" % [kind, sources[i], ctx["tag"]])
			return false
		img.convert(Image.FORMAT_RGB8)
		var part := img.get_region(crop)
		part.resize(int(crop.size.x * scale), int(crop.size.y * scale), Image.INTERPOLATE_LANCZOS)
		out.blit_rect(part, Rect2i(Vector2i.ZERO, part.get_size()), Vector2i(int(cell.x * i + (cell.x - part.get_width()) * 0.5), int((cell.y - part.get_height()) * 0.5)))
	var err := out.save_png(_out.path_join("%s_%s.png" % [kind, ctx["tag"]]))
	print("[h1b_capture] %s_%s (%s, x%.2f) -> %s" % [kind, ctx["tag"], ", ".join(sources), scale, error_string(err)])
	return err == OK


# --- commit 5: the first-play coach ------------------------------------------------------------------------------------

## The coach for this match, built once (as GameHud.bind does on a flagged match: after the radar, bound to the HUD),
## saving to a scratch profile; then step `id` forced into view in shooting mode `mode`.
func _coach_show(ctx: Dictionary, id: String, mode: String) -> HudCoach:
	await _prompt_prep(ctx)
	AppFlow.profile = {"shooting_mode": mode}
	var touch: Control = ctx["touch"]
	touch.refresh_shooting_mode()
	touch.relayout()
	var game: GameHud = ctx["game"]
	if not ctx.has("coach"):
		var c := HudCoach.new()
		c.save = SaveService.new(COACH_PROFILE)
		game.radar.add_sibling(c)
		c.bind(game.director, game.pawn, touch, ctx["pm"], game)
		ctx["coach"] = c
	var coach: HudCoach = ctx["coach"]
	var ids: Array = []
	for st: Dictionary in coach.steps:
		ids.append(str(st["id"]))
	coach.forced_step = ids.find(id)
	game.show_banner(String(game._banner_cfg["kill_text"]), true)
	return coach


func _coach_save(ctx: Dictionary, coach: HudCoach, kind: String) -> bool:
	await _frames(4)
	var h := coach.hint_layout(ctx["size"])
	print("[h1b_capture] %s %s step=%s shown=%s reason=\"%s\" target=%s bubble=%s tip=%s covered=%.0f text=\"%s\" skip=%s" % [ctx["tag"], kind,
		coach.current_id(), coach.showing_hint(), coach.paused_reason, h.get("target"), h.get("bubble"), h.get("tip"),
		float(h.get("covered", -1.0)), h.get("text", ""), HudCoach.skip_rect(ctx["size"])])
	var ok: bool = await _save(ctx["svp"], "%s_%s" % [kind, ctx["tag"]])
	return ok and coach.showing_hint()


func _shot_coach_move(ctx: Dictionary) -> bool:
	return await _coach_save(ctx, await _coach_show(ctx, "move", "advanced"), "coach_move")


func _shot_coach_look(ctx: Dictionary) -> bool:
	return await _coach_save(ctx, await _coach_show(ctx, "look", "advanced"), "coach_look")


func _shot_coach_aim(ctx: Dictionary) -> bool:
	return await _coach_save(ctx, await _coach_show(ctx, "aim", "advanced"), "coach_aim")


func _shot_coach_fire_advanced(ctx: Dictionary) -> bool:
	return await _coach_save(ctx, await _coach_show(ctx, "fire", "advanced"), "coach_fire_advanced")


func _shot_coach_fire_simple(ctx: Dictionary) -> bool:
	return await _coach_save(ctx, await _coach_show(ctx, "fire", "simple"), "coach_fire_simple")


func _shot_coach_cover(ctx: Dictionary) -> bool:
	return await _coach_save(ctx, await _coach_show(ctx, "cover", "advanced"), "coach_cover")


func _shot_coach_pickup(ctx: Dictionary) -> bool:
	var coach := await _coach_show(ctx, "pickup", "advanced")
	_drop_gun(ctx, _rel(ctx, 0.5, 1.4, 0.15))
	return await _coach_save(ctx, coach, "coach_pickup")


func _shot_coach_map(ctx: Dictionary) -> bool:
	return await _coach_save(ctx, await _coach_show(ctx, "map", "advanced"), "coach_map")


## The HUD layout editor (as Settings opens it) over the match, showing the fixed elements; the coach is hidden for it.
func _shot_editor(ctx: Dictionary) -> bool:
	if ctx.has("coach"):
		(ctx["coach"] as HudCoach).forced_step = -1
		(ctx["coach"] as HudCoach).skip()
	# The editor's preview touch HUD releases the virtual-stick actions when it suspends; this capture match uses the
	# custom stick, which never registers them, so register them as the virtual stick does (else 4 ERROR lines a frame).
	for a in ["vjoy_move_left", "vjoy_move_right", "vjoy_move_up", "vjoy_move_down"]:
		if not InputMap.has_action(a):
			InputMap.add_action(a, 0.0)
	var layer := CanvasLayer.new()
	layer.layer = 100
	(ctx["svp"] as SubViewport).add_child(layer)
	var ed: LayoutEditor = load("res://scenes/ui/layout_editor.tscn").instantiate()
	ed.save = SaveService.new(COACH_PROFILE)
	layer.add_child(ed)
	ed.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	ed.size = ctx["size"]
	await _frames(6)
	ed.refresh()
	await _frames(3)
	print("[h1b_capture] %s editor drawn_fixed=%s fixed=%s issues=%d" % [ctx["tag"], str(ed.drawn_fixed), str(LayoutEditor.fixed_elements(ctx["size"])), ed.issues.size()])
	var ok: bool = await _save(ctx["svp"], "editor_" + ctx["tag"])
	layer.queue_free()
	return ok and ed.drawn_fixed.size() == LayoutEditor.fixed_elements(ctx["size"]).size()


## Contact sheet: the shots of one size scaled to SHEET_CELL_W wide, 3 columns, in KINDS order, on a dark background.
func _sheet(size: Vector2i, kinds: Array, sheet_name: String = "sheet") -> bool:
	var tag := _tag(size)
	var cw := SHEET_CELL_W
	var ch := int(round(float(cw) * size.y / size.x))
	var gap := 12
	var rows := int(ceil(kinds.size() / 3.0))
	var sheet := Image.create_empty(3 * cw + 4 * gap, rows * ch + (rows + 1) * gap, false, Image.FORMAT_RGB8)
	sheet.fill(Color(0.08, 0.08, 0.1))
	for i in kinds.size():
		var img := Image.load_from_file(_out.path_join("%s_%s.png" % [kinds[i], tag]))
		if img == null:
			push_error("[h1b_capture] missing %s_%s.png" % [kinds[i], tag])
			return false
		img.convert(Image.FORMAT_RGB8)
		img.resize(cw, ch, Image.INTERPOLATE_LANCZOS)
		sheet.blit_rect(img, Rect2i(0, 0, cw, ch), Vector2i(gap + (i % 3) * (cw + gap), gap + (i / 3) * (ch + gap)))
	var err := sheet.save_png(_out.path_join("%s_%s.png" % [sheet_name, tag]))
	print("[h1b_capture] %s_%s %dx%d -> %s" % [sheet_name, tag, sheet.get_width(), sheet.get_height(), error_string(err)])
	return err == OK
