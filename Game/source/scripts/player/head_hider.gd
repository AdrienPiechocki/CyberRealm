extends SkeletonModifier3D
## Cache la tête d'un avatar en vue 1ère personne : réduit l'os de la tête à (presque) zéro APRÈS l'animation
## (un modificateur s'exécute après l'AnimationPlayer, la pose animée ne l'écrase donc pas). Tout ce qui est
## skinné sur cet os (crâne, cheveux, casque) et les BoneAttachment3D enfants disparaissent avec lui.

var bone_name := ""
var hidden := false

const HIDE_SCALE := Vector3.ONE * 0.001   # pas 0 : une matrice singulière donne des normales NaN

func _process_modification_with_delta(_delta: float) -> void:
	if not hidden:
		return
	var sk := get_skeleton()
	if sk == null:
		return
	var i := sk.find_bone(bone_name)
	if i >= 0:
		sk.set_bone_pose_scale(i, HIDE_SCALE)
