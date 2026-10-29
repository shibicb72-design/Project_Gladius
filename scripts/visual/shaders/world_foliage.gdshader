shader_type spatial;
uniform float amplitude;
uniform float speed;
uniform float frequency;
uniform float height_m;
uniform vec4 base_color : source_color;
uniform float roughness;
void vertex() {
	float weight = clamp((VERTEX.y + height_m * 0.5) / height_m, 0.0, 1.0);
	VERTEX.x += sin(TIME * speed + MODEL_MATRIX[3].x * frequency) * amplitude * weight;
}
void fragment() {
	ALBEDO = base_color.rgb;
	ROUGHNESS = roughness;
}
