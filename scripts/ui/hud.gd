class_name GameHud
extends Control
## Gameplay HUD: presentation only. Reads MatchDirector signals and the local pawn; decides nothing.

const _Theme := preload("res://scenes/ui/theme.tres")

var director: MatchDirector
var pawn: Pawn
var fire_mode_button: FireModeButton
var cover_crouch_button: CoverCrouchButton
var cover_fire_button: CoverFireButton
## data/ui.json hud.roman_numerals (OQ-38); tests may override.
var roman_numerals: bool = HudNumbers.roman_enabled()

var stats: VBoxContainer
var shield_bar: ProgressBar
var health_bar: ProgressBar
var ammo_label: Label
var weapon_label: Label
var scores_label: Label
var timer_label: Label
var hill_label: Label
var respawn_label: Label
var own_death_label: Label
var _own_death_cfg: Dictionary = {}
## Action feedback (data/ui.json "feedback"): reload bar, Full/Empty cue, swap toast, hit marker.
var reload_box: VBoxContainer
var reload_bar: ProgressBar
var cue_label: Label
var toast_label: Label
var hit_marker: Label
var banner_label: Label
## Permanent centre aim reticle (data/ui.json "crosshair", OQ-CROSSHAIR); hidden while the local pawn is dead.
var crosshair: Control

var _fb: Dictionary = {}
var _ch: Dictionary = {}
var _crosshair_arms: Array[ColorRect] = []
var _cue_left_s: float = 0.0
var _toast_left_s: float = 0.0
var _marker_left_s: float = 0.0
var _banner_cfg: Dictionary = {}
var _banner_left_s: float = 0.0
var _banner_is_kill: bool = false
var _last_hill_text: String = ""
var _kill_bridge: NetMatchBridge
var _watched_pawns: Dictionary = {}
var _attack_open: bool = false
var _attack_frame: int = -1
var _killed_during_attack: Dictionary = {}


func _ready() -> void:
	theme = _Theme
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()


func _exit_tree() -> void:
	# The sibling can still be awaiting its deferred insertion when a short-lived HUD is freed.
	if is_instance_valid(fire_mode_button):
		fire_mode_button.queue_free()
	if is_instance_valid(cover_crouch_button):
		cover_crouch_button.queue_free()
	if is_instance_valid(cover_fire_button):
		cover_fire_button.queue_free()


func _build() -> void:
	if scores_label != null:
		return
	var top := HBoxContainer.new()
	top.set_anchors_preset(Control.PRESET_TOP_WIDE)
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(top)
	scores_label = _label(top, "")
	scores_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	timer_label = _label(top, "")
	hill_label = _label(top, "")

	stats = VBoxContainer.new()
	stats.set_anchors_preset(Control.PRESET_TOP_LEFT)
	stats.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(stats)
	shield_bar = _bar(stats, Color(0.4, 0.6, 0.95))
	health_bar = _bar(stats, Color(0.8, 0.15, 0.15))
	weapon_label = _label(stats, "")
	ammo_label = _label(stats, "")
	resized.connect(_place_stats)
	_place_stats()

	respawn_label = _label(self, "")
	respawn_label.set_anchors_preset(Control.PRESET_CENTER)
	respawn_label.visible = false
	_build_feedback()


func _build_feedback() -> void:
	_fb = DataRegistry.new().load_file("res://data/ui.json")["feedback"]
	reload_box = VBoxContainer.new()
	reload_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_anchor_row(reload_box, float(_fb["reload_anchor_y_frac"]))
	add_child(reload_box)
	var reload_text := _label(reload_box, String(_fb["reload_text"]))
	reload_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	reload_bar = ProgressBar.new()
	reload_bar.show_percentage = false
	reload_bar.max_value = 1.0
	reload_bar.custom_minimum_size = Vector2(float(_fb["reload_bar_size"][0]), float(_fb["reload_bar_size"][1]))
	reload_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	reload_bar.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	reload_bar.add_theme_stylebox_override("fill", _fill_style(_color(_fb["cue_color"])))
	reload_bar.add_theme_stylebox_override("background", _fill_style(Color(0, 0, 0, 0.6)))
	reload_box.add_child(reload_bar)
	reload_box.visible = false
	cue_label = _row_label(float(_fb["cue_anchor_y_frac"]), _color(_fb["cue_color"]))
	toast_label = _row_label(float(_fb["toast_anchor_y_frac"]), _color(_fb["toast_color"]))
	_build_crosshair()  # before the hit marker, so the marker (a later sibling) draws on top of the reticle
	hit_marker = _row_label(0.5, _color(_fb["hit_marker_color"]))
	hit_marker.text = String(_fb["hit_marker_text"])
	resized.connect(_size_hit_marker)
	_banner_cfg = DataRegistry.new().load_file("res://data/ui.json")["kill_feed"]
	banner_label = _row_label(float(_banner_cfg["anchor_y_frac"]), _color(_banner_cfg["color"]))
	banner_label.add_theme_color_override("font_outline_color", _color(_banner_cfg["outline_color"]))
	resized.connect(_size_banner)
	_size_banner()

	_own_death_cfg = DataRegistry.new().load_file("res://data/ui.json")["own_death"]
	own_death_label = _row_label(float(_own_death_cfg["anchor_y_frac"]), _color(_own_death_cfg["color"]))
	own_death_label.text = String(_own_death_cfg["text"])
	own_death_label.add_theme_color_override("font_outline_color", _color(_own_death_cfg["outline_color"]))
	resized.connect(_size_own_death)
	_size_own_death()


func _size_own_death() -> void:
	own_death_label.add_theme_font_size_override("font_size", int(float(_own_death_cfg["font_frac_of_height"]) * size.y))
	own_death_label.add_theme_constant_override("outline_size", int(float(_own_death_cfg["outline_size_frac_of_height"]) * size.y))


func _size_banner() -> void:
	banner_label.add_theme_font_size_override("font_size", int(float(_banner_cfg["font_frac_of_height"]) * size.y))
	banner_label.add_theme_constant_override("outline_size", int(float(_banner_cfg["outline_size_frac_of_height"]) * size.y))


func show_banner(text: String, is_kill: bool = false, contested: bool = false) -> void:
	# A state change must not erase the local kill that just happened.
	if not is_kill and _banner_is_kill and _banner_left_s > 0.0:
		return
	_size_banner()
	banner_label.text = text
	banner_label.add_theme_color_override("font_color", _color(_banner_cfg["contested_color"] if contested else _banner_cfg["color"]))
	banner_label.visible = true
	_banner_is_kill = is_kill
	_banner_left_s = float(_banner_cfg["duration_s"])


## Client kills arrive via the existing authority event. Host/offline use synchronous damage below.
func bind_kill_bridge(bridge: NetMatchBridge) -> void:
	if _kill_bridge != null and _kill_bridge.kill_event.is_connected(_on_bridge_kill):
		_kill_bridge.kill_event.disconnect(_on_bridge_kill)
	_kill_bridge = bridge
	if bridge != null:
		bridge.kill_event.connect(_on_bridge_kill)


func _on_bridge_kill(killer_id: int, victim_id: int) -> void:
	if _kill_bridge.local_player_id >= 0 and killer_id == _kill_bridge.local_player_id and victim_id != killer_id:
		show_banner(String(_banner_cfg["kill_text"]), true)


func _watch_pawns() -> void:
	if director == null:
		return
	for target: Pawn in director.all_players().values():
		if is_instance_valid(target) and not _watched_pawns.has(target.get_instance_id()):
			_watched_pawns[target.get_instance_id()] = true
			target.damaged.connect(_on_watched_damage.bind(target))


func _begin_local_attack() -> void:
	_watch_pawns()  # Also covers a pawn added since the previous HUD frame.
	_killed_during_attack.clear()
	_attack_open = true
	_attack_frame = Engine.get_process_frames()


func _on_watched_damage(result: DamageRules.HitResult, target: Pawn) -> void:
	if _attack_open and _attack_frame == Engine.get_process_frames() and result.killed and target != pawn:
		_killed_during_attack[target] = true


func _on_melee_landed() -> void:
	if _attack_open and _attack_frame == Engine.get_process_frames() and not _killed_during_attack.is_empty():
		show_banner(String(_banner_cfg["kill_text"]), true)
	_end_local_attack()


func _end_local_attack() -> void:
	_attack_open = false
	_killed_during_attack.clear()


func _anchor_row(c: Control, y_frac: float) -> void:
	# A centred band, not the full width, so the row rect never reaches the buttons or sticks.
	c.anchor_left = float(_fb["row_x_frac"][0])
	c.anchor_right = float(_fb["row_x_frac"][1])
	c.anchor_top = y_frac
	c.anchor_bottom = y_frac
	c.grow_vertical = Control.GROW_DIRECTION_BOTH


## A hidden, centred, full-width label at a fraction of the HUD height.
func _row_label(y_frac: float, color: Color) -> Label:
	var l := _label(self, "")
	_anchor_row(l, y_frac)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_color_override("font_color", color)
	l.visible = false
	return l


func _color(c: Array) -> Color:
	return Color(c[0], c[1], c[2], c[3])


func _size_hit_marker() -> void:
	hit_marker.add_theme_font_size_override("font_size",
			int(float(_fb["hit_marker_font_frac_of_height"]) * size.y))


## Screen-centre reticle: at rest the camera-centre aim ray (AimMath / CameraRig.get_aim_point) points through the
## HUD centre. A root Control anchored at the centre encloses four ColorRect arms around an open centre gap.
func _build_crosshair() -> void:
	_ch = DataRegistry.new().load_file("res://data/ui.json")["crosshair"]
	crosshair = Control.new()
	crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	crosshair.anchor_left = 0.5
	crosshair.anchor_top = 0.5
	crosshair.anchor_right = 0.5
	crosshair.anchor_bottom = 0.5
	add_child(crosshair)
	for i in 4:
		var arm := ColorRect.new()
		arm.color = _color(_ch["color"])
		arm.mouse_filter = Control.MOUSE_FILTER_IGNORE
		crosshair.add_child(arm)
		_crosshair_arms.append(arm)
	crosshair.visible = bool(_ch["enabled"])
	resized.connect(_size_crosshair)
	_size_crosshair()


## Sizes the reticle from the HUD height (folding the phone resizes the HUD at runtime). Offsets of +-half the span
## keep the root centred; the arms are left, right, top, bottom.
func _size_crosshair() -> void:
	var span := float(_ch["size_frac_of_height"]) * size.y
	var gap := float(_ch["gap_frac_of_height"]) * size.y
	var thick := maxf(1.0, float(_ch["thickness_frac_of_height"]) * size.y)  # never thinner than 1 px
	var half := span * 0.5
	crosshair.offset_left = -half
	crosshair.offset_top = -half
	crosshair.offset_right = half
	crosshair.offset_bottom = half
	var arm := maxf(0.0, (span - gap) * 0.5)
	var mid := half - thick * 0.5
	var rects: Array[Rect2] = [Rect2(0.0, mid, arm, thick), Rect2(span - arm, mid, arm, thick),
			Rect2(mid, 0.0, thick, arm), Rect2(mid, span - arm, thick, arm)]
	for i in rects.size():
		_crosshair_arms[i].position = rects[i].position
		_crosshair_arms[i].size = rects[i].size


func show_cue(text: String) -> void:
	cue_label.text = text
	cue_label.visible = true
	_cue_left_s = _fb["cue_duration_s"]


func show_toast(text: String) -> void:
	toast_label.text = text
	toast_label.visible = true
	_toast_left_s = _fb["toast_duration_s"]


func show_hit_marker() -> void:
	_size_hit_marker()
	hit_marker.visible = true
	_marker_left_s = _fb["hit_marker_duration_s"]


func _on_reload_rejected(reason: String) -> void:
	show_cue(String(_fb["cue_full_text"]) if reason == "full" else String(_fb["cue_no_reserve_text"]))


func _on_fire_empty() -> void:
	show_cue(String(_fb["cue_empty_text"]))


func _on_weapon_switched(_slot: int) -> void:
	var w: Weapon = pawn.loadout.get_active()
	if w != null:
		show_toast(w.def.display_name)


func _on_shot_resolved(_origin: Vector3, _end: Vector3, hit: Dictionary) -> void:
	if hit.get("target") != null:
		show_hit_marker()
		if _attack_open and _attack_frame == Engine.get_process_frames() and _killed_during_attack.has(hit["target"]):
			show_banner(String(_banner_cfg["kill_text"]), true)
	_end_local_attack()


func _tick_feedback(delta: float) -> void:
	if _banner_left_s > 0.0:
		_banner_left_s -= delta
		banner_label.visible = _banner_left_s > 0.0
	if _cue_left_s > 0.0:
		_cue_left_s -= delta
		cue_label.visible = _cue_left_s > 0.0
	if _toast_left_s > 0.0:
		_toast_left_s -= delta
		toast_label.visible = _toast_left_s > 0.0
	if _marker_left_s > 0.0:
		_marker_left_s -= delta
		hit_marker.visible = _marker_left_s > 0.0


## Positions the stat block from data/ui.json (hud_layout.stat_block_pos, fractions of the HUD size).
func _place_stats() -> void:
	var cfg := DataRegistry.new().load_file("res://data/ui.json")
	var p: Array = cfg.get("hud_layout", {}).get("stat_block_pos", [0.01, 0.08])
	stats.position = Vector2(float(p[0]) * size.x, float(p[1]) * size.y)


func _label(parent: Node, text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l


func _bar(parent: Node, color: Color) -> ProgressBar:
	var b := ProgressBar.new()
	b.show_percentage = false
	b.custom_minimum_size = Vector2(240, 16)
	b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_theme_stylebox_override("fill", _fill_style(color))
	parent.add_child(b)
	return b


func _fill_style(color: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = color
	return s


## Connects to the match director and the local pawn. Safe to call before the node enters the tree.
func bind(match_director: MatchDirector, local_pawn: Pawn) -> void:
	_build()
	director = match_director
	pawn = local_pawn
	if fire_mode_button == null:
		fire_mode_button = FireModeButton.new()
		var touch := get_node_or_null("../TouchHud") as Control
		fire_mode_button.bind(pawn, touch, get_node_or_null("../PauseMenu") as PauseMenu)
		if touch != null:
			touch.add_sibling.call_deferred(fire_mode_button)
		else:
			add_child(fire_mode_button)
	else:
		fire_mode_button.bind(pawn, get_node_or_null("../TouchHud") as Control, get_node_or_null("../PauseMenu") as PauseMenu)
	if cover_crouch_button == null:
		cover_crouch_button = CoverCrouchButton.new()
		cover_fire_button = CoverFireButton.new()
		var touch := get_node_or_null("../TouchHud") as Control
		for button: CoverCrouchButton in [cover_crouch_button, cover_fire_button]:
			button.bind(pawn, touch, get_node_or_null("../PauseMenu") as PauseMenu)
			if touch != null:
				touch.add_sibling.call_deferred(button)
			else:
				add_child(button)
	else:
		cover_crouch_button.bind(pawn, get_node_or_null("../TouchHud") as Control, get_node_or_null("../PauseMenu") as PauseMenu)
		cover_fire_button.bind(pawn, get_node_or_null("../TouchHud") as Control, get_node_or_null("../PauseMenu") as PauseMenu)
	pawn.reload_rejected.connect(_on_reload_rejected)
	pawn.fire_empty.connect(_on_fire_empty)
	pawn.weapon_switched.connect(_on_weapon_switched)
	pawn.shot_resolved.connect(_on_shot_resolved)
	pawn.fired.connect(_begin_local_attack)
	pawn.melee_landed.connect(_on_melee_landed)
	_watch_pawns()
	director.score_changed.connect(_on_score_changed)
	director.time_changed.connect(_on_time_changed)
	director.player_respawned.connect(_on_player_respawned)
	refresh_pawn()


func _process(delta: float) -> void:
	_tick_feedback(delta)
	_watch_pawns()
	if _attack_open and _attack_frame != Engine.get_process_frames():
		_end_local_attack()
	if pawn != null:
		refresh_pawn()


func _on_score_changed(scores: Dictionary) -> void:
	var parts: Array[String] = []
	var keys := scores.keys()
	keys.sort()
	for squad in keys:
		parts.append("%s: %s" % [_squad_name(int(squad)), HudNumbers.number(int(scores[squad]), roman_numerals)])
	scores_label.text = "   ".join(parts)


func _on_time_changed(remaining_s: float) -> void:
	var t := int(ceil(remaining_s))
	timer_label.text = "%d:%02d" % [t / 60, t % 60]


func _on_player_respawned(_player_id: int) -> void:
	refresh_pawn()


## Updates the per-pawn widgets: bars, weapon, ammo, hill indicator and respawn countdown.
func refresh_pawn() -> void:
	if pawn == null or pawn.bridge == null:
		return
	var st := pawn.bridge.state
	shield_bar.max_value = maxf(st.max_shield, 1.0)
	shield_bar.value = st.shield
	health_bar.max_value = maxf(st.max_health, 1.0)
	health_bar.value = st.health
	var w: Weapon = pawn.loadout.get_active() if pawn.loadout != null else null
	if w != null:
		weapon_label.text = w.def.display_name
		ammo_label.text = "-" if w.def.is_melee() else "%d / %d" % [w.ammo_in_mag, w.reserve]
		reload_box.visible = w.reloading
		reload_bar.value = w.reload_fraction(pawn.get_clock())
	var waiting := not pawn.is_alive()
	respawn_label.visible = waiting
	own_death_label.visible = waiting
	crosshair.visible = bool(_ch["enabled"]) and not waiting  # no shot is possible while dead
	if waiting and director != null and director.spawn_rules != null:
		var left := director.spawn_rules.respawn_remaining(_pawn_player_id())
		respawn_label.text = "Respawn in %d" % int(ceil(left))
	var hill_text := _hill_text()
	if hill_text != _last_hill_text:
		if hill_text == "Hill: yours":
			show_banner(String(_banner_cfg["secured_text"]))
		elif hill_text == "Hill: contested":
			show_banner(String(_banner_cfg["contested_text"]), false, true)
		_last_hill_text = hill_text
	hill_label.text = hill_text


func _pawn_player_id() -> int:
	if director == null:
		return -1
	for id in director.all_players():
		if director.all_players()[id] == pawn:
			return int(id)
	return -1


func _hill_text() -> String:
	if director == null or director.hill_zone == null or pawn == null:
		return ""
	var occ := director.hill_zone.occupancy()
	if occ.is_empty():
		return "Hill: empty"
	if occ.size() > 1:
		return "Hill: contested"
	return "Hill: yours" if occ.has(pawn.squad_id) else "Hill: enemy"


func _squad_name(squad: int) -> String:
	return HudNumbers.squad_name(squad, roman_numerals)
