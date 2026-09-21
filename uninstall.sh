#!/usr/bin/env bash

# Reverses everything install.sh created — helpers, launchers, compositor
# integrations (KWin / GNOME / Hyprland), the Godot export template, firewall
# rules and project build artifacts. NEVER touches the project source itself.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
GODOT_VER="4.7.2.stable"
MANIFEST="$HOME/.local/state/cyberrealm/manifest"
GNOME_UUID="cyberrealm@cyberrealm.local"

ASSUME_YES=0
for arg in "$@"; do
    case "$arg" in
        --yes|-y)  ASSUME_YES=1 ;;
        --help|-h)
            cat <<'HELP'
Usage: ./uninstall.sh [--yes]

Remove everything install.sh created, without touching the project source:
  - user helpers (~/.local/bin/cyberrealm-*) and game .desktop launcher
  - KWin script (removed + disabled), GNOME extension, Hyprland rule/require
  - Godot 4.7.2 export template (~/.local/share/godot/export_templates)
  - GDExtension build outputs and project build artifacts (build/, Game/build)
  - firewall rules opened for UDP 7777/9999 and TCP 22

System packages installed by install.sh are NOT removed.

  --yes   skip the confirmation prompt
  --help  show this help
HELP
            exit 0
            ;;
    esac
done

if [[ $EUID -eq 0 ]]; then
    as_root() { "$@"; }
else
    as_root() { command sudo "$@"; }
fi

# Uninstall is destructive: require an explicit confirmation unless --yes.
if [[ "$ASSUME_YES" -ne 1 ]]; then
    if [[ ! -t 0 ]]; then
        echo "uninstall: no terminal — run with --yes to force removal." >&2
        exit 1
    fi
    printf 'This will remove all CyberRealm files installed on this system (not the project itself).\nContinue? [y/N] '
    read -r ans
    case "$ans" in
        y|Y|yes|YES|Yes) ;;
        *)
            echo "uninstall: aborted."
            exit 0
            ;;
    esac
fi

echo "uninstall: reading install manifest ..."
if [[ -f "$MANIFEST" ]]; then
    sed 's/^/  /' "$MANIFEST" || true
else
    echo "uninstall: no manifest found — removing everything by known paths anyway."
fi

# --- Firewall (mirror of firewall_open, reversing) -------------------------
firewall_close() {
    local proto="$1" port="$2"
    if command -v ufw >/dev/null 2>&1 && as_root ufw status >/dev/null 2>&1; then
        as_root ufw delete allow "$port/$proto" >/dev/null 2>&1 || true
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        as_root firewall-cmd --permanent --remove-port="$port/$proto" >/dev/null 2>&1 || true
        as_root firewall-cmd --reload
    elif command -v nft >/dev/null 2>&1 && as_root nft list ruleset >/dev/null 2>&1; then
        as_root nft delete rule inet filter input tcp dport "$port" accept 2>/dev/null || true
        as_root nft delete rule inet filter input udp dport "$port" accept 2>/dev/null || true
    elif command -v iptables >/dev/null 2>&1; then
        as_root iptables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
        as_root iptables -D INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || true
    fi
}

echo "uninstall: reversing firewall rules (UDP 7777, 9999, TCP 22) ..."
firewall_close udp 7777
firewall_close udp 9999
firewall_close tcp 22

# --- User helpers & launcher -------------------------------------------------
echo "uninstall: removing helpers and desktop launcher ..."
rm -f "$HOME/.local/bin/cyberrealm-run" \
      "$HOME/.local/bin/cyberrealm-launch" \
      "$HOME/.local/bin/cyberrealm-exec"
rmdir "$HOME/.local/bin" 2>/dev/null || true
rm -f "$HOME/.local/share/applications/cyberrealm.desktop"
rmdir "$HOME/.local/share/applications" 2>/dev/null || true

# --- KWin integration ---------------------------------------------------------
echo "uninstall: removing the KWin script ..."
if command -v kpackagetool6 >/dev/null 2>&1; then
    kpackagetool6 -t KWin/Script -r cyberrealm >/dev/null 2>&1 || true
fi
rm -rf "$HOME/.local/share/kwin/scripts/cyberrealm"
if command -v kwriteconfig6 >/dev/null 2>&1; then
    kwriteconfig6 --file kwinrc --group Plugins --key cyberrealmEnabled false >/dev/null 2>&1 || true
elif [[ -f "$HOME/.config/kwinrc" ]]; then
    if grep -q '^cyberrealmEnabled=' "$HOME/.config/kwinrc"; then
        sed -i 's/^cyberrealmEnabled=.*/cyberrealmEnabled=false/' "$HOME/.config/kwinrc"
    else
        printf '\n[Plugins]\ncyberrealmEnabled=false\n' >> "$HOME/.config/kwinrc"
    fi
fi
if command -v qdbus6 >/dev/null 2>&1 \
    && qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.isScriptLoaded cyberrealm 2>/dev/null; then
    qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript cyberrealm 2>/dev/null || true
    sleep 1
fi
qdbus6 org.kde.KWin /KWin reconfigure 2>/dev/null || true

# --- GNOME extension ----------------------------------------------------------
echo "uninstall: removing the GNOME Shell extension ..."
if command -v gnome-extensions >/dev/null 2>&1; then
    gnome-extensions disable "$GNOME_UUID" >/dev/null 2>&1 || true
fi
rm -rf "$HOME/.local/share/gnome-shell/extensions/$GNOME_UUID"

# --- Hyprland rule -------------------------------------------------------------
HYPR_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hypr"
HYPR_CONFIG="$HYPR_DIR/hyprland.lua"
echo "uninstall: removing the Hyprland rule ..."
rm -f "$HYPR_DIR/cyberrealm.lua"
if [[ -f "$HYPR_CONFIG" ]] && grep -q 'require("cyberrealm")' "$HYPR_CONFIG"; then
    sed -i '/require("cyberrealm")/d' "$HYPR_CONFIG"
    echo "uninstall: removed require(\"cyberrealm\") from $HYPR_CONFIG."
fi
hyprctl reload >/dev/null 2>&1 || true

# --- Godot export template ------------------------------------------------------
echo "uninstall: removing the Godot export template ..."
TEMPLATES_DIR="$HOME/.local/share/godot/export_templates/$GODOT_VER"
rm -f "$TEMPLATES_DIR/linux_release.x86_64" \
      "$TEMPLATES_DIR/linux_debug.x86_64" \
      "$TEMPLATES_DIR/linux_release.x86_64.shortcuts-inhibit"
rmdir "$TEMPLATES_DIR" 2>/dev/null || true
rmdir "$HOME/.local/share/godot/export_templates" 2>/dev/null || true
rmdir "$HOME/.local/share/godot" 2>/dev/null || true

# --- System-level package the installer may have added (wlroots0.19 AUR) -------
# Only on Arch when the AUR path was used. Other distros build wlroots into
# build/ and never install it system-wide.
if command -v pacman >/dev/null 2>&1 && pacman -Qq wlroots0.19 >/dev/null 2>&1; then
    echo "uninstall: removing the wlroots0.19 AUR package ..."
    as_root pacman -R --noconfirm wlroots0.19
elif [[ -d "$SCRIPT_DIR/build/wlroots" ]]; then
    echo "uninstall: removing the source-built wlroots (build/wlroots)..."
    rm -rf "$SCRIPT_DIR/build/wlroots" \
           "$SCRIPT_DIR/build/wlroots-src" \
           "$SCRIPT_DIR/build/wlroots-build"
fi

# --- Project-local build artifacts (all gitignored, regenerable) ----------------
echo "uninstall: removing project build artifacts ..."
rm -rf "$SCRIPT_DIR/build/portal" \
       "$SCRIPT_DIR/build/portal-src" \
       "$SCRIPT_DIR/build/godot-src" \
       "$SCRIPT_DIR/build/godot-bin"
rmdir "$SCRIPT_DIR/build" 2>/dev/null || true
rm -f "$SCRIPT_DIR/Game/build/CyberRealm.x86_64"
rmdir "$SCRIPT_DIR/Game/build" 2>/dev/null || true
rm -f "$SCRIPT_DIR/Game/source/bin"/libwaylandgodot*.so
rm -f "$SCRIPT_DIR/Game/source/bin"/libwaylandgodot*.dylib
rmdir "$SCRIPT_DIR/Game/source/bin" 2>/dev/null || true
find "$SCRIPT_DIR/compositors/ingame" "$SCRIPT_DIR/compositors/protocols" \
     -type f \( -name '*.o' -o -name '*.os' \) -delete 2>/dev/null || true
if [[ -f "$SCRIPT_DIR/.sconsign.dblite" ]]; then
    rm -f "$SCRIPT_DIR/.sconsign.dblite"
fi

# --- Cloned dependency (gitignored) -----------------------------------------------
if [[ -d "$SCRIPT_DIR/godot-cpp" ]]; then
    echo "uninstall: removing the cloned godot-cpp dependency ..."
    rm -rf "$SCRIPT_DIR/godot-cpp"
fi

# --- Install manifest ---------------------------------------------------------------
rm -f "$MANIFEST"
rmdir "$HOME/.local/state/cyberrealm" 2>/dev/null || true

echo
echo "uninstall: done. System packages installed by install.sh were left untouched."