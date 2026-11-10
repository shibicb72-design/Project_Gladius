extends SceneTree
## Seeded texture generator (run by hand, never at load):
##   godot --headless --path . --script res://tools/gen_textures.gd [-- --layers=1,2 --preview=build/s/tex]
## Writes res://assets/generated/textures/world_surfaces.png, a 4 x 4 grid of 512 px tiles that Godot imports as a
## 16-layer Texture2DArray (the .import file beside it sets the slices), and noise_pack.png (clouds, macro
## variation, stars). Everything is made here from FastNoiseLite and plain maths: no source images.
## A surface tile packs four data channels: R = albedo modulation (0.5 leaves the paint unchanged),
## G = roughness, B = normal x, A = normal y (tangent space of the tile: x = +u, y = +v, 0.5 = flat).
## After a run, tools/asset_hashes.gd --write records the new sha256 values in data/asset_catalog.json.
## Layer names and their order must match data/art_materials.json "layers".

const S := 512
const M := S - 1
const GRID := 4
const OUT_DIR := "res://assets/generated/textures"
const SEED := 20261109
const LAYERS: Array[String] = ["neutral", "ashlar", "marble", "plaster", "metal", "wood", "cloth", "roof",
		"rock", "panel", "dirt", "grass", "paving", "bronze", "sand", "concrete"]

var _a := PackedFloat32Array()  # albedo modulation
var _r := PackedFloat32Array()  # roughness
var _h := PackedFloat32Array()  # height
var _noise_cache := {}


func _initialize() -> void:
	var only: Array[int] = []
	var preview := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--layers="):
			for token in arg.substr(9).split(","):
				only.append(int(token))
		elif arg.begins_with("--preview="):
			preview = arg.substr(10)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var path := OUT_DIR + "/world_surfaces.png"
	var sheet := Image.create(S * GRID, S * GRID, false, Image.FORMAT_RGBA8)
	if not only.is_empty() and FileAccess.file_exists(path):
		sheet = Image.load_from_file(ProjectSettings.globalize_path(path))
	var contact: Image = null
	_a.resize(S * S)
	_r.resize(S * S)
	_h.resize(S * S)
	for layer in LAYERS.size():
		if not only.is_empty() and not only.has(layer):
			continue
		var started := Time.get_ticks_msec()
		var strength := float(call("_layer_" + LAYERS[layer]))
		var tile := _pack(strength)
		sheet.blit_rect(tile, Rect2i(0, 0, S, S), Vector2i((layer % GRID) * S, (layer / GRID) * S))
		if preview != "":
			DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://").path_join(preview))
			var lit := _preview(tile)
			lit.save_png(ProjectSettings.globalize_path("res://").path_join(preview).path_join("%02d_%s.png" % [layer, LAYERS[layer]]))
			if contact == null:
				contact = Image.create(S * GRID, S * GRID, false, Image.FORMAT_RGB8)
			contact.blit_rect(lit, Rect2i(0, 0, S, S), Vector2i((layer % GRID) * S, (layer / GRID) * S))
		print("GEN_TEXTURES layer %d %s %d ms" % [layer, LAYERS[layer], Time.get_ticks_msec() - started])
	if contact != null:
		contact.save_png(ProjectSettings.globalize_path("res://").path_join(preview).path_join("contact.png"))
	var err := sheet.save_png(ProjectSettings.globalize_path(path))
	print("GEN_TEXTURES wrote %s (%dx%d) err=%d" % [path, sheet.get_width(), sheet.get_height(), err])
	if only.is_empty():
		var pack := _noise_pack()
		err = pack.save_png(ProjectSettings.globalize_path(OUT_DIR + "/noise_pack.png"))
		print("GEN_TEXTURES wrote %s/noise_pack.png err=%d" % [OUT_DIR, err])
	quit()


## A seamless noise tile as bytes (one per pixel). `kind`: 0 simplex fbm, 1 cellular distance, 2 cellular value,
## 3 cellular distance2 - distance (thin at cell borders), 4 ridged simplex.
func _nz(salt: int, frequency: float, octaves: int = 4, kind: int = 0, size: int = S) -> PackedByteArray:
	var key := "%d/%f/%d/%d/%d" % [salt, frequency, octaves, kind, size]
	if _noise_cache.has(key):
		return _noise_cache[key]
	var n := FastNoiseLite.new()
	n.seed = SEED + salt
	n.frequency = frequency
	n.fractal_octaves = octaves
	n.fractal_type = FastNoiseLite.FRACTAL_FBM if octaves > 1 else FastNoiseLite.FRACTAL_NONE
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	match kind:
		1:
			n.noise_type = FastNoiseLite.TYPE_CELLULAR
			n.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
		2:
			n.noise_type = FastNoiseLite.TYPE_CELLULAR
			n.cellular_return_type = FastNoiseLite.RETURN_CELL_VALUE
		3:
			n.noise_type = FastNoiseLite.TYPE_CELLULAR
			n.cellular_return_type = FastNoiseLite.RETURN_DISTANCE2_SUB
		4:
			n.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	if kind in [1, 2, 3]:
		n.fractal_type = FastNoiseLite.FRACTAL_NONE
		n.cellular_jitter = 1.0
	var image := n.get_seamless_image(size, size, false, false, 0.2, true)
	image.convert(Image.FORMAT_L8)
	var bytes := image.get_data()
	_noise_cache[key] = bytes
	return bytes


## A tile of jittered cells that wraps exactly (the seamless blend of FastNoiseLite smears cellular noise).
## Returns [distance to the nearest point, gap to the second nearest (0 on a border), cell id], each 0..1 per pixel.
func _cells(count: int, salt: int) -> Array:
	var key := "cells/%d/%d" % [count, salt]
	if _noise_cache.has(key):
		return _noise_cache[key]
	var px := PackedFloat32Array()
	var py := PackedFloat32Array()
	px.resize(count * count)
	py.resize(count * count)
	for cy in count:
		for cx in count:
			px[cy * count + cx] = (float(cx) + 0.15 + 0.7 * _hash(cx, cy, salt)) / float(count)
			py[cy * count + cx] = (float(cy) + 0.15 + 0.7 * _hash(cx, cy, salt + 1)) / float(count)
	var near := PackedFloat32Array()
	var gap := PackedFloat32Array()
	var id := PackedFloat32Array()
	near.resize(S * S)
	gap.resize(S * S)
	id.resize(S * S)
	var scale := float(count)
	for y in S:
		var v := (float(y) + 0.5) / float(S)
		var cy0 := int(v * scale)
		for x in S:
			var u := (float(x) + 0.5) / float(S)
			var cx0 := int(u * scale)
			var best := 9.0
			var second := 9.0
			var best_id := 0
			for oy in range(-1, 2):
				var cy := cy0 + oy
				var wy := posmod(cy, count)
				var shift_y := float(cy - wy) / scale
				for ox in range(-1, 2):
					var cx := cx0 + ox
					var wx := posmod(cx, count)
					var k := wy * count + wx
					var dx := px[k] + float(cx - wx) / scale - u
					var dy := py[k] + shift_y - v
					var d := dx * dx + dy * dy
					if d < best:
						second = best
						best = d
						best_id = k
					elif d < second:
						second = d
			var i := y * S + x
			near[i] = clampf(sqrt(best) * scale, 0.0, 1.0)
			gap[i] = clampf((sqrt(second) - sqrt(best)) * scale, 0.0, 1.0)
			id[i] = _hash(best_id, salt, 5)
	var out := [near, gap, id]
	_noise_cache[key] = out
	return out


static func _hash(x: int, y: int, salt: int = 0) -> float:
	var h := (x * 374761393 + y * 668265263 + salt * 2147483647 + SEED) & 0x7fffffff
	h = ((h ^ (h >> 13)) * 1274126177) & 0x7fffffff
	return float((h ^ (h >> 16)) & 0xffff) / 65535.0


static func _ss(edge0: float, edge1: float, x: float) -> float:
	var t := clampf((x - edge0) / (edge1 - edge0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


## Packs the three work arrays into one RGBA tile; the normal comes from the height (wrapping at the edges).
func _pack(strength: float) -> Image:
	var bytes := PackedByteArray()
	bytes.resize(S * S * 4)
	for y in S:
		var up := ((y - 1) & M) * S
		var down := ((y + 1) & M) * S
		var row := y * S
		for x in S:
			var i := row + x
			var nx := (_h[row + ((x - 1) & M)] - _h[row + ((x + 1) & M)]) * strength
			var ny := (_h[up + x] - _h[down + x]) * strength
			var o := i * 4
			bytes[o] = int(clampf(_a[i], 0.0, 1.0) * 255.0 + 0.5)
			bytes[o + 1] = int(clampf(_r[i], 0.0, 1.0) * 255.0 + 0.5)
			bytes[o + 2] = int(clampf(0.5 + nx * 0.5, 0.0, 1.0) * 255.0 + 0.5)
			bytes[o + 3] = int(clampf(0.5 + ny * 0.5, 0.0, 1.0) * 255.0 + 0.5)
	return Image.create_from_data(S, S, false, Image.FORMAT_RGBA8, bytes)


## Reviewer's preview: the albedo modulation lit from the upper left by the packed normal (not used by the game).
func _preview(tile: Image) -> Image:
	var out := Image.create(S, S, false, Image.FORMAT_RGB8)
	for y in S:
		for x in S:
			var c := tile.get_pixel(x, y)
			var light := clampf(0.75 + ((c.b - 0.5) * -1.2 + (c.a - 0.5) * -1.2), 0.0, 1.5)
			var v := clampf(c.r * 1.4 * light, 0.0, 1.0)
			out.set_pixel(x, y, Color(v, v, v))
	return out


func _layer_neutral() -> float:
	var fine := _nz(1, 0.05, 3)
	for i in S * S:
		var f := fine[i] / 255.0
		_a[i] = 0.5 + (f - 0.5) * 0.08
		_r[i] = 0.8 + (f - 0.5) * 0.1
		_h[i] = 0.5 + (f - 0.5) * 0.05
	return 1.0


## Travertine ashlar: 1 m x 0.5 m blocks in running bond on a 4 m tile, mortar grooves, pores in bands.
func _layer_ashlar() -> float:
	var low := _nz(11, 0.006, 3)
	var fine := _nz(12, 0.06, 3)
	var pores: PackedFloat32Array = _cells(40, 13)[0]
	for y in S:
		var row := y >> 6
		var fy := y & 63
		var off := (row & 1) * 64 + int(_hash(row, 7) * 24.0) - 12
		for x in S:
			var xs := (x + off) & M
			var bx := xs >> 7
			var fx := xs & 127
			var id := _hash(bx, row, 3)
			var edge := float(mini(mini(fx, 127 - fx), mini(fy, 63 - fy)))
			var mortar := _ss(0.5, 3.5, edge)
			var bevel := _ss(0.0, 10.0, edge)
			var i := y * S + x
			var f := fine[i] / 255.0
			var l := low[i] / 255.0
			# Pores stretched along the bed of the stone (three samples across for one down).
			var pore := 1.0 - _ss(0.0, 0.2, pores[((y * 3) & M) * S + x])
			pore *= _ss(0.35, 0.6, fine[((y * 2) & M) * S + ((x + 97) & M)] / 255.0)
			_h[i] = mortar * (0.72 + 0.28 * bevel) + (f - 0.5) * 0.06 - pore * 0.35
			_a[i] = (0.5 + (id - 0.5) * 0.22 + (l - 0.5) * 0.2 + (f - 0.5) * 0.12) * (0.62 + 0.38 * mortar) - pore * 0.14
			_r[i] = lerpf(0.97, 0.8 + (f - 0.5) * 0.2, mortar)
	return 3.2


## Polished marble: 1 m slabs with thin seams, two families of dark veins bent by low noise.
func _layer_marble() -> float:
	var warp := _nz(21, 0.004, 3)
	var warp2 := _nz(22, 0.009, 3)
	var ridged := _nz(23, 0.004, 3, 4)
	var ridged2 := _nz(25, 0.011, 4, 4)
	var fine := _nz(24, 0.08, 2)
	for y in S:
		var fy := y & 255
		for x in S:
			var i := y * S + x
			var fx := x & 255
			var w := warp[i] / 255.0 - 0.5
			var w2 := warp2[i] / 255.0 - 0.5
			var bent := ridged[((y + int(w * 90.0)) & M) * S + ((x + int(w2 * 70.0)) & M)] / 255.0
			var vein := pow(bent, 9.0)
			var vein2 := pow(ridged2[i] / 255.0, 5.0) * 0.6
			var edge := float(mini(mini(fx, 255 - fx), mini(fy, 255 - fy)))
			var seam := 1.0 - _ss(0.0, 2.0, edge)
			var f := fine[i] / 255.0
			_a[i] = 0.57 + w * 0.16 + (f - 0.5) * 0.04 - vein * 0.34 - vein2 * 0.3 - seam * 0.3
			_h[i] = 0.8 - seam * 0.6 - vein * 0.04 - vein2 * 0.05
			_r[i] = 0.2 + vein * 0.15 + vein2 * 0.2 + seam * 0.6 + (f - 0.5) * 0.08
	return 2.0


## Lime plaster: blotches, trowel grain and a few hairline cracks.
func _layer_plaster() -> float:
	var low := _nz(31, 0.005, 4)
	var mid := _nz(32, 0.02, 3)
	var fine := _nz(33, 0.11, 2)
	var crack := _nz(34, 0.007, 3, 4)
	for i in S * S:
		var l := low[i] / 255.0
		var m := mid[i] / 255.0
		var f := fine[i] / 255.0
		var c := _ss(0.86, 0.97, crack[i] / 255.0) * _ss(0.45, 0.6, l)
		_a[i] = 0.5 + (l - 0.5) * 0.24 + (m - 0.5) * 0.1 + (f - 0.5) * 0.07 - c * 0.3
		_h[i] = 0.5 + (m - 0.5) * 0.25 + (f - 0.5) * 0.2 - c * 0.5
		_r[i] = 0.9 + (f - 0.5) * 0.1
	return 1.6


## Brushed steel plate: fine streaks along u, 1 m panels with seams and corner rivets.
func _layer_metal() -> float:
	var base := _nz(41, 0.012, 3)
	var low := _nz(42, 0.005, 3)
	for y in S:
		var fy := y & 255
		for x in S:
			var i := y * S + x
			var fx := x & 255
			var streak := base[((y * 16) & M) * S + x] / 255.0
			var scratch := _ss(0.8, 0.95, base[((y * 5 + 131) & M) * S + ((x * 2) & M)] / 255.0)
			var l := low[i] / 255.0
			var edge := float(mini(mini(fx, 255 - fx), mini(fy, 255 - fy)))
			var seam := 1.0 - _ss(0.5, 3.0, edge)
			var rx := float(mini(fx, 255 - fx)) - 18.0
			var ry := float(mini(fy, 255 - fy)) - 18.0
			var rivet := 1.0 - _ss(3.0, 6.0, sqrt(rx * rx + ry * ry))
			_a[i] = 0.5 + (streak - 0.5) * 0.16 + (l - 0.5) * 0.14 + scratch * 0.12 - seam * 0.3 + rivet * 0.1
			_h[i] = 0.6 + (streak - 0.5) * 0.05 - seam * 0.5 + rivet * 0.35 - scratch * 0.04
			_r[i] = 0.3 + streak * 0.22 + (l - 0.5) * 0.2 + seam * 0.4 - scratch * 0.1
	return 2.4


## Timber planks along u, 0.25 m wide on a 2 m tile, with grain, butt joints and nails.
func _layer_wood() -> float:
	var base := _nz(51, 0.008, 4)
	var fine := _nz(52, 0.05, 2)
	for y in S:
		var plank := y >> 6
		var fy := y & 63
		var shift := int(_hash(plank, 5) * 512.0)
		var tint := _hash(plank, 9)
		for x in S:
			var i := y * S + x
			var xs := (x + shift) & M
			var grain := base[((y * 9) & M) * S + xs] / 255.0
			var ring := 0.5 + 0.5 * sin(grain * 40.0 + float(fy) * 0.2)
			var f := fine[i] / 255.0
			var edge := float(mini(fy, 63 - fy))
			var seam := 1.0 - _ss(0.0, 2.5, edge)
			var butt := 1.0 - _ss(0.0, 2.0, float(mini(xs & 255, 255 - (xs & 255))))
			var nx := float(mini(xs & 255, 255 - (xs & 255))) - 10.0
			var ny := float(mini(fy, 63 - fy)) - 12.0
			var nail := 1.0 - _ss(1.5, 3.5, sqrt(nx * nx + ny * ny))
			var gap := maxf(seam, butt)
			_a[i] = 0.5 + (tint - 0.5) * 0.2 + (ring - 0.5) * 0.16 + (grain - 0.5) * 0.2 + (f - 0.5) * 0.06 - gap * 0.35 - nail * 0.25
			_h[i] = 0.6 + (ring - 0.5) * 0.12 - gap * 0.55 + nail * 0.1
			_r[i] = 0.72 + (ring - 0.5) * 0.12 + gap * 0.2 - nail * 0.3
	return 2.2


## Plain weave: 4 px threads, alternately over and under, with slubs.
func _layer_cloth() -> float:
	var low := _nz(61, 0.006, 3)
	var slub := _nz(62, 0.02, 2)
	for y in S:
		var cy := y >> 2
		var fy := (float(y & 3) + 0.5) / 4.0
		for x in S:
			var i := y * S + x
			var cx := x >> 2
			var fx := (float(x & 3) + 0.5) / 4.0
			var over := ((cx + cy) & 1) == 0
			var across := sin(PI * (fy if over else fx))
			var along := 0.75 + 0.25 * sin(PI * (fx if over else fy))
			var thread := across * along
			var l := low[i] / 255.0
			var s := slub[((y * 2) & M) * S + x] / 255.0 if over else slub[y * S + ((x * 2) & M)] / 255.0
			_h[i] = 0.3 + thread * 0.6
			_a[i] = 0.42 + thread * 0.16 + (l - 0.5) * 0.14 + (s - 0.5) * 0.14
			_r[i] = 0.94
	return 1.4


## Clay roof tiles: half-round ridges running down v, overlapping courses every quarter tile.
func _layer_roof() -> float:
	var fine := _nz(71, 0.07, 2)
	var low := _nz(72, 0.008, 3)
	for y in S:
		var course := y >> 7
		var fy := y & 127
		for x in S:
			var i := y * S + x
			var column := x >> 6
			var fx := float(x & 63) / 64.0
			var round_part := pow(absf(sin(PI * fx)), 0.55)
			var tint := _hash(column, course, 4)
			var f := fine[i] / 255.0
			var l := low[i] / 255.0
			var lip := 1.0 - _ss(0.0, 7.0, float(fy))  # shadow under the course above
			_h[i] = round_part * 0.5 + float(fy) / 127.0 * 0.4 + (f - 0.5) * 0.05
			_a[i] = 0.47 + (tint - 0.5) * 0.24 + (round_part - 0.5) * 0.12 + (l - 0.5) * 0.16 + (f - 0.5) * 0.08 - lip * 0.3
			_r[i] = 0.8 + (f - 0.5) * 0.12
	return 3.0


## Broken rock: ridged strata, cracks and grit.
func _layer_rock() -> float:
	var ridged := _nz(81, 0.008, 5, 4)
	var low := _nz(82, 0.004, 3)
	var fine := _nz(83, 0.09, 3)
	var crack := _nz(84, 0.012, 3, 4)
	for i in S * S:
		var rg := ridged[i] / 255.0
		var l := low[i] / 255.0
		var f := fine[i] / 255.0
		var c := _ss(0.88, 0.98, crack[i] / 255.0)
		_h[i] = rg * rg * 0.6 + l * 0.3 + f * 0.1 - c * 0.3
		_a[i] = 0.5 + (rg - 0.5) * 0.3 + (l - 0.5) * 0.2 + (f - 0.5) * 0.12 - c * 0.3
		_r[i] = 0.9 - rg * 0.1
	return 3.4


## Dark composite plating for the future-tech pieces: staggered panels, inset lines, vents and bolts.
func _layer_panel() -> float:
	var base := _nz(91, 0.012, 3)
	var low := _nz(92, 0.005, 3)
	for y in S:
		var row := y >> 7
		var fy := y & 127
		var off := (row & 1) * 128
		for x in S:
			var i := y * S + x
			var xs := (x + off) & M
			var col := xs >> 8
			var fx := xs & 255
			var id := _hash(col, row, 6)
			var edge := float(mini(mini(fx, 255 - fx), mini(fy, 127 - fy)))
			var groove := 1.0 - _ss(0.5, 3.0, edge)
			var inset := (1.0 - _ss(0.0, 1.5, absf(edge - 12.0))) * 0.5
			var vent := 0.0
			if id > 0.6 and fx > 150 and fx < 226 and fy > 30 and fy < 98:
				vent = 1.0 - _ss(1.5, 3.5, absf(float((fy - 30) % 14) - 7.0))
			var bx := float(mini(fx, 255 - fx)) - 26.0
			var by := float(mini(fy, 127 - fy)) - 26.0
			var bolt := 1.0 - _ss(2.5, 5.0, sqrt(bx * bx + by * by))
			var streak := base[((y * 12) & M) * S + x] / 255.0
			var l := low[i] / 255.0
			_a[i] = 0.5 + (id - 0.5) * 0.14 + (streak - 0.5) * 0.08 + (l - 0.5) * 0.12 - groove * 0.35 - inset * 0.12 - vent * 0.3 + bolt * 0.12
			_h[i] = 0.7 - groove * 0.6 - inset * 0.12 - vent * 0.4 + bolt * 0.25
			_r[i] = 0.42 + streak * 0.16 + (l - 0.5) * 0.14 + groove * 0.35 + vent * 0.3
	return 2.6


## Trodden earth with pebbles.
func _layer_dirt() -> float:
	var low := _nz(101, 0.006, 4)
	var mid := _nz(102, 0.025, 3)
	var fine := _nz(103, 0.12, 2)
	var cells := _cells(22, 104)
	var cell: PackedFloat32Array = cells[0]
	var cell_id: PackedFloat32Array = cells[2]
	for i in S * S:
		var l := low[i] / 255.0
		var m := mid[i] / 255.0
		var f := fine[i] / 255.0
		var pebble := (1.0 - _ss(0.08, 0.2 + 0.2 * cell_id[i], cell[i])) * _ss(0.84, 0.9, cell_id[i])
		_h[i] = 0.35 + (m - 0.5) * 0.3 + (f - 0.5) * 0.18 + pebble * 0.45
		_a[i] = 0.47 + (l - 0.5) * 0.3 + (m - 0.5) * 0.16 + (f - 0.5) * 0.12 + pebble * 0.22
		_r[i] = 0.95 - pebble * 0.2
	return 2.6


## Short dry grass seen from above: tufts, blades and gaps.
func _layer_grass() -> float:
	var low := _nz(111, 0.007, 3)
	var tuft := _nz(112, 0.04, 2)
	var base := _nz(113, 0.09, 2)
	for y in S:
		for x in S:
			var i := y * S + x
			var l := low[i] / 255.0
			var t := tuft[i] / 255.0
			var blade_a := base[y * S + ((x * 3) & M)] / 255.0
			var blade_b := base[((y * 3) & M) * S + ((x + 211) & M)] / 255.0
			var blade := _ss(0.42, 0.8, maxf(blade_a, blade_b))
			_h[i] = 0.15 + blade * 0.6 + t * 0.25
			_a[i] = 0.24 + blade * 0.5 + (t - 0.5) * 0.2 + (l - 0.5) * 0.16
			_r[i] = 0.88
	return 2.0


## Roman road: irregular fitted stones with deep joints.
func _layer_paving() -> float:
	var cells := _cells(7, 121)
	var border: PackedFloat32Array = cells[1]
	var id: PackedFloat32Array = cells[2]
	var fine := _nz(122, 0.08, 3)
	var low := _nz(123, 0.006, 3)
	for i in S * S:
		var b := border[i]
		var joint := 1.0 - _ss(0.02, 0.07, b)
		var dome := _ss(0.0, 0.35, b)
		var tint := id[i]
		var f := fine[i] / 255.0
		var l := low[i] / 255.0
		_h[i] = 0.55 + dome * 0.3 - joint * 0.55 + (f - 0.5) * 0.08
		_a[i] = 0.5 + (tint - 0.5) * 0.3 + (f - 0.5) * 0.12 + (l - 0.5) * 0.14 - joint * 0.34
		_r[i] = 0.62 + (f - 0.5) * 0.25 + joint * 0.3 - dome * 0.12
	return 3.0


## Hammered bronze: shallow dimples and a worn polish.
func _layer_bronze() -> float:
	var cell: PackedFloat32Array = _cells(18, 131)[0]
	var low := _nz(132, 0.006, 3)
	var fine := _nz(133, 0.09, 2)
	for i in S * S:
		var d := cell[i]
		var l := low[i] / 255.0
		var f := fine[i] / 255.0
		_h[i] = 0.5 + _ss(0.0, 0.6, d) * 0.4
		_a[i] = 0.5 + (l - 0.5) * 0.26 + (d - 0.3) * 0.16 + (f - 0.5) * 0.05
		_r[i] = 0.34 + (l - 0.5) * 0.3 + (1.0 - d) * 0.12
	return 1.5


## Wind-combed sand and fine gravel.
func _layer_sand() -> float:
	var low := _nz(141, 0.005, 3)
	var warp := _nz(142, 0.01, 2)
	var fine := _nz(143, 0.14, 2)
	for y in S:
		for x in S:
			var i := y * S + x
			var w := warp[i] / 255.0 - 0.5
			var ripple := 0.5 + 0.5 * sin(TAU * float(y * 12 + x * 2) / float(S) + w * 7.0)
			var l := low[i] / 255.0
			var f := fine[i] / 255.0
			_h[i] = 0.4 + ripple * 0.25 + (f - 0.5) * 0.25
			_a[i] = 0.5 + (ripple - 0.5) * 0.1 + (l - 0.5) * 0.2 + (f - 0.5) * 0.16
			_r[i] = 0.93
	return 1.6


## Cast stone for bases and floors: 2 m bays with form lines, stains and pinholes.
func _layer_concrete() -> float:
	var low := _nz(151, 0.004, 4)
	var mid := _nz(152, 0.03, 3)
	var fine := _nz(153, 0.13, 2)
	var holes: PackedFloat32Array = _cells(36, 154)[0]
	for y in S:
		var fy := y & 255
		for x in S:
			var i := y * S + x
			var fx := x & 255
			var l := low[i] / 255.0
			var m := mid[i] / 255.0
			var f := fine[i] / 255.0
			var edge := float(mini(mini(fx, 255 - fx), mini(fy, 255 - fy)))
			var seam := 1.0 - _ss(0.5, 2.5, edge)
			var hole := (1.0 - _ss(0.0, 0.12, holes[i])) * _ss(0.5, 0.7, m)
			var stain := _ss(0.55, 0.9, low[((y * 2) & M) * S + ((x + 53) & M)] / 255.0)
			_h[i] = 0.7 - seam * 0.5 - hole * 0.4 + (f - 0.5) * 0.08
			_a[i] = 0.5 + (l - 0.5) * 0.22 + (m - 0.5) * 0.08 + (f - 0.5) * 0.06 - seam * 0.3 - hole * 0.25 - stain * 0.1
			_r[i] = 0.74 + (f - 0.5) * 0.14 + seam * 0.2 - stain * 0.1
	return 2.0


## noise_pack.png: R = cloud fbm, G = macro variation (ground and wall blotches), B = fine grain,
## A = sparse stars (mostly 0). 512 px, tiles in both directions.
func _noise_pack() -> Image:
	var cloud := _nz(201, 0.006, 5)
	var macro := _nz(202, 0.012, 3)
	var grain := _nz(203, 0.1, 2)
	var bytes := PackedByteArray()
	bytes.resize(S * S * 4)
	for y in S:
		for x in S:
			var i := y * S + x
			bytes[i * 4] = cloud[i]
			bytes[i * 4 + 1] = macro[i]
			bytes[i * 4 + 2] = grain[i]
			var star := _hash(x, y, 77)
			bytes[i * 4 + 3] = int(_ss(0.9965, 1.0, star) * 255.0)
	return Image.create_from_data(S, S, false, Image.FORMAT_RGBA8, bytes)
