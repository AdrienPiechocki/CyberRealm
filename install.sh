#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
GAME="$SCRIPT_DIR/Game/build/CyberRealm.x86_64"

# --- Options -------------------------------------------------------------
# --with-gnome / --without-gnome : override l'auto-détection (présence d'une
# session GNOME). Par défaut, l'extension GNOME et le template Godot patché
# (zwp_keyboard_shortcuts_inhibit_v1) ne sont gérés que si gnome-shell est
# installé.
GNOME_WANTED="auto"
for arg in "$@"; do
    case "$arg" in
        --with-gnome)   GNOME_WANTED="yes" ;;
        --without-gnome) GNOME_WANTED="no" ;;
    esac
done

GNOME_INSTALL=0
GNOME_AVAILABLE=0
if command -v gnome-shell >/dev/null 2>&1 || command -v gnome-extensions >/dev/null 2>&1; then
    GNOME_AVAILABLE=1
fi
case "$GNOME_WANTED" in
    yes) GNOME_INSTALL=1 ;;
    no)  GNOME_INSTALL=0 ;;
    auto) GNOME_INSTALL="$GNOME_AVAILABLE" ;;
esac

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

# -- Patch Godot (zwp_keyboard_shortcuts_inhibit_v1) --------------------------
# Sur GNOME, le blocage des raccourcis (Super, Alt+Tab, PrtScr…) pendant la
# partie exige que le jeu lui-même lie le protocole : on patche le driver
# Wayland de Godot (compositors/gnome/godot-4.7-shortcuts-inhibit.patch) et on
# reconstruit le template. Idempotent : ne reconstruit que si nécessaire et ne
# réapplique jamais deux fois.
GODOT_PATCH="$SCRIPT_DIR/compositors/gnome/godot-4.7-shortcuts-inhibit.patch"
GODOT_KSI_XML="/usr/share/wayland-protocols/unstable/keyboard-shortcuts-inhibit/keyboard-shortcuts-inhibit-unstable-v1.xml"
GODOT_KSI_DEST="thirdparty/wayland-protocols/unstable/keyboard-shortcuts-inhibit/keyboard-shortcuts-inhibit-unstable-v1.xml"
# Marqueur : le template installé vient-il réellement d'une source patchée ?
GODOT_PATCH_STAMP="$TEMPLATES_DIR/linux_release.x86_64.shortcuts-inhibit"

REBUILD_TEMPLATE=0
if [[ ! -f "$TEMPLATES_DIR/linux_release.x86_64" ]]; then
    REBUILD_TEMPLATE=1
elif [[ "$GNOME_INSTALL" -eq 1 ]] \
    && ( [[ ! -f "$GODOT_PATCH_STAMP" ]] || ! cmp -s "$GODOT_PATCH" "$GODOT_PATCH_STAMP" ); then
    # Session GNOME : le template doit embarquer le patch, sinon rien ne
    # bloque les raccourcis du compositeur.
    REBUILD_TEMPLATE=1
fi

if [[ "$REBUILD_TEMPLATE" -eq 1 ]]; then
    echo "install: building Linux Godot $GODOT_VER template (scons platform=linuxbsd target=template_release) ..."
    GODOT_SRC="$SCRIPT_DIR/build/godot-src"
    if [[ ! -d "$GODOT_SRC" ]]; then
        git clone --depth 1 --branch "$GODOT_TAG" https://github.com/godotengine/godot.git "$GODOT_SRC"
    else
        (cd "$GODOT_SRC" && git fetch --depth 1 origin tag "$GODOT_TAG" && git checkout "$GODOT_TAG")
    fi

    PATCH_OK=0
    if [[ -f "$GODOT_KSI_XML" ]]; then
        # Copie du XML du protocole dans l'arbre vendu (dépend de
        # wayland-protocols, déjà installé ci-dessus).
        mkdir -p "$(dirname "$GODOT_SRC/$GODOT_KSI_DEST")"
        cp "$GODOT_KSI_XML" "$GODOT_SRC/$GODOT_KSI_DEST"
        PATCH_OK=1
    else
        echo "install: $GODOT_KSI_XML introuvable (package wayland-protocols) — template non patché." >&2
    fi

    if [[ "$PATCH_OK" -eq 1 ]]; then
        if (cd "$GODOT_SRC" && git apply --check "$GODOT_PATCH" 2>/dev/null); then
            (cd "$GODOT_SRC" && git apply "$GODOT_PATCH")
        elif (cd "$GODOT_SRC" && git apply --reverse --check "$GODOT_PATCH" 2>/dev/null); then
            echo "install: patch godot déjà appliqué dans $GODOT_SRC"
        else
            echo "install: conflit de patch dans $GODOT_SRC (arbre localement modifié ?)" >&2
            exit 1
        fi
    fi

    (cd "$GODOT_SRC" && scons -j"$(nproc)" platform=linuxbsd target=template_release)
    mkdir -p "$TEMPLATES_DIR"
    install -m644 "$GODOT_SRC/bin/godot.linuxbsd.template_release.x86_64" "$TEMPLATES_DIR/linux_release.x86_64"
    install -m644 "$GODOT_SRC/bin/godot.linuxbsd.template_release.x86_64" "$TEMPLATES_DIR/linux_debug.x86_64"
    if [[ "$PATCH_OK" -eq 1 ]]; then
        cp "$GODOT_PATCH" "$GODOT_PATCH_STAMP"
    fi
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
install -Dm755 "$SCRIPT_DIR/compositors/cyberrealm-launch" "$HOME/.local/bin/cyberrealm-launch"

# --- Game launcher (cyberrealm-run) -----------------------------------------
# Launches the game in a systemd scope (cgroup) then kills the whole cgroup
# when the game exits (crash, SIGKILL, normal close...): no daemon launched
# inside the game survives its shutdown. Also installs the .desktop on top.
install -Dm755 "$SCRIPT_DIR/compositors/cyberrealm-run" "$HOME/.local/bin/cyberrealm-run"

# --- Runtime commands (cyberrealm-exec) -------------------------------------
# Executes commands on the game at runtime via file IPC.
# Usage: cyberrealm-exec launch firefox
#        cyberrealm-exec windows
install -Dm755 "$SCRIPT_DIR/compositors/cyberrealm-exec" "$HOME/.local/bin/cyberrealm-exec"

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

# --- GNOME Shell extension -----------------------------------------------------
# Ne s'installe que si une session GNOME est présente (ou --with-gnome). Usine
# à gaz volontairement minimale : l'extension ne fait que mettre la fenêtre du
# jeu en plein écran + focus. Le blocage réel des raccourcis (Super, Alt+Tab,
# PrtScr…) pendant la partie est assuré par le jeu lui-même via le driver
# Godot patché (zwp_keyboard_shortcuts_inhibit_v1), dont le template a été
# reconstruit ci-dessus.
GNOME_UUID="cyberrealm@cyberrealm.local"
if [[ "$GNOME_INSTALL" -eq 1 ]] && command -v gnome-extensions >/dev/null 2>&1; then
    GNOME_SRC="$SCRIPT_DIR/compositors/gnome/$GNOME_UUID"
    GNOME_DST="$HOME/.local/share/gnome-shell/extensions/$GNOME_UUID"
    echo "install: installing GNOME Shell extension $GNOME_UUID ..."
    mkdir -p "$GNOME_DST"
    install -m644 "$GNOME_SRC/metadata.json" "$GNOME_DST/metadata.json"
    install -m644 "$GNOME_SRC/extension.js" "$GNOME_DST/extension.js"
    install -m644 "$GNOME_SRC/prefs.js" "$GNOME_DST/prefs.js"
    cp -r "$GNOME_SRC/schemas" "$GNOME_DST/schemas"
    if command -v glib-compile-schemas >/dev/null 2>&1; then
        glib-compile-schemas "$GNOME_DST/schemas"
    fi
    gnome-extensions enable "$GNOME_UUID" >/dev/null 2>&1 || true
    echo "install: GNOME extension active after a shell restart (Alt+F2 → r, or logout)."
else
    echo "install: no GNOME session detected — GNOME extension and the Godot patch ignored (--with-gnome to force)."
fi

# --- Hyprland (config Lua) ---------------------------------------------------
# La règle de fenêtre (compositors/hyprland/cyberrealm.lua) reproduit le plein
# écran + focus permanent de l'extension GNOME / du script KWin. On la copie
# dans ~/.config/hypr puis, si elle n'y est pas déjà, on ajoute
# require("cyberrealm") à la config. Idempotent : ne modifie hyprland.lua que
# si l'include manque.
HYPR_RULE="$SCRIPT_DIR/compositors/hyprland/cyberrealm.lua"
HYPR_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hypr"
HYPR_CONFIG="$HYPR_DIR/hyprland.lua"
if [[ -f "$HYPR_CONFIG" ]]; then
    install -Dm644 "$HYPR_RULE" "$HYPR_DIR/cyberrealm.lua"
    if grep -q 'require("cyberrealm")' "$HYPR_CONFIG"; then
        echo "install: Hyprland — require(\"cyberrealm\") already in hyprland.lua."
    else
        printf '\nrequire("cyberrealm")\n' >> "$HYPR_CONFIG"
        echo "install: Hyprland — require(\"cyberrealm\") added to hyprland.lua."
    fi
    # Rechargement non bloquant si une session Hyprland tourne.
    if hyprctl reload >/dev/null 2>&1; then
        echo "install: Hyprland — configuration reloaded."
    fi
else
    # Aucune config : rien à modifier (Hyprland génère hyprland.lua au premier
    # démarrage ; relancer install.sh ensuite pour activer la règle).
    echo "install: no Hyprland config found ($HYPR_CONFIG)."
fi
