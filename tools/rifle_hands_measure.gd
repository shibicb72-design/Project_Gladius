extends SceneTree
## M2 AN3 stage D: the third-person rifle hands, measured headless at 1/60 s, per gun (pilum_br, sagittarii_rifle):
##   godot.cmd --headless --path . --fixed-fps 60 --log-file <log> --script res://tools/rifle_hands_measure.gd
## The gun is made the pawn's active weapon (SoldierModel shows the active weapon's gun every frame).
## - aim: pitch -1, 0, +1 x aim_pitch_limit_deg held 0.5 s each: the left hand's distance to the shown gun's foregrip
##   (SoldierModel.hand_error_m; the runtime left-hand IK is on), and the stock's distance to the right shoulder;
## - reload, keyed and code-built (SoldierModel.code_built_reload), each started the way the game starts it
##   (Pawn.reload_started -> SoldierModel.play_reload, the gun's own WeaponDef.reload_s): the same distance per
##   frame. The IK is off during the reload (SoldierHandSync), so the clip alone places the hand: its error at the
##   start and end (where the hand should be on the foregrip), the farthest it gets, and the largest one-frame jump of
##   the hand around the reload's start and around its end (the IK taking the hand back: a snap when the clip's end
##   does not match the gun).
## One line per gun and phase (RIFLE_HANDS ...). Presentation measurement only.

const DT := 1.0 / 60.0
const GUNS: Array[String] = ["pilum_br", "sagittarii_rifle"]


func _initialize() -> void:
	_run.call_deferred()


func _step(pawn: Pawn, model: SoldierModel) -> void:
	pawn.velocity = Vector3.ZERO
	model._process(DT)
	model.animation_tree.advance(DT)
	model.skeleton.advance(DT)
	await process_frame


func _left_hand(model: SoldierModel) -> Vector3:
	return model.skeleton.global_transform * model.pose_cache[model.skeleton.find_bone("LeftHand")].origin


func _jump(hands: Array[Vector3], from: int, to: int) -> float:
	var out := 0.0
	for i in range(maxi(from, 1), mini(to, hands.size())):
		out = maxf(out, hands[i].distance_to(hands[i - 1]))
	return out


func _run() -> void:
	var registry := DataRegistry.new()
	var limit := deg_to_rad(float(SoldierRig.config()["upper_body"]["aim_pitch_limit_deg"]))
	for gun in GUNS:
		for mode in ["code", "keyed"]:
			SoldierModel.code_built_reload = mode == "code"
			var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
			root.add_child(pawn)
			pawn.set_physics_process(false)
			var def := registry.get_weapon_def(gun)
			pawn.loadout.slots[pawn.loadout.active] = Weapon.new(def)
			var model := pawn.get_node("SoldierModel") as SoldierModel
			model.set_process(false)
			model.animation_tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
			model.skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
			for i in 10:
				await _step(pawn, model)
			if mode == "code":
				var shoulder_bone := model.skeleton.find_bone("RightUpperArm")
				for pitch in [-1.0, 0.0, 1.0]:
					pawn.pitch = limit * pitch
					var worst := 0.0
					var stock := 0.0
					for i in 30:
						await _step(pawn, model)
						worst = maxf(worst, model.hand_error_m)
						var shoulder := (model.skeleton.global_transform * model.pose_cache[shoulder_bone]).origin
						stock = maxf(stock, shoulder.distance_to(model.rifle.global_transform * model.stock_point))
					print("RIFLE_HANDS gun=%s shown=%s phase=aim pitch=%+.0f hand_error_max_m=%.4f stock_shoulder_max_m=%.4f" % [gun, model.shown_gun, pitch, worst, stock])
				pawn.pitch = 0.0
				for i in 30:
					await _step(pawn, model)
			var aim_error := model.hand_error_m
			var errors: Array[float] = []
			var hands: Array[Vector3] = [_left_hand(model)]
			pawn.reload_started.emit()
			var reload_s := def.reload_s
			var last_active := -1
			for i in roundi((reload_s + 0.4) / DT):
				await _step(pawn, model)
				errors.append(_left_hand(model).distance_to(model.foregrip.global_position))
				hands.append(_left_hand(model))
				if bool(model.animation_tree.get("parameters/reload/active")):
					last_active = i
			var away := 0.0
			for e in errors:
				away = maxf(away, e)
			# hands[0] is the aimed frame before the reload; hands[i + 1] the i-th frame after the reload started.
			# snap_start: the aimed frame -> the first reload frame; snap_end: the last reload frame -> the first frame
			# the IK holds the hand again; clip_end_step: the clip's own last step before it (the hand still moving).
			var end := last_active + 1
			print("RIFLE_HANDS gun=%s shown=%s phase=reload mode=%s reload_s=%.2f reload_frames=%d aim_error_m=%.4f start_error_m=%.4f end_error_m=%.4f max_away_m=%.4f snap_start_m=%.4f snap_end_m=%.4f clip_end_step_m=%.4f after_max_step_m=%.4f" % [
				gun, model.shown_gun, mode, reload_s, end, aim_error, errors[0], errors[last_active], away,
				hands[1].distance_to(hands[0]), hands[end + 1].distance_to(hands[end]), hands[end].distance_to(hands[end - 1]),
				_jump(hands, end + 2, hands.size())])
			pawn.free()
			await process_frame
	SoldierModel.code_built_reload = false
	print("RIFLE_HANDS DONE")
	quit(0)
