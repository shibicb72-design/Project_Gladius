extends "res://tests/test_case.gd"
## D1 (spec G1.5) source guards. T7: scripts/ui may only READ a CoverController. T8: the host ignores the
## crouch/prone/interact frame bits until D9/G3.2 (cover stays owner-only, OQ-COVER).

const UI_DIR := "res://scripts/ui"
const NET_DIR := "res://scripts/net"
const COVER_PATH := "res://scripts/systems/cover_controller.gd"

## Read-only CoverController API that UI may call. Field reads and null checks are also allowed.
const READ_ONLY_METHODS: Array[String] = ["state_name", "blocks_fire", "can_quick_draw"]
## Every other func in cover_controller.gd, written out (derived from its `func` lines; the test fails when a
## new func appears so it must be classified here). UI may call none of them.
const MUTATORS: Array[String] = ["_init", "reset", "toggle_crouch", "set_look_active", "quick_draw",
	"quick_draw_trigger", "round_fired", "refresh_shot_clear", "refresh_completed_pose", "tick", "_update_crouch",
	"_tick_draw", "_try_snap", "_plane_position", "_begin_exit", "movement_velocity"]
## Crouch mutators: forbidden anywhere in scripts/ui, with no exception.
const CROUCH_METHODS: Array[String] = ["toggle_crouch", "_update_crouch"]
const CROUCH_FIELDS: Array[String] = ["crouched", "crouch_amount"]
## ONE exception list, keyed by file and method (not lines). TODO(D2): cover FIRE still drives the controller
## from UI (look-hold and quick-draw); D2 owns "a path for cover FIRE" and should empty this list.
const EXCEPTIONS := {"cover_fire_button.gd": ["quick_draw", "set_look_active"]}


## Removes `#` comments, keeping `#` inside string literals.
static func strip_comments(src: String) -> String:
	var out: PackedStringArray = []
	for line in src.split("\n"):
		var quote := ""
		var cut := line.length()
		var i := 0
		while i < line.length():
			var c := line[i]
			if quote != "":
				if c == "\\":
					i += 1
				elif c == quote:
					quote = ""
			elif c == "\"" or c == "'":
				quote = c
			elif c == "#":
				cut = i
				break
			i += 1
		out.append(line.substr(0, cut))
	return "\n".join(out)


static func _names(src: String, pattern: String) -> Array[String]:
	var re := RegEx.new()
	re.compile(pattern)
	var found: Array[String] = []
	for m in re.search_all(src):
		if not found.has(m.get_string(1)):
			found.append(m.get_string(1))
	return found


## Violations in one UI source: "method:<name>" / "assign:<field>" on a cover receiver, or a crouch mutator.
static func violations(src: String) -> Array[String]:
	var code := strip_comments(src)
	# Receivers: any `...cover`, plus local aliases of it and anything typed CoverController.
	var receivers: Array[String] = ["cover"]
	for alias in _names(code, "(?m)\\bvar\\s+(\\w+)\\s*(?::\\s*\\w*\\s*)?=\\s*[\\w.]*\\bcover\\s*$"):
		receivers.append(alias)
	for alias in _names(code, "(\\w+)\\s*:\\s*CoverController\\b"):
		receivers.append(alias)
	var bad: Array[String] = []
	for r in receivers:
		for m in _names(code, "\\b%s\\s*\\.\\s*(\\w+)\\s*\\(" % r):
			if not READ_ONLY_METHODS.has(m) and not bad.has("method:" + m):
				bad.append("method:" + m)
		for f in _names(code, "\\b%s\\s*\\.\\s*(\\w+)\\s*(?:[-+*/%%|&^]|<<|>>)?=(?!=)" % r):
			if not bad.has("assign:" + f):
				bad.append("assign:" + f)
	for m in CROUCH_METHODS:
		if RegEx.create_from_string("\\b%s\\b" % m).search(code) != null and not bad.has("crouch:" + m):
			bad.append("crouch:" + m)
	for f in CROUCH_FIELDS:
		if RegEx.create_from_string("\\.\\s*%s\\s*(?:[-+*/]?=(?!=))" % f).search(code) != null:
			bad.append("crouch:" + f)
		# set("crouched", ...) / call style writes by name, on any object.
		if RegEx.create_from_string("\\b(?:set|set_deferred|call|callv|call_deferred)\\s*\\(\\s*&?[\"']%s[\"']" % f).search(code) != null:
			bad.append("crouch:" + f)
	return bad


func _cover_fields() -> Array[String]:
	return _names(FileAccess.get_file_as_string(COVER_PATH), "(?m)^var\\s+(\\w+)")


# ---- T7 -----------------------------------------------------------------------------------------

func test_t7_mutator_list_is_derived_from_cover_controller() -> void:
	var src := FileAccess.get_file_as_string(COVER_PATH)
	var funcs := _names(src, "(?m)^func\\s+(\\w+)")
	assert_true(funcs.size() > 0, "cover_controller.gd funcs parsed")
	for f in funcs:
		assert_true(READ_ONLY_METHODS.has(f) or MUTATORS.has(f), "cover func %s classified as read-only or mutator" % f)
	for m in MUTATORS + READ_ONLY_METHODS:
		assert_true(funcs.has(m), "listed func %s exists in cover_controller.gd" % m)
	var fields := _cover_fields()
	for f in ["state", "crouched", "crouch_amount"]:
		assert_true(fields.has(f), "cover field %s parsed" % f)


func test_t7_scanner_bites_on_samples() -> void:
	var cases := {
		"pawn.cover.toggle_crouch()": "method:toggle_crouch",
		"\tvar c := pawn.cover\n\tc.reset()": "method:reset",
		"\tvar c: CoverController = pawn.cover\n\tc.state = 0": "assign:state",
		"func f(k: CoverController) -> void:\n\tk.round_fired()": "method:round_fired",
		"pawn.cover.crouch_amount += 0.5": "assign:crouch_amount",
		"pawn.cover.set(\"crouched\", true)": "method:set",
		"var t := pawn.cover.quick_draw_trigger()": "method:quick_draw_trigger",
		"x.crouched = true": "crouch:crouched",
	}
	for sample in cases:
		assert_true(violations(sample).has(cases[sample]), "scanner flags %s in: %s" % [cases[sample], sample])
	assert_true(violations("obj.set(\"crouch_amount\", 1.0)").has("crouch:crouch_amount"), "scanner flags set() by name")
	var clean := "\t# pawn.cover.toggle_crouch()\n\tvar s := pawn.cover.state_name()\n\tif pawn.cover != null and pawn.cover.state == CoverController.State.IN_COVER and not pawn.cover.blocks_fire() and pawn.cover.can_quick_draw():\n\t\tlabel.text = \"#\" + str(pawn.cover.crouched)"
	assert_eq(violations(clean), [] as Array[String], "reads, null checks and comments are allowed")


func test_t7_no_ui_script_mutates_cover_controller() -> void:
	var dir := DirAccess.open(UI_DIR)
	assert_true(dir != null, "scripts/ui opens")
	var files := dir.get_files()
	var scanned := 0
	var used := {}
	for file in files:
		if not file.ends_with(".gd"):
			continue
		scanned += 1
		var allowed: Array = EXCEPTIONS.get(file, [])
		for v in violations(FileAccess.get_file_as_string(UI_DIR + "/" + file)):
			var meth := v.trim_prefix("method:")
			if v.begins_with("method:") and allowed.has(meth) and not CROUCH_METHODS.has(meth):
				used[file + ":" + meth] = true
				continue
			failures.append("%s mutates CoverController from UI: %s" % [file, v])
	assert_true(scanned >= 2, "UI scripts scanned")
	# The D2 exception stays exact: every listed entry is still in use (remove it when D2 reroutes cover FIRE).
	for file in EXCEPTIONS:
		for meth in EXCEPTIONS[file]:
			assert_true(used.has(file + ":" + meth), "exception %s:%s still needed" % [file, meth])


# ---- T8 -----------------------------------------------------------------------------------------

const _PawnScene := preload("res://scenes/player/pawn.tscn")
const PEER := 77
const PID := 5


func _aim_state_after(bits: bool) -> Array:
	var root := Node.new()
	(Engine.get_main_loop() as SceneTree).root.add_child(root)
	var director := MatchDirector.new()
	root.add_child(director)
	var bridge := NetMatchBridge.new()
	bridge.name = "Bridge"
	root.add_child(bridge)
	bridge.set_physics_process(false)
	bridge.setup(director)
	var pawn: Pawn = _PawnScene.instantiate()
	root.add_child(pawn)
	pawn.set_physics_process(false)
	director.add_player(PID, pawn)
	bridge.register_peer(PEER, PID)
	var f := InputFrame.new()
	f.aim_pressed = true
	f.has_aim_point = true
	f.aim_point = Vector3(1, 2, -9)
	for a in ["crouch", "prone", "interact"]:
		f.set_button(a, bits, bits)
	bridge.host_note_input(PEER, f.to_array())
	var state := [bridge._last_aim.get(PID), bridge._last_aim_point.get(PID)]
	root.queue_free()
	return state


func test_t8_host_ignores_crouch_prone_interact_bits() -> void:
	var with_bits := _aim_state_after(true)
	var without := _aim_state_after(false)
	assert_eq(with_bits, without, "host aim state identical with crouch/prone/interact set")
	assert_eq(with_bits, [true, Vector3(1, 2, -9)], "aim still read from the frame")


func test_t8_net_scripts_never_read_the_new_bits() -> void:
	var dir := DirAccess.open(NET_DIR)
	assert_true(dir != null, "scripts/net opens")
	var re := RegEx.create_from_string("(?i)crouch|prone|interact")
	var scanned := 0
	for file in dir.get_files():
		if not file.ends_with(".gd"):
			continue
		scanned += 1
		var hit := re.search(strip_comments(FileAccess.get_file_as_string(NET_DIR + "/" + file)))
		assert_true(hit == null, "%s reads %s (host must ignore it until D9/G3.2)" % [file, hit.get_string() if hit != null else ""])
	assert_true(scanned > 0, "net scripts scanned")
