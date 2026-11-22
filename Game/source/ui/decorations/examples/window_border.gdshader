// Exemple de shader de bordure : le motif du cadre, avec un liseré lumineux qui
// parcourt le pourtour. Copier dans user://window_border.gdshader pour
// l'activer ; le rechargement est à chaud. S'applique aux pièces du cadre ET à
// la bande de titre.
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never;

uniform sampler2D border_texture : source_color, filter_linear_mipmap;
uniform vec2 part_offset = vec2(0.0);      // position de la pièce dans la fenêtre
uniform vec2 piece_size = vec2(1.0);
uniform vec2 window_half_size = vec2(1.0);
uniform vec3 glow_color : source_color = vec3(0.3, 0.8, 1.0);

varying vec2 win_pos; // position dans la fenêtre (repère du quad)

void vertex() {
	win_pos = VERTEX.xy + part_offset;
}

void fragment() {
	vec4 tex = texture(border_texture, UV);
	// Abscisse curviligne grossière autour de la fenêtre : angle depuis le centre.
	float ang = atan(win_pos.y, win_pos.x) / TAU + 0.5;
	float glow = smoothstep(0.1, 0.0, abs(fract(ang - TIME * 0.15) - 0.5));
	ALBEDO = mix(tex.rgb, glow_color, glow * 0.6);
	ALPHA = tex.a;
}
