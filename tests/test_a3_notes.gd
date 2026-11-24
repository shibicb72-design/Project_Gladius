extends "res://tests/test_case.gd"
## A3 fix pass 1, B1: the generic licence notes must not call every source CC0. forum_stall and farm_cart derive from
## Tripo assets (data/asset_catalog.json "assets"), so 56108e9 (A1) worded both notes neutrally; stale templates in
## tools/asset_hashes.gd and tools/blender/gladius_bl.py wrote "CC0" back on the next run. Checks both files' generic
## note and the two template strings that write them (only the template strings: code comments elsewhere in those
## files are not written to any data file).

const BANNED := ["CC0 asset", "CC0 source"]
const CATALOG := "res://data/asset_catalog.json"
const MANIFEST := "res://tools/blender/manifest.json"
const HASHES_TOOL := "res://tools/asset_hashes.gd"
const BLENDER_LIB := "res://tools/blender/gladius_bl.py"


func _json(path: String) -> Dictionary:
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	assert_true(data is Dictionary, "%s parses" % path)
	return data if data is Dictionary else {}


func _clean(what: String, text: String) -> void:
	assert_true(text.length() > 40, "%s: found (%d chars)" % [what, text.length()])
	for phrase in BANNED:
		assert_true(not text.contains(phrase), "%s does not say '%s'" % [what, phrase])


## The template line(s) of a source file: from the first line containing `start` up to the first line (inclusive)
## containing `stop` (both may be the same line).
func _template(path: String, start: String, stop: String) -> String:
	var lines := FileAccess.get_file_as_string(path).split("\n")
	var out := ""
	var inside := false
	for line in lines:
		if not inside and line.contains(start):
			inside = true
		if inside:
			out += line + "\n"
			if line.contains(stop):
				break
	return out


func test_generic_notes_do_not_call_every_source_cc0() -> void:
	var note := str(_json(CATALOG).get("_generated_note", ""))
	_clean("asset_catalog.json _generated_note", note)
	assert_true(note.contains("made from that catalogued asset of the assets list"), "the catalog note keeps the A1 wording")
	_clean("manifest.json _note", str(_json(MANIFEST).get("_note", "")))


func test_the_templates_that_write_the_notes_do_not_either() -> void:
	var hashes := _template(HASHES_TOOL, "catalog[\"_generated_note\"] =", "\"")
	_clean("tools/asset_hashes.gd _generated_note template", hashes)
	var blender := _template(BLENDER_LIB, "manifest[\"_note\"] =", ")")
	_clean("tools/blender/gladius_bl.py _note template", blender)
	# The catalog note is exactly what the template writes, so the next --write keeps it.
	var note := str(_json(CATALOG).get("_generated_note", ""))
	assert_true(hashes.contains(note.json_escape()) or hashes.contains(note), "asset_hashes.gd writes the catalog note as it stands")
