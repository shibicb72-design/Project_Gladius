class_name NetDebugPing
extends Node
## W2: debug counters for the two-browser LAN smoke (tools/web/lan_smoke.mjs). NetSession._enter_tree adds one child of
## this, named NODE_NAME, on EVERY peer and in every build, so the RPC paths below always match; it only acts (pings,
## prints) when `active`: a debug build in the browser (OS.is_debug_build() and the "web" feature tag), or a test's
## simulate_active. Release builds, desktop and the headless suite keep it inert and silent.
##
## Round trip: a guest sends `_ping(t_us)` to the host (peer 1) every PING_INTERVAL_S; the host answers `_pong(t_us)` to
## the sender; the guest keeps (now - t_us) in ms. Both RPCs are UNRELIABLE: a reliable ping would fold
## retransmission waits into the number and stall behind reliable game traffic; a lost ping only loses one sample.
## Snapshots: counts the session bridge's snapshot_received (the guest applying a host snapshot).
## Console markers (active only; the smoke reads them):
##   GLADIUS_LAN_SNAPSHOTS <count>                            every REPORT_INTERVAL_S
##   GLADIUS_LAN_PING median_ms=<x> max_ms=<y> n=<n>          every REPORT_INTERVAL_S once there are samples
##   GLADIUS_LAN_HOST_READY <urls>, GLADIUS_LAN_CONNECTED, GLADIUS_LAN_ERROR <last_error>, GLADIUS_LAN_HOST_LOST
##   <last_error>, GLADIUS_LAN_PEER_JOINED <id>, GLADIUS_LAN_PEER_LEFT <id>   when the session signals fire

const NODE_NAME := "NetDebugPing"
## Debug tool values (not game tunables): ping cadence, marker cadence, kept samples.
const PING_INTERVAL_S := 1.0
const REPORT_INTERVAL_S := 5.0
const MAX_SAMPLES := 600

## Test hook: when non-null it replaces the debug-and-web gate. Never set in shipping code.
static var simulate_active: Variant = null

var active: bool = false
## Round-trip samples in ms (the last MAX_SAMPLES).
var samples: Array[float] = []
var pings_sent: int = 0
var snapshots: int = 0
## Test hook: when valid, markers go to marker_sink.call(line) instead of print.
var marker_sink: Callable

var _session: NetSession
var _ping_left_s: float = 0.0
var _report_left_s: float = 0.0


## The gate: debug build in the browser, unless a test overrides it.
static func gate() -> bool:
	if simulate_active != null:
		return bool(simulate_active)
	return OS.is_debug_build() and OS.has_feature("web")


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	active = gate()
	_session = get_parent() as NetSession
	if _session == null:
		return
	if _session.bridge != null:
		_session.bridge.snapshot_received.connect(_on_snapshot)
	_session.host_ready.connect(func(urls: PackedStringArray) -> void: _marker("GLADIUS_LAN_HOST_READY " + ",".join(urls)))
	_session.connected.connect(func() -> void: _marker("GLADIUS_LAN_CONNECTED"))
	_session.failed.connect(func() -> void: _marker("GLADIUS_LAN_ERROR " + _session.last_error))
	_session.host_lost.connect(func() -> void: _marker("GLADIUS_LAN_HOST_LOST " + _session.last_error))
	_session.peer_joined.connect(func(id: int) -> void: _marker("GLADIUS_LAN_PEER_JOINED %d" % id))
	_session.peer_left.connect(func(id: int) -> void: _marker("GLADIUS_LAN_PEER_LEFT %d" % id))
	set_process(active)


func _process(delta: float) -> void:
	_ping_left_s -= delta
	if _ping_left_s <= 0.0:
		_ping_left_s = PING_INTERVAL_S
		send_ping()
	_report_left_s -= delta
	if _report_left_s <= 0.0:
		_report_left_s = REPORT_INTERVAL_S
		report()


## True when this peer is a guest connected to a host (the only time a ping is sent).
func _guest_online() -> bool:
	var mp := multiplayer
	if mp == null or not mp.has_multiplayer_peer() or mp.is_server():
		return false
	return mp.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


## Guest: one ping to the host. Returns whether it was sent.
func send_ping() -> bool:
	if not active or not _guest_online():
		return false
	pings_sent += 1
	_ping.rpc_id(1, Time.get_ticks_usec())
	return true


@rpc("any_peer", "call_remote", "unreliable")
func _ping(t_us: int) -> void:
	if not active or not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender > 1:
		_pong.rpc_id(sender, t_us)


@rpc("any_peer", "call_remote", "unreliable")
func _pong(t_us: int) -> void:
	if not active or multiplayer.get_remote_sender_id() != 1:
		return
	add_sample(float(Time.get_ticks_usec() - t_us) / 1000.0)


func add_sample(ms: float) -> void:
	samples.append(ms)
	if samples.size() > MAX_SAMPLES:
		samples.remove_at(0)


func _on_snapshot() -> void:
	snapshots += 1


## Prints the snapshot count and, once there are samples, the ping summary.
func report() -> void:
	_marker("GLADIUS_LAN_SNAPSHOTS %d" % snapshots)
	if not samples.is_empty():
		_marker("GLADIUS_LAN_PING median_ms=%.1f max_ms=%.1f n=%d min_ms=%.1f" % [median(samples), max_of(samples),
				samples.size(), min_of(samples)])


func _marker(line: String) -> void:
	if not active:
		return
	if marker_sink.is_valid():
		marker_sink.call(line)
	else:
		print(line)


## Pure: the median of `values` (the mean of the middle two for an even count); 0 when empty.
static func median(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var s := values.duplicate()
	s.sort()
	var n := s.size()
	var mid := n >> 1
	if n % 2 == 1:
		return float(s[mid])
	return (float(s[mid - 1]) + float(s[mid])) * 0.5


## Pure: the smallest of `values`; 0 when empty.
static func min_of(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var m := values[0]
	for v: float in values:
		m = minf(m, v)
	return m


## Pure: the largest of `values`; 0 when empty.
static func max_of(values: Array[float]) -> float:
	var m := 0.0
	for v: float in values:
		m = maxf(m, v)
	return m
