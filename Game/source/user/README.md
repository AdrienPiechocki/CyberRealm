# Personnalisation

Ce dossier est réservé à **vos** assets, **votre** niveau et **votre** avatar.
Tout ce qui s'y trouve est ignoré par git et remplace le contenu par défaut du
jeu au démarrage.

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

## Performance : occlusion culling

Pour les maps denses (intérieurs à pièces multiples), le jeu génère
**automatiquement** un occludeur basé sur la géométrie réelle du niveau au
chargement (boot, et aussi sur les maps reçues en LAN) : ce qui se trouve
derrière les murs et les gros objets n'est plus dessiné par le GPU. Une
arche ou une porte ne masque que là où il y a de la matière — pas
d'objets qui disparaissent à travers les ouvertures.

- Aucune action requise : la génération copie les triangles des meshes
  opaques (budget ~120 000 triangles, plus gros objets d'abord, ~20 ms).
- **Bake manuel possible** : si vous ajoutez vous-même un `OccluderInstance3D`
  baké dans l'éditeur (« Bake Occlusion »), il est respecté et la génération
  auto est sautée.
- Diagnostic : lancez le jeu avec `CYBERREALM_OCC_DEBUG=1` pour voir le
  volume d'occludeur généré.
- Fonctionne avec le rendu Forward+ (défaut du projet) ; sans effet en
  Compatibility.

## Performance : résolution 3D adaptative

Sur les GPU intégrés, le shading à pleine résolution peut saturer le GPU
même après occlusion culling. Le jeu abaisse alors automatiquement la
résolution interne du rendu 3D par paliers (1.0 → 0.5, upscale bilinéaire)
quand les FPS passent sous ~45 soutenus, et remonte au-dessus de ~58. Les
changements sont loggés (`[scaler]`).

- Désactivation : `CYBERREALM_ADAPTIVE_SCALE=0`.
- Diagnostic rendu complet (FPS, draw calls, primitives, VRAM, échelle) :
  `CYBERREALM_RENDER_DEBUG=1` — utile pour comparer deux machines.
- GPU intégrés très limites : essayer le rendu Mobile, moins coûteux en
  fillrate que Forward+ : `./cyberrealm --rendering-method mobile`.
- Utilisation GPU élevée : le projet plafonne à 120 FPS, un GPU rapide
  travaille donc en continu. `CYBERREALM_MAX_FPS=60` (ou 30) réduit la
  charge et les ventilateurs sans toucher au projet.

## Performance : captures de fenêtres adaptatives

Le compositeur recapture les fenêtres qui se redessinent (30/s, 60/s si
partagées en vidéo). Sur un GPU intégré, ces captures entrent en concurrence
avec le rendu du jeu : quand le temps de frame dépasse ~25 ms, la cadence
passe automatiquement à 10/s (puis 5/s sous ~25 ms), et remonte dès que le
GPU respire. Deux garde-fous supplémentaires : au plus 2 captures de fenêtres
non partagées par frame (les autres attendent la frame suivante), et l'attente
GPU de chaque capture est plafonnée à 4 ms sous pression au lieu de 25 ms.
Les changements sont loggés (`[capture] … pression N`).

- Forcer la cadence normale (diagnostic) : `CYBERREALM_CAPTURE_UNTHROTTLED=1`.

## Performance : partage vidéo en LAN

Partager une fenêtre mobilise côté hôte un thread d'encodage en continu
(lecture du DMA-BUF, conversion couleurs, encodage H.264/AV1) à 60 ips par
fenêtre. Le mode d'encodage est annoncé au démarrage du partage
(`video_share: démarré codec=… mode=…`) : « matériel (VAAPI) » utilise le bloc
vidéo du GPU, « LOGICIEL (libx264) » indique que VAAPI a échoué et que le CPU
encode — à surveiller sur les machines modestes.

- Réduire la charge hôte : `CYBERREALM_SHARE_FPS=30` (ou 20) divise le coût
  d'encodage et de capture d'autant ; 30 ips suffit pour la plupart des usages.

## Créer son avatar

1. Placez vos assets 3D (`.glb`, `.fbx`, …) dans `res://user/assets/`.
2. Copiez `res://scenes/avatar.tscn` vers `res://user/avatar.tscn` et
   modifiez-le, ou créez une nouvelle scène 3D.
3. **Le script `avatar.gd` doit être attaché** à la scène.
4. Ajoutez un nœud `Label3D` nommé **NameLabel** (mode billboard) pour le nom
   du joueur. Ajoutez vos meshes (`MeshInstance3D`) comme enfants.
5. Lancez le jeu : s'il trouve `res://user/avatar.tscn`, il l'utilise à la
   place de la scène par défaut.
6. En LAN, choisissez votre avatar dans le menu déroulant de la page
   **LAN Game** : tous les `avatar.tscn` du projet y sont listés (nommés
   d'après le nœud racine de chaque scène). Votre choix est mémorisé et
   l'avatar réel — meshes et animations embarqués — est envoyé aux autres
   joueurs.

### Règles avatar

- Convention : `res://user/avatar.tscn` est l'avatar « auto », utilisé sans
  toucher au menu LAN. Tout fichier nommé `avatar.tscn` ailleurs dans le
  projet apparaît aussi dans le menu déroulant LAN.
- **Script obligatoire** : attachez `res://scripts/avatar.gd` à la
  scène (le nœud racine ou un enfant).
- **NameLabel obligatoire** : un `Label3D` nommé `NameLabel` (billboard). S'il
  est absent, un label factice sera créé automatiquement à `Y = 1.8`.
- La couleur du joueur est appliquée automatiquement sur les meshes qui n'ont
  **pas** de matériau défini. Si vous créez un `StandardMaterial3D` avec vos
  propres textures sur un mesh dans l'éditeur, la couleur de joueur ne
  l'écrasera pas.
- La transparence de proximité (< 1 m) fonctionne sur tous les meshes de
  l'avatar, y compris les meshes texturés (leurs matériaux sont dupliqués
  automatiquement).
- Le nom du joueur (NameLabel) est visible à travers les murs.

## Revenir au niveau par défaut

Supprimez (ou renommez) `res://user/level.tscn`. Le jeu utilisera alors
`res://scenes/level.tscn`.

## Revenir à l'avatar par défaut

Supprimez (ou renommez) `res://user/avatar.tscn`. Le jeu utilisera alors la
capsule + casque par défaut (`res://scenes/avatar.tscn`).

## Multijoueur LAN

Votre niveau custom est **jouable en LAN même avec des builds différents** :
l'hôte sérialise son niveau en un blob binaire auto-suffisant (meshes,
matériaux et textures embarqués) et l'envoie aux joueurs qui rejoignent.
Les clients n'ont donc pas besoin de `res://user/` sur leur machine.

### Choisir son avatar en LAN

Dans la page **LAN Game** du menu pause, un menu déroulant liste tous les
`avatar.tscn` trouvés dans le projet (l'avatar par défaut en premier, puis
les customs par ordre de chemin). Chaque entrée porte le **nom du nœud
racine** de sa scène. Le choix — persisté entre les sessions — détermine la
scène bakée et envoyée aux autres joueurs : chacun voit votre vrai modèle
avec ses animations. Sans choix explicite, l'avatar « auto » est utilisé
(`res://user/avatar.tscn` s'il existe, sinon le défaut).

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
- **Le client charge la map AVANT d'entrer dans la partie** : après la
  connexion, il reçoit et applique le niveau de l'hôte en étant gelé et
  invisible des autres joueurs (progression affichée : « Loading host
  map… X% »). Il n'apparaît chez les autres qu'une fois la map chargée.
- Grosses maps : le blob est compressé (ZSTD) et envoyé en chunks, mais un
  niveau très lourd (plusieurs centaines de Mo d'assets) mettra du temps à
  charger côté client. Si le transfert est définitivement mort (aucun chunk
  pendant 15 s), le client entre quand même dans la partie sur sa map locale.
