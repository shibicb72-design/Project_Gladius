class_name GroundPaint
extends RefCounted
## S2: the small map the ground shader blends by (R = paving, G = grass, neither = trodden earth), painted once
## from the map data: paving on the citadel floor, around each landmark, on the roads from the citadel to the
## landmarks and on the ring road; grass in the outer ring; bare earth around cover. Numbers:
## data/art_materials.json "ground" (placeholders, OQ-GFX-MATERIALS). The same image answers "what is under
## this point" for the footstep sounds, so look and sound agree. Presentation only.

static var _cache := {}


## The paint image for a square map `map_size_m` wide centred on the origin. `landmarks` = [{at: [x, z]}, ...],
## `trodden` = points (x, z) that wear the grass away (cover and structures). Cached by `key`.
static func build(key: String, map_size_m: float, landmarks: Array, trodden: PackedVector2Array) -> Image:
	if _cache.has(key):
		return _cache[key]
	var g: Dictionary = WorldSurface.config()["ground"]
	var px := int(g["map_px"])
	var metres := map_size_m / float(px)
	var citadel := float(g["citadel_paving_m"])
	var plaza := float(g["landmark_paving_m"])
	var road := float(g["road_half_width_m"])
	var ring := float(g.get("ring_road_radius_m", 0.0))
	var grass_from := float(g["grass_from_m"])
	var grass_full := float(g["grass_full_m"])
	var soft := metres * 1.5
	var centres := PackedVector2Array()
	for landmark: Dictionary in landmarks:
		centres.append(Vector2(float(landmark["at"][0]), float(landmark["at"][1])))
	var bytes := PackedByteArray()
	bytes.resize(px * px * 4)
	for y in px:
		for x in px:
			var p := Vector2((float(x) + 0.5) * metres - map_size_m * 0.5, (float(y) + 0.5) * metres - map_size_m * 0.5)
			var r := p.length()
			var paved := citadel - r  # metres inside the nearest paved shape (negative = outside)
			if ring > 0.0:
				paved = maxf(paved, road - absf(r - ring))
			for c in centres:
				paved = maxf(paved, plaza - p.distance_to(c))
				# The road is the straight line from the origin to the landmark.
				var along := clampf(p.dot(c) / c.length_squared(), 0.0, 1.0)
				paved = maxf(paved, road - p.distance_to(c * along))
			var paving := clampf(0.5 + paved / (soft * 2.0), 0.0, 1.0)
			var grass := clampf((r - grass_from) / maxf(grass_full - grass_from, 0.01), 0.0, 1.0)
			var o := (y * px + x) * 4
			bytes[o] = int(paving * 255.0)
			bytes[o + 1] = int(grass * 255.0)
			bytes[o + 2] = 0
			bytes[o + 3] = 255
	# Feet wear the grass away around cover: stamp a soft bare patch at each point.
	var reach := float(g["cover_trodden_m"])
	var span := int(ceil(reach / metres))
	for t in trodden:
		var cx := int((t.x + map_size_m * 0.5) / metres)
		var cy := int((t.y + map_size_m * 0.5) / metres)
		for y in range(maxi(cy - span, 0), mini(cy + span + 1, px)):
			for x in range(maxi(cx - span, 0), mini(cx + span + 1, px)):
				var q := Vector2((float(x) + 0.5) * metres - map_size_m * 0.5, (float(y) + 0.5) * metres - map_size_m * 0.5)
				var keep := clampf(q.distance_to(t) / reach, 0.0, 1.0)
				var o := (y * px + x) * 4 + 1
				bytes[o] = mini(bytes[o], int(float(bytes[o]) * keep))
	var image := Image.create_from_data(px, px, false, Image.FORMAT_RGBA8, bytes)
	_cache[key] = image
	return image


static var _textures := {}

## The cached image of `key` as a texture for the ground shader (one per map, shared by every instance).
static func texture(key: String) -> Texture2D:
	if not _textures.has(key) and _cache.has(key):
		_textures[key] = ImageTexture.create_from_image(_cache[key])
	return _textures.get(key)


## Name of the ground under a world point: "paving", "grass" or "earth" (the shader's noisy edge is ignored).
static func surface_at(image: Image, map_size_m: float, at: Vector3) -> String:
	if image == null:
		return "earth"
	var px := image.get_width()
	var x := clampi(int((at.x / map_size_m + 0.5) * px), 0, px - 1)
	var y := clampi(int((at.z / map_size_m + 0.5) * px), 0, px - 1)
	var c := image.get_pixel(x, y)
	if c.r >= 0.5:
		return "paving"
	return "grass" if c.g >= 0.5 else "earth"
