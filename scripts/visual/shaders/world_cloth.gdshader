shader_type spatial;
render_mode cull_disabled;
// Banners and tent cloth (WorldAmbient). S7: the cloth takes light on both sides, ripples in two waves that
// grow away from the pole (UV.x = 0 is the fixed edge), shows a woven surface from the shared surface array,
// and carries a trim: a gold band near the free edge and one across the top. Uniform names amplitude, speed,
// frequency, base_color and roughness are the ones WorldAmbient has always set.
uniform float amplitude;
uniform float speed;
uniform float frequency;
uniform vec4 base_color : source_color;
uniform float roughness;
uniform sampler2DArray surfaces : filter_linear_mipmap, repeat_enable;
uniform float cloth_layer = 6.0;
uniform float weave_per_uv = 5.0;
uniform vec3 trim_color : source_color = vec3(0.85, 0.62, 0.2);
uniform float trim = 1.0;
varying float v_fold;

void vertex() {
	float t = TIME * speed;
	float reach = UV.x;
	float wave = sin(t + UV.x * frequency) * 0.7 + sin(t * 1.7 + UV.x * frequency * 2.3 + UV.y * 3.0) * 0.3;
	VERTEX.z += wave * amplitude * reach;
	VERTEX.y += sin(t * 0.8 + UV.x * frequency * 0.6) * amplitude * 0.25 * reach;
	// The fold's slope shades the cloth: a cheap stand-in for recomputed normals.
	v_fold = cos(t + UV.x * frequency) * reach;
}

void fragment() {
	vec4 weave = texture(surfaces, vec3(UV * weave_per_uv, cloth_layer));
	vec3 color = base_color.rgb * (0.7 + 0.6 * weave.r);
	float band = step(0.82, UV.x) * step(UV.x, 0.9) + step(UV.y, 0.1) * step(0.03, UV.y);
	color = mix(color, trim_color * (0.7 + 0.6 * weave.r), clamp(band, 0.0, 1.0) * trim);
	ALBEDO = color * (0.82 + 0.18 * v_fold);
	ROUGHNESS = roughness;
}
