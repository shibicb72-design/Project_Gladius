extends SceneTree
## Audio import: cuts, fades, levels and encodes chosen CC0 takes from a read-only staging folder to OGG Vorbis
## in the repo with ffmpeg, and records their provenance rows in the asset catalog. Raw sources never enter the repo.
##   godot --headless --path . --script res://tools/import_audio.gd -- --stage=<folder> --ffmpeg=<ffmpeg binary> [options]
## --stage and --ffmpeg are required in every mode (the ffmpeg path is used as given, never looked up).
## Modes:
##   (default) IMPORT  encode every recipe output (or those whose id or group contains --only=<text>) to
##                     <out_dir>/<pack>/<id>.ogg and upsert its catalog row. Prints
##                     "IMPORT <id> <bytes> <sha256 first 12> <seconds>s <channels>ch <peak dB>" per output (length
##                     from the last Ogg granule, peak = float peak of the decoded file) and
##                     "IMPORT files=<n> bytes=<total> failed=<n>". Exit 1 if anything failed.
##   --check           re-encode the selected outputs into res://build/import_audio_check/ and compare each sha256
##                     with the file at the output path and its catalog row: "CHECK <id> same|DIFFERENT|MISSING",
##                     "CHECK files=<n> different=<n> missing=<n>". Writes nothing under out_dir or the catalog.
##   --dry-run         print the ffmpeg argument lists (measure pass and encode pass) per output; runs nothing.
##   --probe=<path>    path relative to --stage, a file or a folder (recursive, sorted); no recipe needed. Per audio
##                     file (.wav .ogg .mp3 .flac): "PROBE\t<rel path>\t<duration_s>\t<channels>\t<rate>\t<peak_db>\t<mean_db>".
##     --segments      also "SEG\t<rel path>\t<index>\t<start_s>\t<end_s>\t<length_s>" for each non-silent part found by
##                     silencedetect (--noise-db=-35, --min-silence-s=0.15).
##     --envelope=<s>  (one file) "ENV\t<rel path>\t<t_start_s>\t<rms_db>\t<peak_db>" per window of <s> seconds.
##     --probe-out=<res:// path>  also write the PROBE rows without the prefix under a header row; SEG / ENV rows are
##                     written after them with their prefix kept, each block under its own header row.
## Other options: --recipe=<res:// path> (default res://tools/audio_import.json); --prune (IMPORT only) deletes the
## STALE files (and their .import) and catalog rows. STALE <path> is always reported for catalog rows under out_dir
## that the recipe no longer lists and for .ogg files under out_dir that no output produces.
##
## Recipe (JSON; keys starting with "_" are notes and ignored):
##   "version": 1, "out_dir": "res://assets/third_party/audio", "catalog": "res://data/asset_catalog.json",
##   "download_date": "YYYY-MM-DD",
##   "defaults": {"rate": 44100, "quality": 4, "one_shot_max_s": 1.5, "fade_in_s": 0.003, "fade_out_s": 0.06, "peak_db": -1.0}
##     (each key falls back to the value shown when missing),
##   "packs": {"<folder, [a-z0-9_-]>": {"source": <name as in LICENSES/THIRD_PARTY_ASSETS.md>, "source_url": <MANIFEST.csv
##     page>, "manifest_file": <MANIFEST.csv file value, or a list of them; each row's licence must start with "CC0">}},
##   "outputs": [{
##     "id": [a-z0-9_]+ (unique; the file is <out_dir>/<pack>/<id>.ogg, catalog id "audio_<id>"),
##     "pack": <packs key>, "group": <free text, used by --only>, "src": <path relative to --stage, not a .zip/.7z>,
##     "channels": "mono" | "stereo"   REQUIRED (mono for positional sounds, stereo for beds and UI),
##     "channel_pick": "mix" (default, ordinary downmix) | "left" | "right"   (mono from a stereo source),
##     "start_s": 0.0, "max_s": defaults.one_shot_max_s, "fade_in_s"/"fade_out_s": defaults (fade out ends at the
##       real end of the cut, also when the source is shorter than max_s),
##     "peak_db": defaults.peak_db (normalise the processed take to this peak, measured by a first pass over the
##       same filter chain, in float with astats since volumedetect clamps at 0 dBFS; if the encoded file then decodes more than 0.1 dB above peak_db + gain_db, as Vorbis
##       does on sharp transients, it is re-encoded with the excess taken off, up to 3 times; null = no normalising),
##     "gain_db": 0.0 (static gain after normalising),
##     "highpass_hz" / "lowpass_hz": optional filters, applied to the whole source before the cut,
##     "quality": defaults.quality (libvorbis -q:a), "rate": defaults.rate,
##     "loop": {"length_s": L, "crossfade_s": X}   present = a LOOP (no fades, no max_s): the piece
##       P = source[start_s, start_s + L + X] becomes acrossfade(P[X, X + L], P[0, X], qsin/qsin), length L, so its end
##       runs into its start; X = 0 is a plain cut of length L for sources that already loop.
##   }]
## Chain order: decode, reset timestamps to 0, resample to rate, channels, high/low pass, cut (sample exact), fades
## or loop seam, volume; encoded with libvorbis and bit-exact flags so reruns give identical bytes (see --check).

const DEFAULT_RECIPE := "res://tools/audio_import.json"
const CHECK_DIR := "res://build/import_audio_check"
const AUDIO_EXT := ["wav", "ogg", "mp3", "flac"]
const PEAK_SLACK_DB := 0.1
const PEAK_ATTEMPTS := 4  # encodes per output at most; one correction is not enough, each re-encode moves the overshoot
# Peaks for levelling are measured in float with astats: volumedetect works in s16 and clamps at 0 dBFS, which
# hides Vorbis overshoot and any chain that peaks above full scale.
const FLOAT_PEAK := "astats=measure_perchannel=none:measure_overall=Peak_level"
const FLOAT_PEAK_RE := "Peak level dB: (\\S+)"
const LICENCE_URL :="https://creativecommons.org/publicdomain/zero/1.0/"
const LAYOUTS := {"mono": 1, "stereo": 2, "2.1": 3, "3.0": 3, "quad": 4, "4.0": 4, "5.0": 5, "5.1": 6, "6.1": 7, "7.1": 8}

var opts := {}
var ffmpeg := ""
var stage := ""


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var pair := arg.trim_prefix("--").split("=", true, 1)
		opts[pair[0]] = pair[1] if pair.size() > 1 else "true"
	ffmpeg = String(opts.get("ffmpeg", ""))
	stage = String(opts.get("stage", "")).replace("\\", "/").trim_suffix("/")
	quit(_main())


func _main() -> int:
	if ffmpeg.is_empty() or stage.is_empty():
		return _fail(["--stage=<folder> and --ffmpeg=<ffmpeg binary> are required"])
	if not FileAccess.file_exists(ffmpeg):
		return _fail(["ffmpeg not found: " + ffmpeg])
	if not DirAccess.dir_exists_absolute(stage):
		return _fail(["stage folder not found: " + stage])
	if opts.has("probe"):
		return _probe_mode()
	var recipe_path := String(opts.get("recipe", DEFAULT_RECIPE))
	var recipe: Variant = JSON.parse_string(FileAccess.get_file_as_string(recipe_path)) if FileAccess.file_exists(recipe_path) else null
	if not recipe is Dictionary:
		return _fail(["recipe missing or not a JSON object: " + recipe_path])
	var problems := _validate(recipe)
	if not problems.is_empty():
		return _fail(problems)
	return _run(recipe)


func _fail(lines: Array) -> int:
	for line in lines:
		printerr("IMPORT_AUDIO_INVALID " + String(line))
	return 1


# ---------- recipe validation ----------

func _manifest() -> Dictionary:
	var rows := {}
	var file := FileAccess.open(stage.path_join("MANIFEST.csv"), FileAccess.READ)
	if file == null:
		return rows
	file.get_csv_line()  # header
	while not file.eof_reached():
		var row := file.get_csv_line()
		if row.size() >= 4:
			rows[row[0]] = row[3]
	return rows


func _validate(recipe: Dictionary) -> Array:
	var problems: Array = []
	var manifest := _manifest()
	if manifest.is_empty():
		problems.append("MANIFEST.csv missing or empty in " + stage)
	var name_ok := RegEx.create_from_string("^[a-z0-9_]+$")
	var pack_ok := RegEx.create_from_string("^[a-z0-9_-]+$")
	var banned := "ha" + "lo"
	for key in ["out_dir", "catalog", "download_date"]:
		if not recipe.get(key) is String or String(recipe.get(key)).is_empty():
			problems.append("recipe needs a String \"%s\"" % key)
	var packs: Dictionary = recipe.get("packs", {})
	for pack: String in packs:
		var info: Dictionary = packs[pack]
		if pack_ok.search(pack) == null or pack.contains(banned):
			problems.append("pack folder name not allowed: " + pack)
		for key in ["source", "source_url"]:
			if not info.get(key) is String or String(info.get(key)).is_empty():
				problems.append("pack %s needs a String \"%s\"" % [pack, key])
		var files: Variant = info.get("manifest_file", [])
		for entry in (files if files is Array else [files]):
			if not manifest.has(String(entry)):
				problems.append("pack %s: manifest_file not in MANIFEST.csv: %s" % [pack, entry])
			elif not String(manifest[entry]).begins_with("CC0"):
				problems.append("pack %s: licence is not CC0: %s" % [pack, manifest[entry]])
		if files is Array and files.is_empty():
			problems.append("pack %s needs a manifest_file" % pack)
	var seen := {}
	var outputs: Array = recipe.get("outputs", [])
	for out: Dictionary in outputs:
		var id := String(out.get("id", ""))
		if name_ok.search(id) == null or id.contains(banned):
			problems.append("output id not allowed (lowercase [a-z0-9_]): \"%s\"" % id)
		if seen.has(id):
			problems.append("duplicate output id: " + id)
		seen[id] = true
		if not packs.has(out.get("pack", "")):
			problems.append("%s: unknown pack \"%s\"" % [id, out.get("pack", "")])
		var src := String(out.get("src", ""))
		var ext := src.get_extension().to_lower()
		if ext in ["zip", "7z"]:
			problems.append("%s: src points at an archive, use the extracted folder: %s" % [id, src])
		elif src.is_empty() or src.contains("..") or not FileAccess.file_exists(stage.path_join(src)):
			problems.append("%s: src file missing: %s" % [id, src])
		if not out.get("channels") in ["mono", "stereo"]:
			problems.append("%s: \"channels\" must be \"mono\" or \"stereo\" (required)" % id)
		if not out.get("channel_pick", "mix") in ["mix", "left", "right"]:
			problems.append("%s: channel_pick must be mix, left or right" % id)
		if out.has("loop"):
			var loop: Dictionary = out["loop"]
			var length := float(loop.get("length_s", 0.0))
			var cross := float(loop.get("crossfade_s", 0.0))
			if length <= 0.0 or cross < 0.0 or cross > length:
				problems.append("%s: loop needs length_s > 0 and 0 <= crossfade_s <= length_s" % id)
	if outputs.is_empty():
		problems.append("recipe has no outputs")
	return problems


# ---------- ffmpeg helpers ----------

func _num(value: float) -> String:
	return "%.6f" % value


func _ffmpeg(args: PackedStringArray) -> Dictionary:
	var output: Array = []
	var code := OS.execute(ffmpeg, args, output, true)
	return {"code": code, "text": "\n".join(PackedStringArray(output))}


func _last(text: String, pattern: String) -> String:
	var found := RegEx.create_from_string(pattern).search_all(text)
	return found[-1].get_string(1) if not found.is_empty() else ""


func _setting(out: Dictionary, defaults: Dictionary, key: String, fallback: Variant, default_key := "") -> Variant:
	if out.has(key):
		return out[key]
	return defaults.get(default_key if not default_key.is_empty() else key, fallback)


## The filter graph for one output; tail is "volumedetect" for the measure pass or "volume=..dB" for the encode.
func _graph(out: Dictionary, defaults: Dictionary, tail: String) -> String:
	var rate := int(_setting(out, defaults, "rate", 44100))
	var chain: Array[String] = ["asetpts=PTS-STARTPTS", "aresample=%d" % rate]
	var pick := String(out.get("channel_pick", "mix"))
	if out["channels"] == "stereo":
		chain.append("aformat=channel_layouts=stereo")
	elif pick == "mix":
		chain.append("aformat=channel_layouts=mono")
	else:
		chain.append("pan=mono|c0=" + ("FL" if pick == "left" else "FR"))
	if out.has("highpass_hz"):
		chain.append("highpass=f=" + _num(float(out["highpass_hz"])))
	if out.has("lowpass_hz"):
		chain.append("lowpass=f=" + _num(float(out["lowpass_hz"])))
	var start := roundi(float(out.get("start_s", 0.0)) * rate)
	if not out.has("loop"):
		var length := roundi(float(_setting(out, defaults, "max_s", 1.5, "one_shot_max_s")) * rate)
		chain.append("atrim=start_sample=%d:end_sample=%d" % [start, start + length])
		chain.append("asetpts=PTS-STARTPTS")
		chain.append("afade=t=in:st=0:d=" + _num(float(_setting(out, defaults, "fade_in_s", 0.003))))
		chain.append("areverse,afade=t=in:st=0:d=%s,areverse" % _num(float(_setting(out, defaults, "fade_out_s", 0.06))))
		return "[0:a:0]" + ",".join(chain) + "," + tail + "[out]"
	var loop_len := roundi(float(out["loop"].get("length_s", 0.0)) * rate)
	var cross := roundi(float(out["loop"].get("crossfade_s", 0.0)) * rate)
	chain.append("atrim=start_sample=%d:end_sample=%d" % [start, start + loop_len + cross])
	chain.append("asetpts=PTS-STARTPTS")
	if cross == 0:
		return "[0:a:0]" + ",".join(chain) + "," + tail + "[out]"
	return ("[0:a:0]%s,asplit=2[piece_main][piece_head];" % ",".join(chain)
		+ "[piece_main]atrim=start_sample=%d,asetpts=PTS-STARTPTS[main];" % cross
		+ "[piece_head]atrim=end_sample=%d[head];" % cross
		+ "[main][head]acrossfade=ns=%d:c1=qsin:c2=qsin,%s[out]" % [cross, tail])


func _measure_args(src: String, graph: String) -> PackedStringArray:
	return PackedStringArray(["-hide_banner", "-nostdin", "-nostats", "-i", src, "-filter_complex", graph, "-map", "[out]", "-f", "null", "-"])


func _encode_args(src: String, graph: String, out: Dictionary, defaults: Dictionary, target: String) -> PackedStringArray:
	var quality := float(_setting(out, defaults, "quality", 4))
	return PackedStringArray(["-y", "-hide_banner", "-nostdin", "-nostats", "-i", src, "-filter_complex", graph,
		"-map", "[out]", "-vn", "-map_metadata", "-1", "-map_chapters", "-1",
		"-c:a", "libvorbis", "-q:a", str(int(quality)) if quality == floorf(quality) else str(quality),
		"-ar", str(int(_setting(out, defaults, "rate", 44100))), "-ac", "2" if out["channels"] == "stereo" else "1",
		"-fflags", "+bitexact", "-flags:a", "+bitexact", target])


func _show(args: PackedStringArray) -> String:
	var parts: Array[String] = [ffmpeg]
	for arg in args:
		parts.append("\"%s\"" % arg if arg.contains(" ") or arg.contains("|") or arg.contains(";") else arg)
	return " ".join(parts)


## Duration / channels / rate / peak / mean of one file; extra_filters run before volumedetect.
func _probe(path: String, extra_filters := "") -> Dictionary:
	var result := _ffmpeg(PackedStringArray(["-hide_banner", "-nostdin", "-nostats", "-i", path, "-af",
		extra_filters + "aformat=sample_fmts=flt|fltp|dbl|dblp," + FLOAT_PEAK + ",volumedetect", "-f", "null", "-"]))
	var text: String = result["text"]
	var banner := text.get_slice("Stream mapping:", 0)
	var info := {"ok": result["code"] == 0, "text": text, "duration": 0.0, "channels": 0, "rate": 0}
	var stream := RegEx.create_from_string("Audio: .*?, (\\d+) Hz, ([^,\\n]+)").search(banner)
	if stream != null:
		info["rate"] = int(stream.get_string(1))
		var layout := stream.get_string(2).strip_edges().get_slice("(", 0)
		info["channels"] = int(LAYOUTS.get(layout, int(layout.get_slice(" ", 0)) if layout.ends_with("channels") else 0))
	var samples := int(_last(text, "n_samples: (\\d+)"))
	if samples > 0 and info["channels"] > 0 and info["rate"] > 0:
		info["duration"] = float(samples) / (info["channels"] * info["rate"])
	info["peak"] = _last(text, "max_volume: (\\S+) dB")
	info["mean"] = _last(text, "mean_volume: (\\S+) dB")
	info["float_peak"] = _last(text, FLOAT_PEAK_RE)
	if info["peak"].is_empty() or not String(info["float_peak"]).is_valid_float():
		info["ok"] = false
	return info


# ---------- import / check ----------

func _run(recipe: Dictionary) -> int:
	var check := opts.has("check")
	var dry := opts.has("dry-run")
	var only := String(opts.get("only", ""))
	var defaults: Dictionary = recipe.get("defaults", {})
	var out_dir := String(recipe["out_dir"]).trim_suffix("/")
	var catalog_path := String(recipe["catalog"])
	var catalog := _load_catalog(catalog_path)
	var rows := {}
	for row: Dictionary in catalog["assets"]:
		rows[String(row.get("path", ""))] = row
	var expected := {}
	var failed := 0
	var total := 0
	var count := 0
	var different := 0
	var missing := 0
	if check:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CHECK_DIR))
		FileAccess.open(CHECK_DIR.path_join(".gdignore"), FileAccess.WRITE).close()
	for out: Dictionary in recipe["outputs"]:
		var id := String(out["id"])
		var pack := String(out["pack"])
		var path := out_dir.path_join(pack).path_join(id + ".ogg")
		expected[path] = true
		if not only.is_empty() and not id.contains(only) and not String(out.get("group", "")).contains(only):
			continue
		count += 1
		var target := (CHECK_DIR if check else out_dir).path_join(pack).path_join(id + ".ogg")
		var src := stage.path_join(String(out["src"]))
		var peak: Variant = _setting(out, defaults, "peak_db", -1.0)
		var gain := float(out.get("gain_db", 0.0))
		if dry:
			if peak != null:
				print("DRYRUN %s measure: %s" % [id, _show(_measure_args(src, _graph(out, defaults, FLOAT_PEAK)))])
			var shown := "volume=<%s - measured peak + %s>dB" % [peak, gain] if peak != null else "volume=%sdB" % _num(gain)
			print("DRYRUN %s encode: %s" % [id, _show(_encode_args(src, _graph(out, defaults, shown), out, defaults, ProjectSettings.globalize_path(target)))])
			continue
		if peak != null:
			var measured := _ffmpeg(_measure_args(src, _graph(out, defaults, FLOAT_PEAK)))
			var max_volume := _last(measured["text"], FLOAT_PEAK_RE)
			if measured["code"] != 0 or not max_volume.is_valid_float():
				failed += 1
				printerr("IMPORT_FAIL %s measure pass failed:\n%s" % [id, measured["text"]])
				continue
			gain += float(peak) - float(max_volume)
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(target.get_base_dir()))
		var facts := {}
		var ok := true
		# Vorbis overshoots sharp transients by up to a few dB; when the decoded peak lands more than PEAK_SLACK_DB
		# above the target, re-encode with the excess taken off, up to PEAK_ATTEMPTS encodes (still deterministic).
		for _attempt in PEAK_ATTEMPTS:
			var encoded := _ffmpeg(_encode_args(src, _graph(out, defaults, "volume=%sdB" % _num(gain)), out, defaults, ProjectSettings.globalize_path(target)))
			facts = _probe(ProjectSettings.globalize_path(target))
			if encoded["code"] != 0 or not FileAccess.file_exists(target) or not facts["ok"]:
				ok = false
				printerr("IMPORT_FAIL %s encode failed:\n%s" % [id, encoded["text"]])
				break
			var excess := float(facts["float_peak"]) -(float(peak) + float(out.get("gain_db", 0.0))) if peak != null else 0.0
			if excess <= PEAK_SLACK_DB:
				break
			gain -= excess
		if not ok:
			failed += 1
			continue
		var sha := FileAccess.get_sha256(target)
		if check:
			var row: Dictionary = rows.get(path, {})
			if not FileAccess.file_exists(path) or row.is_empty():
				missing += 1
				print("CHECK %s MISSING" % id)
			elif FileAccess.get_sha256(path) != sha or String(row.get("sha256", "")) != sha:
				different += 1
				print("CHECK %s DIFFERENT" % id)
			else:
				print("CHECK %s same" % id)
			continue
		var bytes := FileAccess.get_file_as_bytes(target).size()
		total += bytes
		var seconds := float(_ogg_granule(target)) / maxi(1, int(facts["rate"]))
		print("IMPORT %s %d %s %.3fs %dch %.2f" % [id, bytes, sha.left(12), seconds, facts["channels"], float(facts["float_peak"])])
		var info: Dictionary = recipe["packs"][pack]
		rows[path] = {"id": "audio_" + id, "path": path, "source": String(info["source"]),
			"source_url": String(info["source_url"]), "licence": "CC0-1.0", "licence_url": LICENCE_URL,
			"redistribution_quote": "", "download_date": String(recipe["download_date"]), "sha256": sha}
	if dry:
		return 0
	var stale := _stale(out_dir, rows, expected)
	if opts.has("prune") and not check:
		for path: String in stale:
			for file in [path, path + ".import"]:
				if FileAccess.file_exists(file):
					DirAccess.remove_absolute(ProjectSettings.globalize_path(file))
			rows.erase(path)
			print("PRUNED " + path)
	if check:
		print("CHECK files=%d different=%d missing=%d" % [count, different, missing])
		return 1 if different + missing + failed > 0 else 0
	_save_catalog(catalog_path, catalog, rows, out_dir)
	print("IMPORT files=%d bytes=%d failed=%d" % [count, total, failed])
	return 1 if failed > 0 else 0


## Granule position of the last Ogg page = the stream length in samples. (ffmpeg's own Vorbis decoder returns ~128
## samples fewer on some files ending in a short block, so the decoded count is not used for the length.)
func _ogg_granule(path: String) -> int:
	var bytes := FileAccess.get_file_as_bytes(path)
	for pos in range(bytes.size() - 27, -1, -1):
		if bytes[pos] == 0x4F and bytes[pos + 1] == 0x67 and bytes[pos + 2] == 0x67 and bytes[pos + 3] == 0x53 and bytes[pos + 4] == 0 and bytes[pos + 5] & 4:
			return bytes.decode_s64(pos + 6)
	return 0


func _ogg_files(path: String) -> Array[String]:
	var found: Array[String] = []
	var dir := DirAccess.open(path)
	if dir == null:
		return found
	for name in dir.get_files():
		if name.get_extension().to_lower() == "ogg":
			found.append(path.path_join(name))
	for name in dir.get_directories():
		found.append_array(_ogg_files(path.path_join(name)))
	return found


func _stale(out_dir: String, rows: Dictionary, expected: Dictionary) -> Array[String]:
	var stale: Array[String] = []
	for path: String in rows:
		if path.begins_with(out_dir + "/") and not expected.has(path):
			stale.append(path)
	for path in _ogg_files(out_dir):
		if not expected.has(path) and not stale.has(path):
			stale.append(path)
	stale.sort()
	for path in stale:
		print("STALE " + path)
	return stale


func _load_catalog(path: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null
	var catalog: Dictionary = parsed if parsed is Dictionary else {"version": 1, "assets": []}
	if not catalog.get("assets") is Array:
		catalog["assets"] = []
	return catalog


## JSON numbers parse as floats; write whole numbers back as integers the way tools/asset_hashes.gd does.
func _ints(value: Variant) -> Variant:
	if value is float and value == floorf(value) and absf(value) < 1e15:
		return int(value)
	if value is Dictionary:
		for key in value:
			value[key] = _ints(value[key])
	elif value is Array:
		for i in value.size():
			value[i] = _ints(value[i])
	return value


func _save_catalog(path: String, catalog: Dictionary, rows: Dictionary, out_dir: String) -> void:
	var kept: Array = []
	for row: Dictionary in catalog["assets"]:
		if not String(row.get("path", "")).begins_with(out_dir + "/"):
			kept.append(row)
	var audio: Array = []
	for row_path: String in rows:
		if row_path.begins_with(out_dir + "/"):
			audio.append(rows[row_path])
	audio.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["path"]) < String(b["path"]))
	catalog["assets"] = kept + audio
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(_ints(catalog), "\t", false) + "\n")
	file.close()


# ---------- probe ----------

func _audio_files(rel: String) -> Array[String]:
	var found: Array[String] = []
	var absolute := stage.path_join(rel) if not rel.is_empty() else stage
	if FileAccess.file_exists(absolute):
		return [rel] as Array[String]
	var dir := DirAccess.open(absolute)
	if dir == null:
		return found
	for name in dir.get_files():
		if name.get_extension().to_lower() in AUDIO_EXT:
			found.append(rel.path_join(name) if not rel.is_empty() else name)
	for name in dir.get_directories():
		found.append_array(_audio_files(rel.path_join(name) if not rel.is_empty() else name))
	found.sort()
	return found


func _probe_mode() -> int:
	var rel := String(opts["probe"]).replace("\\", "/").trim_prefix("/").trim_suffix("/")
	var files := _audio_files(rel)
	if files.is_empty():
		printerr("IMPORT_AUDIO_INVALID no audio files at " + stage.path_join(rel))
		return 1
	var window := float(opts.get("envelope", "0"))
	if opts.has("envelope") and (files.size() != 1 or window <= 0.0):
		printerr("IMPORT_AUDIO_INVALID --envelope=<seconds> needs a positive window and --probe on ONE file")
		return 1
	var noise := float(opts.get("noise-db", "-35"))
	var min_silence := float(opts.get("min-silence-s", "0.15"))
	var lines: Array[String] = ["path\tduration_s\tchannels\tsample_rate\tpeak_db\tmean_db"]
	var extra: Array[String] = []
	var failed := 0
	for file in files:
		var segments := opts.has("segments")
		var pre := "asetpts=PTS-STARTPTS,silencedetect=n=%sdB:d=%s," % [noise, min_silence] if segments else ""
		var info := _probe(stage.path_join(file), pre)
		if not info["ok"]:
			failed += 1
			printerr("PROBE_FAIL %s\n%s" % [file, info["text"]])
			continue
		var row := "%s\t%.3f\t%d\t%d\t%s\t%s" % [file, info["duration"], info["channels"], info["rate"], info["peak"], info["mean"]]
		print("PROBE\t" + row)
		lines.append(row)
		if segments:
			for seg in _segments(info["text"], info["duration"], file):
				print(seg)
				extra.append(seg)
		if opts.has("envelope"):
			for env in _envelope(file, window, int(info["rate"])):
				print(env)
				extra.append(env)
	if opts.has("probe-out"):
		if opts.has("segments"):
			lines.append("SEG\tpath\tindex\tstart_s\tend_s\tlength_s")
		if opts.has("envelope"):
			lines.append("ENV\tpath\tt_start_s\trms_db\tpeak_db")
		lines.append_array(extra)
		var out_path := String(opts["probe-out"])
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_path.get_base_dir()))
		var handle := FileAccess.open(out_path, FileAccess.WRITE)
		handle.store_string("\n".join(lines) + "\n")
		handle.close()
	return 1 if failed > 0 else 0


func _segments(text: String, duration: float, file: String) -> Array[String]:
	var found: Array[String] = []
	var cursor := 0.0
	var events := RegEx.create_from_string("silence_(start|end): (-?[0-9.]+)").search_all(text)
	var bounds: Array = []  # [start, end] of each non-silent part
	for event in events:
		var t := maxf(0.0, float(event.get_string(2)))
		if event.get_string(1) == "start":
			if t > cursor:
				bounds.append([cursor, t])
			cursor = duration
		else:
			cursor = t
	if cursor < duration:
		bounds.append([cursor, duration])
	for i in bounds.size():
		var part: Array = bounds[i]
		found.append("SEG\t%s\t%d\t%.3f\t%.3f\t%.3f" % [file, i, part[0], part[1], part[1] - part[0]])
	return found


func _envelope(file: String, seconds: float, rate: int) -> Array[String]:
	var window := maxi(1, roundi(seconds * rate))
	var result := _ffmpeg(PackedStringArray(["-hide_banner", "-nostdin", "-nostats", "-i", stage.path_join(file), "-af",
		"asetpts=PTS-STARTPTS,asetnsamples=n=%d:p=0,astats=metadata=1:reset=1:measure_perchannel=none:measure_overall=Peak_level+RMS_level,ametadata=mode=print" % window,
		"-f", "null", "-"]))
	var found: Array[String] = []
	if result["code"] != 0:
		printerr("ENV_FAIL %s\n%s" % [file, result["text"]])
		return found
	# Every frame holds exactly `window` samples (only the last may be shorter), so the start time is index * window
	# / rate; the pts_time ametadata prints follows the source timestamps and can drift by a few ms.
	var frame := -1
	var rms := ""
	var peak := ""
	for line in String(result["text"]).split("\n"):
		if line.contains("pts_time:"):
			if frame >= 0:
				found.append("ENV\t%s\t%.3f\t%s\t%s" % [file, float(frame * window) / rate, rms, peak])
			frame += 1
		elif line.contains("Overall.RMS_level="):
			rms = _db(line.get_slice("=", 1))
		elif line.contains("Overall.Peak_level="):
			peak = _db(line.get_slice("=", 1))
	if frame >= 0:
		found.append("ENV\t%s\t%.3f\t%s\t%s" % [file, float(frame * window) / rate, rms, peak])
	return found


func _db(text: String) -> String:
	text = text.strip_edges()
	return "%.2f" % float(text) if text.is_valid_float() else text
