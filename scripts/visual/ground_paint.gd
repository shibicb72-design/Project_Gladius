class_name GroundPaint
extends RefCounted
## S2: the small map the ground shader blends by (R = paving, G = grass, neither = trodden earth), painted once
## from the map data: paving on the citadel floor, around each landmark, on the roads from the citadel to the
## landmarks and on the ring road; grass in the outer ring; bare earth around cover. Numbers:
## data/art_materials.json "ground" (placeholders, OQ-GFX-MATERIALS). The same image answers "what is under
## this point" for the footstep sounds, so look and sound agree. Presentation only.

static var _cache := {}


## M2P1B: the paint's width in pixels for a ground `map_size_m` wide: the same detail per metre on every map
## size, capped so a large map's image stays small (art_materials.json "ground" paint_px_per_m, paint_px_cap).
## M2L1: `settings` = the paint numbers to use (settings_for(); empty = the global art_materials.json "ground").
static func px_for(map_size_m: float, settings: Dictionary = {}) -> int:
	var g: Dictionary = settings if not settings.is_empty() else WorldSurface.config()["ground"]
	return maxi(1, mini(roundi(map_size_m * float(g["paint_px_per_m"])), int(g["paint_px_cap"])))


## M2L1 (binding fix 6): the paint numbers of one map: art_materials.json "ground" with the map json's own
## "ground_paint" keys over it (same key names, plus "roads": false to leave out the spokes from the origin to
## the landmarks and "baked": the path of an offline-baked paint). A map without "ground_paint" gets the global
## dictionary itself, so alesia and test_300 paint exactly as before.
static func settings_for(map_def: Dictionary) -> Dictionary:
	var g: Dictionary = WorldSurface.config()["ground"]
	var own: Variant = map_def.get("ground_paint")
	if typeof(own) != TYPE_DICTIONARY:
		return g
	var merged := g.duplicate()
	for k: String in own:
		if not k.begins_with("_"):
			merged[k] = own[k]
	return merged


## M2L1: the sha256 of everything a paint is made from (its numbers, the ground size and pixel width, the
## landmark centres and the trodden points). An offline-baked paint carries it as its "inputs_sha256" meta; a
## different value at load means the bake is stale.
static func inputs_hash(map_size_m: float, landmarks: Array, trodden: PackedVector2Array, settings: Dictionary) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	var numbers := {}
	for k: String in settings:
		if not k.begins_with("_") and k != "baked" and k != "baked_sha256":
			numbers[k] = settings[k]
	ctx.update(("%s|%s|%d|" % [JSON.stringify(numbers, "", true, true), str(map_size_m), px_for(map_size_m, settings)]).to_utf8_buffer())
	var centres := PackedFloat32Array()
	for landmark: Dictionary in landmarks:
		centres.append(float(landmark["at"][0]))
		centres.append(float(landmark["at"][1]))
	ctx.update(centres.to_byte_array())
	ctx.update("|".to_utf8_buffer())
	var points := PackedFloat32Array()
	for t in trodden:
		points.append(t.x)
		points.append(t.y)
	ctx.update(points.to_byte_array())
	return ctx.finish().hex_encode()


## M2L1: an offline-baked paint (a saved Image .res, see save_baked) as the paint of `key`, or null when the file
## is missing, not an RGBA8 image of `px` pixels, or stale (its inputs_sha256 meta differs from `want_hash`).
## A loaded paint is cached like a painted one, so texture(key) works the same.
static func load_baked(key: String, path: String, px: int, want_hash: String) -> Image:
	if _cache.has(key):
		return _cache[key]
	if path == "" or not ResourceLoader.exists(path):
		return null
	var image := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as Image
	if image == null or image.get_width() != px or image.get_height() != px or image.get_format() != Image.FORMAT_RGBA8:
		return null
	if String(image.get_meta(&"inputs_sha256", "")) != want_hash:
		return null
	_cache[key] = image
	return image


## M2L1: why load_baked would give null ("" = it would load). For the one printed line and for tests.
static func baked_problem(path: String, px: int, want_hash: String) -> String:
	if path == "" or not ResourceLoader.exists(path):
		return "baked paint '%s' is missing" % path
	var image := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as Image
	if image == null or image.get_width() != px or image.get_height() != px or image.get_format() != Image.FORMAT_RGBA8:
		return "baked paint '%s' is not an RGBA8 image of %d px" % [path, px]
	if String(image.get_meta(&"inputs_sha256", "")) != want_hash:
		return "baked paint '%s' is stale (its inputs changed)" % path
	return ""


## M2L1: saves a paint as a compressed binary Image resource with its inputs hash (never a PNG: the footsteps read
## it with Image.get_pixel, and a PNG would be imported as a texture).
static func save_baked(image: Image, path: String, hash: String) -> Error:
	var copy := image.duplicate() as Image
	copy.set_meta(&"inputs_sha256", hash)
	return ResourceSaver.save(copy, path, ResourceSaver.FLAG_COMPRESS)


## Drops the cached paint of `key` (and its texture): a tool or test that rebuilds the same map's paint.
static func forget(key: String) -> void:
	_cache.erase(key)
	_textures.erase(key)


## The paint image for a square map `map_size_m` wide centred on the origin. `landmarks` = [{at: [x, z]}, ...],
## `trodden` = points (x, z) that wear the grass away (cover and structures). Cached by `key`.
## M2L1: `settings` as in px_for; "roads": false leaves out the roads from the origin to the landmarks.
static func build(key: String, map_size_m: float, landmarks: Array, trodden: PackedVector2Array, settings: Dictionary = {}) -> Image:
	if _cache.has(key):
		return _cache[key]
	var g: Dictionary = settings if not settings.is_empty() else WorldSurface.config()["ground"]
	var roads := bool(g.get("roads", true))
	var px := px_for(map_size_m, g)
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
				if not roads:
					continue
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
