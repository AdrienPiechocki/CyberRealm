// Exemple de transition de fermeture : la fenêtre rétrécit vers son centre
// en fondu. Copier dans user://window_close.gdshader (dossier de données du jeu)
// pour l'activer ; le rechargement est à chaud.
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never;

uniform sampler2D window_texture : filter_linear_mipmap;
uniform vec2 content_size = vec2(0.0);   // taille utile du contenu (px), 0 pour le décor
uniform bool opaque_mode = true;
uniform bool is_decoration = false;      // true : pièce du cadre / bouton
uniform bool closing = false;
uniform float progress : hint_range(0.0, 1.0) = 0.0; // 0 → 1 sur la durée
uniform vec2 part_offset = vec2(0.0);    // position de la pièce dans la fenêtre
uniform vec2 window_half_size = vec2(1.0);

void vertex() {
	// Toutes les pièces se déforment autour du CENTRE de la fenêtre, pas de leur
	// propre origine : le cadre reste collé au contenu.
	float t = smoothstep(0.0, 1.0, progress);
	float k = mix(1.0, 0.6, t);
	vec2 wp = (VERTEX.xy + part_offset) * k;
	VERTEX.xy = wp - part_offset;
}

void fragment() {
	vec2 ts = vec2(textureSize(window_texture, 0));
	vec2 uv = (!is_decoration && ts.x > 0.0 && content_size.x > 0.0) ? UV * content_size / ts : UV;
	vec4 tex = texture(window_texture, uv);
	if (tex.a <= 0.01) discard;
	vec3 rgb = is_decoration ? tex.rgb : tex.rgb / max(tex.a, 0.001);
	ALBEDO = pow(rgb, vec3(2.2));
	float a = (is_decoration || !opaque_mode) ? tex.a : clamp(tex.a * 2.0, 0.0, 1.0);
	ALPHA = a * (1.0 - smoothstep(0.4, 1.0, progress));
}
