extends "res://tests/test_case.gd"
## M2 P0: the phone frame-time logger is off by default and, when on, writes a header and numeric rows.

const _TMP := "user://test_perf_log.csv"


func test_off_by_default() -> void:
	var cfg := DataRegistry.new().load_file(PerfLog.CFG_PATH)
	assert_true(not bool(cfg.get("enabled", true)), "data/perf_log.json ships with enabled false")
	assert_true(not FileAccess.file_exists(PerfLog.FLAG_PATH), "no flag file in the test profile")
	assert_true(not PerfLog.wanted(), "so a match adds no logger")


func test_writes_a_header_and_numeric_rows() -> void:
	if FileAccess.file_exists(_TMP):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_TMP))
	var log := PerfLog.new()
	log.cfg = {"enabled": true, "interval_s": 0.1, "path": _TMP}
	var tree: SceneTree = Engine.get_main_loop()
	tree.root.add_child(log)
	for i in 12:
		await tree.process_frame
	log.write_row()
	log.queue_free()
	await tree.process_frame
	var lines := FileAccess.get_file_as_string(_TMP).strip_edges().split("\n")
	assert_eq(lines[0], PerfLog.HEADER, "header first")
	assert_true(lines[1].begins_with("# match start"), "a start marker")
	var rows := 0
	for line in lines.slice(2):
		var cols := line.split(",")
		assert_eq(cols.size(), PerfLog.HEADER.split(",").size(), "a full row: " + line)
		assert_true(cols[2].is_valid_float() and float(cols[2]) >= 0.0, "mean frame time is a number")
		rows += 1
	assert_true(rows >= 1, "at least one row (%d)" % rows)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_TMP))
