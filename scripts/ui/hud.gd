class_name GameHud
extends Control
## Gameplay HUD: presentation only. Reads MatchDirector signals and the local pawn; decides nothing.

const _Theme := preload("res://scenes/ui/theme.tres")

var director: MatchDirector
var pawn: Pawn
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
## Action feedback (data/ui.json "feedback"): reload bar, Full/Empty cue, swap toast, hit marker.
var reload_box: VBoxContainer
var reload_bar: ProgressBar
var cue_label: Label
var toast_label: Label
var hit_marker: Label

var _fb: Dictionary = {}
var _cue_left_s: float = 0.0
var _toast_left_s: float = 0.0
var _marker_left_s: float = 0.0


func _ready() -> void:
	theme = _Theme
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()


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
	hit_marker = _row_label(0.5, _color(_fb["hit_marker_color"]))
	hit_marker.text = String(_fb["hit_marker_text"])
	resized.connect(_size_hit_marker)


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


func _tick_feedback(delta: float) -> void:
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
	pawn.reload_rejected.connect(_on_reload_rejected)
	pawn.fire_empty.connect(_on_fire_empty)
	pawn.weapon_switched.connect(_on_weapon_switched)
	pawn.shot_resolved.connect(_on_shot_resolved)
	director.score_changed.connect(_on_score_changed)
	director.time_changed.connect(_on_time_changed)
	director.player_respawned.connect(_on_player_respawned)
	refresh_pawn()


func _process(delta: float) -> void:
	_tick_feedback(delta)
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
	if waiting and director != null and director.spawn_rules != null:
		var left := director.spawn_rules.respawn_remaining(_pawn_player_id())
		respawn_label.text = "Respawn in %d" % int(ceil(left))
	hill_label.text = _hill_text()


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
