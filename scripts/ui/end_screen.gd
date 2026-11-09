class_name EndScreen
extends Control
## Victory / Draw / "Placed N of M" and the local player's kills, then back to the main menu.

const _Theme := preload("res://scenes/ui/theme.tres")

var result: Dictionary = {}
## data/ui.json hud.roman_numerals (OQ-38); tests may override.
var roman_numerals: bool = HudNumbers.roman_enabled()
var title_label: Label
var scores_label: Label


func _ready() -> void:
	theme = _Theme
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var box := VBoxContainer.new()
	center.add_child(box)
	title_label = Label.new()
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title_label)
	scores_label = Label.new()
	scores_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(scores_label)
	var b := Button.new()
	b.text = "Main menu"
	b.pressed.connect(_on_menu)
	box.add_child(b)
	UiScale.bind(self)
	show_result(result if not result.is_empty() else AppFlow.last_result)


## Battle royale result (BrRules.result() plus MatchRoot's local_player_id / local_squad_id / squad_count).
## Wording is placeholder text (S6 restyles it).
func show_result(r: Dictionary) -> void:
	result = r
	if title_label == null:
		return
	title_label.text = title_text(r)
	var me := int(r.get("local_player_id", -1))
	var kills: Dictionary = r.get("kills", {})
	scores_label.text = "Kills %s" % HudNumbers.number(int(kills.get(me, 0)), roman_numerals) if me >= 0 else ""


func title_text(r: Dictionary) -> String:
	var mine := int(r.get("local_squad_id", -1))
	var placements: Dictionary = r.get("placements", {})
	if bool(r.get("draw", false)):
		return "Draw"
	if mine >= 0 and r.get("winner") != null and int(r["winner"]) == mine:
		return "Victory"
	if mine >= 0 and placements.has(mine):
		var total := int(r.get("squad_count", placements.size()))
		return "Placed %s of %s" % [HudNumbers.number(int(placements[mine]), roman_numerals),
				HudNumbers.number(total, roman_numerals)]
	if r.get("winner") == null or int(r["winner"]) < 0:
		return "Match over"
	return "%s wins" % HudNumbers.squad_name(int(r["winner"]), roman_numerals)


func _on_menu() -> void:
	AppFlow.end_session()
	AppFlow.go(get_tree(), AppFlow.MENU_SCENE)
