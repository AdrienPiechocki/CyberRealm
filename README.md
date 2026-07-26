# Wayland-Godot — GDExtension compositeur Wayland

## Build

```bash
# Dépendances (Arch Linux)
sudo pacman -S wlroots0.18 wayland wayland-protocols pixman libdrm \
               libinput xkbcommon scons pkgconf

# godot-cpp en submodule
git submodule update --init --recursive
# ou, hors dépôt git :
git clone --branch 4.3 --depth 1 https://github.com/godotengine/godot-cpp.git

scons platform=linux target=template_debug
```

La bibliothèque compilée atterrit dans `demo/bin/`, référencée par
`demo/bin/plasmacraft.gdextension`. Ouvrez `demo/` comme projet Godot 4.2+
pour tester `wayland_room.gd`.
