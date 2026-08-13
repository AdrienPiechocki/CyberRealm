#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
GAME="$SCRIPT_DIR/Game/build/CyberRealm.x86_64"

sudo pacman -S --needed wlroots0.19 wayland wayland-protocols pixman libdrm xwayland-satellite \
               libinput scons pkgconf meson ninja vulkan-headers vulkan-icd-loader xdg-desktop-portal-wlr

if [[ ! -d "$SCRIPT_DIR/godot-cpp" ]]; then
    git clone https://github.com/godotengine/godot-cpp.git
fi

scons target=template_debug platform=linux
scons target=template_release platform=linux

# --- xdg-desktop-portal-wlr (build customisé) ------------------------------
# Clone le vrai xdg-desktop-portal-wlr (tag v0.8.2) puis écrase les fichiers
# customisés par ceux de compositors/portal-wlr (capture fenêtre via
# ext_foreign_toplevel + sélecteur interactif cyberrealm-capture-pending /
# cyberrealm-capture-choice). Compilation meson/ninja dans build/portal-src,
# install dans build/portal : le jeu lance ce binaire (launch_portals dans
# wlr_compositor.cpp pointe vers build/portal/libexec/xdg-desktop-portal-wlr).
PORTAL_SRC="$SCRIPT_DIR/build/portal-src"
PORTAL_PREFIX="$SCRIPT_DIR/build/portal"
if [[ ! -d "$PORTAL_SRC" ]]; then
    git clone --branch v0.8.2 --depth 1 https://github.com/emersion/xdg-desktop-portal-wlr.git "$PORTAL_SRC"
fi
cp "$SCRIPT_DIR/compositors/portal-wlr/include/screencast_common.h" "$PORTAL_SRC/include/"
cp "$SCRIPT_DIR/compositors/portal-wlr/include/wlr_screencast.h" "$PORTAL_SRC/include/"
cp "$SCRIPT_DIR/compositors/portal-wlr/include/ext_image_copy.h" "$PORTAL_SRC/include/"
cp "$SCRIPT_DIR/compositors/portal-wlr/src/core/main.c" "$PORTAL_SRC/src/core/"
cp "$SCRIPT_DIR/compositors/portal-wlr/src/core/request.c" "$PORTAL_SRC/src/core/"
cp "$SCRIPT_DIR/compositors/portal-wlr/src/core/session.c" "$PORTAL_SRC/src/core/"
cp "$SCRIPT_DIR/compositors/portal-wlr/src/screencast/chooser.c" "$PORTAL_SRC/src/screencast/"
cp "$SCRIPT_DIR/compositors/portal-wlr/src/screencast/ext_image_copy.c" "$PORTAL_SRC/src/screencast/"
cp "$SCRIPT_DIR/compositors/portal-wlr/src/screencast/pipewire_screencast.c" "$PORTAL_SRC/src/screencast/"
cp "$SCRIPT_DIR/compositors/portal-wlr/src/screencast/screencast.c" "$PORTAL_SRC/src/screencast/"
cp "$SCRIPT_DIR/compositors/portal-wlr/src/screencast/wlr_screencast.c" "$PORTAL_SRC/src/screencast/"
if [[ ! -f "$PORTAL_SRC/build/build.ninja" ]]; then
    meson setup "$PORTAL_SRC/build" "$PORTAL_SRC" --buildtype release --prefix "$PORTAL_PREFIX"
else
    meson setup --reconfigure "$PORTAL_SRC/build" "$PORTAL_SRC" --buildtype release --prefix "$PORTAL_PREFIX"
fi
ninja -C "$PORTAL_SRC/build"
meson install -C "$PORTAL_SRC/build"

# --- Export du jeu Godot ---------------------------------------------------
# L'extension GDExtension (libwaylandgodot) est déjà compilée par scons
# ci-dessus ; on exporte ensuite le projet (preset "Linux" de
# export_presets.cfg) vers Game/build/CyberRealm.x86_64.
echo "install: export du jeu (godot --headless) ..."
godot --headless --path "$SCRIPT_DIR/Game/source" --export-release "Linux" "$GAME"
if [[ ! -x "$GAME" ]]; then
    echo "install: échec de l'export Godot, binaire absent : $GAME" >&2
    exit 1
fi

# --- Script KWin -----------------------------------------------------------
# Remplace la session dwl : le jeu se lance depuis Plasma (menu applications
# ou bureau). Ce script KWin passe sa fenêtre en plein écran + focus et bloque
# les raccourcis globaux KDE tant que le jeu détient le focus.
KWIN_SRC="$SCRIPT_DIR/compositors/kwin/cyberrealm.kwinscript"
if command -v kpackagetool6 >/dev/null 2>&1; then
    if ! kpackagetool6 -t KWin/Script -i "$KWIN_SRC" >/dev/null 2>&1; then
        kpackagetool6 -t KWin/Script -u "$KWIN_SRC" >/dev/null
    fi
else
    # Fallback manuel (kpackagetool6 absent)
    KWIN_DST="$HOME/.local/share/kwin/scripts/cyberrealm"
    mkdir -p "$KWIN_DST/contents/code"
    install -m644 "$KWIN_SRC/metadata.json" "$KWIN_DST/metadata.json"
    install -m644 "$KWIN_SRC/contents/code/main.js" "$KWIN_DST/contents/code/main.js"
fi

kwriteconfig6 --file kwinrc --group Plugins --key cyberrealmEnabled true
# reconfigure ne recharge PAS le code du script : il faut le décharger d'abord,
# sinon une mise à jour de main.js n'est jamais prise en compte.
if qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.isScriptLoaded cyberrealm 2>/dev/null; then
    qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript cyberrealm 2>/dev/null || true
    sleep 1
fi
qdbus6 org.kde.KWin /KWin reconfigure 2>/dev/null || true

# --- Wrapper de lancement d'apps dans le jeu -------------------------------
# cyberrealm-launch <cmd> : redirige une commande vers le compositeur du jeu
# (socket cyberrealm-0) quand celui-ci est actif. Utilisez-le dans les .desktop
# pour lancer des apps dans les quads 3D depuis Plasma.
install -Dm755 "$SCRIPT_DIR/compositors/kwin/cyberrealm-launch" "$HOME/.local/bin/cyberrealm-launch"

# --- Lanceur .desktop du jeu ----------------------------------------------
mkdir -p "$HOME/.local/share/applications"
cat > "$HOME/.local/share/applications/cyberrealm.desktop" <<EOF
[Desktop Entry]
Name=CyberRealm
Comment=Open CyberRealm (3D evironment desktop)
Exec=$GAME
Type=Application
Categories=Game;
StartupNotify=false
EOF
