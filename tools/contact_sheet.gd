extends SceneTree
## M2 AN1: tiles the images of a folder into one JPG contact sheet with Godot's Image class (no python, no ffmpeg).
## Headless:
##   godot --headless --path . --script tools/contact_sheet.gd -- --dir=build/an1_after/c2_hastati --out=build/an1_after/c2_hastati_sheet.jpg
## Options:
##   --dir=<folder>        images to tile (png, jpg, webp), in file-name order; relative paths are under the project
##   --out=<file.jpg>      output JPG (default <dir>_sheet.jpg)
##   --filter=<text>       only file names containing this text
##   --every=<n>           keep every n-th image after filtering (default 1)
##   --cols=<n>            columns (default 4)
##   --tile=<px>           tile width in pixels (default 640); the height follows the first image's aspect
##   --gap=<px>            gap between tiles (default 6)
##   --quality=<0..1>      JPG quality (default 0.85)
## Every tile keeps its own aspect, fitted inside the cell and centred on a dark background. The tile order and file
## names are printed (CONTACT lines) so the sheet can be read without labels.

const EXTENSIONS: Array[String] = ["png", "jpg", "jpeg", "webp"]


func _initialize() -> void:
	var dir := ""
	var out := ""
	var filter := ""
	var every := 1
	var cols := 4
	var tile_w := 640
	var gap := 6
	var quality := 0.85
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--dir="):
			dir = a.substr(6)
		elif a.begins_with("--out="):
			out = a.substr(6)
		elif a.begins_with("--filter="):
			filter = a.substr(9)
		elif a.begins_with("--every="):
			every = maxi(1, int(a.substr(8)))
		elif a.begins_with("--cols="):
			cols = maxi(1, int(a.substr(7)))
		elif a.begins_with("--tile="):
			tile_w = maxi(16, int(a.substr(7)))
		elif a.begins_with("--gap="):
			gap = maxi(0, int(a.substr(6)))
		elif a.begins_with("--quality="):
			quality = clampf(float(a.substr(10)), 0.05, 1.0)
	if dir == "":
		print("CONTACT error: --dir is required")
		quit(1)
		return
	if not dir.is_absolute_path():
		dir = ProjectSettings.globalize_path("res://").path_join(dir)
	if out == "":
		out = dir.trim_suffix("/") + "_sheet.jpg"
	elif not out.is_absolute_path():
		out = ProjectSettings.globalize_path("res://").path_join(out)
	var names: Array[String] = []
	for f in DirAccess.get_files_at(dir):
		if EXTENSIONS.has(f.get_extension().to_lower()) and (filter == "" or f.contains(filter)):
			names.append(f)
	names.sort()
	var kept: Array[String] = []
	for i in names.size():
		if i % every == 0:
			kept.append(names[i])
	if kept.is_empty():
		print("CONTACT error: no images in %s" % dir)
		quit(1)
		return
	var first := Image.load_from_file(dir.path_join(kept[0]))
	if first == null or first.is_empty():
		print("CONTACT error: cannot read %s" % kept[0])
		quit(1)
		return
	var tile_h := maxi(16, roundi(float(tile_w) * first.get_height() / first.get_width()))
	var rows := ceili(float(kept.size()) / cols)
	var sheet := Image.create(cols * tile_w + (cols + 1) * gap, rows * tile_h + (rows + 1) * gap, false, Image.FORMAT_RGB8)
	sheet.fill(Color(0.08, 0.08, 0.09))
	for i in kept.size():
		var img := Image.load_from_file(dir.path_join(kept[i]))
		if img == null or img.is_empty():
			print("CONTACT skip unreadable %s" % kept[i])
			continue
		img.convert(Image.FORMAT_RGB8)
		var s := minf(float(tile_w) / img.get_width(), float(tile_h) / img.get_height())
		var w := maxi(1, roundi(img.get_width() * s))
		var h := maxi(1, roundi(img.get_height() * s))
		img.resize(w, h, Image.INTERPOLATE_LANCZOS)
		var col := i % cols
		var row := i / cols
		var at := Vector2i(gap + col * (tile_w + gap) + (tile_w - w) / 2, gap + row * (tile_h + gap) + (tile_h - h) / 2)
		sheet.blit_rect(img, Rect2i(0, 0, w, h), at)
		print("CONTACT tile %d (row %d, col %d): %s" % [i, row, col, kept[i]])
	DirAccess.make_dir_recursive_absolute(out.get_base_dir())
	var err := sheet.save_jpg(out, quality)
	print("CONTACT %s -> %s (%d tiles, %dx%d)" % [dir, out, kept.size(), sheet.get_width(), sheet.get_height()])
	quit(0 if err == OK else 1)
