class_name SoldierClips
extends RefCounted
## M2 AN1 commit 4: shared post-processing of the library clips baked onto the soldier (AnimRetarget, ClipLibrary).
## Locomotion cycles are measured on the soldier's own legs (stride: the stance foot's travel against the hips per
## second of ground contact), turned to start at the left foot's forward-most point, optionally reversed, and
## stretched to one normalized cycle (`CYCLE_S`), so the graph can play every gait in phase at one rate:
## cycles per second = ground speed / cycle_m. Results are cached per source clip: every soldier shares them.
## Presentation only; numbers in data/anim_third_person.json "gait" (OQ-ANIM-FOOTSLIDE placeholders).

const CYCLE_S := 1.0
static var _gaits: Dictionary = {}
static var _measures: Dictionary = {}


static func cfg() -> Dictionary:
	return SoldierRig.config()["gait"]


## The ground contact points of the soldier's boots: per foot [bone, heel, toe], bone-local, the bottom back and
## bottom front centre of the boot part's bind-pose box (the toe is the -Z end). A rolling foot touches with one or
## the other, so each is a contact point of its own.
static func sole_points(skeleton: Skeleton3D) -> Array:
	var parts: Array = SoldierLook.parts()
	var bounds := SoldierRig.part_local_bounds(parts, skeleton)
	var out: Array = []
	for side in ["l", "r"]:
		for i in parts.size():
			if parts[i]["name"] == "boot_" + side:
				var box: AABB = bounds[i]
				var mid := box.get_center()
				var foot := skeleton.find_bone("LeftFoot" if side == "l" else "RightFoot")
				out.append([foot, Vector3(mid.x, box.position.y, box.end.z), Vector3(mid.x, box.position.y, box.position.z), skeleton.get_bone_parent(foot)])
	return out


## Skeleton-space contact points [left heel, left toe, right heel, right toe, left knee, right knee] of a pose
## (global bone poses). The knees (shin bone origins) only touch in the downed knee-crawl.
static func contacts(poses: Array[Transform3D], soles: Array) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for sole: Array in soles:
		out.append(poses[int(sole[0])] * (sole[1] as Vector3))
		out.append(poses[int(sole[0])] * (sole[2] as Vector3))
	for sole: Array in soles:
		out.append(poses[int(sole[3])].origin)
	return out


## Measures a baked cycle on `skeleton`: speed_mps (how fast the touching heel or toe moves back against the hips,
## averaged over the time it touches: the ground speed at which it would stay planted), cycle_m (that speed times
## the clip length), left_forward_s (time of the left foot's forward-most point) and contact (fraction of samples
## with any point down). A point touches within contact_height_m of the lowest point of the cycle.
static func measure(clip: Animation, skeleton: Skeleton3D) -> Dictionary:
	var key := clip.get_instance_id()
	if _measures.has(key):
		return _measures[key]
	var samples := int(cfg()["measure_samples"])
	var contact_m := float(cfg()["contact_height_m"])
	var soles := sole_points(skeleton)
	var hips := skeleton.find_bone("Hips")
	var frames: Array = []
	var floor_y := INF
	for i in samples + 1:
		var poses := AnimRetarget.sample_globals(clip, skeleton, clip.length * float(i) / samples)
		var points := contacts(poses, soles)
		for p in points:
			floor_y = minf(floor_y, p.y)
		frames.append([points, poses[hips].origin, poses[int(soles[0][0])].origin.z])
	var travel := 0.0
	var time := 0.0
	var down := 0
	var dt := clip.length / samples
	for i in samples:
		var moved := 0.0
		var touching := 0
		for p in 4:
			var a: Vector3 = frames[i][0][p]
			var b: Vector3 = frames[i + 1][0][p]
			if a.y <= floor_y + contact_m and b.y <= floor_y + contact_m:
				moved += b.z - a.z
				touching += 1
		if touching > 0:
			travel += moved / touching
			time += dt
			down += 1
	var forward_at := 0
	for i in samples:
		if float(frames[i][2]) < float(frames[forward_at][2]):
			forward_at = i
	var speed := travel / time if time > 0.0 else 0.0
	var result := {"speed_mps": speed, "cycle_m": speed * clip.length, "left_forward_s": clip.length * float(forward_at) / samples, "contact": float(down) / samples}
	_measures[key] = result
	return result


## A gait cycle ready for the graph: {clip, cycle_m, speed_mps}. `reverse` plays it backwards (a back-pedal from a
## forward clip). Shared: one Animation per (source clip, reverse) for every soldier.
static func gait(clip: Animation, skeleton: Skeleton3D, reverse: bool) -> Dictionary:
	var key := str(clip.get_instance_id()) + ("r" if reverse else "f")
	if not _gaits.has(key):
		var m := measure(clip, skeleton)
		var normalized := retime(clip, float(m["left_forward_s"]), reverse, CYCLE_S)
		_gaits[key] = {"clip": normalized, "cycle_m": float(m["cycle_m"]), "speed_mps": float(m["speed_mps"]), "contact": float(m["contact"])}
	return _gaits[key]


## Resamples every track: new time t in [0, length] reads the source at offset + t / length * source length
## (backwards when reversed), wrapped. Loops linearly.
static func retime(clip: Animation, offset_s: float, reverse: bool, length: float) -> Animation:
	var result := Animation.new()
	result.length = length
	result.loop_mode = Animation.LOOP_LINEAR
	var count := maxi(8, ceili(clip.length * float(SoldierRig.config()["retarget"]["sample_hz"])))
	for track in clip.get_track_count():
		var kind := clip.track_get_type(track)
		if kind != Animation.TYPE_ROTATION_3D and kind != Animation.TYPE_POSITION_3D:
			continue
		var out := result.add_track(kind)
		result.track_set_path(out, clip.track_get_path(track))
		for i in count + 1:
			var t := length * float(i) / count
			var source_t := fposmod(offset_s + (-1.0 if reverse else 1.0) * clip.length * float(i) / count, clip.length)
			if kind == Animation.TYPE_ROTATION_3D:
				result.rotation_track_insert_key(out, t, clip.rotation_track_interpolate(track, source_t))
			else:
				result.position_track_insert_key(out, t, clip.position_track_interpolate(track, source_t))
	return result


## A one-shot clip stretched or cut to `duration` (a fresh copy; the shared source is untouched).
static func fit_one_shot(clip: Animation, duration: float) -> Animation:
	return ClipLibrary.fit(clip, duration, Animation.LOOP_NONE)
