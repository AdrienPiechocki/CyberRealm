extends SkeletonModifier3D
## Cache la tête d'un avatar en vue 1ère personne : réduit l'os de la tête (et du cou, que la caméra verrait en
## regardant vers le bas) à (presque) zéro APRÈS l'animation (un modificateur s'exécute après l'AnimationPlayer, la
## pose animée ne l'écrase donc pas). Tout ce qui est skinné sur ces os (crâne, cheveux, casque, cou) et les
## BoneAttachment3D enfants disparaissent avec eux.

var bone_name := ""                  # os de la tête (sert aussi à placer la caméra)
var extra_bones: Array[String] = []  # os supplémentaires à cacher (cou)
var hidden := false

const HIDE_SCALE := Vector3.ONE * 0.001   # pas 0 : une matrice singulière donne des normales NaN

func _process_modification_with_delta(_delta: float) -> void:
	if not hidden:
		return
	var sk := get_skeleton()
	if sk == null:
		return
	var head := sk.find_bone(bone_name)
	if head >= 0:
		sk.set_bone_pose_scale(head, HIDE_SCALE)
	for nm in extra_bones:
		var i := sk.find_bone(nm)
		if i < 0:
			continue
		sk.set_bone_pose_scale(i, HIDE_SCALE)
		# Les os enfants (ex. clavicules -> bras, rattachées au COU sur les rigs « Bip01 ») héritent de l'échelle :
		# on la compense (échelle et position locales x 1/HIDE_SCALE) pour que leur pose globale reste intacte.
		# La tête, elle, doit disparaître avec le cou.
		for c in sk.get_bone_children(i):
			if c == head:
				continue
			sk.set_bone_pose_position(c, sk.get_bone_pose_position(c) / HIDE_SCALE.x)
			sk.set_bone_pose_scale(c, sk.get_bone_pose_scale(c) / HIDE_SCALE.x)
