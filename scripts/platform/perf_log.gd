class_name PerfLog
extends Node
## M2 P0: a frame-time logger for measuring a match on a real phone. Off by default. It runs when data/perf_log.json
## "enabled" is true, or when the flag file user://perf_log_on exists (created over adb on a debug build:
## `adb shell run-as <package> touch files/perf_log_on`). Every interval_s it appends one CSV row to `path`:
## frame time (mean and worst over the interval), fps, draw calls, primitives, video and static memory, node count.
## It only reads engine monitors; it changes nothing in the match. Desktop and headless runs work the same way.

const CFG_PATH := "res://data/perf_log.json"
const FLAG_PATH := "user://perf_log_on"
const HEADER := "t_s,frames,frame_ms_mean,frame_ms_max,fps,draw_calls,primitives,video_mem_mb,static_mem_mb,nodes"

var cfg: Dictionary = {}
var path := "user://perf_log.csv"
var interval_s := 1.0
var _file: FileAccess
var _t := 0.0
var _since := 0.0
var _frames := 0
var _sum_ms := 0.0
var _max_ms := 0.0


## True when the data key or the flag file asks for a log.
static func wanted(config: Dictionary = {}) -> bool:
	var c := config if not config.is_empty() else DataRegistry.new().load_file(CFG_PATH)
	return bool(c.get("enabled", false)) or FileAccess.file_exists(FLAG_PATH)


func _ready() -> void:
	name = "PerfLog"
	process_mode = Node.PROCESS_MODE_ALWAYS
	if cfg.is_empty():
		cfg = DataRegistry.new().load_file(CFG_PATH)
	path = str(cfg.get("path", path))
	interval_s = maxf(0.1, float(cfg.get("interval_s", interval_s)))
	var existed := FileAccess.file_exists(path)
	_file = FileAccess.open(path, FileAccess.READ_WRITE if existed else FileAccess.WRITE)
	if _file == null:
		push_warning("PerfLog: cannot open %s" % path)
		set_process(false)
		return
	_file.seek_end()
	if not existed:
		_file.store_line(HEADER)
	_file.store_line("# match start %s, %s, %dx%d" % [Time.get_datetime_string_from_system(), OS.get_model_name(),
			get_viewport().get_visible_rect().size.x, get_viewport().get_visible_rect().size.y])


func _process(delta: float) -> void:
	_t += delta
	_since += delta
	_frames += 1
	var ms := delta * 1000.0
	_sum_ms += ms
	_max_ms = maxf(_max_ms, ms)
	if _since >= interval_s:
		write_row()


## One CSV row for the frames since the last row (public for tests).
func write_row() -> void:
	if _file == null or _frames == 0:
		return
	_file.store_line("%.2f,%d,%.2f,%.2f,%.1f,%d,%d,%.1f,%.1f,%d" % [_t, _frames, _sum_ms / _frames, _max_ms,
			Engine.get_frames_per_second(),
			int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
			int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
			Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
			Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
			int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))])
	_file.flush()
	_since = 0.0
	_frames = 0
	_sum_ms = 0.0
	_max_ms = 0.0


func _exit_tree() -> void:
	write_row()
	if _file != null:
		_file.close()
