#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
GAME="$SCRIPT_DIR/Game/build/CyberRealm.x86_64"

sudo pacman -S --needed base-devel godot wayland wayland-protocols pixman libdrm xwayland-satellite \
               libinput scons pkgconf meson ninja vulkan-headers vulkan-icd-loader xdg-desktop-portal-wlr \
               ffmpeg libva-mesa-driver libva libx11

# wlroots 0.19 n'est plus dans les dépôts officiels d'Arch (retiré au profit de
# wlroots0.20) alors que le compositeur du jeu est codé contre son API. Si
# pkg-config ne le trouve pas, on compile le paquet AUR wlroots0.19 (0.19.3)
# avec makepkg puis on l'installe avec pacman -U.
if ! pkg-config --exists wlroots-0.19; then
    echo "install: wlroots-0.19 absent des dépôts officiels — build depuis AUR ..."
    WLR_AUR="$(mktemp -d)"
    git clone --depth 1 https://aur.archlinux.org/wlroots0.19.git "$WLR_AUR/wlroots0.19"
    (cd "$WLR_AUR/wlroots0.19" && makepkg -s --noconfirm)
    sudo pacman -U --noconfirm "$WLR_AUR"/wlroots0.19/wlroots0.19-*.pkg.tar.zst
    rm -rf "$WLR_AUR"
fi

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

# --- Template d'export Godot (Linux) ---------------------------------------
# Le paquet `godot` d'Arch fournit l'éditeur mais PAS les templates d'export,
# et `godot-export-templates` n'est pas dans les dépôts officiels. On compile
# donc le template Linux depuis les sources godot, à la version exacte de
# l'éditeur installé, et on l'installe dans le dossier export_templates que
# `godot --export-release` cherche (~/.local/share/godot/export_templates/).
GODOT_TAG="4.7.2-stable"
GODOT_VER="4.7.2.stable"
TEMPLATES_DIR="$HOME/.local/share/godot/export_templates/$GODOT_VER"
if [[ ! -f "$TEMPLATES_DIR/linux_release.x86_64" ]]; then
    echo "install: build du template Linux Godot $GODOT_VER (scons platform=linuxbsd target=template_release) ..."
    GODOT_SRC="$SCRIPT_DIR/build/godot-src"
    if [[ ! -d "$GODOT_SRC" ]]; then
        git clone --depth 1 --branch "$GODOT_TAG" https://github.com/godotengine/godot.git "$GODOT_SRC"
    else
        (cd "$GODOT_SRC" && git fetch --depth 1 origin tag "$GODOT_TAG" && git checkout "$GODOT_TAG")
    fi
    (cd "$GODOT_SRC" && scons -j"$(nproc)" platform=linuxbsd target=template_release)
    mkdir -p "$TEMPLATES_DIR"
    install -m644 "$GODOT_SRC/bin/godot.linuxbsd.template_release.x86_64" "$TEMPLATES_DIR/linux_release.x86_64"
    install -m644 "$GODOT_SRC/bin/godot.linuxbsd.template_release.x86_64" "$TEMPLATES_DIR/linux_debug.x86_64"
else
    echo "install: template Linux Godot $GODOT_VER déjà présent, rien à faire."
fi

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

# --- Lanceur du jeu (cyberrealm-run) ---------------------------------------
# Lance le jeu dans un scope systemd (cgroup) puis tue tout le cgroup quand le
# jeu se ferme (crash, SIGKILL, fermeture normale…) : aucun daemon lancé dans
# le jeu ne survit à sa fermeture. Installe aussi le .desktop dessus.
install -Dm755 "$SCRIPT_DIR/compositors/kwin/cyberrealm-run" "$HOME/.local/bin/cyberrealm-run"

# --- Lanceur .desktop du jeu ----------------------------------------------
mkdir -p "$HOME/.local/share/applications"
cat > "$HOME/.local/share/applications/cyberrealm.desktop" <<EOF
[Desktop Entry]
Name=CyberRealm
Comment=Open CyberRealm (3D environment desktop)
Exec=$HOME/.local/bin/cyberrealm-run "$GAME"
Type=Application
Categories=Game;
StartupNotify=false
EOF

# for multiplayer
sudo ufw allow 7777/udp
sudo ufw allow 9999/udp
