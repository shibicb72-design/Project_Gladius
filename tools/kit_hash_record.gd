extends SceneTree
## Records the C1 kit baseline: godot --headless --path . --script res://tools/kit_hash_record.gd
## First run: copies today's soldier parts, rifle parts and cover types into tests/fixtures/kit_baseline.json.
## Every run: rewrites the hashes of the meshes LowpolyKit builds from that frozen copy (tests/kit_hash.gd).
## Run it ONLY when the old geometry is meant to change; tests/test_kit_baseline.gd compares the kit against
## this file on every suite run. "source_commit" is the commit the part data was copied at and never changes.
## "exact_source_commit" is the commit whose kit code the exact hashes were last recorded from (45b76aa, the F1
## winding fix): after a deliberate re-record, set it by hand to the commit that carries the kit change.

const _KitHash := preload("res://tests/kit_hash.gd")
const KINDS: Array[String] = ["pillar", "rock", "rubble", "arch", "sandbags", "wall", "low_wall", "barrier", "crate", "camp", "box"]
const PROBE_SIZES: Array = [[2, 1, 1], [3, 2.5, 0.6]]


func _initialize() -> void:
	var fixture := {}
	if FileAccess.file_exists(_KitHash.FIXTURE):
		fixture = JSON.parse_string(FileAccess.get_file_as_string(_KitHash.FIXTURE))
	else:
		var registry := DataRegistry.new()
		var art: Dictionary = registry.load_file("res://data/art_astra.json")
		var commit: Array = []
		OS.execute("git", ["rev-parse", "--short", "HEAD"], commit)
		fixture = {
			"_note": "Frozen copy of part data, written by tools/kit_hash_record.gd. Not live art data: do not edit by hand.",
			"source_commit": String(commit[0]).strip_edges() if not commit.is_empty() else "unknown",
			"soldier_parts": art["soldier"]["parts"],
			"rifle_parts": art["rifle"]["parts"],
			"skin_bone_count": (registry.load_file("res://data/anim.json")["bones"] as Array).size(),
			"cover_types": registry.load_file("res://data/maps/alesia_cover.json")["types"],
			"kinds": KINDS,
			"probe_sizes": PROBE_SIZES,
		}
	var before: Dictionary = fixture.get("hashes", {})
	var before_canonical: Dictionary = fixture.get("canonical_hashes", {})
	fixture["hashes"] = _KitHash.compute(fixture)
	fixture["canonical_hashes"] = _KitHash.compute(fixture, true)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/fixtures"))
	var file := FileAccess.open(_KitHash.FIXTURE, FileAccess.WRITE)
	file.store_string(JSON.stringify(fixture, "\t") + "\n")
	file.close()
	# The numbers went through text: prove the file rebuilds the very same meshes.
	var reread: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(_KitHash.FIXTURE))
	var same: bool = _KitHash.compute(reread) == fixture["hashes"] and _KitHash.compute(reread, true) == fixture["canonical_hashes"]
	print("KIT_BASELINE recorded=", (fixture["hashes"] as Dictionary).size(), " round_trip_identical=", same, " commit=", fixture["source_commit"],
			" exact_changed=", _changed(before, fixture["hashes"]), " canonical_changed=", _changed(before_canonical, fixture["canonical_hashes"]))
	quit(0 if same else 1)


## How many previously recorded hashes differ now (0 on a first recording).
static func _changed(before: Dictionary, now: Dictionary) -> int:
	var count := 0
	for key: String in before:
		if now.get(key, "") != before[key]:
			count += 1
	return count
