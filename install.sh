#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
GAME="$SCRIPT_DIR/Game/build/CyberRealm.x86_64"

sudo pacman -S --needed wlroots0.19 wayland wayland-protocols pixman libdrm xwayland-satellite \
               libinput scons pkgconf vulkan-headers vulkan-icd-loader xdg-desktop-portal-wlr

if [[ ! -d "$SCRIPT_DIR/godot-cpp" ]]; then
    git clone https://github.com/godotengine/godot-cpp.git
fi

scons target=template_debug platform=linux
scons target=template_release platform=linux

if [[ ! -d "$SCRIPT_DIR/compositors/dwl" ]]; then
    git clone https://codeberg.org/dwl/dwl.git "$SCRIPT_DIR/compositors/dwl"
fi

# Patch CyberRealm: redirige les apps lancées depuis les raccourcis dwl vers
# le compositeur du jeu (socket "cyberrealm-0") quand celui-ci est actif.
if [[ -f "$SCRIPT_DIR/compositors/dwl_custom/dwl.c" ]]; then
    cp "$SCRIPT_DIR/compositors/dwl_custom/dwl.c" "$SCRIPT_DIR/compositors/dwl/dwl.c"
fi

# Script de session: lance dwl puis le jeu, et termine dwl quand le jeu sort.
# Le .desktop pointe dessus (chemin unique sans espace) car plasmalogin
# exécute la ligne Exec via `exec $@` NON quoté dans wayland-session : une
# commande avec des espaces/guillemets y est découpée en plusieurs argv, ce
# qui fait planter getopt de dwl (écran gris figé, session morte).
if [[ -f "$SCRIPT_DIR/compositors/dwl_custom/dwl-session.sh" ]]; then
    cp "$SCRIPT_DIR/compositors/dwl_custom/dwl-session.sh" "$SCRIPT_DIR/compositors/dwl/dwl-session.sh"
    chmod +x "$SCRIPT_DIR/compositors/dwl/dwl-session.sh"
fi

cd $SCRIPT_DIR/compositors/dwl
cat > "$SCRIPT_DIR/compositors/dwl/dwl.desktop" <<EOF
[Desktop Entry]
Name=CyberRealm
Comment=Launch CyberRealm via dwl
Exec=$SCRIPT_DIR/compositors/dwl/dwl-session.sh
Type=Application
EOF

if [[ -f "$SCRIPT_DIR/compositors/dwl/config.h" ]]; then
    rm config.h
fi

sudo make clean install
