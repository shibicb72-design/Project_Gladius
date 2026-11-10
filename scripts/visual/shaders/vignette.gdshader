shader_type canvas_item;
// Darkens the corners of the 3D view. A plain blended rectangle: it does not read the screen.
uniform vec4 tint : source_color = vec4(0.02, 0.02, 0.06, 1.0);
uniform float strength = 0.38;
uniform float inner = 0.55;
uniform float outer = 1.25;

void fragment() {
	vec2 p = (UV - 0.5) * 2.0;
	COLOR = vec4(tint.rgb, smoothstep(inner, outer, length(p)) * strength);
}
