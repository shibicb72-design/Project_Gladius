extends "res://tests/test_case.gd"
## A3 fix pass 1 (S1): what a death costs on the CPU. DeathFx builds the corpse with SoldierModel.make_corpse
## (SoldierCorpse.build: the rig, the snapshot, authored_collapse with the hand settle and the crossfade's feet).
## Measured with Time.get_ticks_usec() around make_corpse, for the FIRST and the TENTH death of each armour set, in
## this test process (headless, on whatever PC runs it: printed as A3_CORPSE_MS, not a performance claim; the first
## is only a real first when this file runs in its own process, --only=test_a3_corpse_cost). Wall-clock asserts flake
## on a shared machine, so only robust facts are asserted: the per-set vertex sets and the sampled death clip are
## cached once the set's soldier model is built (before any death; the deaths add no clip sampling), and the tenth
## death stays under contact.corpse_first_budget_ms x SLACK.

const DT := 1.0 / 60.0
const DEATHS := 10
const SLACK := 4.0


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _pawn(set_id: String) -> Pawn:
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	pawn.set_meta("armour_set", set_id)
	_tree().root.add_child(pawn)
	pawn.set_physics_process(false)
	var model := pawn.get_node("SoldierModel") as SoldierModel
	model.set_process(false)
	model.animation_tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	model.skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
	return pawn


func _tick(model: SoldierModel) -> void:
	model._process(DT)
	model.animation_tree.advance(DT)
	model.skeleton.advance(DT)
	await _tree().process_frame


func test_corpse_cost_first_and_tenth_death_per_set() -> void:
	var budget := float(SoldierRig.config()["contact"]["corpse_first_budget_ms"])
	assert_true(bool(SoldierRig.config()["contact"]["_placeholder"]), "the budget is a placeholder (OQ-A3-CONTACT)")
	for set_id: String in SoldierRig.armour_sets():
		var pawn := _pawn(set_id)
		var model := pawn.get_node("SoldierModel") as SoldierModel
		for i in 10:
			await _tick(model)
		# Fix pass 1: the set's hand and foot vertex sets are read when its soldier model is built, not at the death.
		var cached := SoldierCorpse.has_limb_verts(model.armor.mesh) and SoldierCorpse.has_settle(model.armor.mesh, SoldierAnimation.shared("death", model.skeleton))
		var clips_before := SoldierCorpse._clip_globals.size()
		var ms: Array[float] = []
		for i in DEATHS:
			var t0 := Time.get_ticks_usec()
			var corpse := model.make_corpse()
			ms.append(float(Time.get_ticks_usec() - t0) / 1000.0)
			corpse.free()
		print("A3_CORPSE_MS set=%s first=%.2f tenth=%.2f all=%s cached_before_first_death=%s (headless, this PC, not a performance claim)" % [set_id, ms[0], ms[DEATHS - 1], ", ".join(ms.map(func(v: float) -> String: return "%.1f" % v)), cached])
		assert_true(cached, "%s: the vertex sets are cached before the first death" % set_id)
		assert_true(clips_before > 0 and SoldierCorpse._clip_globals.size() == clips_before, "%s: the deaths used the death clip sampled when the model was built (%d -> %d entries)" % [set_id, clips_before, SoldierCorpse._clip_globals.size()])
		assert_true(ms[DEATHS - 1] <= budget * SLACK, "%s: the tenth death costs %.1f ms (generous limit %.0f ms)" % [set_id, ms[DEATHS - 1], budget * SLACK])
		pawn.free()
		await _tree().process_frame
