shader_type spatial;
render_mode cull_disabled;
// Grass tufts (WorldAmbient): one batch. S7: a tuft is a few blades; the vertex colour runs dark at the root
// to light at the tip, the tip sways with a gust that travels across the field, and the blades take the
// ground's light (their normal points up) so a tuft never flashes dark when a blade turns edge-on.
uniform float amplitude;
uniform float speed;
uniform float frequency;
uniform float height_m;
uniform vec4 base_color : source_color;
uniform float roughness;
// M2W1 astraB (optional; the defaults draw exactly as before). solid_by_alpha 1: a vertex whose colour alpha is
// below 0.5 is a solid part merged into a clutter patch (a stone): it neither sways nor takes the upward normal.
// fade_to_m > 0: an instance shrinks into the ground between fade_from_m and fade_to_m from the camera (its origin),
// so patches end softly instead of at the batch's range.
uniform float solid_by_alpha = 0.0;
uniform float fade_from_m = 0.0;
uniform float fade_to_m = 0.0;

void vertex() {
	float blade = mix(1.0, step(0.5, COLOR.a), solid_by_alpha);
	float weight = clamp(VERTEX.y / height_m, 0.0, 1.0) * blade;
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float gust = sin(TIME * speed + world.x * frequency * 0.35 + world.z * frequency * 0.22) * 0.7
			+ sin(TIME * speed * 2.3 + world.x * 1.7) * 0.3;
	VERTEX.x += gust * amplitude * weight * weight;
	VERTEX.z += gust * amplitude * 0.4 * weight * weight;
	if (fade_to_m > 0.0) {
		float d = length(MODEL_MATRIX[3].xyz - CAMERA_POSITION_WORLD);
		VERTEX *= 1.0 - smoothstep(fade_from_m, fade_to_m, d);
	}
	NORMAL = normalize(mix(NORMAL, (inverse(MODEL_MATRIX) * vec4(0.0, 1.0, 0.0, 0.0)).xyz, blade));
}

void fragment() {
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;  // the engine turns a back face's normal round; a blade is lit the same from both sides
	}
	ALBEDO = base_color.rgb * COLOR.rgb;
	ROUGHNESS = roughness;
}
