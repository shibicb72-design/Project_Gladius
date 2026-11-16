extends RefCounted
## (No class_name: users preload this file, `const PlaceMap := preload("res://scripts/visual/place_map.gd")`.)
## M2W1 astraB: the "place map", a small RGBA8 texture over the ground square that tells the ground shader (and the
## clutter) where a place is used. Built in GDScript at map build from the PLACED pieces (structure, cover, chest,
## door and ladder bodies the map builder already made) and, later, the clutter clusters; deterministic, never saved,
## never an input of GroundPaint.inputs_hash or the navigation manifest (it reads no file those hashes read: only the
## built nodes and data/art_ground_detail.json "place_map"). Looks only: nothing in gameplay reads it.
## Channels: R = trodden (compacted aprons round buildings, gates, towers, stairs, cover and chests, wider at
## doorways, and soft worn tracks from each camp to its nearest gate and between neighbouring buildings),
## G = shelter (a band on the lee side and at the foot of walls, piers and buildings: damp, weedy ground),
## B = contact (a soft dark blob under clutter clusters and along wall feet: grounding for things without shadows),
## A = the ground's broad noise (the noise pack's G at the 360 m tile, baked here so the shader saves that fetch).
## Data: data/art_ground_detail.json "place_map" (placeholders, OQ-ART-WORLD).

const R := 0
const G := 1
const B := 2
const A := 3

var px := 512
var size_m := 1000.0
var data := PackedByteArray()
var build_ms := 0
var stamps := 0
var _cfg := {}


static func config() -> Dictionary:
	return WorldSurface.ground_detail_config().get("place_map", {})


func _init(ground_size_m: float = 1000.0, pixels: int = 512) -> void:
	size_m = maxf(ground_size_m, 1.0)
	px = maxi(pixels, 8)
	data.resize(px * px * 4)
	data.fill(0)
	_cfg = config()


## Pixel coordinates (continuous; pixel i covers [i, i+1)) of a ground point (x, z).
func to_px(p: Vector2) -> Vector2:
	return (p / size_m + Vector2(0.5, 0.5)) * float(px)


func to_world(x: float, y: float) -> Vector2:
	return (Vector2(x, y) / float(px) - Vector2(0.5, 0.5)) * size_m


## The map's value (0..1 per channel) at a ground point, nearest pixel (CPU side, for the clutter).
func sample(p: Vector2) -> Color:
	var q := to_px(p)
	var x := clampi(int(q.x), 0, px - 1)
	var y := clampi(int(q.y), 0, px - 1)
	var i := (y * px + x) * 4
	return Color(data[i] / 255.0, data[i + 1] / 255.0, data[i + 2] / 255.0, data[i + 3] / 255.0)


func _put(x: int, y: int, ch: int, v: float) -> void:
	var i := (y * px + x) * 4 + ch
	var b := clampi(int(v * 255.0 + 0.5), 0, 255)
	if b > data[i]:
		data[i] = b


## value x (1 - smoothstep(inner, outer, distance to the oriented box o)), kept where it is the larger.
## o = {c, ax, half} (WorldClutter.obb); offset moves the box (the lee side).
func stamp_box(ch: int, o: Dictionary, inner: float, outer: float, value: float, offset := Vector2.ZERO) -> void:
	var c: Vector2 = (o["c"] as Vector2) + offset
	var ax: Vector2 = o["ax"]
	var az := Vector2(-ax.y, ax.x)
	var half: Vector2 = o["half"]
	var reach := half.length() + outer
	var lo := to_px(c - Vector2(reach, reach))
	var hi := to_px(c + Vector2(reach, reach))
	var m := size_m / float(px)
	stamps += 1
	for y in range(maxi(0, floori(lo.y)), mini(px, ceili(hi.y))):
		for x in range(maxi(0, floori(lo.x)), mini(px, ceili(hi.x))):
			var d := Vector2((x + 0.5) * m - size_m * 0.5, (y + 0.5) * m - size_m * 0.5) - c
			var lx := absf(d.dot(ax)) - half.x
			var lz := absf(d.dot(az)) - half.y
			var dist := Vector2(maxf(lx, 0.0), maxf(lz, 0.0)).length()
			if dist >= outer:
				continue
			_put(x, y, ch, value * (1.0 - smoothstep(inner, outer, dist)))


func stamp_disc(ch: int, c: Vector2, inner: float, outer: float, value: float) -> void:
	stamp_box(ch, {"c": c, "ax": Vector2.RIGHT, "half": Vector2.ZERO}, inner, outer, value)


## A soft band from a to b (discs every pixel along it).
func stamp_line(ch: int, a: Vector2, b: Vector2, inner: float, outer: float, value: float) -> void:
	var step := size_m / float(px)
	var n := maxi(1, ceili(a.distance_to(b) / step))
	for i in n + 1:
		stamp_disc(ch, a.lerp(b, float(i) / float(n)), inner, outer, value)


## A = the ground's broad noise (noise pack G at detail_large_m, offset as the shader's old large fetch).
func bake_noise(noise: Image, tile_m: float, offset: Vector2) -> void:
	if noise == null or noise.is_empty():
		for i in px * px:
			data[i * 4 + 3] = 128
		return
	var img := noise
	if img.is_compressed():
		img = noise.duplicate()
		img.decompress()
	if img.get_format() != Image.FORMAT_RGBA8:
		img = img.duplicate()
		img.clear_mipmaps()
		img.convert(Image.FORMAT_RGBA8)
	var nw := img.get_width()
	var nh := img.get_height()
	var src := img.get_data()
	var m := size_m / float(px)
	for y in px:
		var v := ((y + 0.5) * m - size_m * 0.5) / tile_m + offset.y
		var ty := posmod(int(floor(v * nh)), nh)
		for x in px:
			var u := ((x + 0.5) * m - size_m * 0.5) / tile_m + offset.x
			var tx := posmod(int(floor(u * nw)), nw)
			data[(y * px + x) * 4 + 3] = src[(ty * nw + tx) * 4 + 1]


func image() -> Image:
	return Image.create_from_data(px, px, false, Image.FORMAT_RGBA8, data)


func texture() -> ImageTexture:
	return ImageTexture.create_from_image(image())


# --- building from the placed pieces ---

## The footprint boxes of a body's collision shapes that reach the ground (bottom within 0.6 m of the terrain).
static func footprints(body: Node, root: Node, terrain: MapTerrain) -> Array:
	var out: Array = []
	for shape: Node in body.find_children("*", "CollisionShape3D", true, false):
		var s := (shape as CollisionShape3D).shape
		if s == null:
			continue
		var box := WorldClutter._shape_box(s)
		var t := WorldClutter.xform_to(shape, root)
		var bottom := (t * box.position).y
		for i in 8:
			var corner := box.position + Vector3(box.size.x if i & 1 else 0.0, box.size.y if i & 2 else 0.0, box.size.z if i & 4 else 0.0)
			bottom = minf(bottom, (t * corner).y)
		var ground := terrain.height_at(t.origin.x, t.origin.z) if terrain != null else 0.0
		if bottom - ground > 0.6:
			continue
		out.append(WorldClutter.box_obb(t, box.get_center(), box.size))
	return out


## Builds R, G and A from the map builder's bodies (call after the doors and ladders exist). Returns the map.
static func build(builder: Node, ground_size_m: float) -> RefCounted:
	var started := Time.get_ticks_usec()
	var cfg := config()
	var map = load("res://scripts/visual/place_map.gd").new(ground_size_m, int(cfg.get("px", 512)))
	var root := builder.get_parent()
	var terrain: MapTerrain = builder.get("terrain")
	var aprons: Dictionary = cfg.get("apron_by_type", {})
	var lee_v: Array = cfg.get("lee_dir", [-0.707, 0.707])
	var lee := Vector2(float(lee_v[0]), float(lee_v[1])).normalized()
	var shelter: Dictionary = cfg.get("shelter_by_type", {})
	var foot := float(cfg.get("wall_foot_contact", 0.0))
	var camps := {}  # camp id -> [Vector2] building centres
	var gates: Array = []
	for body: Node in builder.get("structure_bodies"):
		var type := String(body.get_meta(&"structure_type", ""))
		var boxes := footprints(body, root, terrain)
		var t := WorldClutter.xform_to(body, root)
		var c := Vector2(t.origin.x, t.origin.z)
		if aprons.has(type):
			var a: Array = aprons[type]  # [inner m, outer m, value]
			for o: Dictionary in boxes:
				map.stamp_box(R, o, float(a[0]), float(a[1]), float(a[2]))
		if shelter.has(type):
			var s: Array = shelter[type]  # [lee offset m, inner m, outer m, value]
			for o: Dictionary in boxes:
				map.stamp_box(G, o, float(s[1]), float(s[2]), float(s[3]), lee * float(s[0]))
				map.stamp_box(G, o, 0.0, float(s[1]) + 1.2, float(s[3]) * 0.8)  # the foot all round
				if foot > 0.0:
					map.stamp_box(B, o, 0.0, float(cfg.get("wall_foot_m", 1.2)), foot)
		if type == "gate":
			gates.append(c)
		var id := String(body.name)
		if (type == "barracks" or type == "tent") and id.contains("_"):
			var camp := id.get_slice("_", 0)
			if not camps.has(camp):
				camps[camp] = []
			(camps[camp] as Array).append(c)
	# Cover (incl. breakables) and chests: small aprons.
	var cover_apron: Array = cfg.get("cover_apron", [0.5, 2.5, 0.45])
	for body: Node in builder.get("cover_bodies"):
		for o: Dictionary in footprints(body, root, terrain):
			map.stamp_box(R, o, float(cover_apron[0]), float(cover_apron[1]), float(cover_apron[2]))
	var chest_apron: Array = cfg.get("chest_apron", [0.5, 2.5, 0.6])
	for body: Node in builder.get("chest_bodies"):
		for o: Dictionary in footprints(body, root, terrain):
			map.stamp_box(R, o, float(chest_apron[0]), float(chest_apron[1]), float(chest_apron[2]))
	# Doorways: a wider worn patch either side of every door and gate opening.
	var door: Array = cfg.get("door_apron", [2.0, 6.0, 0.9, 3.0])  # [inner, outer, value, reach along the lane]
	for body: Node in builder.get("door_bodies"):
		var t := WorldClutter.xform_to(body, root)
		var through := t.basis * Vector3.BACK
		var dir := Vector2(through.x, through.z).normalized()
		var c := Vector2(t.origin.x, t.origin.z)
		map.stamp_line(R, c - dir * float(door[3]), c + dir * float(door[3]), float(door[0]), float(door[1]), float(door[2]))
	for ladder: Node in builder.get("ladders"):
		var t := WorldClutter.xform_to(ladder, root)
		map.stamp_disc(R, Vector2(t.origin.x, t.origin.z), 0.5, 2.5, 0.6)
	# Worn tracks: each camp's centre to its nearest gate, and each building to its nearest neighbour in the camp.
	var track: Array = cfg.get("track", [1.0, 3.5, 0.55, 260.0])  # [inner, outer, value, longest m]
	var nb: Array = cfg.get("neighbour_track", [0.8, 2.8, 0.5, 40.0])
	var camp_ids := camps.keys()
	camp_ids.sort()
	for camp: String in camp_ids:
		var list: Array = camps[camp]
		var centre := Vector2.ZERO
		for p: Vector2 in list:
			centre += p
		centre /= float(list.size())
		var best := Vector2.INF
		for g: Vector2 in gates:
			if g.distance_to(centre) < best.distance_to(centre):
				best = g
		if best != Vector2.INF and best.distance_to(centre) <= float(track[3]):
			map.stamp_line(R, centre, best, float(track[0]), float(track[1]), float(track[2]))
		for p: Vector2 in list:
			var near := Vector2.INF
			for q: Vector2 in list:
				if q != p and q.distance_to(p) < near.distance_to(p):
					near = q
			if near != Vector2.INF and near.distance_to(p) <= float(nb[3]):
				map.stamp_line(R, p, near, float(nb[0]), float(nb[1]), float(nb[2]))
	var noise_path := String(WorldSurface.config().get("noise", ""))
	var noise_tex := load(noise_path) as Texture2D if noise_path != "" else null
	var detail: Dictionary = WorldSurface.ground_detail_config().get("uniforms", {})
	map.bake_noise(noise_tex.get_image() if noise_tex != null else null, float(detail.get("detail_large_m", 360.0)), Vector2(0.37, 0.11))
	map.build_ms = int((Time.get_ticks_usec() - started) / 1000)
	return map


## Contact blobs (B) under clutter: one soft disc per cluster or patch {c: Vector2, r: float}.
func add_contact(spots: Array) -> void:
	var c: Array = _cfg.get("contact", [0.6, 1.8, 0.75])  # [inner share of r, outer extra m, value]
	for s: Dictionary in spots:
		var r := float(s["r"])
		stamp_disc(B, s["c"], r * float(c[0]), r + float(c[1]), float(s.get("v", c[2])))
		if float(s.get("g", 0.0)) > 0.0:  # a vegetation pocket: damp, greener ground round it (shelter)
			stamp_disc(G, s["c"], r, r * float(s.get("g_reach", 2.2)), float(s["g"]))
