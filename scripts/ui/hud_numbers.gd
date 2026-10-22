class_name HudNumbers
extends RefCounted
## Single place that turns HUD numbers and squad names into text (OQ-38, DECIDED Oct 22 2026):
## plain digits. Roman numerals stay available behind data/ui.json hud.roman_numerals (default false).

const UI_PATH := "res://data/ui.json"


## data/ui.json hud.roman_numerals; false when the file or key is missing.
static func roman_enabled() -> bool:
	var hud_cfg: Dictionary = DataRegistry.new().load_file(UI_PATH).get("hud", {})
	return bool(hud_cfg.get("roman_numerals", false))


static func number(value: int, roman: bool = false) -> String:
	return RomanNumerals.to_roman(value) if roman else str(value)


## Zero-based squad index to its display name: "Squad 1", "Squad 2", ...
static func squad_name(squad: int, roman: bool = false) -> String:
	return "Squad %s" % number(squad + 1, roman)
