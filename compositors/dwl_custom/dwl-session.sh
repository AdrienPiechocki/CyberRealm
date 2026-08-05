#!/bin/sh
# Session CyberRealm : dwl comme compositeur d'amorçage, puis le jeu
# CyberRealm qui embarque le vrai compositeur (compositors/ingame) et lance
# les apps du bureau dans ses fenêtres 3D.
#
# Pourquoi un script séparé ? plasmalogin (KDE) exécute la commande du
# fichier .desktop via `exec $@` NON quoté dans
# /usr/share/plasmalogin/scripts/wayland-session. Une commande contenant des
# espaces ou des guillemets y est donc découpée en plusieurs argv : le
# `-s "GAME; kill -TERM \$PPID"` devenait 6 arguments, getopt de dwl
# échouait (« Usage: dwl [...] ») et dwl mourait instantanément — écran gris
# figé, session morte, redémarrage obligatoire.
#
# En pointant le .desktop sur CE script (un seul chemin, sans espace), la
# ligne de commande surviv au découpage de plasmalogin, et le quoting est
# fait ici proprement par le shell.
#
# Quand le jeu se termine, `kill -TERM $PPID` termine dwl (son parent, voir
# run() dans dwl.c) pour rendre la main au gestionnaire de connexion.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
GAME="$SCRIPT_DIR/../../Game/build/CyberRealm.x86_64"

if [ ! -x "$GAME" ]; then
    echo "dwl-session: jeu introuvable : $GAME" >&2
    exit 1
fi

exec dwl -s "\"$GAME\"; kill -TERM \$PPID"
