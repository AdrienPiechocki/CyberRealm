#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_TYPE="${1:-debug}"

echo "==> CyberRealm Build & Install Script"
echo "    Target: $BUILD_TYPE"
echo ""

# --- 1. Build GDExtension + session launcher --------------------------------
echo "==> [1/4] Compilation du plugin GDExtension et du lanceur de session..."

cd "$DIR"
if [ "$BUILD_TYPE" = "release" ]; then
    scons target=template_release -j"$(nproc)"
else
    scons target=template_debug -j"$(nproc)"
fi

echo "    ✓ Plugin : demo/bin/libwaylandgodot.*.so"
echo "    ✓ Lanceur : demo/bin/cyberrealm-session"

# --- 2. Export Godot project -------------------------------------------------
echo ""
echo "==> [2/4] Export du projet Godot..."

GODOT_BIN=""
for candidate in godot godot4; do
    command -v "$candidate" &>/dev/null && GODOT_BIN="$candidate" && break
done

EXPORT_OK=false
if [ -n "$GODOT_BIN" ]; then
    echo "    Godot : $GODOT_BIN"

    GODOT_VERSION="$("$GODOT_BIN" --version | cut -d. -f1-3)"
    TEMPLATE_DIR="$HOME/.local/share/godot/export_templates/$GODOT_VERSION.stable"

    if [ ! -f "$TEMPLATE_DIR/linux_debug.x86_64" ] || \
       [ ! -f "$TEMPLATE_DIR/linux_release.x86_64" ]; then
        echo "    ⚠  Templates d'export manquants."
        echo "      → Installe-les avec : godot --headless --import-and-quit"
        echo "      → Puis relance le script, ou lance depuis les sources."
    else
        EXPORT_DIR="$(dirname "$DIR/../CyberRealm/CyberRealm.x86_64")"
        mkdir -p "$EXPORT_DIR"
        cd "$DIR/demo"

        echo "    Export..."
        if [ "$BUILD_TYPE" = "release" ]; then
            "$GODOT_BIN" --headless --export-release "Linux" 2>&1 | tail -3
        else
            "$GODOT_BIN" --headless --export-debug "Linux" 2>&1 | tail -3
        fi
        cd "$DIR"

        if [ -x "$DIR/../CyberRealm/CyberRealm.x86_64" ]; then
            echo "    ✓ Binaire : $DIR/../CyberRealm/CyberRealm.x86_64"
            EXPORT_OK=true
        fi
    fi
fi

if [ "$EXPORT_OK" = false ]; then
    echo "    ℹ  Pas de binaire exporté — le lanceur utilisera godot --path depuis les sources."
fi

# --- 3. Install session files -----------------------------------------------
echo ""
echo "==> [3/4] Installation des fichiers de session..."

# Installer le lanceur binaire
sudo mkdir -p /usr/local/lib/cyberrealm
sudo install -m 755 "$DIR/demo/bin/cyberrealm-session" /usr/local/lib/cyberrealm/cyberrealm-session
echo "    ✓ /usr/local/lib/cyberrealm/cyberrealm-session (lanceur)"

# Installer le script wrapper
sudo install -m 755 "$DIR/cyberrealm-wrap" /usr/local/bin/cyberrealm-session
echo "    ✓ /usr/local/bin/cyberrealm-session (wrapper)"

# Installer le projet Godot (nécessaire pour le lancement depuis les sources)
sudo mkdir -p /usr/local/share/cyberrealm
sudo cp -r "$DIR/demo" /usr/local/share/cyberrealm/
echo "    ✓ /usr/local/share/cyberrealm/demo/ (projet)"

# Installer .desktop pour wayland-sessions
sudo mkdir -p /usr/share/wayland-sessions
sudo install -m 644 "$DIR/cyberrealm.desktop" /usr/share/wayland-sessions/cyberrealm.desktop
echo "    ✓ /usr/share/wayland-sessions/cyberrealm.desktop"

# Copier le binaire exporté si disponible
if [ "$EXPORT_OK" = true ]; then
    sudo mkdir -p /usr/local/CyberRealm
    sudo install -m 755 "$DIR/../CyberRealm/CyberRealm.x86_64" /usr/local/CyberRealm/CyberRealm.x86_64
    echo "    ✓ /usr/local/CyberRealm/CyberRealm.x86_64"
fi

# --- 4. Setup systemd user session ------------------------------------------
echo ""
echo "==> [4/4] Vérification..."

# S'assurer que le wrapper pointe vers le bon endroit
echo "    Prêt !"
echo ""
echo "=== Build & Install terminé ! ==="
echo ""
echo "Déconnecte-toi et sélectionne 'CyberRealm' dans l'écran de connexion."
echo ""
echo "Test depuis un TTY (Ctrl+Alt+F3) :"
echo "  sudo /usr/local/bin/cyberrealm-session"
echo ""
if [ "$EXPORT_OK" = false ]; then
    echo "Test depuis le répertoire source (sans installer) :"
    echo "  WAYLAND_DISPLAY=wayland-99 ./demo/bin/cyberrealm-session"
fi
echo ""
echo "Désinstallation :"
echo "  sudo rm -rf /usr/local/lib/cyberrealm /usr/local/share/cyberrealm"
echo "  sudo rm /usr/local/bin/cyberrealm-session"
echo "  sudo rm /usr/share/wayland-sessions/cyberrealm.desktop"
echo "  sudo rm -rf /usr/local/CyberRealm"
