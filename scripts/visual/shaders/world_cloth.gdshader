shader_type spatial;
render_mode cull_disabled;
uniform float amplitude;
uniform float speed;
uniform float frequency;
uniform vec4 base_color : source_color;
uniform float roughness;
void vertex() {
	VERTEX.z += sin(TIME * speed + UV.x * frequency) * amplitude * UV.x;
}
void fragment() {
	ALBEDO = base_color.rgb;
	ROUGHNESS = roughness;
}
