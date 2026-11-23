class_name PlatformServices
extends RefCounted
## Platform-specific code lives here behind an OS.get_name() switch with no-op fallbacks.


## Tool/test hook: makes the desktop branch below behave as if the DisplayServer reported a
## touchscreen, so the real auto-detect path can be exercised off-device. Never set in shipping code.
static var simulate_touchscreen: bool = false


## Tool/test hook: pretend the screen reports this DPI (0 = use the DisplayServer). Never set in shipping code.
static var dpi_override: float = 0.0


## Screen DPI as the platform reports it (160 when unknown, so 1 dp = 1 px).
func get_screen_dpi() -> float:
	if dpi_override > 0.0:
		return dpi_override
	var dpi := float(DisplayServer.screen_get_dpi())
	return dpi if dpi > 0.0 else 160.0


## Tool/test hook: pretend the platform reports these safe-area insets (left, top, right, bottom fractions of the
## screen) when non-null. Never set in shipping code.
static var safe_insets_override: Variant = null


## Safe-area insets (cutouts, rounded corners, system bars) as fractions of the screen, Vector4(left, top,
## right, bottom). Zero where the platform reports none (desktop, web, or a failed query), so callers fall back
## to the whole viewport.
func get_safe_insets() -> Vector4:
	if safe_insets_override is Vector4:
		return safe_insets_override
	match OS.get_name():
		"Android", "iOS":
			var screen := Vector2(DisplayServer.screen_get_size())
			var safe := DisplayServer.get_display_safe_area()
			if screen.x <= 0.0 or screen.y <= 0.0 or safe.size.x <= 0 or safe.size.y <= 0:
				return Vector4.ZERO
			return Vector4(
					clampf(safe.position.x / screen.x, 0.0, 0.5), clampf(safe.position.y / screen.y, 0.0, 0.5),
					clampf((screen.x - safe.end.x) / screen.x, 0.0, 0.5), clampf((screen.y - safe.end.y) / screen.y, 0.0, 0.5))
		_:
			return Vector4.ZERO


## Window pixels per density-independent pixel (Android baseline: 160 dpi = 1.0).
func get_dp_scale() -> float:
	return get_screen_dpi() / 160.0


## Startup diagnostic so a device run can confirm the real density.
func log_display_info() -> void:
	print("[display] os=%s screen_get_dpi=%d screen_get_scale=%.3f dp_scale=%.3f window=%s" % [
			OS.get_name(), DisplayServer.screen_get_dpi(), DisplayServer.screen_get_scale(),
			get_dp_scale(), DisplayServer.window_get_size()])


## Tool/test hook (W0): makes is_web() true off the browser, so the web-only menu path (Host and Join disabled) can
## be exercised headless. Never set in shipping code.
static var simulate_web: bool = false


## W0: true in a web (browser) export. ENet does not exist in browsers, so LAN hosting / joining is unavailable there
## (main_menu.gd disables Host and Join with a note). The one place that reads the "web" feature tag.
func is_web() -> bool:
	return simulate_web or OS.has_feature("web")


## Tool/test hook (W1a): makes is_pc() true, also in a headless run, so the PC graphics presets and Settings rows can be
## exercised in tests. Never set in shipping code.
static var simulate_pc: bool = false


## W1a: true on a PC: a browser (any web export, also a touch laptop or a phone's browser) or a desktop OS. Decides
## by platform, never by touchscreen. A headless run (tests, tools, a dedicated server) is never a PC, so it keeps
## the "default" graphics preset and today's Settings rows; simulate_pc forces true.
func is_pc() -> bool:
	if simulate_pc:
		return true
	if DisplayServer.get_name() == "headless":
		return false
	return is_web() or OS.get_name() in ["Windows", "macOS", "Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD"]


## W0 / W2: whether this platform can host or join a LAN game. Off the web always (ENet). In the browser only when the
## page came from the LAN relay (tools/lan: GET /lan.json answered {"lan": true, "proto": 1}); a page from
## tools/web/serve.mjs, a plain host or a file has no relay, so LAN stays off and W0's note shows.
func can_lan() -> bool:
	return not is_web() or uses_relay()


# ---- W2: LAN relay detection --------------------------------------------------------------------

## The relay protocol version this build speaks (tools/lan/lan_protocol.mjs, NetSignaling.PROTO).
const RELAY_PROTO := 1
const RELAY_INFO_PATH := "/lan.json"
## Seconds before the /lan.json probe gives up (no relay). Tool value, not a game tunable.
const RELAY_PROBE_TIMEOUT_S := 5.0


## Emits `changed` whenever the relay answer is set (the menu re-applies LAN availability). Static signals do not exist
## in GDScript, so the signal lives on this one shared object.
class RelayEvents extends RefCounted:
	signal changed


static var relay_events := RelayEvents.new()
## The validated relay answer ({"lan": true, "proto": 1, "urls": PackedStringArray, "max_peers": int}); {} = no relay
## (the default, also while the probe is running). Set only by set_relay_info (the probe, or a test).
static var relay_info: Dictionary = {}
## "" = not probed yet, "pending", "done". The probe runs once per page load.
static var _probe_state: String = ""


## W2: true when this page talks to a LAN relay: in the browser (is_web) AND a relay answered. Decides the menu's
## transport (WebRTC through the relay); never is_web() alone. False off the web even if relay_info is set.
func uses_relay() -> bool:
	return is_web() and not relay_info.is_empty()


## Pure: whether `d` is a relay answer this build accepts: a Dictionary with lan == true and proto == RELAY_PROTO.
static func is_relay_answer(d: Variant) -> bool:
	if not d is Dictionary:
		return false
	var dict: Dictionary = d
	var proto: Variant = dict.get("proto")
	return dict.get("lan") is bool and bool(dict["lan"]) and (proto is int or proto is float) and int(proto) == RELAY_PROTO


## Records the relay answer (also the test hook that simulates "web with relay" and "the answer arriving later"):
## an accepted answer is kept (urls as PackedStringArray), anything else clears it. Emits relay_events.changed.
static func set_relay_info(info: Variant) -> void:
	if is_relay_answer(info):
		var d: Dictionary = info
		var urls := PackedStringArray()
		var raw: Variant = d.get("urls", [])
		if raw is Array or raw is PackedStringArray:
			for u: Variant in raw:
				if u is String:
					urls.append(u)
		relay_info = {"lan": true, "proto": RELAY_PROTO, "urls": urls, "max_peers": int(d.get("max_peers", 0))}
	else:
		relay_info = {}
	relay_events.changed.emit()


## Test hook: no relay, not probed.
static func reset_relay_for_tests() -> void:
	relay_info = {}
	_probe_state = ""


## Pure: the relay answer in a /lan.json response body, or {} when it is not one (an HTML 404 page, bad JSON, lan
## false, another protocol version).
static func parse_relay_answer(body: String) -> Dictionary:
	var json := JSON.new()
	if json.parse(body) != OK or not is_relay_answer(json.data):
		return {}
	return json.data


## W2: in a real web export, asks the page's own origin for /lan.json once per page load (an HTTPRequest under the
## tree root, so it survives scene changes) and calls set_relay_info with the answer. Off the web (also with
## simulate_web) it does nothing: headless tests set the answer with set_relay_info.
static func start_relay_probe(tree: SceneTree) -> void:
	if _probe_state != "" or not OS.has_feature("web") or tree == null:
		return
	var origin: Variant = JavaScriptBridge.eval("location.origin", true)
	if not origin is String or not String(origin).begins_with("http"):
		_probe_state = "done"  # file:// or an opaque origin: no relay
		return
	_probe_state = "pending"
	var req := HTTPRequest.new()
	req.name = "LanRelayProbe"
	req.timeout = RELAY_PROBE_TIMEOUT_S
	tree.root.add_child(req)
	req.request_completed.connect(func(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
			_probe_state = "done"
			req.queue_free()
			var info := {}
			if result == HTTPRequest.RESULT_SUCCESS and code == 200:
				info = parse_relay_answer(body.get_string_from_utf8())
			set_relay_info(info))
	if req.request(String(origin) + RELAY_INFO_PATH) != OK:
		_probe_state = "done"
		req.queue_free()


func is_touch_device() -> bool:
	match OS.get_name():
		"Android", "iOS":
			return true
		_:
			return simulate_touchscreen or DisplayServer.is_touchscreen_available()


## Turns touch-to-mouse emulation on or off at runtime (never the project setting) and
## returns the previous value.
func set_mouse_emulation_from_touch(enabled: bool) -> bool:
	var prev := Input.emulate_mouse_from_touch
	Input.emulate_mouse_from_touch = enabled
	return prev


func has_gyro() -> bool:
	match OS.get_name():
		"Android", "iOS":
			return DisplayServer.get_name() != "headless"
		_:
			return false


## Angular rate in rad/s (x pitch, y yaw, z roll). Zero where unsupported.
func get_gyro_rate() -> Vector3:
	if not has_gyro():
		return Vector3.ZERO
	return Input.get_gyroscope()


func vibrate(ms: int) -> void:
	match OS.get_name():
		"Android", "iOS":
			if DisplayServer.get_name() != "headless":
				Input.vibrate_handheld(ms)
		_:
			pass
