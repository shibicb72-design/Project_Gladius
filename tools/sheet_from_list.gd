extends SceneTree
## M2 AN1: before / after sheets. Tiles the images named in a JSON manifest into JPG sheets (Godot's Image class):
##   godot --headless --path . --script tools/sheet_from_list.gd -- --list=build/an1_sheets.json
## Manifest: {"out_dir": "<folder, absolute or under the project>", "tile": 840, "sheets": [{"out": "gap1.jpg",
## "cols": 2, "images": ["build/a.png", "build/b.png", ...]}, ...]}. Images are placed in order, row by row, each
## fitted inside its cell on a dark background. A missing image leaves its cell empty and prints SHEET MISSING.
## Presentation tooling only: nothing in the game reads it.


func _initialize() -> void:
	var list := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--list="):
			list = a.substr(7)
	var text := FileAccess.get_file_as_string(_abs(list))
	var data: Variant = JSON.parse_string(text)
	if not (data is Dictionary):
		print("SHEET bad manifest %s" % list)
		quit(1)
		return
	var out_dir := _abs(String(data.get("out_dir", "build")))
	DirAccess.make_dir_recursive_absolute(out_dir)
	var tile_w := int(data.get("tile", 840))
	var failed := 0
	for sheet: Dictionary in data.get("sheets", []):
		var cols := maxi(1, int(sheet.get("cols", 2)))
		var images: Array = sheet.get("images", [])
		var cell := Vector2i(tile_w, 0)
		var loaded: Array[Image] = []
		for path in images:
			var img := Image.load_from_file(_abs(String(path)))
			if img == null:
				print("SHEET MISSING %s" % path)
				failed += 1
			elif cell.y == 0:
				cell.y = int(round(tile_w * float(img.get_height()) / float(img.get_width())))
			loaded.append(img)
		if cell.y == 0:
			continue
		var gap := 8
		var rows := int(ceil(loaded.size() / float(cols)))
		var canvas := Image.create(cols * (cell.x + gap) + gap, rows * (cell.y + gap) + gap, false, Image.FORMAT_RGB8)
		canvas.fill(Color(0.07, 0.07, 0.08))
		for i in loaded.size():
			var img := loaded[i]
			if img == null:
				continue
			img.convert(Image.FORMAT_RGB8)
			var s := minf(cell.x / float(img.get_width()), cell.y / float(img.get_height()))
			var size := Vector2i(maxi(1, int(img.get_width() * s)), maxi(1, int(img.get_height() * s)))
			img.resize(size.x, size.y, Image.INTERPOLATE_LANCZOS)
			var at := Vector2i(gap + (i % cols) * (cell.x + gap) + (cell.x - size.x) / 2, gap + (i / cols) * (cell.y + gap) + (cell.y - size.y) / 2)
			canvas.blit_rect(img, Rect2i(Vector2i.ZERO, size), at)
		var out := out_dir.path_join(String(sheet.get("out", "sheet.jpg")))
		var err := canvas.save_jpg(out, 0.88)
		print("SHEET %s images=%d err=%d" % [out, loaded.size(), err])
		if err != OK:
			failed += 1
	quit(1 if failed > 0 else 0)


func _abs(path: String) -> String:
	if path.is_absolute_path():
		return path
	return ProjectSettings.globalize_path("res://" + path)
