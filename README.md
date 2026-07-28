# Wayland-Godot — GDExtension compositeur Wayland

Un compositeur Wayland complet implémenté comme GDExtension Godot 4, utilisant
wlroots 0.18 en backend. Les fenêtres Wayland sont rendues en 3D dans une scène
Godot avec gestion complète du clavier, de la souris, des popups, et d'un mode
focus plein écran.

## Build

```bash
# Dépendances (Arch Linux)
sudo pacman -S wlroots0.18 wayland wayland-protocols pixman libdrm \
               libinput xkbcommon scons pkgconf

# godot-cpp en submodule
git submodule update --init --recursive

scons platform=linux target=template_debug
```

La bibliothèque compilée atterrit dans `demo/bin/`. Ouvrez `demo/` comme projet
Godot 4.2+ pour tester `wayland_room.gd`.

---

## Protocoles Wayland supportés

| Protocole | Description |
|---|---|
| `wl_compositor` (v6) | Gestion des surfaces |
| `wl_seat` | Abstraction périphériques d'entrée (pointeur + clavier) |
| `wl_data_device_manager` | Presse-papiers / drag-and-drop |
| `wl_primary_selection_v1` | Sélection primaire (clic-milieu) |
| `wl_subcompositor` | Sous-surfaces (requis pour Firefox WebRender) |
| `wl_viewporter` | Viewport/cropping de surfaces |
| `linux_dmabuf_v1` (v4) | Partage de buffers DMA-BUF (clients GPU) |
| `xdg_shell` (v3) | Fenêtres toplevel + popups (dont popups imbriquées) |
| `zwp_pointer_constraints_v1` | Verrouillage/confinement du pointeur (jeux FPS) |
| `zwp_relative_pointer_v1` | Événements de mouvement relatif (jeux FPS) |

---

## Pipeline de rendu (3 niveaux, auto-négocié)

### 1. Vulkan Zero-Copy (préféré)
- wlroots rend via EGL/GLES2 vers un buffer offscreen DMA-BUF
- Le fd DMA-BUF est importé dans le Vulkan de Godot via `VK_KHR_external_memory_fd`
- Crée un `VkImage` (tiling LINEAR) + `VkDeviceMemory` liés au DMA-BUF importé
- Wrappé en RID Godot via `texture_create_from_extension`, puis en `Texture2DRD`
- **Aucun mmap, aucun memcpy** — la texture est directement un VkImage échantillonné par le shader
- Synchronisation GPU cross-API via `DMA_BUF_IOCTL_EXPORT_SYNC_FILE` (Linux 5.20+) avec fallback `DMA_BUF_IOCTL_SYNC`
- Destruction différée des ressources (une frame en retard)

### 2. DMA-BUF + mmap (fallback)
- Rendu GPU vers buffer offscreen DMA-BUF (GLES2/GBM allocator)
- Vérification du modifier linéaire pour mmap
- Export des attributs DMA-BUF, mmap du fd pour accès CPU direct
- Copie pixel par pixel avec swizzle BGRA→RGBA si nécessaire
- Préfère ABGR8888 (RGBA en mémoire) pour éviter le swizzle

### 3. Pixman CPU (dernier recours)
- Rendu logiciel via Pixman
- `wlr_buffer_begin_data_ptr_access` pour accès direct aux pixels
- Swizzle BGRA→RGBA sur chaque pixel

### Optimisations
- **CaptureCache** — Buffer offscreen, mmap et tampon CPU réutilisés entre frames
- **Allocation arrondie** — Dimensions arrondies par pas de 64px pour éviter les reallocations pendant le resize
- **Timing détaillé** — Logs de performance par étape quand le total dépasse 2ms

---

## Gestion des fenêtres

### Fenêtres toplevel
- Spawn face à la caméra à la position du joueur
- Taille par défaut 1280×720
- Cycle de vie complet : map/unmap/destroy avec signaux
- Tracking de la fenêtre active (recapture à chaque frame)
- Géométrie de contenu honorée (`xdg_surface.set_window_geometry`) — les ombres CSD sont exclues
- Traverse les sous-surfaces (`wlr_surface_for_each_surface`)

### Popups
- Hiérarchie parent→enfant (dont popups de popup pour sous-menus)
- Placement relatif au parent avec contrainte de bounds
- Détection de région d'input (menus = oui, tooltips = non)
- Recapture toutes les 2 frames (~30Hz) pour les sous-surfaces désynchronisées

### Shader de rendu
- Unshaded, blend_mix, cull_disabled
- Remapping UV pour allocation arrondie
- Dépréfixage alpha (`rgb / alpha`)
- Correction gamma linéaire→sRGB (`pow(rgb, 2.2)`)
- Seuil d'alpha avec discard

---

## Input

### Clavier
- Clavier virtuel software (`wlr_keyboard` avec XKB layout `fr`)
- Table de traduction complète Godot→evdev (75+ touches)
- Correction AZERTY pour `<` et `>`
- Focus clavier sur clic + activation de la fenêtre

### Pointeur
- Mouvement absolu avec auto-enter/motion/frame
- Boutons souris (gauche, droite) et axis (scroll vertical + horizontal)
- Mouvement relatif via `zwp_relative_pointer_v1`
- Verrouillage du pointeur via `zwp_pointer_constraints_v1` (LOCKED et CONFINED)
- Signal `pointer_lock_changed(window_id, locked)` émis à l'activation/destruction

### Interaction 3D (scene Godot)
- Raycast physique de la caméra vers les quads 3D
- Calcul UV à partir de la position du hit
- Déplacement de fenêtre (middle-click drag + titlebar drag)
- Redimensionnement par les bords/corners (détection de zone, 8 directions)
- Ajustement de profondeur au scroll pendant le déplacement

---

## Mode Focus

- Touche **F** pour entrer/sortir du mode focus sur une fenêtre visée
- Affichage plein écran via `TextureRect` avec `STRETCH_KEEP_ASPECT_CENTERED`
- **Mapping pixel-perfect** : calcul d'aspect ratio basé sur `get_global_rect()` du TextureRect
- **Bouton X** en haut à droite pour quitter le mode focus
- **Souris capturée** automatiquement quand le client demande le pointer lock (jeux FPS)
  - Tracking UV par accumulation de `event.relative` en mode capturé
  - Forward de `forward_pointer_relative_motion` au client Wayland
  - Maintien du pointer focus pour livraison des events relatifs
- **Input forward** en mode focus :
  - Mouvement souris (absolu ou relatif selon l'état de capture)
  - Clic gauche/droit, scroll haut/bas
  - Tous les événements clavier (dont corrections AZERTY)
- Sortie auto si la fenêtre est unmapée

---

## Launcher Menu

- Parsing des fichiers `.desktop` depuis :
  - `/usr/share/applications`
  - `/usr/local/share/applications`
  - `~/.local/share/applications`
  - Tous les répertoires de `$XDG_DATA_DIRS`
- **Déduplication** par ligne `Exec`
- **10 catégories** triées par ordre canonique (AudioVideo, Development, Education, Game, Graphics, Network, Office, Settings, System, Utility + Other)
- **En-têtes de catégories collapsibles** avec compteur
- **Recherche en temps réel** filtrant sur toutes les catégories
- **Détection automatique d'émulateur de terminal** (konsole, alacritty, kitty, xterm) — les apps `Terminal=true` sont wrappées avec `-e`
- Nettoyage des codes de champ `.desktop` (%f, %F, %u, %U, etc.)
- Thème dark avec effets hover/press

---

## Application Launcher

- `launch_app(command)` — fork + setsid + execl("/bin/sh", "-c", command)
- Lancement automatique de `xwayland-satellite :1` au démarrage
- Variable `WAYLAND_DISPLAY` définie automatiquement

---

## Player (contrôleur FPS)

- `CharacterBody3D` avec gravité, WASD, saut
- Souris capturée avec sensibilité (0.002) et clamp vertical (±80°)
- Toggle souris : Escape affiche, clic recapture
- Respawn si chute sous y=-50

---

## Signaux GDExtension

| Signal | Paramètres | Description |
|---|---|---|
| `window_mapped` | id, title, app_id | Nouvelle fenêtre toplevel |
| `window_unmapped` | id | Fenêtre toplevel fermée |
| `window_texture_updated` | id, texture, width, height | Contenu de la fenêtre re-rendu |
| `popup_mapped` | id, parent_window_id, parent_popup_id, x, y, width, height | Popup apparue |
| `popup_unmapped` | id | Popup fermée |
| `popup_texture_updated` | id, texture, width, height | Contenu du popup re-rendu |
| `pointer_lock_changed` | window_id, locked | Verrouillage du pointeur activé/désactivé |
