#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
GAME="$SCRIPT_DIR/Game/build/CyberRealm.x86_64"

sudo pacman -S --needed wlroots0.19 wayland wayland-protocols pixman libdrm xwayland-satellite \
               libinput scons pkgconf vulkan-headers vulkan-icd-loader

if [[ ! -d "$SCRIPT_DIR/godot-cpp" ]]; then
    git clone https://github.com/godotengine/godot-cpp.git
fi

scons target=template_debug platform=linux
scons target=template_release platform=linux

if [[ ! -d "$SCRIPT_DIR/compositors/dwl" ]]; then
    git clone https://codeberg.org/dwl/dwl.git "$SCRIPT_DIR/compositors/dwl"
fi

cd $SCRIPT_DIR/compositors/dwl
cat > "$SCRIPT_DIR/compositors/dwl/dwl.desktop" <<EOF
[Desktop Entry]
Name=CyberRealm
Comment=Launch CyberRealm via dwl
Exec=dwl -s $GAME
Type=Application
EOF

if [[ -f "$SCRIPT_DIR/compositors/dwl/config.h" ]]; then
    rm config.h
fi

sudo make clean install
