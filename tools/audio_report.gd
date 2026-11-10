extends SceneTree
## Reviewer's view of the generated sounds (nobody can listen in a headless run):
##   godot --headless --path . --script res://tools/audio_report.gd [-- --out=build/s/audio.png --only=shot_]
## Prints one line per WAV in res://assets/generated/audio (seconds, peak, RMS, spectral centre) and saves a
## sheet of spectrograms (time left to right, 0 to 16 kHz bottom to top, brighter = louder; log scale).

const DIR := "res://assets/generated/audio"
const FFT := 512
const CELL_W := 300
const CELL_H := 96
const COLUMNS := 4


func _initialize() -> void:
	var out := "build/s/audio.png"
	var only := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out = arg.substr(6)
		elif arg.begins_with("--only="):
			only = arg.substr(7)
	var names: Array[String] = []
	for file in DirAccess.get_files_at(DIR):
		if file.ends_with(".wav") and (only == "" or file.contains(only)):
			names.append(file)
	names.sort()
	var rows := int(ceil(float(names.size()) / COLUMNS))
	var sheet := Image.create(COLUMNS * CELL_W, maxi(rows, 1) * CELL_H, false, Image.FORMAT_RGB8)
	for index in names.size():
		var samples := _read(DIR + "/" + names[index])
		var rate := 32000.0
		var peak := 0.0
		var sum := 0.0
		for v in samples:
			peak = maxf(peak, absf(v))
			sum += v * v
		var rms := sqrt(sum / maxf(samples.size(), 1.0))
		var centre := _draw(sheet, samples, Vector2i((index % COLUMNS) * CELL_W, (index / COLUMNS) * CELL_H))
		print("AUDIO %s seconds=%.2f peak=%.2f rms=%.3f centre_hz=%.0f" % [names[index].trim_suffix(".wav"), samples.size() / rate, peak, rms, centre * rate / FFT])
	var path := ProjectSettings.globalize_path("res://").path_join(out)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	print("AUDIO sheet %s err=%d (%d sounds, %d per row, each cell %dx%d)" % [path, sheet.save_png(path), names.size(), COLUMNS, CELL_W, CELL_H])
	quit()


## 16-bit mono PCM samples of a WAV file written by tools/gen_audio.gd, as floats.
func _read(path: String) -> PackedFloat32Array:
	var bytes := FileAccess.get_file_as_bytes(path)
	var out := PackedFloat32Array()
	var at := 12  # after "RIFF", size, "WAVE": chunks of id (4), size (4), body
	while at + 8 <= bytes.size() and bytes.slice(at, at + 4).get_string_from_ascii() != "data":
		at += 8 + bytes.decode_u32(at + 4)
	if at + 8 > bytes.size():
		return out
	var count := bytes.decode_u32(at + 4) / 2
	out.resize(count)
	for i in count:
		out[i] = bytes.decode_s16(at + 8 + i * 2) / 32768.0
	return out


## Draws one spectrogram cell; returns the energy-weighted mean bin.
func _draw(sheet: Image, samples: PackedFloat32Array, at: Vector2i) -> float:
	var frames := maxi((samples.size() - FFT) / (FFT / 2), 1)
	var weighted := 0.0
	var total := 0.0
	var columns: Array = []
	for f in frames:
		var re := PackedFloat32Array()
		var im := PackedFloat32Array()
		re.resize(FFT)
		im.resize(FFT)
		for i in FFT:
			var k := f * (FFT / 2) + i
			re[i] = (samples[k] if k < samples.size() else 0.0) * (0.5 - 0.5 * cos(TAU * i / FFT))
		_fft(re, im)
		var mags := PackedFloat32Array()
		mags.resize(FFT / 2)
		for b in FFT / 2:
			mags[b] = sqrt(re[b] * re[b] + im[b] * im[b])
			weighted += mags[b] * b
			total += mags[b]
		columns.append(mags)
	var top := 0.0001
	for mags: PackedFloat32Array in columns:
		for m in mags:
			top = maxf(top, m)
	# 48 dB below the loudest bin is black; the frequency axis is logarithmic from 60 Hz to 16 kHz.
	for x in CELL_W - 4:
		var mags: PackedFloat32Array = columns[mini(int(float(x) / (CELL_W - 4) * frames), frames - 1)]
		for y in CELL_H - 4:
			var hz := 60.0 * pow(16000.0 / 60.0, float(CELL_H - 5 - y) / (CELL_H - 5))
			var b := clampi(int(hz / 32000.0 * FFT), 0, FFT / 2 - 1)
			var v := clampf(1.0 + 20.0 * log(mags[b] / top + 0.000001) / log(10.0) / 48.0, 0.0, 1.0)
			sheet.set_pixel(at.x + x, at.y + y, Color(v * v, v, sqrt(v) * 0.6))
	return weighted / maxf(total, 0.0001)


func _fft(re: PackedFloat32Array, im: PackedFloat32Array) -> void:
	var n := re.size()
	var j := 0
	for i in range(1, n):
		var bit := n >> 1
		while j & bit:
			j ^= bit
			bit >>= 1
		j |= bit
		if i < j:
			var t := re[i]
			re[i] = re[j]
			re[j] = t
	var length := 2
	while length <= n:
		var angle := -TAU / length
		for start in range(0, n, length):
			for k in length / 2:
				var wr := cos(angle * k)
				var wi := sin(angle * k)
				var a := start + k
				var b := a + length / 2
				var xr := re[b] * wr - im[b] * wi
				var xi := re[b] * wi + im[b] * wr
				re[b] = re[a] - xr
				im[b] = im[a] - xi
				re[a] += xr
				im[a] += xi
		length <<= 1
