shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;
// S7: a brazier's flame on two crossed quads: noise scrolls upward, the flame narrows and breaks up with
// height, white-hot at the root and red at the tips. Additive, one noise fetch pair, no depth or screen read.
uniform sampler2D noise_pack : filter_linear_mipmap, repeat_enable;
uniform vec3 core_color : source_color = vec3(1.0, 0.9, 0.6);
uniform vec3 mid_color : source_color = vec3(1.0, 0.45, 0.08);
uniform vec3 tip_color : source_color = vec3(0.7, 0.08, 0.02);
uniform float strength = 1.6;
uniform float speed = 1.1;
varying float v_phase;

void vertex() {
	v_phase = MODEL_MATRIX[3].x * 0.37 + MODEL_MATRIX[3].z * 0.61;
	// The top of the flame leans and wobbles.
	float h = 1.0 - UV.y;
	VERTEX.x += sin(TIME * 5.0 + v_phase * 7.0 + h * 3.0) * 0.06 * h;
	VERTEX.z += cos(TIME * 4.3 + v_phase * 5.0) * 0.05 * h;
}

void fragment() {
	float h = 1.0 - UV.y;  // 0 at the root, 1 at the tip
	vec2 uv = vec2(UV.x * 0.5 + v_phase, UV.y * 0.7 + TIME * speed);
	float n = texture(noise_pack, uv).b * 0.6 + texture(noise_pack, uv * 2.3 + 0.4).g * 0.4;
	float width = mix(0.48, 0.06, h);
	float shape = 1.0 - smoothstep(width * 0.4, width, abs(UV.x - 0.5) + (n - 0.5) * 0.25 * (0.3 + h));
	float body = shape * smoothstep(0.0, 0.08, h) * (1.0 - smoothstep(0.45 + n * 0.5, 1.0, h));
	vec3 color = mix(mix(core_color, mid_color, smoothstep(0.0, 0.4, h + (1.0 - shape) * 0.5)), tip_color, smoothstep(0.35, 0.95, h));
	ALBEDO = color * body * strength;
	ALPHA = 1.0;
}
