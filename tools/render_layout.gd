extends SceneTree
## M2L1 item 8: the layout picture of a map for Shibi, drawn FROM THE DATA into an Image (no window, no renderer):
## the ground bands, the hill shaded with 5 m contours, every collider footprint (DataRegistry.collider_footprints)
## coloured by class, the rings with their radii, every landmark, gate, tower, aqueduct, camp, spawn and reserved J1
## spot labelled, the play circle and the zone start, a legend, a north arrow and a 100 m scale bar. Text uses a
## built-in 5x7 bitmap font (Font drawing needs a canvas; this stays headless and deterministic).
##   godot --headless --path . --script res://tools/render_layout.gd --log-file build/l1/layout.log -- --out=<absolute png>
## Options: --map=res://data/maps/alesia_1km.json (default), --size=2000 (picture side in px).
## Ground shots (windowed, needs a renderer): the map scene built the way MatchRoot builds it (ArtBuilder.map_json
## handed over), lit by the match's own Light + WorldEnvironment (GreyboxArt, the match look), no match, no pawns;
## a Camera3D at eye height (1.7 m over the terrain) at six named points; 2520 x 1080 offscreen SubViewport:
##   godot --path . --script res://tools/render_layout.gd --log-file build/l1/shots.log -- --shots=<absolute dir>
## Prints one RENDER_LAYOUT / RENDER_SHOT line per file; exit 1 on a problem. Every size and name it shows is a
## proposal (OQ-ALESIA-LAYOUT); the picture's title says so.

const MAP_PATH := "res://data/maps/alesia_1km.json"
const Gen := preload("res://tools/gen_alesia.gd")
const SHOT_SIZE := Vector2i(2520, 1080)
const EYE_M := 1.7

## 5x7 glyphs, one 5-bit row per entry (bit 4 = left column). Lower case draws as upper case.
const FONT := {
	"A": [14, 17, 17, 31, 17, 17, 17], "B": [30, 17, 17, 30, 17, 17, 30], "C": [14, 17, 16, 16, 16, 17, 14],
	"D": [28, 18, 17, 17, 17, 18, 28], "E": [31, 16, 16, 30, 16, 16, 31], "F": [31, 16, 16, 30, 16, 16, 16],
	"G": [14, 17, 16, 23, 17, 17, 15], "H": [17, 17, 17, 31, 17, 17, 17], "I": [14, 4, 4, 4, 4, 4, 14],
	"J": [7, 2, 2, 2, 2, 18, 12], "K": [17, 18, 20, 24, 20, 18, 17], "L": [16, 16, 16, 16, 16, 16, 31],
	"M": [17, 27, 21, 21, 17, 17, 17], "N": [17, 17, 25, 21, 19, 17, 17], "O": [14, 17, 17, 17, 17, 17, 14],
	"P": [30, 17, 17, 30, 16, 16, 16], "Q": [14, 17, 17, 17, 21, 18, 13], "R": [30, 17, 17, 30, 20, 18, 17],
	"S": [15, 16, 16, 14, 1, 1, 30], "T": [31, 4, 4, 4, 4, 4, 4], "U": [17, 17, 17, 17, 17, 17, 14],
	"V": [17, 17, 17, 17, 17, 10, 4], "W": [17, 17, 17, 21, 21, 21, 10], "X": [17, 17, 10, 4, 10, 17, 17],
	"Y": [17, 17, 10, 4, 4, 4, 4], "Z": [31, 1, 2, 4, 8, 16, 31],
	"0": [14, 17, 19, 21, 25, 17, 14], "1": [4, 12, 4, 4, 4, 4, 14], "2": [14, 17, 1, 2, 4, 8, 31],
	"3": [31, 2, 4, 2, 1, 17, 14], "4": [2, 6, 10, 18, 31, 2, 2], "5": [31, 16, 30, 1, 1, 17, 14],
	"6": [6, 8, 16, 30, 17, 17, 14], "7": [31, 1, 2, 4, 8, 8, 8], "8": [14, 17, 17, 14, 17, 17, 14],
	"9": [14, 17, 17, 15, 1, 2, 12],
	" ": [0, 0, 0, 0, 0, 0, 0], ".": [0, 0, 0, 0, 0, 12, 12], ",": [0, 0, 0, 0, 12, 4, 8],
	"-": [0, 0, 0, 31, 0, 0, 0], ":": [0, 12, 12, 0, 12, 12, 0], "(": [2, 4, 8, 8, 8, 4, 2],
	")": [8, 4, 2, 2, 2, 4, 8], "/": [1, 1, 2, 4, 8, 16, 16], "=": [0, 0, 31, 0, 31, 0, 0],
	"+": [0, 4, 4, 31, 4, 4, 0], "'": [4, 4, 8, 0, 0, 0, 0], "%": [24, 25, 2, 4, 8, 19, 3],
	"_": [0, 0, 0, 0, 0, 0, 31], "?": [14, 17, 1, 2, 4, 0, 4], "!": [4, 4, 4, 4, 4, 0, 4],
	">": [8, 4, 2, 1, 2, 4, 8], "<": [2, 4, 8, 16, 8, 4, 2], "#": [10, 10, 31, 10, 31, 10, 10],
	"*": [0, 21, 14, 31, 14, 21, 0], ";": [0, 12, 12, 0, 12, 4, 8],
}

## Footprint classes: colour and legend text, in legend order.
const CLASSES := {
	"wall": [Color(0.42, 0.40, 0.38), "wall walk"],
	"stair": [Color(0.70, 0.66, 0.58), "wall stair"],
	"gate": [Color(0.86, 0.36, 0.12), "gate"],
	"tower": [Color(0.50, 0.20, 0.62), "watchtower"],
	"aqueduct": [Color(0.18, 0.42, 0.80), "aqueduct span"],
	"ramp": [Color(0.45, 0.72, 0.95), "aqueduct ramp"],
	"citadel": [Color(0.95, 0.88, 0.55), "citadel pieces (Arx)"],
	"barracks": [Color(0.48, 0.30, 0.16), "barracks"],
	"tent": [Color(0.82, 0.70, 0.46), "tent"],
	"stakes": [Color(0.62, 0.10, 0.10), "stake row"],
	"cover": [Color(0.16, 0.22, 0.12), "cover (crates, low walls ...)"],
	"decor": [Color(0.30, 0.30, 0.32), "decor (arch, rocks)"],
}
const RESERVED_COLOURS := {"jump_pad": Color(0.10, 0.85, 0.30), "man_cannon": Color(1.0, 0.85, 0.0), "lily_trap": Color(1.0, 0.25, 0.85)}
const RESERVED_TAGS := {"jump_pad": "J", "man_cannon": "C", "lily_trap": "L"}
const COMPASS := ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]

var _img: Image
var _k := 1.0  # px per metre
var _origin := Vector2.ZERO  # px of world (0, 0)
var _taken: Array[Rect2i] = []  # label boxes already drawn


func _initialize() -> void:
	var out := ""
	var shots := ""
	var map_path := MAP_PATH
	var side := 2000
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
		elif a.begins_with("--shots="):
			shots = a.substr(8)
		elif a.begins_with("--map="):
			map_path = a.substr(6)
		elif a.begins_with("--size="):
			side = int(a.substr(7))
	if shots != "":
		var ok: bool = await _shots(map_path, shots)
		quit(0 if ok else 1)
		return
	if out == "":
		printerr("render_layout: give --out=<absolute png path> or --shots=<dir>")
		quit(1)
		return
	var def := DataRegistry.parse_quiet(map_path)
	if def.is_empty():
		printerr("render_layout: cannot read %s" % map_path)
		quit(1)
		return
	var t0 := Time.get_ticks_msec()
	var items := layout_items(def)
	var img := render(def, items, side)
	DirAccess.make_dir_recursive_absolute(out.get_base_dir())
	var err := img.save_png(out)
	print("RENDER_LAYOUT out=%s size=%dx%d items=%d footprints=%d ms=%d err=%d" % [out, img.get_width(), img.get_height(), items.size(),
			DataRegistry.collider_footprints(def).size(), Time.get_ticks_msec() - t0, err])
	quit(0 if err == OK else 1)


# --- the data pass (no drawing; tests/test_alesia_1km_data.gd checks it) ---

static func compass_of(bearing_deg: float) -> String:
	return COMPASS[int(round(fposmod(bearing_deg, 360.0) / 22.5)) % 16]


## Every labelled thing of the picture: [{kind, id, label, at: Vector2 (world x, z)}]. Kinds: landmark, gate
## (inner and outer), tower, aqueduct, spawn, reserved (plus "spot_kind"), ring, circle (play circle, zone start).
static func layout_items(def: Dictionary) -> Array:
	var out: Array = []
	var gen: Dictionary = def.get("generator", {})
	var landmarks: Array = DataRegistry.parse_quiet(str(def.get("landmarks", ""))).get("landmarks", [])
	var landmark_ids := {}
	for lm: Dictionary in landmarks:
		landmark_ids[str(lm["id"])] = true
		out.append({"kind": "landmark", "id": str(lm["id"]), "label": str(lm["name"]), "at": Vector2(float(lm["at"][0]), float(lm["at"][1])),
			"landmark_kind": str(lm.get("kind", ""))})
	for ring_key: String in ["inner_wall", "outer_wall"]:
		var ring: Dictionary = gen.get(ring_key, {})
		if ring.is_empty():
			continue
		var r := float(ring["radius_m"])
		var bearings: Array = ring.get("gate_bearings_deg", [])
		var names: Array = ring.get("gate_names", [])
		for i in bearings.size():
			var gate_name := str(names[i]) if i < names.size() else ""
			out.append({"kind": "gate", "id": "%s_gate_%d" % [ring_key, i], "label": gate_name, "at": Gen.dir_of(float(bearings[i])) * r,
				"ring": ring_key, "is_landmark": landmark_ids.has(gate_name.to_snake_case())})
		var towers: Array = ring.get("tower_bearings_deg", [])
		for i in towers.size():
			var b := float(towers[i])
			var specula := is_equal_approx(b, float(gen.get("specula_bearing_deg", -1.0)))
			out.append({"kind": "tower", "id": "%s_tower_%d" % [ring_key, i], "label": "Specula (tower %s)" % compass_of(b) if specula else "Tower %s" % compass_of(b),
				"at": Gen.dir_of(b) * r, "is_landmark": specula and landmark_ids.has("specula")})
		out.append({"kind": "ring", "id": ring_key, "label": "%s r %d m, %d sides" % ["Inner wall" if ring_key == "inner_wall" else "Outer wall", int(r), int(ring.get("sides", 0))],
			"at": Gen.dir_of(float(ring.get("label_bearing_deg", 200.0))) * r, "radius_m": r, "sides": int(ring.get("sides", 0))})
	for aq: Dictionary in gen.get("aqueducts", []):
		var b := float(aq["bearing_deg"])
		var outer := float(aq["inner_m"]) + SPAN_M * float(aq["spans_out"])
		out.append({"kind": "aqueduct", "id": str(aq["id"]), "label": str(aq["name"]),
			"at": Gen.dir_of(b) * (outer + 40.0) + Gen.right_of(b) * float(aq["offset_m"]), "is_landmark": landmark_ids.has(str(aq["id"]))})
	var spawns: Dictionary = def.get("spawns", {})
	var spawn_ids: Array = spawns.keys()
	spawn_ids.sort()
	for sid: String in spawn_ids:
		var v: Array = spawns[sid]
		out.append({"kind": "spawn", "id": sid, "label": "spawn %s" % sid.trim_prefix("spot_"), "at": Vector2(float(v[0]), float(v[2]))})
	for spot: Dictionary in def.get("reserved_spots", []):
		var kind := str(spot["kind"])
		out.append({"kind": "reserved", "id": str(spot["id"]), "spot_kind": kind,
			"label": "%s%d" % [RESERVED_TAGS.get(kind, "?"), int(str(spot["id"]).get_slice("_", str(spot["id"]).get_slice_count("_") - 1))],
			"at": Vector2(float(spot["at"][0]), float(spot["at"][1]))})
	var play := float(def.get("play_radius_m", 0.0))
	if play > 0.0:
		out.append({"kind": "circle", "id": "play_circle", "label": "play circle r %d m" % int(play), "at": Vector2.ZERO, "radius_m": play})
	var zone: Dictionary = def.get("overrides", {}).get("br", {}).get("zone", {})
	if zone.has("start_radius_m"):
		var c: Array = zone.get("start_center", [0, 0])
		out.append({"kind": "circle", "id": "zone_start", "label": "zone start r %d m (OQ-BR-ZONE)" % int(float(zone["start_radius_m"])),
			"at": Vector2(float(c[0]), float(c[1])), "radius_m": float(zone["start_radius_m"])})
	return out

const SPAN_M := 10.0


## The class of every footprint id: {id: class key of CLASSES}.
static func footprint_classes(def: Dictionary) -> Dictionary:
	var out := {}
	var placed := DataRegistry.parse_quiet(str(def.get("cover_data", "")))
	for list: String in ["pieces", "ring_pieces"]:
		for entry: Dictionary in placed.get(list, []):
			out[str(entry["id"])] = "cover"
	for entry: Dictionary in placed.get("decor", []):
		out[str(entry["id"])] = "decor"
	var by_type := {"wall_walk": "wall", "wall_stair": "stair", "gate": "gate", "watchtower": "tower", "aqueduct_span": "aqueduct",
		"aqueduct_ramp": "ramp", "barracks": "barracks", "tent": "tent", "stake_row": "stakes"}
	for entry: Dictionary in WorldKit.pieces_for(def):
		out[str(entry["id"])] = by_type.get(str(entry["type"]), "citadel")
	return out


# --- drawing ---

func _px(world: Vector2) -> Vector2:
	return _origin + world * _k


func render(def: Dictionary, items: Array, side: int) -> Image:
	_img = Image.create(side, side, false, Image.FORMAT_RGBA8)
	_img.fill(Color(0.93, 0.92, 0.88))
	_taken.clear()
	var ground := float(def.get("terrain", {}).get("size_m", 1000.0))
	var margin := int(side * 0.075)
	_k = float(side - 2 * margin) / ground
	_origin = Vector2(side * 0.5, side * 0.5)
	var gen: Dictionary = def.get("generator", {})
	var paint: Dictionary = def.get("ground_paint", {})
	# Ground bands (flat colours from the map's ground_paint keys) and the hill's height shading.
	var paved := float(paint.get("citadel_paving_m", 0.0))
	var grass := float(paint.get("grass_from_m", ground))
	var hill: Dictionary = gen.get("hill", {})
	var half := ground * 0.5
	var x0 := int(_px(Vector2(-half, -half)).x)
	var x1 := int(_px(Vector2(half, half)).x)
	for py in range(x0, x1):
		for px in range(x0, x1):
			var w := (Vector2(px, py) - _origin) / _k
			var r := w.length()
			var c := Color(0.55, 0.68, 0.38) if r >= grass else Color(0.72, 0.62, 0.46)
			if r < paved:
				c = Color(0.80, 0.78, 0.72)
			if not hill.is_empty() and r < float(hill["radius_m"]) + 2.0:
				var h := Gen.hill_height(hill, w.x, w.y)
				c = c.darkened(0.25 * (1.0 - h / float(hill["height_m"]))) if h > 0.0 else c
				var h_next := Gen.hill_height(hill, w.x + 1.0 / _k, w.y)
				var h_down := Gen.hill_height(hill, w.x, w.y + 1.0 / _k)
				if h > 0.0 and (floori(h / 5.0) != floori(h_next / 5.0) or floori(h / 5.0) != floori(h_down / 5.0)):
					c = Color(0.35, 0.30, 0.25)
			_img.set_pixel(px, py, c)
	_frame_rect(Rect2i(x0, x0, x1 - x0, x1 - x0), Color(0.2, 0.2, 0.2), 2)
	# Footprints, by class.
	var classes := footprint_classes(def)
	for fp: Dictionary in DataRegistry.collider_footprints(def):
		var cls := String(classes.get(str(fp["id"]), "cover"))
		_fill_footprint(fp, CLASSES[cls][0])
	# Circles: rings (thin), play circle, zone start.
	for item: Dictionary in items:
		if item["kind"] == "ring":
			_circle(Vector2.ZERO, float(item["radius_m"]), Color(0.25, 0.25, 0.25, 0.6), 1, 0)
		elif item["id"] == "play_circle":
			_circle(item["at"], float(item["radius_m"]), Color(0.1, 0.1, 0.1), 3, 18)
		elif item["id"] == "zone_start":
			_circle(item["at"], float(item["radius_m"]) - 3.0, Color(0.0, 0.55, 0.85), 2, 10)
	# Markers first (so labels go on top), then labels by priority.
	for item: Dictionary in items:
		var p := _px(item["at"])
		match String(item["kind"]):
			"spawn":
				_disc(p, 9, Color(0.05, 0.05, 0.05))
				_disc(p, 6, Color(1, 1, 1))
				_disc(p, 3, Color(0.05, 0.05, 0.05))
			"reserved":
				_reserved_marker(p, String(item["spot_kind"]), 9)
			"gate":
				_disc(p, 7, CLASSES["gate"][0].darkened(0.3))
			"tower":
				_disc(p, 7, CLASSES["tower"][0].darkened(0.2))
	for item: Dictionary in items:
		if item["kind"] == "reserved":
			_reserve(Rect2i(Vector2i(_px(item["at"])) - Vector2i(10, 10), Vector2i(20, 20)))
	var order := ["landmark", "gate", "tower", "aqueduct", "ring", "spawn", "circle", "reserved"]
	var scales := {"landmark": 3, "gate": 2, "tower": 2, "aqueduct": 3, "ring": 2, "spawn": 2, "circle": 2, "reserved": 2}
	var colours := {"landmark": Color(0.05, 0.05, 0.05), "gate": Color(0.55, 0.15, 0.0), "tower": Color(0.35, 0.05, 0.45),
		"aqueduct": Color(0.05, 0.20, 0.55), "ring": Color(0.15, 0.15, 0.15), "spawn": Color(0.05, 0.05, 0.05),
		"circle": Color(0.05, 0.05, 0.05), "reserved": Color(0.10, 0.10, 0.10)}
	for kind: String in order:
		for item: Dictionary in items:
			if item["kind"] != kind or bool(item.get("is_landmark", false)):
				continue  # a gate, tower or aqueduct that is also a landmark is labelled once, as the landmark
			var text := String(item["label"])
			if kind == "landmark" and item.get("landmark_kind", "") == "citadel":
				text += " (hill %d m, r %d m)" % [int(float(hill.get("height_m", 0))), int(float(hill.get("radius_m", 0)))]
			if kind == "gate" and String(item.get("ring", "")) == "inner_wall":
				text += " (inner)"
			var anchor := _px(item["at"])
			if kind == "circle":
				anchor = _px(item["at"] + Gen.dir_of(315.0 if item["id"] == "play_circle" else 300.0) * float(item["radius_m"]))
			_label(anchor, text, int(scales[kind]), colours[kind], kind != "reserved")
	_header(def, side, margin)
	_legend(side, margin)
	_north_arrow(Vector2(side - margin * 0.55, margin * 1.6))
	_scale_bar(Vector2(side - margin - 100.0 * _k, margin - 28))
	return _img


func _header(def: Dictionary, side: int, margin: int) -> void:
	var title := "%s - LAYOUT PICTURE FROM THE DATA (GREY-BOX, M2 L1)" % String(def.get("name", def.get("id", "map")))
	_text(Vector2i(24, 18), title, 4, Color(0.05, 0.05, 0.05), Color(0.93, 0.92, 0.88))
	_text(Vector2i(24, 18 + 40), "EVERY SIZE, COUNT, POSITION AND NAME HERE IS A PROPOSAL FOR SHIBI TO CHANGE (OQ-ALESIA-LAYOUT). NORTH = -Z UP.", 2, Color(0.6, 0.0, 0.0), Color(0.93, 0.92, 0.88))
	_text(Vector2i(24, 18 + 62), "GROUND %d M; RINGS ARE APOTHEMS (CENTRE TO SIDE MIDDLE); ZONE / DROP / LOOT ARE GUESSES (OQ-BR-ZONE, -DROP, -LOOT)." % int(float(def.get("terrain", {}).get("size_m", 0))), 2, Color(0.2, 0.2, 0.2), Color(0.93, 0.92, 0.88))


func _legend(side: int, margin: int) -> void:
	var x := 24
	var y := side - margin + 14
	var col := 0
	var keys: Array = CLASSES.keys()
	for i in keys.size():
		var cx := x + col * 480
		_img.fill_rect(Rect2i(cx, y, 22, 14), CLASSES[keys[i]][0])
		_text(Vector2i(cx + 30, y + 1), String(CLASSES[keys[i]][1]), 2, Color(0.05, 0.05, 0.05), Color(0.93, 0.92, 0.88))
		col += 1
		if col == 4 or (i == keys.size() - 1):
			col = 0
			y += 26
	var ry := y + 4
	var rx := x
	for kind: String in RESERVED_COLOURS:
		_reserved_marker(Vector2(rx + 10, ry + 8), kind, 9)
		var t := "%s0, %s1 ... = reserved J1 %s spot" % [RESERVED_TAGS[kind], RESERVED_TAGS[kind], kind.replace("_", " ")]
		_text(Vector2i(rx + 26, ry + 1), t, 2, Color(0.05, 0.05, 0.05), Color(0.93, 0.92, 0.88))
		rx += 520
	_text(Vector2i(rx, ry + 1), "(places only, no behaviour)", 2, Color(0.05, 0.05, 0.05), Color(0.93, 0.92, 0.88))
	ry += 26
	_disc(Vector2(x + 10, ry + 8), 9, Color(0.05, 0.05, 0.05))
	_disc(Vector2(x + 10, ry + 8), 6, Color(1, 1, 1))
	_text(Vector2i(x + 26, ry + 1), "spawn (fallback; the drop decides)", 2, Color(0.05, 0.05, 0.05), Color(0.93, 0.92, 0.88))
	_dash(Vector2(x + 520, ry + 8), Vector2(x + 580, ry + 8), Color(0.1, 0.1, 0.1), 3, 18)
	_text(Vector2i(x + 590, ry + 1), "play circle", 2, Color(0.05, 0.05, 0.05), Color(0.93, 0.92, 0.88))
	_dash(Vector2(x + 760, ry + 8), Vector2(x + 820, ry + 8), Color(0.0, 0.55, 0.85), 2, 10)
	_text(Vector2i(x + 830, ry + 1), "zone start (drawn 3 m inside)", 2, Color(0.05, 0.05, 0.05), Color(0.93, 0.92, 0.88))
	_text(Vector2i(x + 1230, ry + 1), "hill: shaded by height, 5 m contours", 2, Color(0.05, 0.05, 0.05), Color(0.93, 0.92, 0.88))


func _north_arrow(at: Vector2) -> void:
	for i in 60:
		var w := int(i * 0.35)
		_img.fill_rect(Rect2i(int(at.x) - w, int(at.y) - 30 + i, w * 2 + 1, 1), Color(0.1, 0.1, 0.1))
	_text(Vector2i(int(at.x) - 9, int(at.y) - 62), "N", 4, Color(0.1, 0.1, 0.1), Color(0.93, 0.92, 0.88))


func _scale_bar(at: Vector2) -> void:
	var len := int(100.0 * _k)
	for i in 5:
		_img.fill_rect(Rect2i(int(at.x) + i * len / 5, int(at.y), len / 5, 10), Color(0.1, 0.1, 0.1) if i % 2 == 0 else Color(1, 1, 1))
	_frame_rect(Rect2i(int(at.x), int(at.y), len, 10), Color(0.1, 0.1, 0.1), 1)
	_text(Vector2i(int(at.x), int(at.y) - 22), "0", 2, Color(0.1, 0.1, 0.1), Color(0.93, 0.92, 0.88))
	_text(Vector2i(int(at.x) + len - 40, int(at.y) - 22), "100 M", 2, Color(0.1, 0.1, 0.1), Color(0.93, 0.92, 0.88))


func _fill_footprint(fp: Dictionary, colour: Color) -> void:
	var rect: Rect2 = fp["rect"]
	var yaw: float = fp["yaw"]
	var at: Vector2 = fp["at"]
	var corners: Array[Vector2] = []
	for c in [rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)]:
		# Godot's yaw turns piece (x, z) to (x cos + z sin, -x sin + z cos) (DataRegistry.footprint_at).
		corners.append(at + Vector2(c.x * cos(yaw) + c.y * sin(yaw), -c.x * sin(yaw) + c.y * cos(yaw)))
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for c in corners:
		lo = lo.min(_px(c))
		hi = hi.max(_px(c))
	var hit_any := false
	for py in range(floori(lo.y), ceili(hi.y) + 1):
		for px in range(floori(lo.x), ceili(hi.x) + 1):
			var w := (Vector2(px, py) - _origin) / _k
			if DataRegistry.footprint_at(w, [fp]) != "":
				_put(px, py, colour)
				hit_any = true
	if not hit_any:  # thinner than a pixel: one dot at its centre
		var p := _px(at + Vector2(rect.get_center().x * cos(yaw) + rect.get_center().y * sin(yaw), -rect.get_center().x * sin(yaw) + rect.get_center().y * cos(yaw)))
		_put(int(p.x), int(p.y), colour)


func _put(x: int, y: int, c: Color) -> void:
	if x >= 0 and y >= 0 and x < _img.get_width() and y < _img.get_height():
		_img.set_pixel(x, y, c if c.a >= 1.0 else _img.get_pixel(x, y).lerp(Color(c.r, c.g, c.b), c.a))


func _disc(p: Vector2, r: int, c: Color) -> void:
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			if dx * dx + dy * dy <= r * r:
				_put(int(p.x) + dx, int(p.y) + dy, c)


func _reserved_marker(p: Vector2, kind: String, r: int) -> void:
	var c: Color = RESERVED_COLOURS.get(kind, Color.WHITE)
	for dy in range(-r - 2, r + 3):
		for dx in range(-r - 2, r + 3):
			var inside := false
			var edge := false
			match kind:
				"jump_pad":  # triangle pointing up
					var t := float(dy + r) / float(2 * r)
					inside = dy >= -r and dy <= r and absf(dx) <= t * r
					edge = dy >= -r - 2 and dy <= r + 2 and absf(dx) <= (float(dy + r + 2) / float(2 * r + 4)) * (r + 2)
				"man_cannon":  # diamond
					inside = absi(dx) + absi(dy) <= r
					edge = absi(dx) + absi(dy) <= r + 2
				_:  # lily trap: ring
					var d := dx * dx + dy * dy
					inside = d <= r * r
					edge = d <= (r + 2) * (r + 2)
			if inside:
				_put(int(p.x) + dx, int(p.y) + dy, c)
			elif edge:
				_put(int(p.x) + dx, int(p.y) + dy, Color(0.05, 0.05, 0.05))


func _circle(centre: Vector2, radius_m: float, c: Color, width: int, dash: int) -> void:
	var steps := int(TAU * radius_m * _k)
	for i in steps:
		if dash > 0 and (i / dash) % 2 == 1:
			continue
		var a := TAU * float(i) / float(steps)
		var p := _px(centre + Vector2(cos(a), sin(a)) * radius_m)
		for dy in range(-width / 2, width - width / 2):
			for dx in range(-width / 2, width - width / 2):
				_put(int(p.x) + dx, int(p.y) + dy, c)


func _dash(a: Vector2, b: Vector2, c: Color, width: int, dash: int) -> void:
	var n := int(a.distance_to(b))
	for i in n:
		if (i / dash) % 2 == 1:
			continue
		var p := a.lerp(b, float(i) / maxf(n, 1))
		_img.fill_rect(Rect2i(int(p.x), int(p.y) - width / 2, 1, width), c)


func _frame_rect(r: Rect2i, c: Color, w: int) -> void:
	_img.fill_rect(Rect2i(r.position.x, r.position.y, r.size.x, w), c)
	_img.fill_rect(Rect2i(r.position.x, r.end.y - w, r.size.x, w), c)
	_img.fill_rect(Rect2i(r.position.x, r.position.y, w, r.size.y), c)
	_img.fill_rect(Rect2i(r.end.x - w, r.position.y, w, r.size.y), c)


func _text_size(text: String, s: int) -> Vector2i:
	return Vector2i(text.length() * 6 * s - s, 7 * s)


## Draws text with a 1-unit halo (background colour) so it reads on any ground.
func _text(at: Vector2i, text: String, s: int, c: Color, halo: Color) -> void:
	var up := text.to_upper()
	for pass_i in 2:
		var x := at.x
		for ch in up:
			var rows: Array = FONT.get(ch, FONT["?"])
			for row in 7:
				var bits := int(rows[row])
				for col in 5:
					if bits & (16 >> col):
						if pass_i == 0:
							_img.fill_rect(Rect2i(x + col * s - s, at.y + row * s - s, s * 3, s * 3), halo)
						else:
							_img.fill_rect(Rect2i(x + col * s, at.y + row * s, s, s), c)
			x += 6 * s


func _reserve(r: Rect2i) -> void:
	_taken.append(r)


## Places a label near `anchor` where it overlaps no earlier label (8 candidate spots, then further rings); a
## leader line joins a label that moved away from its anchor.
func _label(anchor: Vector2, text: String, s: int, c: Color, leader: bool) -> void:
	var size := _text_size(text, s) + Vector2i(4, 4)
	var bounds := Rect2i(Vector2i.ZERO, Vector2i(_img.get_width(), _img.get_height()))
	for ring in 6:
		var d := 14 + ring * 22
		var candidates := [Vector2i(d, -size.y / 2), Vector2i(-d - size.x, -size.y / 2), Vector2i(-size.x / 2, -d - size.y),
			Vector2i(-size.x / 2, d), Vector2i(d, -d - size.y), Vector2i(-d - size.x, -d - size.y), Vector2i(d, d), Vector2i(-d - size.x, d)]
		for off: Vector2i in candidates:
			var r := Rect2i(Vector2i(anchor) + off, size)
			if not bounds.encloses(r):
				continue
			var free := true
			for t in _taken:
				if t.intersects(r):
					free = false
					break
			if free:
				_taken.append(r)
				if leader and ring > 0:
					_line(anchor, Vector2(clampf(anchor.x, r.position.x, r.end.x), clampf(anchor.y, r.position.y, r.end.y)), c)
				_text(r.position + Vector2i(2, 2), text, s, c, Color(1, 1, 1))
				return
	_text(Vector2i(anchor) + Vector2i(12, -size.y / 2), text, s, c, Color(1, 1, 1))  # nowhere free: draw anyway


func _line(a: Vector2, b: Vector2, c: Color) -> void:
	var n := int(a.distance_to(b))
	for i in n:
		var p := a.lerp(b, float(i) / maxf(n, 1))
		_put(int(p.x), int(p.y), c)


# --- ground shots (windowed) ---

## The six named ground shots: [name, camera (x, z), look at (x, y above its ground, z)]; eye height over the terrain.
static func shot_points(def: Dictionary) -> Array:
	var gen: Dictionary = def["generator"]
	var camps: Dictionary = gen["camps"]
	var camp_b := float(camps["first_bearing_deg"])
	var camp := Gen.dir_of(camp_b) * float(camps["radius_m"])
	var spec_b := float(gen["specula_bearing_deg"])
	var outer_r := float(gen["outer_wall"]["radius_m"])
	var spec := Gen.dir_of(spec_b) * outer_r
	var magnus: Dictionary = gen["aqueducts"][0]
	var mag_off := Gen.right_of(float(magnus["bearing_deg"])) * float(magnus["offset_m"])
	var mag_in := float(magnus["inner_m"])
	var field_b := 340.0  # the camera looks south-east, away from the low sun of the match look
	return [
		["citadel", Vector2(-4.0, 21.0), Vector3(0.0, 4.0, -6.0), "the Arx top from its south edge: eagle, columns, colonnades, pediment"],
		["gate", Gen.dir_of(0.0) * (outer_r + 45.0) + Vector2(-6.0, 0.0), Vector3(0.0, 3.0, -outer_r), "Porta Aquilae from outside (north), Aquaeductus Magnus to the left"],
		["camp", camp + Gen.dir_of(camp_b) * 55.0 + Gen.right_of(camp_b) * 18.0, Vector3(camp.x, 2.0, camp.y), "Castra Prima from its outer side"],
		["tower", spec - Gen.dir_of(spec_b) * 26.0 + Gen.right_of(spec_b) * 12.0, Vector3(spec.x, 5.0, spec.y), "Specula from inside the outer wall"],
		["aqueduct", Gen.dir_of(0.0) * (mag_in - 40.0) + mag_off + Vector2(-38.0, 0.0), Vector3(mag_off.x, 3.0, Gen.dir_of(0.0).y * (mag_in + 15.0)), "Aquaeductus Magnus and its inner ramp, looking out along it"],
		["fields", Gen.dir_of(field_b) * 465.0, Vector3(Gen.dir_of(field_b).x * outer_r, 2.0, Gen.dir_of(field_b).y * outer_r), "the fields (stake lines, low cover) towards the outer wall"],
	]


func _shots(map_path: String, dir: String) -> bool:
	if DisplayServer.get_name() == "headless":
		printerr("render_layout --shots needs a window (run without --headless)")
		return false
	var def := DataRegistry.parse_quiet(map_path)
	DirAccess.make_dir_recursive_absolute(dir)
	await process_frame
	var view := SubViewport.new()
	view.size = SHOT_SIZE
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	view.own_world_3d = true
	root.add_child(view)
	var stage := Node3D.new()
	stage.name = "Match"
	var light := DirectionalLight3D.new()
	light.name = "Light"
	stage.add_child(light)
	var world := WorldEnvironment.new()
	world.name = "WorldEnvironment"
	world.set_script(load("res://scripts/visual/greybox_art.gd"))  # the match's look (light, sky, fog by preset)
	stage.add_child(world)
	view.add_child(stage)
	var map: Node3D = load(String(def["scene"])).instantiate()
	map.get_node("ArtBuilder").set("map_json", map_path)
	stage.add_child(map)
	var terrain: MapTerrain = map.get_node("ArtBuilder").get("terrain")
	var camera := Camera3D.new()
	camera.fov = 70.0
	camera.far = 2000.0
	stage.add_child(camera)
	camera.make_current()
	var ok := true
	for frame in 10:
		await process_frame
	for shot: Array in shot_points(def):
		var at: Vector2 = shot[1]
		var look: Vector3 = shot[2]
		var gy := terrain.height_at(at.x, at.y) if terrain != null else 0.0
		var ly := terrain.height_at(look.x, look.z) if terrain != null else 0.0
		camera.global_position = Vector3(at.x, gy + EYE_M, at.y)
		camera.look_at(Vector3(look.x, ly + look.y, look.z), Vector3.UP)
		for frame in 30:
			await process_frame
		await RenderingServer.frame_post_draw
		var img := view.get_texture().get_image()
		var path := dir.path_join("shot_%s.png" % shot[0])
		var err := img.save_png(path)
		ok = ok and err == OK
		print("RENDER_SHOT %s %dx%d err=%d camera=(%.1f, %.1f, %.1f) look=(%.1f, %.1f, %.1f): %s" % [path, img.get_width(), img.get_height(), err,
				camera.global_position.x, camera.global_position.y, camera.global_position.z, look.x, ly + look.y, look.z, shot[3]])
	view.queue_free()
	await process_frame
	return ok
