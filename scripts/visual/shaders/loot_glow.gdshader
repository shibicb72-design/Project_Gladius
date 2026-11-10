shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;
// S6: the glow of a ground item, one batch for every item (instance colour = the item kind's colour).
// UV2.x picks the part: 0 = a soft pulsing ring on the ground, 1 = a thin beam that fades with height.
uniform float strength = 0.9;
uniform float pulse_speed = 2.4;
varying float v_part;
varying float v_phase;

void vertex() {
	v_part = UV2.x;
	v_phase = MODEL_MATRIX[3].x * 0.7 + MODEL_MATRIX[3].z * 1.3;
}

void fragment() {
	float alpha;
	if (v_part < 0.5) {
		float d = length(UV - 0.5) * 2.0;
		float pulse = 0.75 + 0.25 * sin(TIME * pulse_speed + v_phase);
		float ring = smoothstep(0.55, 0.82, d) * (1.0 - smoothstep(0.86, 1.0, d));
		alpha = (ring * 0.9 + (1.0 - smoothstep(0.0, 0.9, d)) * 0.18) * pulse;
	} else {
		float across = 1.0 - abs(UV.x - 0.5) * 2.0;
		alpha = across * across * pow(1.0 - UV.y, 1.8) * 0.55;
	}
	ALBEDO = COLOR.rgb * alpha * strength;
	ALPHA = 1.0;
}
