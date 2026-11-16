extends SceneTree
## M2W1: screen values of a capture (read-only). Averages a 9x9 pixel block at each point and prints the sRGB
## colour (0-255), the value (max channel, %) and the luma (Rec.709 on sRGB, %).
##   godot --headless --path . --log-file <log> --script res://tools/m2w1_pixel_probe.gd -- --png=<abs path> --at=x,y;x,y;...
## Points are in the picture's own pixels. One PIXEL line per point.

func _initialize() -> void:
	var png := ""
	var at := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--png="):
			png = a.substr(6)
		elif a.begins_with("--at="):
			at = a.substr(5)
	var img := Image.load_from_file(png)
	if img == null or img.is_empty():
		printerr("m2w1_pixel_probe: cannot read %s" % png)
		quit(1)
		return
	for p in at.split(";", false):
		var xy := p.split(",")
		var cx := int(xy[0])
		var cy := int(xy[1])
		var sum := Color(0, 0, 0, 0)
		var n := 0
		for y in range(cy - 4, cy + 5):
			for x in range(cx - 4, cx + 5):
				if x >= 0 and y >= 0 and x < img.get_width() and y < img.get_height():
					sum += img.get_pixel(x, y)
					n += 1
		var c := sum / maxf(1.0, n)
		var luma := 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
		print("PIXEL %d,%d rgb=(%d,%d,%d) value=%d%% luma=%d%%" % [cx, cy, roundi(c.r * 255), roundi(c.g * 255), roundi(c.b * 255),
				roundi(maxf(c.r, maxf(c.g, c.b)) * 100), roundi(luma * 100)])
	quit()
