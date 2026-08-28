#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
GAME="$SCRIPT_DIR/Game/build/CyberRealm.x86_64"

sudo pacman -S --needed base-devel godot wayland wayland-protocols pixman libdrm xwayland-satellite \
               libinput scons pkgconf meson ninja vulkan-headers vulkan-icd-loader xdg-desktop-portal-wlr \
               ffmpeg libva-mesa-driver libva libx11 openssh rsync

# wlroots 0.19 is no longer in the official Arch repos (removed in favor of
# wlroots 0.20) while the game's compositor is written against its API. If
# pkg-config cannot find it, build the AUR package wlroots0.19 (0.19.3) with
# makepkg and install it with pacman -U.
if ! pkg-config --exists wlroots-0.19; then
    echo "install: wlroots-0.19 missing from official repos — building from AUR ..."
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

# --- xdg-desktop-portal-wlr (custom build) ------------------------------
# Clone the real xdg-desktop-portal-wlr (tag v0.8.2) and overwrite the custom
# files with those from compositors/portal-wlr (window capture via
# ext_foreign_toplevel + interactive selector cyberrealm-capture-pending /
# cyberrealm-capture-choice). meson/ninja build into build/portal-src, install
# into build/portal: the game launches that binary (launch_portals in
# wlr_compositor.cpp points to build/portal/libexec/xdg-desktop-portal-wlr).
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

# --- Godot export template (Linux) ------------------------------------------
# The `godot` package from Arch provides the editor but NOT the export
# templates, and `godot-export-templates` is not in the official repos. We
# therefore build the Linux template from the godot sources at the exact
# version of the installed editor, and install it into the export_templates
# directory that `godot --export-release` looks for
# (~/.local/share/godot/export_templates/).
GODOT_TAG="4.7.2-stable"
GODOT_VER="4.7.2.stable"
TEMPLATES_DIR="$HOME/.local/share/godot/export_templates/$GODOT_VER"
if [[ ! -f "$TEMPLATES_DIR/linux_release.x86_64" ]]; then
    echo "install: building Linux Godot $GODOT_VER template (scons platform=linuxbsd target=template_release) ..."
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
    echo "install: Linux Godot $GODOT_VER template already present, nothing to do."
fi

# --- Godot game export ------------------------------------------------------
# The GDExtension (libwaylandgodot) is already built by scons above; then we
# export the project (preset "Linux" of export_presets.cfg) to
# Game/build/CyberRealm.x86_64.
echo "install: exporting the game (godot --headless) ..."
mkdir -p Game/build
godot --headless --path "$SCRIPT_DIR/Game/source" --export-release "Linux" "$GAME"
if [[ ! -x "$GAME" ]]; then
    echo "install: Godot export failed, binary missing: $GAME" >&2
    exit 1
fi

# --- KWin script -----------------------------------------------------------
# Replaces the dwl session: the game is launched from Plasma (applications menu
# or desktop). This KWin script puts its window fullscreen + focus and blocks
# KDE global shortcuts while the game holds focus.
KWIN_SRC="$SCRIPT_DIR/compositors/kwin/cyberrealm.kwinscript"
if command -v kpackagetool6 >/dev/null 2>&1; then
    if ! kpackagetool6 -t KWin/Script -i "$KWIN_SRC" >/dev/null 2>&1; then
        kpackagetool6 -t KWin/Script -u "$KWIN_SRC" >/dev/null
    fi
else
    # Manual fallback (kpackagetool6 missing)
    KWIN_DST="$HOME/.local/share/kwin/scripts/cyberrealm"
    mkdir -p "$KWIN_DST/contents/code"
    install -m644 "$KWIN_SRC/metadata.json" "$KWIN_DST/metadata.json"
    install -m644 "$KWIN_SRC/contents/code/main.js" "$KWIN_DST/contents/code/main.js"
fi

kwriteconfig6 --file kwinrc --group Plugins --key cyberrealmEnabled true
# reconfigure does NOT reload the script code: you must unload it first,
# otherwise a main.js update is never taken into account.
if qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.isScriptLoaded cyberrealm 2>/dev/null; then
    qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript cyberrealm 2>/dev/null || true
    sleep 1
fi
qdbus6 org.kde.KWin /KWin reconfigure 2>/dev/null || true

# --- App launch wrapper inside the game -------------------------------------
# cyberrealm-launch <cmd>: redirects a command to the game's compositor
# (cyberrealm-0 socket) while it is active. Use it in .desktop entries to
# launch apps inside the 3D quads from Plasma.
install -Dm755 "$SCRIPT_DIR/compositors/kwin/cyberrealm-launch" "$HOME/.local/bin/cyberrealm-launch"

# --- Game launcher (cyberrealm-run) -----------------------------------------
# Launches the game in a systemd scope (cgroup) then kills the whole cgroup
# when the game exits (crash, SIGKILL, normal close...): no daemon launched
# inside the game survives its shutdown. Also installs the .desktop on top.
install -Dm755 "$SCRIPT_DIR/compositors/kwin/cyberrealm-run" "$HOME/.local/bin/cyberrealm-run"

# --- Runtime commands (cyberrealm-exec) -------------------------------------
# Executes commands on the game at runtime via file IPC.
# Usage: cyberrealm-exec launch firefox
#        cyberrealm-exec windows
install -Dm755 "$SCRIPT_DIR/compositors/kwin/cyberrealm-exec" "$HOME/.local/bin/cyberrealm-exec"

# --- Game .desktop launcher ------------------------------------------------
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
# For UDP ports 7777/9999 (LAN multiplayer) and TCP 22 (drag & drop,
# rsync-over-ssh). Detect the active firewall backend for portability across
# distributions (ufw, firewalld, nftables, iptables).
firewall_open() {
    local proto="$1" port="$2"
    if command -v ufw >/dev/null 2>&1 && sudo ufw status >/dev/null 2>&1; then
        sudo ufw allow "$port/$proto"
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        sudo firewall-cmd --permanent --add-port="$port/$proto"
    elif command -v nft >/dev/null 2>&1 && sudo nft list ruleset >/dev/null 2>&1; then
        # Non-destructive add if an identical rule is already present.
        sudo nft add rule inet filter input tcp dport "$port" accept 2>/dev/null || true
        sudo nft add rule inet filter input udp dport "$port" accept 2>/dev/null || true
    elif command -v iptables >/dev/null 2>&1; then
        sudo iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null \
            || sudo iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
        sudo iptables -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null \
            || sudo iptables -I INPUT -p udp --dport "$port" -j ACCEPT
    else
        echo "install: no firewall backend detected (ufw/firewalld/nft/iptables)."
        echo "          Manually open UDP ports 7777 & 9999 and TCP 22."
    fi
}
firewall_open udp 7777
firewall_open udp 9999
firewall_open tcp 22

# Applicability: firewalld/nft/iptables are permanent for this session but may
# not survive a reboot depending on the config; for persistent effect, prefer
# ufw (active) or the firewalld config.

# --- File sharing (drag & drop) ---------------------------------------------
# openssh + rsync are installed above. Receiving files additionally requires
# the recipient's ssh daemon: we do NOT enable it automatically (a security
# decision for each machine), just a reminder.
if ! systemctl is-active --quiet sshd && ! systemctl is-enabled --quiet sshd; then
    echo "install: sshd inactive — to RECEIVE files via drag & drop:"
    echo "          sudo systemctl enable --now sshd"
fi
