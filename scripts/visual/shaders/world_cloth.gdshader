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

// W1a: the Compatibility renderer (WebGL 2) shades in sRGB space: OUTPUT_IS_SRGB is true there and base_color /
// trim_color (source_color) arrive unconverted, so the weave and fold factors below darkened sRGB values on the web
// (banners and tents too dark). There, W1A_LIN() takes the colours to linear, the albedo is worked out as on
// Mobile and W1A_OUT() hands it over in sRGB. Mobile and Forward+ compile W1A_LIN(c) and W1A_OUT(c) as (c).
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
vec3 w1a_to_linear(vec3 c) {
	return mix(pow((c + vec3(0.055)) * (1.0 / 1.055), vec3(2.4)), c * (1.0 / 12.92), lessThan(c, vec3(0.04045)));
}
vec3 w1a_to_srgb(vec3 c) {
	c = max(c, vec3(0.0));
	return mix(vec3(1.055) * pow(c, vec3(1.0 / 2.4)) - vec3(0.055), c * 12.92, lessThan(c, vec3(0.0031308)));
}
#define W1A_LIN(c) w1a_to_linear(c)
#define W1A_OUT(c) w1a_to_srgb(c)
#else
#define W1A_LIN(c) (c)
#define W1A_OUT(c) (c)
#endif

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
	vec3 color = W1A_LIN(base_color.rgb) * (0.7 + 0.6 * weave.r);
	float band = step(0.82, UV.x) * step(UV.x, 0.9) + step(UV.y, 0.1) * step(0.03, UV.y);
	color = mix(color, W1A_LIN(trim_color) * (0.7 + 0.6 * weave.r), clamp(band, 0.0, 1.0) * trim);
	ALBEDO = W1A_OUT(color * (0.82 + 0.18 * v_fold));
	ROUGHNESS = roughness;
}
