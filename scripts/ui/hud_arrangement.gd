class_name HudArrangement
extends RefCounted
## M2 H1b: where the in-match HUD's passive displays and the reserved minimap / radar panel sit, for any view size and
## density. Pure geometry from data (data/ui.json "hud_arrangement", "minimap", "radar"; data/input.json touch_layout
## for the primary button side and the look-area insets), static, so GameHud, the touch HUD, the fire-mode and Interact
## buttons, the pause gear, the tests and the probe all read the same rects without instancing each other.
## Placement (hud_arrangement.placement, OQ-HUD):
##   "above_row": the weapon block sits just above the bottom-centre action row, right of the Interact slot; no button moves.
##   "split_row": the block sits on the bottom edge at the centre and the row is split around it (Fire mode and Swap left,
##                Cover / Shoulder right, Interact above the block's left end). Only where the view is at least split_row.min_aspect wide;
##                narrower views (the near-square Fold inner and 1152x959) use "above_row" (they have no room, see notes).
## All rects are in view (HUD) space, origin top-left. Every number is a placeholder (OQ-HUD, OQ-MINIMAP, OQ-RADAR).

const UI_PATH := "res://data/ui.json"
const INPUT_PATH := "res://data/input.json"
const ABOVE_ROW := "above_row"
const SPLIT_ROW := "split_row"
## Buttons whose DEFAULT place follows the weapon block in "split_row" (layout-editor slot positions still win).
const SPLIT_KEYS: Array[String] = ["swap_weapon", "swap_shoulder"]

## Tests and capture tools: "" = data; "above_row" / "split_row" = forced.
static var placement_override: String = ""
static var _ui: Dictionary = {}
static var _tl: Dictionary = {}


static func ui() -> Dictionary:
	if _ui.is_empty():
		_ui = DataRegistry.new().load_file(UI_PATH)
	return _ui


static func touch_layout() -> Dictionary:
	if _tl.is_empty():
		_tl = DataRegistry.new().load_file(INPUT_PATH).get("touch_layout", {})
	return _tl


static func cfg() -> Dictionary:
	return ui().get("hud_arrangement", {})


static func dp() -> float:
	return PlatformServices.new().get_dp_scale()


## The placement asked for (data or override), before the per-size aspect check.
static func placement() -> String:
	var p := placement_override if placement_override != "" else str(cfg().get("placement", ABOVE_ROW))
	return p if p == SPLIT_ROW else ABOVE_ROW


## The placement actually used at a view size: "split_row" only where the view is wide enough.
static func placement_for(view: Vector2) -> String:
	if placement() != SPLIT_ROW or view.y <= 0.0:
		return ABOVE_ROW
	var min_aspect := float(cfg()["weapon_block"]["split_row"]["min_aspect"])
	return SPLIT_ROW if view.x / view.y >= min_aspect - 1e-4 else ABOVE_ROW


## HUD unit: a fraction of the view height, never below unit_min_dp (so text stays readable on short dense screens).
static func unit(view: Vector2) -> float:
	return maxf(float(cfg()["unit_frac_of_height"]) * view.y, float(cfg()["unit_min_dp"]) * dp())


static func edge_margin(view: Vector2) -> float:
	return float(cfg()["edge_margin_dp"]) * dp() if view.y > 0.0 else 0.0


## The touch HUD's primary button side (touch_hud.gd _button_size at 100 %): the unit of the button offsets.
static func button_side(view: Vector2) -> float:
	var tl := touch_layout()
	return maxf(float(tl["button_size_frac_of_height"]) * view.y, float(tl["button_min_dp"]) * dp())


## Side of a bottom-row ring button at 100 % (touch_hud.gd _button_side).
static func ring_side(view: Vector2) -> float:
	var tl := touch_layout()
	return maxf(float(tl["button_size_frac_of_height"]) * view.y * float(tl["ring_size_ratio"]), float(tl["button_min_dp"]) * dp())


static func _bottom_centre(view: Vector2) -> Vector2:
	var a: Array = touch_layout()["bottom_centre_anchor"]
	return Vector2(float(a[0]) * view.x, float(a[1]) * view.y)


# --- weapon block --------------------------------------------------------------------------------------------------

static func weapon_block_size(view: Vector2) -> Vector2:
	var wb: Dictionary = cfg()["weapon_block"]
	var u := unit(view)
	return Vector2(float(wb["width_units"]), float(wb["height_units"])) * u


static func weapon_block_rect(view: Vector2) -> Rect2:
	var wb: Dictionary = cfg()["weapon_block"]
	var sz := weapon_block_size(view)
	var s := button_side(view)
	var bc := _bottom_centre(view)
	if placement_for(view) == SPLIT_ROW:
		var sr: Dictionary = wb["split_row"]
		var bottom := bc.y + float(sr["bottom_offset_buttons"]) * s
		return Rect2(Vector2(bc.x - sz.x * 0.5, bottom - sz.y), sz)
	var ar: Dictionary = wb["above_row"]
	var left := bc.x + float(ar["left_offset_buttons"]) * s
	var bottom2 := bc.y + float(ar["bottom_offset_buttons"]) * s
	return Rect2(Vector2(left, bottom2 - sz.y), sz)


## "split_row": default centre of a split button (Swap left of the block, Cover / Shoulder right of it, Fire mode left
## of Swap, Interact above the block's left end), or null when the key does not move at this size (then its data offset
## stands).
static func split_center(key: String, view: Vector2) -> Variant:
	if placement_for(view) != SPLIT_ROW:
		return null
	var sr: Dictionary = cfg()["weapon_block"]["split_row"]
	var s := button_side(view)
	var gap := float(sr["gap_buttons"]) * s
	var block := weapon_block_rect(view)
	var ring := ring_side(view)
	var row_y := _bottom_centre(view).y + float(sr["row_offset_y_buttons"]) * s
	var swap_x := block.position.x - gap - ring * 0.5
	match key:
		"swap_weapon":
			return Vector2(swap_x, row_y)
		"swap_shoulder":
			return Vector2(block.end.x + gap + ring * 0.5, row_y)
		"fire_mode":
			var fm := float(ui()["fire_mode_button"]["touch_dp"]) * dp()
			return Vector2(swap_x - ring * 0.5 - gap - fm * 0.5, row_y)
		"interact":
			# Above the block's left end, still in the left half (above Swap it met Left Fire on 1512x648).
			var side := s * float(ui()["interact_button"]["size_buttons"])
			return Vector2(block.position.x + side * 0.5, block.position.y - gap - side * 0.5)
	return null


# --- top row: objective line, kill banner, alive / zone chip ------------------------------------------------------

static func chip_rect(view: Vector2) -> Rect2:
	var c: Dictionary = cfg()["chip"]
	var u := unit(view)
	var m := edge_margin(view)
	return Rect2(Vector2(m, m), Vector2(float(c["width_units"]), float(c["height_units"])) * u)


## Top-centre strip for the objective / hint line (and the DOWNED / spectating status, which takes its place).
static func objective_rect(view: Vector2) -> Rect2:
	var o: Dictionary = cfg()["objective"]
	var u := unit(view)
	var gap := float(o["side_gap_units"]) * u
	var half := float(o["max_width_frac"]) * view.x * 0.5
	half = minf(half, panel_rect(view).position.x - gap - view.x * 0.5)
	half = minf(half, view.x * 0.5 - chip_rect(view).end.x - gap)
	half = maxf(half, 0.0)
	var top := float(o["top_units"]) * u
	return Rect2(Vector2(view.x * 0.5 - half, top), Vector2(2.0 * half, float(o["height_units"]) * u))


## The local kill banner: under the objective strip, the same width (so it never reaches the panel or the chip).
static func banner_rect(view: Vector2) -> Rect2:
	var b: Dictionary = ui()["kill_feed"]
	var o := objective_rect(view)
	var top := o.end.y + float(cfg()["banner"]["gap_units"]) * unit(view)
	var font := float(b["font_frac_of_height"]) * view.y
	var h := font * float(cfg()["banner"]["height_per_font"])
	var w := minf(o.size.x, font * float(cfg()["banner"]["width_per_font"]))
	return Rect2(Vector2(view.x * 0.5 - w * 0.5, top), Vector2(w, h))


# --- reserved minimap / radar panel (drawn in H1b commits 3-4) -----------------------------------------------------

## The minimap picture: a square at the top-right corner.
static func minimap_rect(view: Vector2) -> Rect2:
	var mm: Dictionary = ui()["minimap"]
	var m := edge_margin(view)
	var side := minf(float(mm["size_frac_of_height"]) * view.y, float(mm["max_frac_of_width"]) * view.x)
	return Rect2(Vector2(view.x - m - side, m), Vector2(side, side))


## The radar: a round sweep left of the minimap, vertically centred on it.
static func radar_rect(view: Vector2) -> Rect2:
	var r: Dictionary = ui()["radar"]
	var mm := minimap_rect(view)
	var d := mm.size.y * float(r["size_frac_of_minimap"])
	var gap := float(r["gap_units"]) * unit(view)
	return Rect2(Vector2(mm.position.x - gap - d, mm.position.y + (mm.size.y - d) * 0.5), Vector2(d, d))


static func panel_rect(view: Vector2) -> Rect2:
	return minimap_rect(view).merge(radar_rect(view))


## Right edge of the main look area (touch_hud.gd get_look_area_rect, in view space).
static func look_area_right(view: Vector2) -> float:
	var la: Dictionary = touch_layout()["look_area"]
	return float(la["right_frac"]) * view.x - float(la["inset_buttons"]["right"]) * button_side(view)


## The minimap's ONLY touch target: a square in the right-edge strip, outside the look area, at the minimap's top-right,
## at least tap_min_dp (48) and at most tap_max_dp. The rest of the panel is passive.
static func minimap_tap_rect(view: Vector2) -> Rect2:
	var mm: Dictionary = ui()["minimap"]
	var pic := minimap_rect(view)
	var right := pic.end.x
	var left := maxf(look_area_right(view) + float(mm["tap_look_gap_px"]), right - float(mm["tap_max_dp"]) * dp())
	var side := maxf(right - left, 0.0)
	return Rect2(Vector2(right - side, pic.position.y), Vector2(side, side))


## Top of the pause gear when it sits under the reserved panel (data ui.json pause_gear.below_panel).
static func gear_top(view: Vector2) -> float:
	return panel_rect(view).end.y + float(ui()["pause_gear"]["below_panel_gap_dp"]) * dp()


## Every passive display rect by name (the probe, the tests and the capture overlay).
static func passive_rects(view: Vector2) -> Dictionary:
	return {"weapon_block": weapon_block_rect(view), "objective": objective_rect(view), "banner": banner_rect(view),
		"chip": chip_rect(view), "radar": radar_rect(view), "minimap": minimap_rect(view)}
