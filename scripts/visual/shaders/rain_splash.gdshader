shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;
// A raindrop's ring on the ground: grows and fades over the particle's life (INSTANCE_CUSTOM.y = age 0..1).
uniform vec4 tint : source_color = vec4(0.75, 0.82, 0.9, 0.4);
varying float v_age;

void vertex() {
	v_age = INSTANCE_CUSTOM.y;
	VERTEX.xz *= 0.25 + 0.75 * v_age;
}

void fragment() {
	float d = length(UV - 0.5) * 2.0;
	float ring = smoothstep(0.55, 0.8, d) * (1.0 - smoothstep(0.85, 1.0, d));
	ALBEDO = tint.rgb;
	ALPHA = ring * tint.a * (1.0 - v_age);
}
