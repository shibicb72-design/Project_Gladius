extends SceneTree
## A3 item 3 THROWAWAY (not collected by tests/run_tests.gd: no test_ prefix). res://build is .gdignore'd, so it lives here.
## Modes (one per run):
##   --capture=<abs png>  windowed: the Murmillo (near LOD), idle pose after a fixed number of fixed-dt ticks, lit by a
##                        grazing side sun, fixed camera, solid background; saves the SubViewport picture.
##   --diff=<before>,<after>,<out side-by-side png>   per-channel mean / max absolute difference (whole image and
##                        soldier pixels only), plus a side-by-side with an x8 difference panel.
##   --sizes              PNG pixel sizes and the imported texture formats / mip counts of the 8 gladiator textures.

const SIZE := Vector2i(900, 1000)
const BG := Color(0.18, 0.2, 0.24)
const TICKS := 30
const DT := 1.0 / 60.0
const NAMES: Array[String] = ["near_albedo", "near_normal", "near_orm", "near_mask", "far_albedo", "far_normal", "far_orm", "far_mask"]


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("--capture="):
			_capture.call_deferred(a.substr(10))
			return
		if a.begins_with("--diff="):
			_diff(a.substr(7).split(","))
			quit(0)
			return
		if a == "--sizes":
			_sizes()
			quit(0)
			return
	push_error("no mode")
	quit(2)


func _sizes() -> void:
	for n in NAMES:
		var path := "res://assets/generated/characters/gladiator_%s.png" % n
		var src := Image.load_from_file(ProjectSettings.globalize_path(path))
		var tex := load(path) as Texture2D
		var img := tex.get_image()
		print("A3_TEX %s png=%dx%d png_format=%d imported_class=%s imported_format=%s mipmaps=%s mip_count=%d data_bytes=%d" % [
				n, src.get_width(), src.get_height(), src.get_format(), tex.get_class(), _fmt(img.get_format()),
				img.has_mipmaps(), img.get_mipmap_count(), img.get_data().size()])
		if n.ends_with("normal"):
			# The source map's unit length and z sign: is rebuilding z from xy the same as reading the blue channel?
			var worst_len := 0.0
			var neg_z := 0
			var worst_rebuild := 0.0
			var sum_rebuild := 0.0
			var used := 0
			var odd := {}
			var lens := [0, 0, 0, 0]  # unit-length error buckets: <0.02, <0.05, <0.2, >=0.2
			for y in range(0, src.get_height(), 2):
				for x in range(0, src.get_width(), 2):
					var c := src.get_pixel(x, y)
					var v := Vector3(c.r, c.g, c.b) * 2.0 - Vector3.ONE
					var le := absf(v.length() - 1.0)
					lens[0 if le < 0.02 else (1 if le < 0.05 else (2 if le < 0.2 else 3))] += 1
					if le >= 0.2 or v.z < 0.0:
						var key := c.to_html(false)
						odd[key] = int(odd.get(key, 0)) + 1
						if v.z < 0.0:
							neg_z += 1
						continue
					used += 1
					worst_len = maxf(worst_len, le)
					var z := sqrt(maxf(0.0, 1.0 - v.x * v.x - v.y * v.y))
					worst_rebuild = maxf(worst_rebuild, absf(z - v.z))
					sum_rebuild += absf(z - v.z)
			var top: Array = odd.keys()
			top.sort_custom(func(p, q): return int(odd[p]) > int(odd[q]))
			var tops := []
			for k in top.slice(0, 5):
				tops.append("%s:%d" % [k, odd[k]])
			print("A3_NORMAL_SRC %s samples(every 2nd px)=%d len_err_buckets(<.02,<.05,<.2,>=.2)=%s odd(len_err>=.2 or z<0)=%d neg_z=%d top_odd=%s" % [n, (src.get_width() / 2) * (src.get_height() / 2), lens, top.size(), neg_z, tops])
			print("A3_NORMAL_SRC %s in-island(len_err<.2, z>=0) px=%d worst_len_err=%.4f z_rebuild_err mean=%.5f worst=%.4f" % [n, used, worst_len, sum_rebuild / maxf(used, 1), worst_rebuild])


func _fmt(f: int) -> String:
	var names := {Image.FORMAT_RGB8: "RGB8", Image.FORMAT_RGBA8: "RGBA8", Image.FORMAT_RG8: "RG8", Image.FORMAT_L8: "L8",
		Image.FORMAT_DXT1: "DXT1(BC1)", Image.FORMAT_DXT3: "DXT3", Image.FORMAT_DXT5: "DXT5(BC3)", Image.FORMAT_RGTC_R: "RGTC_R(BC4)",
		Image.FORMAT_RGTC_RG: "RGTC_RG(BC5)", Image.FORMAT_BPTC_RGBA: "BPTC(BC7)", Image.FORMAT_ETC2_RGB8: "ETC2_RGB8",
		Image.FORMAT_ETC2_RGBA8: "ETC2_RGBA8", Image.FORMAT_ETC2_RG11: "ETC2_RG11", Image.FORMAT_ASTC_4x4: "ASTC_4x4"}
	return names.get(f, "format_%d" % f)


func _capture(out_path: String) -> void:
	var svp := SubViewport.new()
	svp.size = SIZE
	svp.own_world_3d = true
	svp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	svp.msaa_3d = Viewport.MSAA_DISABLED
	root.add_child(svp)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = BG
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.25, 0.27, 0.3)
	env.ambient_light_energy = 0.35
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new()
	we.environment = env
	svp.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.light_energy = 1.6
	sun.shadow_enabled = false
	svp.add_child(sun)
	# Grazing light from the soldier's left (+X), slightly from above and in front, so the normal map's relief shows.
	sun.look_at_from_position(Vector3(6.0, 1.6, -1.6), Vector3.ZERO)
	var cam := Camera3D.new()
	cam.fov = 32.0
	svp.add_child(cam)
	cam.look_at_from_position(Vector3(0.0, 1.15, -3.6), Vector3(0.0, 1.05, 0.0))
	cam.current = true
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	pawn.set_meta("armour_set", "murmillo")
	svp.add_child(pawn)
	pawn.set_physics_process(false)
	var model := pawn.get_node("SoldierModel") as SoldierModel
	model.set_process(false)
	model.animation_tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	model.skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
	for i in TICKS:
		pawn.velocity = Vector3.ZERO
		model._process(DT)
		model.animation_tree.advance(DT)
		model.skeleton.advance(DT)
		await process_frame
	for i in 20:  # shader compile and texture upload settle; the pose no longer advances
		await RenderingServer.frame_post_draw
	var img := svp.get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
	var err := img.save_png(out_path)
	print("A3_CAPTURE out=%s err=%d size=%s renderer=%s near_visible=%s" % [out_path, err, img.get_size(),
			RenderingServer.get_current_rendering_method(), model.armor.visible])
	quit(0 if err == OK else 1)


func _diff(paths: PackedStringArray) -> void:
	var a := Image.load_from_file(paths[0])
	var b := Image.load_from_file(paths[1])
	a.convert(Image.FORMAT_RGB8)
	b.convert(Image.FORMAT_RGB8)
	var sum := [0.0, 0.0, 0.0]
	var mx := [0, 0, 0]
	var fg_sum := [0.0, 0.0, 0.0]
	var fg := 0
	var over := [0, 0, 0]  # soldier pixels differing by more than 8/255 in a channel
	var w := a.get_width()
	var h := a.get_height()
	var da := a.get_data()
	var db := b.get_data()
	var bg := [roundi(BG.r * 255.0), roundi(BG.g * 255.0), roundi(BG.b * 255.0)]
	var diff := Image.create(w, h, false, Image.FORMAT_RGB8)
	var dd := PackedByteArray()
	dd.resize(da.size())
	for p in w * h:
		var is_fg := false
		for c in 3:
			if absi(int(da[p * 3 + c]) - int(bg[c])) > 3 or absi(int(db[p * 3 + c]) - int(bg[c])) > 3:
				is_fg = true
		if is_fg:
			fg += 1
		for c in 3:
			var d := absi(int(da[p * 3 + c]) - int(db[p * 3 + c]))
			sum[c] += d
			mx[c] = maxi(mx[c], d)
			if is_fg:
				fg_sum[c] += d
				if d > 8:
					over[c] += 1
			dd[p * 3 + c] = mini(d * 8, 255)
	diff.set_data(w, h, false, Image.FORMAT_RGB8, dd)
	var n := float(w * h)
	print("A3_DIFF all_pixels=%d mean_abs=(%.3f, %.3f, %.3f) max_abs=(%d, %d, %d) [0..255]" % [w * h, sum[0] / n, sum[1] / n, sum[2] / n, mx[0], mx[1], mx[2]])
	print("A3_DIFF soldier_pixels=%d mean_abs=(%.3f, %.3f, %.3f) over_8=(%d, %d, %d)" % [fg, fg_sum[0] / maxf(fg, 1), fg_sum[1] / maxf(fg, 1), fg_sum[2] / maxf(fg, 1), over[0], over[1], over[2]])
	var side := Image.create(w * 3, h, false, Image.FORMAT_RGB8)
	side.blit_rect(a, Rect2i(0, 0, w, h), Vector2i(0, 0))
	side.blit_rect(b, Rect2i(0, 0, w, h), Vector2i(w, 0))
	side.blit_rect(diff, Rect2i(0, 0, w, h), Vector2i(w * 2, 0))
	print("A3_DIFF side_by_side=%s err=%d (before | after | abs diff x8)" % [paths[2], side.save_png(paths[2])])
