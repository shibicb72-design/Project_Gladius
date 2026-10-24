class_name EndScreen
extends Control
## Winner/draw and per-squad scores, then back to the main menu.

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


func show_result(r: Dictionary) -> void:
	result = r
	if title_label == null:
		return
	if bool(r.get("draw", false)):
		title_label.text = "Draw"
	elif r.get("winner") == null:
		title_label.text = "Match over"
	else:
		title_label.text = "%s wins" % HudNumbers.squad_name(int(r["winner"]), roman_numerals)
	var scores: Dictionary = r.get("scores", {})
	var keys := scores.keys()
	keys.sort()
	var lines: Array[String] = []
	for squad in keys:
		lines.append("%s: %s" % [HudNumbers.squad_name(int(squad), roman_numerals),
				HudNumbers.number(int(scores[squad]), roman_numerals)])
	scores_label.text = "\n".join(lines)


func _on_menu() -> void:
	AppFlow.end_session()
	AppFlow.go(get_tree(), AppFlow.MENU_SCENE)
