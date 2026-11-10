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

void vertex() {
	float weight = clamp(VERTEX.y / height_m, 0.0, 1.0);
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float gust = sin(TIME * speed + world.x * frequency * 0.35 + world.z * frequency * 0.22) * 0.7
			+ sin(TIME * speed * 2.3 + world.x * 1.7) * 0.3;
	VERTEX.x += gust * amplitude * weight * weight;
	VERTEX.z += gust * amplitude * 0.4 * weight * weight;
	NORMAL = normalize((inverse(MODEL_MATRIX) * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
}

void fragment() {
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;  // the engine turns a back face's normal round; a blade is lit the same from both sides
	}
	ALBEDO = base_color.rgb * COLOR.rgb;
	ROUGHNESS = roughness;
}
