extends "res://tests/test_case.gd"
## W1c fix pass 1 (review B1, B2): the shader warm-up's coverage is what its COPIES drew (scripts/visual/shader_warmup.gd
## step / check), never what the source nodes have; every required listed entry (data/warmup.json "listed") exists,
## the view weapons are derived from the data, and the warm-up leaves the match as it was.
## Headless there is no GL: these check that each item MADE its geometry with the expected draw keys. Breakable debris
## makes nothing headless by design (Breakable._spawn_fx returns at once, breakable.gd): its entry and items are
## asserted here, its draw is checked only in the browser.

const _MatchScene := preload("res://scenes/match/match.tscn")
const MAP_500 := "res://data/maps/alesia_500.json"
## The listed kinds a match needs, kept here on purpose (not read from ShaderWarmup.REQUIRED_LISTED): removing one from
## data/warmup.json fails test_every_required_listed_entry_exists.
const REQUIRED: Array[String] = ["soldier_sets", "corpse", "shot_fx", "impacts", "breakable_fx", "loot", "zone_wall",
		"view_weapons", "swing_bar"]


## A warm-up whose copies are never made (as if _copy_of returned null).
class _NullCopy extends ShaderWarmup:
	func _copy_of(_src: Node) -> Node3D:
		return null


## A warm-up whose mesh copies drop the source's material override (a copy that draws another program).
class _DropOverride extends ShaderWarmup:
	func _copy_of(src: Node) -> Node3D:
		var c := super(src)
		if c is GeometryInstance3D:
			(c as GeometryInstance3D).material_override = null
		return c


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _frames(n: int) -> void:
	for i in n:
		await _tree().process_frame


static func _mesh_instance(mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.material = mat
	mi.mesh = box
	return mi


## A small scene in the tree with two draw keys no listed item draws (one through a material override).
func _fake_match(node_name: String) -> Node3D:
	var root := Node3D.new()
	root.name = node_name
	var a := StandardMaterial3D.new()
	a.rim_enabled = true
	root.add_child(_mesh_instance(a))
	var b := StandardMaterial3D.new()
	b.clearcoat_enabled = true
	var over := _mesh_instance(b)
	var m := StandardMaterial3D.new()
	m.subsurf_scatter_enabled = true
	over.material_override = m
	root.add_child(over)
	_tree().root.add_child(root)
	return root


func _run(w: ShaderWarmup) -> int:
	var steps := 0
	while not w.step() and steps < 800:
		steps += 1
		await _tree().process_frame
	return steps


static func _ids(list: Array) -> Array:
	return list.map(func(f: Variant) -> String: return String((f as Dictionary)["id"]) if f is Dictionary else String(f))


## (2), (3): every required kind is in data/warmup.json; a config without one is reported missing by the warm-up.
func test_every_required_listed_entry_exists() -> void:
	var cfg := ShaderWarmup.config()
	var missing := ShaderWarmup.missing_required(cfg, REQUIRED)
	assert_true(missing.is_empty(), "data/warmup.json lists every required kind; missing: %s" % ", ".join(missing))
	for kind in REQUIRED:
		assert_true(ShaderWarmup.REQUIRED_LISTED.has(kind), "%s: the warm-up itself warns in a real run when it is missing" % kind)
	var root := _fake_match("W1cRequiredMatch")
	for kind in REQUIRED:
		var cut := cfg.duplicate(true)
		cut["listed"] = (cut["listed"] as Array).filter(func(e: Dictionary) -> bool: return String(e.get("kind", "")) != kind)
		assert_eq(Array(ShaderWarmup.missing_required(cut, REQUIRED)), [kind], "a config without %s is reported missing it" % kind)
		var w := ShaderWarmup.new()
		w.quiet = true
		root.add_child(w)
		w.setup(root, null, cut)
		assert_true((w.check()["missing_required"] as PackedStringArray).has(kind), "the warm-up reports %s missing" % kind)
		assert_true(w.items.filter(func(i: Dictionary) -> bool: return String(i["id"]).begins_with("listed:" + kind)).is_empty(),
				"and makes no %s item" % kind)
		root.remove_child(w)
		w.free()
	root.queue_free()
	await _frames(1)


## (2): the view weapons are every id the data can put in a hand (loadouts, loot weapons, start kit), not a typed list.
func test_view_weapons_are_derived_from_the_data() -> void:
	var reg := DataRegistry.new()
	var want := {}
	for cls: Dictionary in (reg.load_file("res://data/loadouts.json")["classes"] as Dictionary).values():
		for slot: String in ["primary", "secondary", "sidearm"]:
			if str(cls.get(slot, "")) != "":
				want[str(cls[slot])] = true
	var loot := reg.load_file("res://data/loot.json")
	for it: Dictionary in (loot["items"] as Dictionary).values():
		if it.get("kind", "") == "weapon":
			want[str(it["weapon"])] = true
	for slot: String in ["primary", "secondary", "sidearm"]:
		if str((loot["start_kit"] as Dictionary).get(slot, "")) != "":
			want[str(loot["start_kit"][slot])] = true
	var ids := ShaderWarmup.view_weapon_ids()
	var expect := PackedStringArray(want.keys())
	expect.sort()
	assert_eq(ids, expect, "view_weapon_ids() is the data's weapon set")
	var melee := 0
	for id in ids:
		assert_true(reg.get_weapon_def(id) != null, "%s has a weapon def" % id)
		melee += 1 if reg.get_weapon_def(id).is_melee() else 0
	assert_true(ids.size() >= 2 and melee >= 1 and melee < ids.size(), "guns and a blade (%s)" % ", ".join(ids))
	var root := _fake_match("W1cViewIdsMatch")
	var w := ShaderWarmup.new()
	w.quiet = true
	root.add_child(w)
	w.setup(root, null)
	for id in ids:
		assert_eq(w.items.filter(func(i: Dictionary) -> bool: return i["id"] == "listed:view_weapons:" + id).size(), 1, "one view weapon item for %s" % id)
	assert_eq(w.items.filter(func(i: Dictionary) -> bool: return i["id"] == "listed:swing_bar").size(), 1, "one swing bar item")
	root.queue_free()
	await _frames(1)


## (3) in-test: a warm-up whose copies are never made covers nothing derived and reports every derived item; one whose
## copy draws another program (the override dropped) reports the key it lacks.
func test_a_copy_that_draws_nothing_or_otherwise_is_reported() -> void:
	for variant in ["null", "drop_override"]:
		var root := _fake_match("W1cBadCopy_" + variant)
		var w: ShaderWarmup = _NullCopy.new() if variant == "null" else _DropOverride.new()
		w.quiet = true
		root.add_child(w)
		w.setup(root, null)
		var derived := w.items.filter(func(i: Dictionary) -> bool: return i["source"] == "derived")
		assert_eq(derived.size(), 2, "%s: two derived items" % variant)
		await _run(w)
		var chk := w.check()
		var failed := _ids(chk["failed"])
		var missing := ShaderWarmup.uncovered(root, w.covered)
		if variant == "null":
			for item: Dictionary in derived:
				assert_true(failed.has(item["id"]), "null: %s is reported failed" % item["id"])
			assert_eq(missing.size(), 2, "null: both source keys stay uncovered: %s" % "; ".join(missing))
		else:
			var bad := (chk["failed"] as Array).filter(func(f: Dictionary) -> bool: return String(f["id"]).begins_with("derived:"))
			var dbg := str(derived.map(func(i: Dictionary) -> String: return "%s %s exp=%s got=%s" % [i["id"], i["status"], str(i["expected"]), str(i["keys"])]))
			assert_eq(bad.size(), 1, "drop_override: one derived item failed: %s" % dbg)
			assert_eq(missing.size(), 1, "drop_override: the overridden key stays uncovered: %s" % "; ".join(missing))
			if bad.size() == 1:
				assert_true(String(bad[0]["why"]).contains("lacks"), "drop_override: the reason names the lacking key (%s)" % bad[0]["why"])
		root.queue_free()
		await _frames(1)


func _open_500() -> Dictionary:
	MatchLook.variant_override = "dusk"
	var s := NetSession.new()
	s.name = "W1cItemsSession"
	s.isolated = true
	_tree().root.add_child(s)
	s.start_offline()
	s.lobby.host_open(2, 1, "Solus")
	s.lobby.state.start()
	var m: MatchRoot = _MatchScene.instantiate()
	m.open_path = MatchRoot.OpenPath.STAGED
	m.session_override = s
	m.lobby_override = s.lobby.state
	m.seed_override = 4242
	m.map_path_override = MAP_500
	_tree().root.add_child(m)
	var n := 0
	while m.opening and n < 4000:
		await _tree().process_frame
		n += 1
	return {"match": m, "session": s}


## (1), (2), (4): on a real staged open of alesia_500 every item, derived and listed, made geometry with its expected
## keys; each required entry made its items; breakable debris is the only inert kind headless.
func test_every_item_draws_its_keys_on_alesia_500() -> void:
	var r: Dictionary = await _open_500()
	var m: MatchRoot = r["match"]
	assert_true(not m.opening and m.director.running, "the match opened")
	var chk: Dictionary = m.warmup_report.get("check", {})
	assert_true(not chk.is_empty(), "the open kept the warm-up's check")
	assert_true((chk["failed"] as Array).is_empty(), "every item drew its keys; failed: %s" % str(chk["failed"]))
	assert_true((chk["pending"] as Array).is_empty(), "every item was stepped")
	assert_true((chk["missing_required"] as PackedStringArray).is_empty(), "no required entry missing")
	assert_true((chk["skipped"] as PackedStringArray).is_empty(), "nothing skipped outside the browser harness")
	var ok: Array = chk["ok"]
	assert_true(ok.filter(func(id: String) -> bool: return id.begins_with("derived:")).size() >= 10, "the derived items drew (%d ok)" % ok.size())
	var by_kind := {}
	for entry: Dictionary in ShaderWarmup.config()["listed"]:
		by_kind[String(entry["kind"])] = "listed:" + String(entry["id"])
	for kind in REQUIRED:
		if kind == "breakable_fx":
			continue
		var prefix: String = by_kind.get(kind, "listed:" + kind)
		assert_true(ok.any(func(id: String) -> bool: return id == prefix or id.begins_with(prefix + ":")), "%s made its items (%s)" % [kind, prefix])
	for id in ShaderWarmup.view_weapon_ids():
		assert_true(ok.has("listed:view_weapons:" + id), "the view weapon %s drew" % id)
	assert_true(ok.has("listed:swing_bar"), "the swing bar drew")
	# (4) Breakable debris: the entry and one item per breakable type exist; headless Breakable._spawn_fx makes no
	# geometry by design, so these are "inert" here and their draw is checked only in the browser (perf harness).
	var types: Dictionary = DataRegistry.new().load_file("res://data/props.json").get("breakables", {})
	var inert: Array = chk["inert"]
	assert_true(not types.is_empty(), "the data has breakable types")
	for t: String in types:
		assert_true(inert.has(String(by_kind["breakable_fx"]) + ":" + t), "breakable debris %s is listed (inert headless)" % t)
	assert_eq(inert.size(), types.size(), "only the breakable debris is inert headless: %s" % str(inert))
	m.queue_free()
	await _frames(2)
	MatchLook.variant_override = ""
	(r["session"] as NetSession).leave()
	(r["session"] as NetSession).queue_free()
	await _frames(1)


## The view weapons are built through the same public builder the view model uses on a first show, so the meshes the
## warm copies drew ARE the ones that first show gets from ViewMesh / ViewHands' caches (no second .glb read or
## per-vertex pass); and the warm-up leaves the match as it was: shown weapon, loadout, ammo, health, armour, sounds,
## the pawn's signals (haptics are bound to them) and the RNG streams.
func test_view_weapons_share_the_view_models_meshes_and_state_stays() -> void:
	var s := NetSession.new()
	s.name = "W1cStateSession"
	s.isolated = true
	_tree().root.add_child(s)
	s.start_offline()
	s.lobby.host_open(2, 1, "Solus")
	s.lobby.state.start()
	var m: MatchRoot = _MatchScene.instantiate()
	m.session_override = s
	m.lobby_override = s.lobby.state
	m.seed_override = 4242
	m.map_path_override = MatchRoot.MAP_PATH
	_tree().root.add_child(m)  # begin() in _ready (headless AUTO)
	for i in 3:
		await _tree().physics_frame
	await _tree().process_frame
	_tree().paused = true  # nothing of the match runs while the warm-up steps (as in the staged open)
	var pawn: Pawn = m.local_player
	var rig := pawn.get_node("CameraRig") as CameraRig
	var vm := rig.get_view_model()
	assert_true(vm != null and vm.get_shown_weapon_id() != "", "the view model shows the starting weapon")
	var signals := {"n": 0}
	var count := func() -> void: signals["n"] += 1
	for sig: String in ["fired", "shot", "reload_started", "weapon_switched", "shot_resolved", "melee_landed", "damaged", "fire_empty"]:
		var args := 0
		for info: Dictionary in pawn.get_signal_list():
			if info["name"] == sig:
				args = (info["args"] as Array).size()
		pawn.connect(sig, count.unbind(args) if args > 0 else count)
	var before := _state(m)
	var w := ShaderWarmup.new()
	w.quiet = true
	m.add_child(w)
	w.setup(m, rig.get_camera())
	var warm_meshes := {}
	var steps := 0
	while not w.step() and steps < 800:
		steps += 1
		var item := w.items[w.index - 1] if w.index > 0 else {}
		if not item.is_empty() and item.get("kind", "") == "view_weapon" and not warm_meshes.has(item["arg"]):
			var node := w.find_children("Weapon_" + String(item["arg"]), "Node3D", true, false)
			if not node.is_empty():
				var arm_mi := node[0].get_node_or_null("RightArm/Skeleton/Mesh") as MeshInstance3D
				warm_meshes[item["arg"]] = {"mesh": (node[0].get_node("Mesh") as MeshInstance3D).mesh,
						"arm": arm_mi.mesh if arm_mi != null else null}
		await _tree().process_frame
	assert_true(w.done, "the warm-up finished")
	assert_true((w.check()["failed"] as Array).is_empty(), "every item drew on alesia_section: %s" % str(w.check()["failed"]))
	# Every seeded stream of the match (the pawns' own RNGs; loot and props: test_w1c_staged_open) is unchanged. The
	# engine's particle nodes draw from the GLOBAL stream when they emit or restart (probed: CPUParticles3D and
	# GPUParticles3D both do, as every live particle node does each frame in play); the match reads that stream only
	# for footstep variety (pawn_audio.gd) and the lobby's seed (before the open), so it is not compared here.
	assert_eq(_state(m), before, "the match state is unchanged by the warm-up")
	assert_eq(signals["n"], 0, "no pawn signal fired (no shot, swing, switch or hit: no sound or haptic event)")
	assert_eq(vm.get_shown_weapon_id(), before["shown"], "the shown weapon is the same")
	var vm_cfg: Dictionary = DataRegistry.new().get_camera_cfg()["first_person"]["view_model"]
	for id in ShaderWarmup.view_weapon_ids():
		assert_true(warm_meshes.has(id), "%s was drawn by the warm-up" % id)
		if not warm_meshes.has(id):
			continue
		var def := DataRegistry.new().get_weapon_def(id)
		var fallback := String(vm_cfg["default_melee" if def.is_melee() else "default_gun"])
		var first_show := ViewWeapons.build(id, fallback)  # what ViewRig.build_weapon (ViewModel._build_weapon) builds
		assert_true((first_show.get_node("Mesh") as MeshInstance3D).mesh == warm_meshes[id]["mesh"], "%s: the first show gets the warm mesh" % id)
		var warm_arm: Variant = warm_meshes[id]["arm"]
		if warm_arm != null:
			var arm := ViewHands.build_arm("r")
			assert_true((arm.get_node("Skeleton/Mesh") as MeshInstance3D).mesh == warm_arm, "%s: and the warm arm mesh" % id)
			arm.free()
		first_show.free()
	m.remove_child(w)
	w.queue_free()
	_tree().paused = false
	m.queue_free()
	await _frames(2)
	s.leave()
	s.queue_free()
	await _frames(1)


func _state(m: MatchRoot) -> Dictionary:
	var pawn: Pawn = m.local_player
	var vm := (pawn.get_node("CameraRig") as CameraRig).get_view_model()
	var slots: Array = []
	for wpn: Weapon in pawn.loadout.slots:
		slots.append([wpn.def.id, wpn.ammo_in_mag, wpn.reserve] if wpn != null else null)
	return {
		"shown": vm.get_shown_weapon_id() if vm != null else "",
		"shown_node": vm.get_shown_weapon().get_instance_id() if vm != null and vm.get_shown_weapon() != null else 0,
		"active": pawn.loadout.active,
		"slots": slots,
		"health": pawn.bridge.state.health,
		"shield": pawn.bridge.state.shield,
		"armor": pawn.armor_tier,
		"life": pawn.life,
		"pawn_rng": (pawn.get("_rng") as RandomNumberGenerator).state,
		"bot_rngs": m.bots.map(func(b: Pawn) -> int: return (b.get("_rng") as RandomNumberGenerator).state),
		"sounds": Sfx.played.size(),
		"bots": m.bots.size(),
		"tick": m.director.tick_count,
	}
