extends "res://tests/test_case.gd"
## C1 guard, committed before the kit gained new shapes: the meshes LowpolyKit builds from the frozen d74333e
## part data must stay byte-identical (vertices, normals, indices; plus bones and weights for the skinned merge).
## The canonical hashes (triangle sets with normals, order-free) must match too: they tell a deliberate
## re-winding from a change of shape. Re-record with tools/kit_hash_record.gd only when old geometry is meant to change.
const KitHash := preload("res://tests/kit_hash.gd")


func _changed(recorded: Dictionary, now: Dictionary) -> PackedStringArray:
	var changed: PackedStringArray = []
	for key: String in recorded:
		if now.get(key, "") != recorded[key]:
			changed.append(key)
	return changed


func test_frozen_part_data_builds_byte_identical_meshes() -> void:
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(KitHash.FIXTURE))
	var recorded: Dictionary = fixture["hashes"]
	var now := KitHash.compute(fixture)
	assert_true(recorded.size() >= 60, "nonvacuous baseline: every soldier, rifle, cover and kind mesh recorded")
	assert_eq(now.size(), recorded.size(), "same mesh list as recorded")
	var changed := _changed(recorded, now)
	# The exact hashes were re-recorded at F1 (winding fix), so they name their own commit; the part data and the
	# canonical hashes are still the d74333e copy.
	assert_true(changed.is_empty(), "kit meshes changed against the exact hashes recorded at %s: %s" % [fixture["exact_source_commit"], ", ".join(changed)])
	var canonical: Dictionary = fixture["canonical_hashes"]
	var canonical_changed := _changed(canonical, KitHash.compute(fixture, true))
	assert_eq(canonical.size(), recorded.size(), "a canonical hash for every mesh")
	assert_true(canonical_changed.is_empty(), "triangle sets changed against the %s baseline: %s" % [fixture["source_commit"], ", ".join(canonical_changed)])
	print("KIT_BASELINE meshes=", recorded.size(), " changed=", changed.size(), " canonical_changed=", canonical_changed.size(), " source_commit=", fixture["source_commit"], " exact_source_commit=", fixture["exact_source_commit"])
