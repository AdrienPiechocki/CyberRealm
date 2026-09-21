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
ASSUME_YES=0
DO_PACKAGES=1
DO_FIREWALL=1
DO_KWIN=1
DO_GNOME_EXT=1
DO_HYPRLAND=1

usage() {
    cat <<'HELP'
Usage: ./install.sh [options]

Install CyberRealm on Arch, Debian/Ubuntu or Fedora/RHEL based distros.
Without --yes you are asked before each major step (system packages, GNOME
patch/template, KWin, firewalld ports, Hyprland config).

  --with-gnome        force the GNOME extension + patched Godot template
  --without-gnome     disable all GNOME-specific steps
  --yes               accept every default, never prompt
  --no-packages       skip the system dependency install
  --no-firewall       don't open firewall ports
  --no-kwin           skip the KWin integration
  --no-gnome-ext      skip the GNOME Shell extension
  --no-hyprland       skip the Hyprland config edit
  --help              show this help

Uninstall with ./uninstall.sh
HELP
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --with-gnome)    GNOME_WANTED="yes" ;;
        --without-gnome) GNOME_WANTED="no" ;;
        --yes)           ASSUME_YES=1 ;;
        --no-packages)   DO_PACKAGES=0 ;;
        --no-firewall)   DO_FIREWALL=0 ;;
        --no-kwin)       DO_KWIN=0 ;;
        --no-gnome-ext)  DO_GNOME_EXT=0 ;;
        --no-hyprland)   DO_HYPRLAND=0 ;;
        --help|-h)       usage; exit 0 ;;
        *)
            echo "install: unknown option: $1" >&2
            echo "          run './install.sh --help' for usage." >&2
            exit 1
            ;;
    esac
    shift
done

# --- Helpers --------------------------------------------------------------

if [[ $EUID -eq 0 ]]; then
    as_root() { "$@"; }
else
    as_root() { command sudo "$@"; }
fi

# Defaults to "yes" when there is no interactive terminal (piped runs).
confirm() {
    [[ "$ASSUME_YES" -eq 1 ]] && return 0
    [[ ! -t 0 ]] && return 0
    local ans
    while true; do
        printf '%s [Y/n] ' "$1"
        read -r ans
        case "$ans" in
            ""|y|Y|yes|YES|Yes) return 0 ;;
            n|N|no|NO|No) return 1 ;;
        esac
    done
}

# --- Distribution detection ------------------------------------------------
PKG_MGR=""
DISTRO_ID=""
DISTRO_ID_LIKE=""

detect_pkg_manager() {
    if [[ -r /etc/os-release ]]; then
        DISTRO_ID="$(. /etc/os-release && printf '%s' "${ID:-}")"
        DISTRO_ID_LIKE="$(. /etc/os-release && printf '%s' "${ID_LIKE:-}")"
    fi
    case "$DISTRO_ID $DISTRO_ID_LIKE" in
        *arch*)            PKG_MGR="pacman" ;;
        *debian*|*ubuntu*) PKG_MGR="apt" ;;
        *fedora*|*rhel*)   PKG_MGR="dnf" ;;
        *)
            echo "install: unsupported distribution (ID=$DISTRO_ID, ID_LIKE=$DISTRO_ID_LIKE)." >&2
            echo "          Supported families: Arch, Debian/Ubuntu, Fedora/RHEL." >&2
            exit 1
            ;;
    esac
    echo "install: detected $DISTRO_ID (${DISTRO_ID_LIKE:-none}) — using $PKG_MGR."
}

# --- System packages -------------------------------------------------------
install_system_packages() {
    local pkgs=()
    case "$PKG_MGR" in
        pacman)
            pkgs=(base-devel godot wayland wayland-protocols pixman libdrm xwayland-satellite \
                  libinput scons pkgconf meson ninja vulkan-headers vulkan-icd-loader \
                  xdg-desktop-portal-wlr ffmpeg libva-mesa-driver libva libx11 openssh rsync \
                  libxkbcommon pipewire opus mesa unzip)
            ;;
        apt)
            pkgs=(build-essential git unzip xwayland \
                  wayland-protocols libwayland-dev libwayland-bin libpixman-1-dev libdrm-dev \
                  libinput-dev scons pkg-config meson ninja-build libvulkan-dev mesa-vulkan-drivers \
                  ffmpeg libavcodec-dev libavutil-dev libswscale-dev libva-dev \
                  libx11-dev libxkbcommon-dev libpipewire-0.3-dev libspa-0.2-dev libopus-dev \
                  libgbm-dev libegl-dev libdbus-1-dev)
            ;;
        dnf)
            pkgs=(gcc-c++ make git unzip xwayland \
                  wayland-protocols-devel wayland-devel pixman-devel libdrm-devel \
                  libinput-devel scons pkgconf-pkg-config meson ninja-build vulkan-headers \
                  vulkan-loader-devel mesa-vulkan-drivers ffmpeg-free libavcodec-free-devel \
                  libavutil-free-devel libswscale-free-devel libva-devel \
                  libX11-devel libxkbcommon-devel pipewire-devel libspa-devel opus-devel \
                  mesa-libgbm-devel mesa-libEGL-devel dbus-devel)
            ;;
    esac
    echo "install: installing system packages via $PKG_MGR:"
    printf '          %s\n' "${pkgs[*]}" | fold -s -w 76 | sed 's/^/          /'
    case "$PKG_MGR" in
        pacman)
            # Install only what is genuinely missing. pacman -S --needed does
            # NOT protect against downgrades: a repo package whose version
            # differs from the installed one (e.g. a CachyOS-rebuilt pipewire)
            # gets "downgraded", which breaks reverse dependencies. Skipping
            # already-installed packages avoids that. base-devel is a group,
            # not a package, hence the pacman -Qg second check.
            local missing=() p present
            for p in "${pkgs[@]}"; do
                present=0
                if pacman -Q "$p" >/dev/null 2>&1; then
                    present=1
                elif pacman -Qg "$p" >/dev/null 2>&1; then
                    present=1
                fi
                if [[ "$present" -eq 0 ]]; then
                    missing+=("$p")
                fi
            done
            if ((${#missing[@]} > 0)); then
                echo "install: pacman — installing missing: ${missing[*]}"
                as_root pacman -S --needed --noconfirm "${missing[@]}"
            else
                echo "install: all base packages already present."
            fi
            ;;
        apt)
            as_root apt-get update
            as_root apt-get install -y "${pkgs[@]}" || {
                echo "install: apt install failed — check the package list above or install those" >&2
                echo "          dependencies manually, then re-run ./install.sh --no-packages" >&2
                exit 1
            }
            ;;
        dnf)
            as_root dnf install -y "${pkgs[@]}" || {
                echo "install: dnf install failed — check the package list above (e.g. ffmpeg-free is" >&2
                echo "          Fedora's ffmpeg; for H.264 support enable RPM Fusion) and re-run" >&2
                echo "          ./install.sh --no-packages" >&2
                exit 1
            }
            ;;
    esac
}

# --- wlroots 0.19 -----------------------------------------------------------
# Le compositor est écrit contre l'API wlroots 0.19. Arch a retiré cette
# version du dépôt officiel (seule 0.20 est présente) : on bâtit le paquet AUR
# wlroots0.19. Les familles Debian/Fedora n'ont généralement pas le .pc
# wlroots-0.19 : fallback sur une construction meson dans build/wlroots, puis
# PKG_CONFIG_PATH pointe dessus.
ensure_wlroots() {
    if pkg-config --exists wlroots-0.19; then
        echo "install: wlroots-0.19 found via pkg-config."
        return
    fi
    if [[ "$PKG_MGR" == "pacman" ]]; then
        echo "install: wlroots-0.19 missing from the official Arch repos — building from AUR ..."
        local aur
        aur="$(mktemp -d)"
        git clone --depth 1 https://aur.archlinux.org/wlroots0.19.git "$aur/wlroots0.19"
        # makepkg verifies the source signatures against validpgpkeys from the
        # PKGBUILD; on a fresh keyring the maintainer's key is unknown and the
        # build aborts. Import those keys first (multiple keyservers guard
        # against port-11371 blocks).
        local k
        for k in $(sed -n 's/^validpgpkeys=//p' "$aur/wlroots0.19/PKGBUILD" | grep -oE '[0-9A-Fa-f]{16,}'); do
            echo "install: importing GPG key $k (AUR wlroots0.19) ..."
            gpg --batch --keyserver hkps://keyserver.ubuntu.com --recv-keys "$k" 2>/dev/null \
                || gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys "$k" 2>/dev/null \
                || echo "install: warning — could not import GPG key $k; makepkg may fail its signature check." >&2
        done
        (cd "$aur/wlroots0.19" && makepkg -s --noconfirm)
        as_root pacman -U --noconfirm "$aur"/wlroots0.19/wlroots0.19-*.pkg.tar.zst
        rm -rf "$aur"
    else
        local src="$SCRIPT_DIR/build/wlroots-src"
        local build="$SCRIPT_DIR/build/wlroots-build"
        local prefix="$SCRIPT_DIR/build/wlroots"
        if [[ ! -d "$src" ]]; then
            echo "install: building wlroots 0.19.3 from source into $prefix ..."
            git clone --depth 1 --branch 0.19.3 https://gitlab.freedesktop.org/wlroots/wlroots.git "$src"
        fi
        if [[ ! -f "$build/build.ninja" ]]; then
            meson setup "$build" "$src" --buildtype release --prefix "$prefix"
        else
            meson setup --reconfigure "$build" "$src" --buildtype release --prefix "$prefix"
        fi
        ninja -C "$build"
        meson install -C "$build"
        export PKG_CONFIG_PATH="$prefix/lib/pkgconfig:$prefix/lib64/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
        if ! pkg-config --exists wlroots-0.19; then
            echo "install: wlroots 0.19 build failed to provide wlroots-0.19.pc." >&2
            exit 1
        fi
    fi
}

# --- Godot editor ---------------------------------------------------------
# La compilation/export dépend d'un éditeur exactement 4.7.2 (le template est
# reconstruit depuis les sources 4.7.2-stable). Le paquet Arch godot est 4.7.2 ;
# sur Debian/Fedora on préfère le binaire officiel du site Godot pour garantir
# la version, au lieu de dépendre des dépôts de la distro.
GODOT_TAG="4.7.2-stable"
GODOT_VER="4.7.2.stable"
GODOT_BIN=""

select_godot_editor() {
    local v
    if command -v godot >/dev/null 2>&1; then
        v="$(godot --version 2>/dev/null || true)"
        if [[ "$v" == 4.7.2* ]]; then
            GODOT_BIN="$(command -v godot)"
            echo "install: using system godot $v."
            return
        fi
        echo "install: system godot is '$v', not 4.7.2 — using the official editor instead."
    fi

    local bin="$SCRIPT_DIR/build/godot-bin/Godot_v${GODOT_TAG}_linux.x86_64"
    if [[ ! -x "$bin" ]]; then
        local zip="$SCRIPT_DIR/build/godot-bin/godot.zip"
        mkdir -p "$SCRIPT_DIR/build/godot-bin"
        local url="https://github.com/godotengine/godot/releases/download/${GODOT_TAG}/Godot_v${GODOT_TAG}_linux.x86_64.zip"
        echo "install: downloading Godot $GODOT_TAG editor ..."
        if command -v wget >/dev/null 2>&1; then
            wget -q --show-progress -O "$zip" "$url"
        elif command -v curl >/dev/null 2>&1; then
            curl -LfsS -o "$zip" "$url"
        else
            echo "install: neither wget nor curl found — cannot download the Godot editor." >&2
            exit 1
        fi
        unzip -o "$zip" -d "$SCRIPT_DIR/build/godot-bin" >/dev/null
        chmod +x "$bin"
        rm -f "$zip"
    fi
    GODOT_BIN="$bin"
    echo "install: using downloaded Godot editor ($GODOT_BIN)."
}

# --- GNOME detection -------------------------------------------------------
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

# --- Firewall --------------------------------------------------------------
# Pour UDP ports 7777/9999 (multijoueur LAN) et TCP 22 (drag & drop,
# rsync-over-ssh). Détection du backend actif pour portabilité multi-distros
# (ufw, firewalld, nftables, iptables).
firewall_open() {
    local proto="$1" port="$2" do_fwcmd
    if command -v ufw >/dev/null 2>&1 && as_root ufw status >/dev/null 2>&1; then
        as_root ufw allow "$port/$proto"
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        as_root firewall-cmd --permanent --add-port="$port/$proto"
        do_fwcmd=1
    elif command -v nft >/dev/null 2>&1 && as_root nft list ruleset >/dev/null 2>&1; then
        as_root nft add rule inet filter input tcp dport "$port" accept 2>/dev/null || true
        as_root nft add rule inet filter input udp dport "$port" accept 2>/dev/null || true
    elif command -v iptables >/dev/null 2>&1; then
        as_root iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null \
            || as_root iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
        as_root iptables -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null \
            || as_root iptables -I INPUT -p udp --dport "$port" -j ACCEPT
    else
        echo "install: no firewall backend detected (ufw/firewalld/nft/iptables)."
        echo "          Manually open UDP ports 7777 & 9999 and TCP 22."
        return
    fi
    [[ -n "${do_fwcmd:-}" ]] && as_root firewall-cmd --reload
}

# --- Main -----------------------------------------------------------------
# scons, meson, godot export ... must run from the project root; make the
# script location-independent.
cd "$SCRIPT_DIR"
detect_pkg_manager

if [[ "$DO_PACKAGES" -eq 1 ]] && confirm "install: install system dependencies via $PKG_MGR?"; then
    install_system_packages
else
    echo "install: skipping system packages (--no-packages or declined)."
fi

ensure_wlroots

if [[ ! -d "$SCRIPT_DIR/godot-cpp" ]]; then
    echo "install: cloning godot-cpp ..."
    git clone https://github.com/godotengine/godot-cpp.git "$SCRIPT_DIR/godot-cpp"
fi

echo "install: building the GDExtension (libwaylandgodot, compositor side) ..."
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

select_godot_editor

# --- Godot export template (Linux) ------------------------------------------
# Le binaire officiel / le paquet godot ne fournissent PAS les export
# templates : on reconstruit le template Linux depuis les sources Godot à la
# version exacte de l'éditeur, installé dans le répertoire
# ~/.local/share/godot/export_templates/ que godot --export-release consulte.
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
GODOT_PATCH_STAMP="$TEMPLATES_DIR/linux_release.x86_64.shortcuts-inhibit"

REBUILD_TEMPLATE=0
if [[ ! -f "$TEMPLATES_DIR/linux_release.x86_64" ]]; then
    REBUILD_TEMPLATE=1
elif [[ "$GNOME_INSTALL" -eq 1 ]] \
    && ( [[ ! -f "$GODOT_PATCH_STAMP" ]] || ! cmp -s "$GODOT_PATCH" "$GODOT_PATCH_STAMP" ); then
    REBUILD_TEMPLATE=1
fi

if [[ "$REBUILD_TEMPLATE" -eq 1 ]] \
    && ! confirm "install: build the Godot $GODOT_VER export template (scons, this takes a while)?"; then
    echo "install: template build declined — the game will not be exported."
    REBUILD_TEMPLATE=0
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
# La GDExtension (libwaylandgodot) est déjà construite par scons ci-dessus ;
# on exporte le projet (preset "Linux" de export_presets.cfg) vers
# Game/build/CyberRealm.x86_64.
if [[ -f "$TEMPLATES_DIR/linux_release.x86_64" ]]; then
    echo "install: exporting the game ($GODOT_BIN --headless) ..."
    mkdir -p "$SCRIPT_DIR/Game/build"
    "$GODOT_BIN" --headless --path "$SCRIPT_DIR/Game/source" --export-release "Linux" "$GAME"
    if [[ ! -x "$GAME" ]]; then
        echo "install: Godot export failed, binary missing: $GAME" >&2
        exit 1
    fi
else
    echo "install: no export template — skipping the game export." >&2
fi

# --- KWin script -----------------------------------------------------------
# Replaces the dwl session: the game is launched from Plasma (applications menu
# or desktop). This KWin script puts its window fullscreen + focus and blocks
# KDE global shortcuts while the game holds focus.
KWIN_SRC="$SCRIPT_DIR/compositors/kwin/cyberrealm.kwinscript"
if [[ "$DO_KWIN" -eq 1 ]] \
    && { command -v kpackagetool6 >/dev/null 2>&1 || [[ "${XDG_CURRENT_DESKTOP:-}" == *KDE* ]]; } \
    && confirm "install: install the KWin (KDE Plasma) integration?"; then
    if command -v kpackagetool6 >/dev/null 2>&1; then
        if ! kpackagetool6 -t KWin/Script -i "$KWIN_SRC" >/dev/null 2>&1; then
            kpackagetool6 -t KWin/Script -u "$KWIN_SRC" >/dev/null
        fi
    else
        KWIN_DST="$HOME/.local/share/kwin/scripts/cyberrealm"
        mkdir -p "$KWIN_DST/contents/code"
        install -m644 "$KWIN_SRC/metadata.json" "$KWIN_DST/metadata.json"
        install -m644 "$KWIN_SRC/contents/code/main.js" "$KWIN_DST/contents/code/main.js"
    fi

    if command -v kwriteconfig6 >/dev/null 2>&1; then
        kwriteconfig6 --file kwinrc --group Plugins --key cyberrealmEnabled true
    fi
    # reconfigure does NOT reload the script code: you must unload it first,
    # otherwise a main.js update is never taken into account.
    if qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.isScriptLoaded cyberrealm 2>/dev/null; then
        qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript cyberrealm 2>/dev/null || true
        sleep 1
    fi
    qdbus6 org.kde.KWin /KWin reconfigure 2>/dev/null || true
else
    echo "install: KWin integration skipped (no KDE detected or declined)."
fi

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
if [[ -x "$GAME" ]]; then
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
fi

# --- Firewall ---------------------------------------------------------------
if [[ "$DO_FIREWALL" -eq 1 ]] \
    && confirm "install: open UDP 7777/9999 and TCP 22 in the firewall? (required for multiplayer)"; then
    firewall_open udp 7777
    firewall_open udp 9999
    firewall_open tcp 22
    echo "install: firewalld/nft/iptables rules are session-scoped and may not survive a reboot;"
    echo "          for persistence prefer ufw or the firewalld config."
else
    echo "install: firewall ports not opened (declined or --no-firewall)."
    echo "          To play LAN multiplayer, open UDP 7777/9999 and TCP 22."
fi

# --- File sharing (drag & drop) ---------------------------------------------
# openssh + rsync sont installés ci-dessus. Recevoir des fichiers requiert en
# plus le daemon ssh côté destinataire : on ne l'active PAS automatiquement
# (décision de sécurité propre à chaque machine), simple rappel.
if ! systemctl is-active --quiet sshd && ! systemctl is-enabled --quiet sshd; then
    echo "install: sshd inactive — to RECEIVE files via drag & drop:"
    echo "          sudo systemctl enable --now sshd"
fi

# --- GNOME Shell extension -----------------------------------------------------
# Ne s'installe que si une session GNOME est présente (ou --with-gnome).
GNOME_UUID="cyberrealm@cyberrealm.local"
if [[ "$GNOME_INSTALL" -eq 1 ]] && command -v gnome-extensions >/dev/null 2>&1; then
    if [[ "$DO_GNOME_EXT" -eq 1 ]] \
        && confirm "install: install the GNOME Shell extension (fullscreen + focus)?"; then
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
        echo "install: GNOME extension declined."
    fi
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
    if [[ "$DO_HYPRLAND" -eq 1 ]] \
        && confirm "install: install the Hyprland window rule (~/.config/hypr)?"; then
        install -Dm644 "$HYPR_RULE" "$HYPR_DIR/cyberrealm.lua"
        if grep -q 'require("cyberrealm")' "$HYPR_CONFIG"; then
            echo "install: Hyprland — require(\"cyberrealm\") already in hyprland.lua."
        else
            printf '\nrequire("cyberrealm")\n' >> "$HYPR_CONFIG"
            echo "install: Hyprland — require(\"cyberrealm\") added to hyprland.lua."
        fi
        if hyprctl reload >/dev/null 2>&1; then
            echo "install: Hyprland — configuration reloaded."
        fi
    else
        echo "install: Hyprland rule skipped (declined)."
    fi
else
    echo "install: no Hyprland config found ($HYPR_CONFIG) — nothing to modify;"
    echo "          re-run after hyprland generates its config to activate the rule."
fi

# --- Install manifest -------------------------------------------------------
mkdir -p "$HOME/.local/state/cyberrealm"
cat > "$HOME/.local/state/cyberrealm/manifest" <<EOF
# CyberRealm install manifest — read by uninstall.sh
manifest_version=1
installed_at=$(date +%FT%T%z)
distro_id=$DISTRO_ID
distro_id_like=$DISTRO_ID_LIKE
pkg_manager=$PKG_MGR
godot_bin=$GODOT_BIN
godot_ver=$GODOT_VER
template_dir=$TEMPLATES_DIR
gnome_extension=0
kwin=0
hyprland=0
firewall=0
EOF

if [[ -f "$HOME/.local/share/kwin/scripts/cyberrealm/contents/code/main.js" ]]; then
    sed -i 's/^kwin=0$/kwin=1/' "$HOME/.local/state/cyberrealm/manifest"
fi
if [[ -d "$HOME/.local/share/gnome-shell/extensions/$GNOME_UUID" ]]; then
    sed -i 's/^gnome_extension=0$/gnome_extension=1/' "$HOME/.local/state/cyberrealm/manifest"
fi
if [[ -f "$HYPR_DIR/cyberrealm.lua" ]]; then
    sed -i 's/^hyprland=0$/hyprland=1/' "$HOME/.local/state/cyberrealm/manifest"
fi
if [[ "$DO_FIREWALL" -eq 1 ]]; then
    sed -i 's/^firewall=0$/firewall=1/' "$HOME/.local/state/cyberrealm/manifest"
fi

echo
echo "install: done. Launch the game with: $HOME/.local/bin/cyberrealm-run"
echo "          Uninstall everything it created with: ./uninstall.sh"