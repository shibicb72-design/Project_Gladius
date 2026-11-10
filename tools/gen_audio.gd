extends SceneTree
## Seeded sound generator (run by hand, never at load):
##   godot --headless --path . --script res://tools/gen_audio.gd [-- --only=shot_]
## Writes 16-bit mono WAV files to res://assets/generated/audio/. Every sound is synthesised here from noise,
## sine / saw / square sweeps, simple filters and echoes: there are no recordings and no samples from any game.
## The ids match data/audio.json "sounds". After a run, tools/asset_hashes.gd --write records the sha256 values.

const OUT := "res://assets/generated/audio"
const RATE := 32000
const SEED := 20261109

var _rng := RandomNumberGenerator.new()
var _only := ""
var _written := 0


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--only="):
			_only = arg.substr(7)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	_weapons()
	_hits()
	_movement()
	_drop_and_zone()
	_match_events()
	_pickups_and_ui()
	_ambience()
	print("GEN_AUDIO wrote %d files to %s" % [_written, OUT])
	quit()


# ---------- toolkit ----------

func _n(seconds: float) -> int:
	return int(seconds * RATE)


func _buf(seconds: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(_n(seconds))
	return out


func _noise(seconds: float, salt: int) -> PackedFloat32Array:
	_rng.seed = SEED + salt
	var out := _buf(seconds)
	for i in out.size():
		out[i] = _rng.randf_range(-1.0, 1.0)
	return out


## One-pole low-pass in place.
func _lp(buf: PackedFloat32Array, hz: float) -> PackedFloat32Array:
	var k := 1.0 - exp(-TAU * hz / RATE)
	var y := 0.0
	for i in buf.size():
		y += (buf[i] - y) * k
		buf[i] = y
	return buf


func _hp(buf: PackedFloat32Array, hz: float) -> PackedFloat32Array:
	var k := 1.0 - exp(-TAU * hz / RATE)
	var y := 0.0
	for i in buf.size():
		y += (buf[i] - y) * k
		buf[i] -= y
	return buf


## State-variable band-pass in place; `hz_end` > 0 sweeps the centre.
func _bp(buf: PackedFloat32Array, hz: float, q: float, hz_end: float = 0.0) -> PackedFloat32Array:
	var low := 0.0
	var band := 0.0
	var n := buf.size()
	for i in n:
		var f := hz if hz_end <= 0.0 else hz * pow(hz_end / hz, float(i) / n)
		var k := 2.0 * sin(PI * minf(f, RATE * 0.24) / RATE)
		low += k * band
		var high := buf[i] - low - band / q
		band += k * high
		buf[i] = band
	return buf


## Multiplies by attack (linear, seconds) then exponential decay (time constant, seconds).
func _env(buf: PackedFloat32Array, attack: float, decay: float) -> PackedFloat32Array:
	var a := maxi(_n(attack), 1)
	for i in buf.size():
		var g := float(i) / a if i < a else exp(-float(i - a) / (decay * RATE))
		buf[i] *= g
	return buf


func _fade(buf: PackedFloat32Array, fade_in: float, fade_out: float) -> PackedFloat32Array:
	var a := _n(fade_in)
	var b := _n(fade_out)
	var n := buf.size()
	for i in mini(a, n):
		buf[i] *= float(i) / a
	for i in mini(b, n):
		buf[n - 1 - i] *= float(i) / b
	return buf


## A tone whose pitch glides from f0 to f1 (exponential). wave: 0 sine, 1 saw, 2 square, 3 triangle.
func _tone(seconds: float, f0: float, f1: float, wave: int = 0, vibrato_hz: float = 0.0, vibrato: float = 0.0) -> PackedFloat32Array:
	var out := _buf(seconds)
	var n := out.size()
	var phase := 0.0
	for i in n:
		var t := float(i) / n
		var f := f0 * pow(f1 / f0, t)
		if vibrato_hz > 0.0:
			f *= 1.0 + vibrato * sin(TAU * vibrato_hz * i / RATE)
		phase = fposmod(phase + f / RATE, 1.0)
		match wave:
			1: out[i] = phase * 2.0 - 1.0
			2: out[i] = 1.0 if phase < 0.5 else -1.0
			3: out[i] = 4.0 * absf(phase - 0.5) - 1.0
			_: out[i] = sin(TAU * phase)
	return out


func _mix(into: PackedFloat32Array, from: PackedFloat32Array, gain: float = 1.0, at: float = 0.0) -> PackedFloat32Array:
	var start := _n(at)
	if into.size() < start + from.size():
		into.resize(start + from.size())
	for i in from.size():
		into[start + i] += from[i] * gain
	return into


func _gain(buf: PackedFloat32Array, gain: float) -> PackedFloat32Array:
	for i in buf.size():
		buf[i] *= gain
	return buf


## Feedback echo in place (buffer grows by `tail` seconds); damp is a low-pass on the feedback path.
func _echo(buf: PackedFloat32Array, delay: float, feedback: float, damp_hz: float, tail: float) -> PackedFloat32Array:
	var d := maxi(_n(delay), 1)
	buf.resize(buf.size() + _n(tail))
	var k := 1.0 - exp(-TAU * damp_hz / RATE)
	var y := 0.0
	for i in range(d, buf.size()):
		y += (buf[i - d] - y) * k
		buf[i] += y * feedback
	return buf


## A small room: three echoes of unrelated lengths.
func _space(buf: PackedFloat32Array, amount: float, tail: float) -> PackedFloat32Array:
	var dry := buf.duplicate()
	var wet := buf.duplicate()
	_echo(wet, 0.031, 0.55, 2600.0, tail)
	var wet2 := dry.duplicate()
	_echo(wet2, 0.047, 0.5, 1900.0, tail)
	var wet3 := dry.duplicate()
	_echo(wet3, 0.071, 0.45, 1400.0, tail)
	var out := _buf(0.0)
	_mix(out, dry, 1.0)
	_mix(out, wet, amount * 0.4)
	_mix(out, wet2, amount * 0.35)
	_mix(out, wet3, amount * 0.3)
	return out


func _drive(buf: PackedFloat32Array, amount: float) -> PackedFloat32Array:
	for i in buf.size():
		buf[i] = tanh(buf[i] * amount)
	return buf


func _peak(buf: PackedFloat32Array, peak: float = 0.9) -> PackedFloat32Array:
	var top := 0.0001
	for v in buf:
		top = maxf(top, absf(v))
	return _gain(buf, peak / top)


## Makes a seamless loop: the last `cross` seconds are blended into the first and cut off.
func _loop(buf: PackedFloat32Array, cross: float) -> PackedFloat32Array:
	var c := _n(cross)
	var n := buf.size() - c
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		out[i] = buf[i]
	for i in c:
		var t := float(i) / c
		out[i] = buf[i] * sqrt(t) + buf[n + i] * sqrt(1.0 - t)
	return out


func _save(id: String, buf: PackedFloat32Array, peak: float = 0.9) -> void:
	if _only != "" and not id.contains(_only):
		return
	_peak(buf, peak)
	var bytes := PackedByteArray()
	bytes.resize(buf.size() * 2)
	for i in buf.size():
		bytes.encode_s16(i * 2, int(clampf(buf[i], -1.0, 1.0) * 32767.0))
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = RATE
	stream.stereo = false
	stream.data = bytes
	var err := stream.save_to_wav(ProjectSettings.globalize_path(OUT + "/" + id + ".wav"))
	_written += 1
	print("GEN_AUDIO %s %.2f s err=%d" % [id, float(buf.size()) / RATE, err])


# ---------- sounds ----------

## A gun shot from four layers: crack (bright click), body (mid band), thump (falling sine), zing (the
## accelerator coil: a falling saw). The tail is the body echoing off stone.
func _shot(salt: int, crack: float, body_hz: float, body_decay: float, thump_from: float, thump_to: float, thump_decay: float,
		zing_from: float, zing_to: float, zing_gain: float, tail: float, room: float) -> PackedFloat32Array:
	var out := _buf(0.02)
	# The loudest part of a shot is a broadband burst (300 Hz to 7 kHz) that dies in tens of milliseconds;
	# the thump only gives it weight.
	_mix(out, _env(_hp(_noise(0.03, salt), 2500.0), 0.0003, 0.005), crack * 1.3)
	_mix(out, _env(_hp(_lp(_noise(0.4, salt + 3), 7000.0), 300.0), 0.0005, body_decay * 0.7), 1.2)
	_mix(out, _env(_bp(_noise(0.4, salt + 1), body_hz, 0.9, body_hz * 0.5), 0.001, body_decay), 1.0)
	_mix(out, _env(_tone(0.35, thump_from, thump_to), 0.002, thump_decay), 0.4)
	_mix(out, _env(_lp(_tone(0.25, zing_from, zing_to, 1), 4000.0), 0.001, 0.05), zing_gain)
	_mix(out, _env(_hp(_lp(_noise(tail, salt + 2), 2400.0), 250.0), 0.01, tail * 0.3), 0.3, 0.01)
	_drive(out, 1.6)
	return _fade(_space(out, room, tail * 0.6), 0.0, 0.08)


func _weapons() -> void:
	_save("shot_pilum_br", _shot(100, 0.9, 1100.0, 0.05, 190.0, 55.0, 0.06, 2600.0, 500.0, 0.25, 0.35, 0.5))
	_save("shot_sagittarii_rifle", _shot(110, 1.0, 700.0, 0.09, 140.0, 36.0, 0.12, 3400.0, 300.0, 0.3, 0.8, 0.9))
	_save("shot_default", _shot(120, 0.8, 1500.0, 0.04, 220.0, 70.0, 0.05, 2000.0, 700.0, 0.18, 0.3, 0.4))
	# A far shot heard across the map: only the low body and the echo survive.
	var far := _lp(_shot(130, 0.3, 500.0, 0.1, 120.0, 40.0, 0.12, 900.0, 300.0, 0.05, 0.9, 1.2), 900.0)
	_save("shot_far", far, 0.7)
	_save("dry_fire", _mix(_env(_bp(_noise(0.05, 140), 3200.0, 3.0), 0.0005, 0.006), _env(_bp(_noise(0.05, 141), 1200.0, 4.0), 0.0005, 0.012), 0.8, 0.03), 0.6)
	# Reload: magazine out, magazine in, charging handle.
	var reload := _buf(1.25)
	_mix(reload, _env(_bp(_noise(0.08, 150), 1800.0, 2.5), 0.001, 0.015), 0.8, 0.05)
	_mix(reload, _env(_tone(0.1, 420.0, 180.0, 3), 0.001, 0.03), 0.4, 0.06)
	_mix(reload, _env(_bp(_noise(0.3, 151), 600.0, 0.8), 0.05, 0.08), 0.15, 0.2)
	_mix(reload, _env(_bp(_noise(0.1, 152), 1300.0, 3.0), 0.001, 0.02), 1.0, 0.62)
	_mix(reload, _env(_tone(0.12, 300.0, 140.0, 3), 0.001, 0.04), 0.6, 0.63)
	_mix(reload, _env(_bp(_noise(0.06, 153), 2600.0, 3.5), 0.001, 0.01), 0.9, 0.98)
	_mix(reload, _env(_bp(_noise(0.08, 154), 2000.0, 3.0), 0.001, 0.014), 1.0, 1.08)
	_mix(reload, _env(_tone(0.2, 900.0, 1500.0), 0.02, 0.06), 0.12, 1.08)
	_save("reload", reload, 0.7)
	var swap := _buf(0.3)
	_mix(swap, _env(_bp(_noise(0.2, 160), 900.0, 0.7, 2400.0), 0.03, 0.05), 0.5)
	_mix(swap, _env(_bp(_noise(0.06, 161), 2200.0, 3.0), 0.001, 0.012), 1.0, 0.16)
	_save("weapon_switch", swap, 0.55)
	# The Gladius Lux: a hard-light blade. Swing = air plus a rising hum; hit = bite and crackle.
	var swing := _buf(0.38)
	_mix(swing, _env(_bp(_noise(0.36, 170), 500.0, 1.2, 2600.0), 0.1, 0.09), 1.0)
	_mix(swing, _fade(_tone(0.36, 180.0, 420.0, 1, 38.0, 0.04), 0.08, 0.2), 0.22)
	_save("blade_swing", _lp(swing, 5000.0), 0.75)
	var bite := _buf(0.5)
	_mix(bite, _env(_hp(_noise(0.05, 171), 1800.0), 0.0005, 0.008), 1.0)
	_mix(bite, _env(_tone(0.3, 130.0, 45.0), 0.002, 0.07), 1.0)
	_mix(bite, _env(_bp(_noise(0.4, 172), 3000.0, 2.0, 900.0), 0.002, 0.09), 0.6)
	_mix(bite, _env(_tone(0.3, 1400.0, 300.0, 2, 60.0, 0.2), 0.001, 0.06), 0.18)
	_save("blade_hit", _space(_drive(bite, 1.6), 0.4, 0.2))


func _hits() -> void:
	# Shield: an energy skin ringing; flesh/armour: a dull knock; break: the shield collapsing.
	var shield := _buf(0.3)
	_mix(shield, _env(_tone(0.28, 2400.0, 1500.0, 0, 90.0, 0.08), 0.001, 0.05), 0.6)
	_mix(shield, _env(_bp(_noise(0.2, 200), 4200.0, 3.0), 0.001, 0.03), 0.6)
	_save("hit_shield", shield, 0.7)
	var body := _buf(0.25)
	_mix(body, _env(_tone(0.2, 170.0, 70.0), 0.001, 0.04), 1.0)
	_mix(body, _env(_bp(_noise(0.1, 210), 1500.0, 1.5), 0.0005, 0.012), 0.7)
	_save("hit_body", body, 0.8)
	var brk := _buf(0.7)
	_mix(brk, _env(_tone(0.6, 1800.0, 140.0, 1), 0.002, 0.16), 0.5)
	_mix(brk, _env(_bp(_noise(0.6, 220), 3500.0, 1.2, 500.0), 0.002, 0.14), 0.8)
	_mix(brk, _env(_tone(0.3, 90.0, 40.0), 0.002, 0.1), 0.8)
	_save("shield_break", _space(brk, 0.5, 0.3), 0.85)
	# Hit marker and kill confirm are for the local player's own shots: short, dry, above the mix.
	_save("hit_marker", _env(_tone(0.07, 1900.0, 1500.0, 3), 0.0005, 0.016), 0.5)
	var head := _buf(0.2)
	_mix(head, _env(_tone(0.18, 2900.0, 2700.0), 0.0005, 0.05), 0.7)
	_mix(head, _env(_tone(0.18, 4350.0, 4100.0), 0.0005, 0.035), 0.35)
	_save("hit_marker_head", head, 0.55)
	var kill := _buf(0.5)
	_mix(kill, _env(_tone(0.2, 880.0, 880.0, 3), 0.002, 0.07), 0.6)
	_mix(kill, _env(_tone(0.35, 1320.0, 1320.0, 3), 0.002, 0.12), 0.6, 0.09)
	_save("kill_confirm", _space(kill, 0.35, 0.3), 0.6)
	# A round striking stone, and one passing close.
	var impact := _buf(0.3)
	_mix(impact, _env(_hp(_noise(0.04, 230), 3000.0), 0.0005, 0.005), 1.0)
	_mix(impact, _env(_bp(_noise(0.25, 231), 1700.0, 1.0, 700.0), 0.001, 0.04), 0.8)
	_mix(impact, _env(_tone(0.1, 320.0, 120.0), 0.001, 0.02), 0.5)
	_save("impact_stone", impact, 0.7)
	var whiz := _env(_bp(_noise(0.3, 240), 3800.0, 5.0, 1200.0), 0.03, 0.06)
	_save("whiz", whiz, 0.6)


func _step(salt: int, hz: float, q: float, decay: float, click: float, low: float) -> PackedFloat32Array:
	var out := _buf(0.3)
	# A step is mostly a short knock in the body band; the low thud under it stays quiet so eighteen
	# soldiers walking do not rumble.
	_mix(out, _env(_bp(_noise(0.25, salt), hz, q), 0.004, decay), 1.0)
	_mix(out, _env(_bp(_noise(0.25, salt + 3), hz * 2.3, q * 0.8), 0.002, decay * 0.6), 0.5)
	_mix(out, _env(_hp(_noise(0.03, salt + 1), 2800.0), 0.0005, 0.004), click)
	_mix(out, _env(_tone(0.1, 150.0, 85.0), 0.002, 0.022), low * 0.35)
	# Armour moving with the step.
	_mix(out, _env(_bp(_noise(0.1, salt + 2), 5200.0, 6.0), 0.01, 0.02), 0.07, 0.03)
	return out


func _movement() -> void:
	for i in 3:
		_save("step_earth_%d" % (i + 1), _step(300 + i * 7, 420.0 + i * 60.0, 0.9, 0.045, 0.1, 0.6), 0.6)
		_save("step_grass_%d" % (i + 1), _step(330 + i * 7, 1500.0 + i * 220.0, 0.6, 0.07, 0.05, 0.3), 0.5)
		_save("step_paving_%d" % (i + 1), _step(360 + i * 7, 900.0 + i * 130.0, 1.6, 0.03, 0.6, 0.5), 0.65)
		_save("step_stone_%d" % (i + 1), _step(390 + i * 7, 1250.0 + i * 150.0, 2.2, 0.025, 0.8, 0.35), 0.65)
		_save("step_wood_%d" % (i + 1), _step(420 + i * 7, 330.0 + i * 50.0, 3.0, 0.06, 0.3, 0.8), 0.65)
	var land := _buf(0.5)
	_mix(land, _env(_tone(0.4, 120.0, 38.0), 0.002, 0.1), 1.0)
	_mix(land, _env(_bp(_noise(0.4, 450), 500.0, 0.8), 0.002, 0.08), 0.8)
	_mix(land, _env(_bp(_noise(0.2, 451), 4500.0, 4.0), 0.01, 0.04), 0.2, 0.02)
	_save("land", _drive(land, 1.5), 0.85)
	var down := _buf(0.7)
	_mix(down, _env(_tone(0.3, 150.0, 50.0), 0.002, 0.07), 1.0, 0.05)
	_mix(down, _env(_bp(_noise(0.3, 460), 2600.0, 2.5), 0.002, 0.04), 0.6)
	_mix(down, _env(_bp(_noise(0.3, 461), 3400.0, 3.0), 0.002, 0.05), 0.4, 0.22)
	_mix(down, _env(_tone(0.5, 700.0, 180.0, 1), 0.01, 0.15), 0.12)
	_save("downed", down, 0.8)


func _drop_and_zone() -> void:
	# Carrier: two detuned engines under a turbine hiss. Loops.
	var carrier := _buf(3.3)
	_mix(carrier, _lp(_tone(3.3, 62.0, 62.0, 1, 0.6, 0.02), 500.0), 0.6)
	_mix(carrier, _lp(_tone(3.3, 93.5, 93.5, 1, 0.45, 0.02), 700.0), 0.4)
	_mix(carrier, _bp(_noise(3.3, 500), 1500.0, 0.6), 0.18)
	_mix(carrier, _tone(3.3, 1240.0, 1240.0, 0, 5.0, 0.004), 0.05)
	_save("carrier_loop", _loop(carrier, 0.3), 0.7)
	var wind := _hp(_lp(_lp(_noise(3.3, 510), 1100.0), 1500.0), 150.0)
	var gust := _tone(3.3, 0.61, 0.61)
	for i in wind.size():
		wind[i] *= 0.7 + 0.3 * gust[i]
	_mix(wind, _bp(_noise(3.3, 511), 2400.0, 3.0), 0.12)
	_save("drop_wind_loop", _loop(wind, 0.3), 0.75)
	# The zone wall: a low field hum with a slow beat and a faint high shimmer. Loops.
	var hum := _buf(3.3)
	_mix(hum, _tone(3.3, 55.0, 55.0, 1), 0.5)
	_mix(hum, _tone(3.3, 55.6, 55.6, 1), 0.5)
	_mix(hum, _tone(3.3, 110.3, 110.3, 3), 0.3)
	_lp(hum, 600.0)
	_mix(hum, _bp(_noise(3.3, 520), 5200.0, 5.0), 0.07)
	_save("zone_hum_loop", _loop(hum, 0.3), 0.65)
	# Standing in the zone's field: skin crackle. Loops.
	var burn := _hp(_noise(1.3, 530), 3000.0)
	_rng.seed = SEED + 531
	var level := 0.0
	for i in burn.size():
		if _rng.randf() < 0.004:
			level = _rng.randf_range(0.4, 1.0)
		level *= 0.998
		burn[i] *= level
	_mix(burn, _lp(_tone(1.3, 48.0, 48.0, 2), 300.0), 0.25)
	_save("zone_burn_loop", _loop(burn, 0.2), 0.6)
	# The cornu call when the zone starts to close: two brass notes with a slow swell.
	var horn := _buf(2.2)
	for note: Array in [[0.0, 146.8, 0.9], [0.85, 196.0, 1.25]]:
		var tone := _tone(float(note[2]), float(note[1]), float(note[1]), 1, 5.2, 0.006)
		_mix(tone, _tone(float(note[2]), float(note[1]) * 2.003, float(note[1]) * 2.003, 1), 0.35)
		_bp(tone, float(note[1]) * 3.2, 0.7)
		_fade(tone, 0.09, 0.3)
		_mix(horn, tone, 1.0, float(note[0]))
	_save("zone_horn", _space(_drive(horn, 2.2), 0.8, 0.8), 0.75)


func _match_events() -> void:
	var revive := _buf(1.1)
	_mix(revive, _fade(_tone(1.1, 220.0, 440.0, 3, 9.0, 0.02), 0.2, 0.1), 0.5)
	_mix(revive, _fade(_bp(_noise(1.1, 600), 1800.0, 2.0, 4200.0), 0.3, 0.1), 0.25)
	_save("revive_loop", _loop(revive, 0.1), 0.5)
	var up := _buf(0.6)
	_mix(up, _env(_tone(0.25, 660.0, 660.0, 3), 0.004, 0.08), 0.6)
	_mix(up, _env(_tone(0.25, 880.0, 880.0, 3), 0.004, 0.08), 0.6, 0.1)
	_mix(up, _env(_tone(0.35, 1320.0, 1320.0, 3), 0.004, 0.12), 0.6, 0.2)
	_save("revived", _space(up, 0.4, 0.3), 0.6)
	var out := _buf(1.2)
	_mix(out, _env(_tone(1.0, 110.0, 30.0), 0.004, 0.3), 1.0)
	_mix(out, _env(_lp(_noise(1.0, 610), 500.0), 0.004, 0.25), 0.6)
	_mix(out, _env(_tone(0.6, 500.0, 120.0, 1), 0.004, 0.12), 0.15)
	_save("eliminated", _space(_drive(out, 1.5), 0.6, 0.5), 0.85)
	# Match start and match end: three-note cornu figures (signals, not music).
	for figure: Array in [["match_start", [[0.0, 196.0, 0.35], [0.3, 196.0, 0.35], [0.6, 293.7, 1.1]]], ["match_end", [[0.0, 293.7, 0.5], [0.45, 246.9, 0.5], [0.9, 196.0, 1.4]]]]:
		var horn := _buf(2.4)
		for note: Array in figure[1]:
			var tone := _tone(float(note[2]), float(note[1]), float(note[1]), 1, 5.0, 0.006)
			_mix(tone, _tone(float(note[2]), float(note[1]) * 1.5, float(note[1]) * 1.5, 1), 0.2)
			_bp(tone, float(note[1]) * 3.0, 0.7)
			_fade(tone, 0.05, 0.2)
			_mix(horn, tone, 1.0, float(note[0]))
		_save(String(figure[0]), _space(_drive(horn, 2.2), 0.8, 0.9), 0.7)


func _pickups_and_ui() -> void:
	var weapon := _buf(0.35)
	_mix(weapon, _env(_bp(_noise(0.1, 700), 1500.0, 2.5), 0.001, 0.02), 1.0)
	_mix(weapon, _env(_tone(0.15, 500.0, 260.0, 3), 0.001, 0.04), 0.5, 0.01)
	_mix(weapon, _env(_bp(_noise(0.08, 701), 2800.0, 3.0), 0.001, 0.012), 0.8, 0.14)
	_save("pickup_weapon", weapon, 0.65)
	var ammo := _buf(0.3)
	for i in 3:
		_mix(ammo, _env(_bp(_noise(0.05, 710 + i), 3600.0 + i * 500.0, 5.0), 0.0005, 0.008), 0.8, 0.02 + i * 0.055)
	_mix(ammo, _env(_tone(0.1, 240.0, 150.0), 0.001, 0.03), 0.4, 0.02)
	_save("pickup_ammo", ammo, 0.6)
	var armor := _buf(0.6)
	_mix(armor, _env(_bp(_noise(0.15, 720), 900.0, 1.2), 0.002, 0.04), 0.9)
	_mix(armor, _fade(_tone(0.45, 300.0, 900.0, 0, 30.0, 0.02), 0.03, 0.2), 0.35, 0.08)
	_mix(armor, _env(_tone(0.2, 1800.0, 1800.0), 0.002, 0.07), 0.25, 0.36)
	_save("pickup_armor", armor, 0.65)
	_save("ui_click", _mix(_env(_tone(0.05, 1300.0, 900.0, 3), 0.0005, 0.012), _env(_hp(_noise(0.02, 730), 3000.0), 0.0005, 0.003), 0.5), 0.45)
	_save("ui_back", _env(_tone(0.07, 700.0, 450.0, 3), 0.0005, 0.02), 0.45)
	var toggle := _buf(0.12)
	_mix(toggle, _env(_tone(0.04, 1000.0, 1000.0, 3), 0.0005, 0.012), 1.0)
	_mix(toggle, _env(_tone(0.05, 1500.0, 1500.0, 3), 0.0005, 0.016), 1.0, 0.05)
	_save("ui_toggle", toggle, 0.45)


func _ambience() -> void:
	# Wind over the hill: slow gusts. Loops.
	# Two low-pass stages keep it a low rush instead of a hiss; a thin band above gives the whistle.
	var wind := _hp(_lp(_lp(_noise(6.4, 800), 520.0), 700.0), 90.0)
	var gust := _tone(6.4, 0.3125, 0.3125)
	var gust2 := _tone(6.4, 0.78125, 0.78125)
	for i in wind.size():
		wind[i] *= 0.55 + 0.3 * gust[i] + 0.15 * gust2[i]
	var whistle := _bp(_noise(6.4, 801), 1300.0, 6.0)
	for i in whistle.size():
		whistle[i] *= maxf(gust[i], 0.0) * maxf(gust2[i], 0.0)
	_mix(wind, whistle, 0.08)
	_save("wind_loop", _loop(wind, 0.4), 0.6)
	# A brazier: a low roar with crackles. Loops.
	var fire := _lp(_noise(3.2, 810), 420.0)
	_gain(fire, 0.6)
	var crackle := _hp(_noise(3.2, 811), 2200.0)
	_rng.seed = SEED + 812
	var level := 0.0
	for i in crackle.size():
		if _rng.randf() < 0.0012:
			level = _rng.randf_range(0.3, 1.0)
		level *= 0.992
		crackle[i] *= level
	_mix(fire, crackle, 0.5)
	_save("fire_loop", _loop(fire, 0.3), 0.6)
	# Rain on stone. Loops.
	var rain := _hp(_hp(_lp(_lp(_noise(3.2, 820), 6000.0), 8000.0), 700.0), 500.0)
	_mix(rain, _bp(_noise(3.2, 821), 2600.0, 1.4), 0.4)
	var drops := _hp(_noise(3.2, 822), 3500.0)
	_rng.seed = SEED + 823
	level = 0.0
	for i in drops.size():
		if _rng.randf() < 0.01:
			level = _rng.randf_range(0.2, 0.8)
		level *= 0.985
		drops[i] *= level
	_mix(rain, drops, 0.5)
	_save("rain_loop", _loop(rain, 0.3), 0.55)
	for i in 2:
		var thunder := _buf(3.5)
		_mix(thunder, _env(_lp(_noise(3.4, 830 + i * 5), 220.0 - i * 50.0), 0.02 + i * 0.1, 0.9), 1.0)
		_mix(thunder, _env(_lp(_noise(1.0, 831 + i * 5), 1200.0), 0.004, 0.1), 0.5 - i * 0.3)
		var rumble := _tone(3.4, 2.3 + i, 1.1)
		for k in mini(thunder.size(), rumble.size()):
			thunder[k] *= 0.7 + 0.3 * rumble[k]
		_save("thunder_%d" % (i + 1), _fade(_space(_drive(thunder, 2.0), 0.7, 0.8), 0.0, 1.0), 0.85)
	# Night insects: thin pulsed tones over quiet air. Loops.
	var night := _lp(_lp(_noise(4.0, 840), 260.0), 400.0)
	_gain(night, 0.12)
	for voice: Array in [[4300.0, 17.0, 0.0], [5100.0, 23.0, 1.3], [3700.0, 13.0, 2.2]]:
		var chirp := _tone(4.0, float(voice[0]), float(voice[0]))
		var pulse := _tone(4.0, float(voice[1]), float(voice[1]), 2)
		for k in chirp.size():
			chirp[k] *= maxf(pulse[k], 0.0) * maxf(sin(TAU * 0.25 * k / RATE + float(voice[2])), 0.0)
		_mix(night, chirp, 0.1)
	_save("night_loop", _loop(night, 0.3), 0.4)
	# A banner snapping in the wind (one shot, played at random near flags).
	var flap := _env(_bp(_noise(0.25, 850), 500.0, 0.7, 1400.0), 0.01, 0.05)
	_mix(flap, _env(_bp(_noise(0.1, 851), 900.0, 1.0), 0.002, 0.02), 0.8, 0.09)
	_save("banner_flap", flap, 0.5)
