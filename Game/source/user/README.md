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
