class_name GameHud
extends Control
## Gameplay HUD: presentation only. Reads MatchDirector signals and the local pawn; decides nothing.

const _Theme := preload("res://scenes/ui/theme.tres")

var director: MatchDirector
var pawn: Pawn

var stats: VBoxContainer
var shield_bar: ProgressBar
var health_bar: ProgressBar
var ammo_label: Label
var weapon_label: Label
var scores_label: Label
var timer_label: Label
var hill_label: Label
var respawn_label: Label


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
	director.score_changed.connect(_on_score_changed)
	director.time_changed.connect(_on_time_changed)
	director.player_respawned.connect(_on_player_respawned)
	refresh_pawn()


func _process(_delta: float) -> void:
	if pawn != null:
		refresh_pawn()


func _on_score_changed(scores: Dictionary) -> void:
	var parts: Array[String] = []
	var keys := scores.keys()
	keys.sort()
	for squad in keys:
		parts.append("%s: %s" % [_squad_name(int(squad)), RomanNumerals.to_roman(int(scores[squad]))])
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
		ammo_label.text = "%d / %d" % [w.ammo_in_mag, w.reserve]
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
	return "Squad %s" % RomanNumerals.to_roman(squad + 1)
