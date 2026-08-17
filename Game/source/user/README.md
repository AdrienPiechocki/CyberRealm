# Niveaux personnalisés

Ce dossier est réservé à **vos** assets et à **votre** niveau. Tout ce qui s'y
trouve est ignoré par git et remplace le niveau par défaut du jeu au démarrage.

## Créer son niveau

1. Placez vos assets (`.glb`, `.fbx`, `.png`, …) dans `res://user/assets/`.
2. Ouvrez le projet dans l'éditeur Godot 4.7 : les assets sont importés
   automatiquement.
3. Créez votre scène :
   - soit copiez `res://scenes/level.tscn` vers `res://user/level.tscn` et
	 modifiez-la (déplacez les murs, ajoutez vos assets),
   - soit créez une nouvelle scène 3D dans `res://user/` et enregistrez-la sous
	 le nom exact `level.tscn`.
4. Lancez le jeu : s'il trouve `res://user/level.tscn`, il le charge à la place
   du niveau par défaut. Sinon, il utilise `res://scenes/level.tscn`.

## Règles

- Le fichier doit s'appeler **exactement** `res://user/level.tscn`.
- Le nœud racine peut être n'importe quel `Node3D` (le jeu l'instancie comme
  enfant de la scène `WaylandRoom`).
- La scène doit contenir un joueur. Utilisez celui dans `res://scenes/player.tscn`.
- Le joueur est téléporté à son spawn s'il va en dessous de la valeur de MAX_DEPTH en Y
  (MAX_DEPTH est modifiable depuis le script du joueur) au cas où le joueur tombe sous la map.
- Les fenêtres Wayland des apps se placent où vous voulez ; seuls les objets
  avec une collision sont traversables (utilisez `StaticBody3D`/`CSGShape3D`
  pour les murs, comme dans le niveau d'exemple).

## Revenir au niveau par défaut

Supprimez (ou renommez) `res://user/level.tscn`. Le jeu utilisera alors
`res://scenes/level.tscn`.

## Multijoueur LAN

Votre niveau custom est **jouable en LAN même avec des builds différents** :
l'hôte sérialise son niveau en un blob binaire auto-suffisant (meshes,
matériaux et textures embarqués) et l'envoie aux joueurs qui rejoignent.
Les clients n'ont donc pas besoin de `res://user/` sur leur machine.

Limites à connaître :

- **Pas de scripts custom** : les meshes/matériaux/textures des maps sont
  embarqués dans le blob, mais les **scripts** ne le sont pas. Une map LAN ne
  doit pas attacher de scripts situés dans `res://user/` (les scripts du jeu,
  `res://scripts/`, fonctionnent normalement).
- Les nodes ajoutés **à la volée pendant la partie** (sous le niveau, sans
  `owner`) ne sont pas transmis — uniquement le contenu de la scène.
- Le **joueur** (`Player`) n'est pas transmis : chaque machine garde son
  propre joueur, le spawn de l'hôte est appliqué côté client.
- Le niveau est envoyé quand un joueur rejoint. Si vous changez de niveau,
  les prochains arrivants recevront le nouveau.
- Grosses maps : le blob est compressé (ZSTD) et envoyé en chunks, mais un
  niveau très lourd (plusieurs centaines de Mo d'assets) mettra du temps à
  charger côté client.
