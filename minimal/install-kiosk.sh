#!/usr/bin/env bash
#
# Install the CyberRealm kiosk compositor as a Wayland session for any
# display manager (GDM, SDDM, LightDM, ...). No autologin.
#
# Usage:
#   ./install-kiosk.sh             install the "CyberRealm Kiosk" session
#   ./install-kiosk.sh --restart   also restart the running display manager
#   ./install-kiosk.sh --uninstall remove the session entry
#
# Options:
#   -r, --restart   restart the active display manager (sddm/gdm/lightdm)
#   -u, --uninstall remove what this script installs
#   -h, --help      show this help
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BIN="$SCRIPT_DIR/cyberrealm"
SESSIONS_DIR=/usr/share/wayland-sessions
DESKTOP_FILE="$SESSIONS_DIR/cyberrealm.desktop"

usage() {
	sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
}

do_restart=0
do_uninstall=0

while [[ $# -gt 0 ]]; do
	case "$1" in
	-r | --restart)
		do_restart=1
		;;
	-u | --uninstall)
		do_uninstall=1
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "unknown option: $1" >&2
		usage
		exit 1
		;;
	esac
	shift
done

if [[ $EUID -ne 0 ]]; then
	echo "error: run as root (sudo $0 ...)" >&2
	exit 1
fi

if [[ ! -x "$BIN" ]]; then
	echo "error: $BIN not found — run 'make' in $SCRIPT_DIR first" >&2
	exit 1
fi

if [[ $do_uninstall -eq 1 ]]; then
	rm -f "$DESKTOP_FILE"
	echo "Removed $DESKTOP_FILE"
	exit 0
fi

mkdir -p "$SESSIONS_DIR"
cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=CyberRealm Kiosk
Comment=Launch CyberRealm fullscreen (Wayland kiosk compositor)
Exec=$BIN
EOF
chmod 644 "$DESKTOP_FILE"
echo "Installed $DESKTOP_FILE"
echo "  (Exec=$BIN)"
echo "Pick \"CyberRealm Kiosk\" in your display manager's session menu (GDM, SDDM, LightDM...)."

if [[ $do_restart -eq 1 ]]; then
	for dm in sddm gdm lightdm; do
		if systemctl is-active --quiet "$dm"; then
			echo "Restarting $dm..."
			systemctl restart "$dm"
			exit 0
		fi
	done
	echo "No running display manager found (sddm/gdm/lightdm). Nothing restarted." >&2
fi
