extends RefCounted
## Construction et recalage du décor 3D d'UNE fenêtre (cadre, barre, boutons).
##
## Tout est enfant du quad de CONTENU : le décor déborde donc du mesh sans
## qu'aucun code de position, de rotation ou de déplacement n'ait à le suivre.
##
## API statique : aucun état propre, tout passe par le quad.

const Decorations := preload("res://scripts/ui/window_decorations.gd")

const FRAME_DEPTH := 0.04
const BUTTON_DEPTH := 0.03
## Pièces du cadre dessinées. `piece` désigne la région du 9-patch, `edge` le
## côté tiré quand le joueur redimensionne par le cadre. Les coins hauts tirent
## « top » comme le fait déjà la barre de titre ; les coins bas tirent leur coin,
## comme la politique CORNER_MARGIN du contenu.
const FRAME_PIECES := [
	{"node": "FrameLeft", "piece": "left", "edge": "left"},
	{"node": "FrameRight", "piece": "right", "edge": "right"},
	{"node": "FrameBottom", "piece": "bottom", "edge": "bottom"},
	{"node": "CornerBL", "piece": "bottomleft", "edge": "bottomleft"},
	{"node": "CornerBR", "piece": "bottomright", "edge": "bottomright"},
	{"node": "CornerTL", "piece": "topleft", "edge": "top"},
	{"node": "CornerTR", "piece": "topright", "edge": "top"},
]
const BUTTON_ORDER := ["close", "maximize", "minimize"]

static func titlebar_metrics(s: float) -> Dictionary:
	return Decorations.world(Decorations.metrics(), s)

## Position et taille monde d'une pièce, dans le repère du quad. Les coins hauts
## font toute la hauteur de la barre : ce sont les coins du titre, pas de la
## simple bordure.
static func frame_piece_rect(piece: String, half: Vector2, t: float, b: float) -> Array:
	var hw := half.x
	var hh := half.y
	match piece:
		"left": return [Vector2(-hw - t * 0.5, 0.0), Vector2(t, hh * 2.0)]
		"right": return [Vector2(hw + t * 0.5, 0.0), Vector2(t, hh * 2.0)]
		"bottom": return [Vector2(0.0, -hh - t * 0.5), Vector2(hw * 2.0, t)]
		"bottomleft": return [Vector2(-hw - t * 0.5, -hh - t * 0.5), Vector2(t, t)]
		"bottomright": return [Vector2(hw + t * 0.5, -hh - t * 0.5), Vector2(t, t)]
		"topleft": return [Vector2(-hw - t * 0.5, hh + b * 0.5), Vector2(t, b)]
		"topright": return [Vector2(hw + t * 0.5, hh + b * 0.5), Vector2(t, b)]
	return [Vector2.ZERO, Vector2.ZERO]

## Position X du centre de chaque bouton, dans l'ordre `BUTTON_ORDER`. Le
## premier élément de la liste est toujours le plus à l'EXTÉRIEUR du lot : à
## droite on part du bord droit et on avance vers la gauche, à l'inverse à
## gauche. Un même pas, un seul sens.
static func button_positions(count: int, alignment: String, btn: float, gap: float,
		margin: float, half_width: float) -> Array:
	var out: Array = []
	var at_right := alignment != "left"
	var x := (half_width - margin - btn * 0.5) if at_right \
		else (-half_width + margin + btn * 0.5)
	var step := -(btn + gap) if at_right else (btn + gap)
	for i in count:
		out.append(x)
		x += step
	return out