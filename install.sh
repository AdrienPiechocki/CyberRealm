#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Installation des fichiers de session CyberRealm"
echo "    (nécessite sudo)"
echo ""

# Lanceur compositeur
sudo mkdir -p /usr/local/lib/cyberrealm
sudo install -m 755 "$DIR/demo/bin/cyberrealm-session" /usr/local/lib/cyberrealm/cyberrealm-session
echo "✓ /usr/local/lib/cyberrealm/cyberrealm-session"

# Projet Godot (fallback si export manquant)
sudo mkdir -p /usr/local/share/cyberrealm
sudo cp -r "$DIR/demo" /usr/local/share/cyberrealm/
echo "✓ /usr/local/share/cyberrealm/demo/"

# Desktop entry pour GDM/SDDM
sudo mkdir -p /usr/share/wayland-sessions
sudo install -m 644 "$DIR/cyberrealm.desktop" /usr/share/wayland-sessions/cyberrealm.desktop
echo "✓ /usr/share/wayland-sessions/cyberrealm.desktop"

# Wrapper (utile pour test depuis TTY)
sudo install -m 755 "$DIR/cyberrealm-wrap" /usr/local/bin/cyberrealm-session
echo "✓ /usr/local/bin/cyberrealm-session (wrapper)"

echo ""
echo "=== Installation terminée ==="
echo ""
echo "Déconnecte-toi et sélectionne 'CyberRealm' dans GDM."
echo ""
echo "Test depuis un TTY (Ctrl+Alt+F3) :"
echo "  export CYBERREALM_PROJECT_DIR=\"$DIR/demo\""
echo "  sudo /usr/local/lib/cyberrealm/cyberrealm-session"
echo ""
echo "Désinstallation :"
echo "  sudo rm -rf /usr/local/lib/cyberrealm /usr/local/share/cyberrealm"
echo "  sudo rm /usr/local/bin/cyberrealm-session"
echo "  sudo rm /usr/share/wayland-sessions/cyberrealm.desktop"
