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
const DPI := 420.0
const SHEET_CELL_W := 900
const ARENA_X := 1000.0

var _out: String = "build/shots"
var _kinds: Array = KINDS + PROMPT_KINDS
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
	var c1: Array = _kinds.filter(func(k: String) -> bool: return not PROMPT_KINDS.has(k))
	var c2: Array = _kinds.filter(func(k: String) -> bool: return PROMPT_KINDS.has(k))
	for size in _sizes:
		for group in [[c1, "sheet", false], [c2, "sheet_prompt", true]]:
			if (group[0] as Array).is_empty():
				continue
			AppFlow.profile = {}
			var done: Array = await _match_shots(size, group[0], group[2])
			if done.size() != (group[0] as Array).size():
				failed += 1
			if done.is_empty() or not _sheet(size, done, group[1]):
				failed += 1
	AppFlow.profile = saved_profile
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
		_label(radar.position, "radar (reserved)", magenta)
		_label(minimap.position + Vector2(0, minimap.size.y - 30), "minimap (reserved)", magenta)
		for k in passive:
			draw_rect(passive[k], Color(0.2, 0.95, 1.0, 0.95), false, 3.0)
			_label(Rect2(passive[k]).position, String(k), Color(0.4, 1.0, 1.0))
		for k in targets:
			var r: Rect2 = targets[k]
			draw_rect(r, Color(1.0, 0.85, 0.1, 0.95), false, 3.0)
			_label(r.position, String(k), Color(1, 1, 0.3))


## One match per size; every requested kind is shot from it. Returns the kinds saved (empty = the match failed).
## `prompts`: the commit-2 match (squads with idle bots, so a squad mate can be downed; ground loot on).
func _match_shots(size: Vector2i, kinds: Array, prompts: bool = false) -> Array:
	var tag := _tag(size)
	var svp := SubViewport.new()
	svp.size = size
	svp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(svp)
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.fill_bots = prompts
	if prompts:
		m.ground_loot = true
		m.seed_override = 31337
	svp.add_child(m)
	await get_tree().physics_frame
	m.director.load_config()
	if prompts:
		m.director.mode_cfg["teams"]["mode"]["value"] = "squads"
	if not m.begin():
		push_error("[h1b_capture] match did not start")
		return []
	if prompts:
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
