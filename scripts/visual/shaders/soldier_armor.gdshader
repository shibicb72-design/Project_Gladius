shader_type spatial;
// One material for every soldier (C3, decision D2). The vertex colour is the paint, authored as sRGB.
// Where the vertex alpha is 0 the paint is the squad colour: a per-instance value, so squads differ
// without a second material. Alpha 1 keeps the vertex colour.
// squad_paint is plain sRGB numbers (a vec3 without a colour hint), so nothing converts it on the way in
// and the one conversion below treats both paints the same.
instance uniform vec3 squad_paint = vec3(0.66, 0.1, 0.09);
uniform float roughness = 0.95;

// The sRGB to linear step StandardMaterial3D applies with vertex_color_is_srgb.
vec3 to_linear(vec3 c) {
	return mix(pow((c + vec3(0.055)) * (1.0 / 1.055), vec3(2.4)), c * (1.0 / 12.92), lessThan(c, vec3(0.04045)));
}

void vertex() {
	COLOR.rgb = to_linear(mix(squad_paint, COLOR.rgb, COLOR.a));
}

void fragment() {
	ALBEDO = COLOR.rgb;
	ROUGHNESS = roughness;
}
