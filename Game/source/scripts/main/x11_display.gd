class_name X11Display
## Sélection du display X11 pour xwayland-satellite.
##
## KWin 6.8+ (MAJ d'octobre 2026) démarre son Xwayland sur :0 ET :1
## (--xwayland-init-display :1) : un "xwayland-satellite :1" codé en dur
## échouait ("server already running — Cannot establish any listening
## sockets") et les apps X11 du jeu atterrissaient sur le bureau KDE via
## l'XAUTHORITY hérité de la session Plasma. Le jeu choisit donc un display
## libre au démarrage et publie le choix dans
## $XDG_RUNTIME_DIR/cyberrealm-x11-display (lu par cyberrealm-launch).

const RUNTIME_FILE := "cyberrealm-x11-display"
const FIRST_DISPLAY := 2
const LAST_DISPLAY := 99

## Un display est considéré pris si son lock (/tmp/.X<n>-lock) ou son
## socket (/tmp/.X11-unix/X<n>) existe : les deux signes qu'un serveur X
## l'utilise actuellement.
static func is_display_busy(display_number: int, lock_dir: String, unix_dir: String) -> bool:
	if FileAccess.file_exists(lock_dir.path_join(".X%d-lock" % display_number)):
		return true
	return FileAccess.file_exists(unix_dir.path_join("X%d" % display_number))

## Premier display libre de [first, last] inclus, ou -1 si la plage est
## entièrement occupée (:0 et :1 sont toujours exclus — hébergés par KWin).
static func pick_free_display(lock_dir: String = "/tmp", unix_dir: String = "/tmp/.X11-unix",
		first: int = 2, last: int = 99) -> int:
	for n in range(first, last + 1):
		if not is_display_busy(n, lock_dir, unix_dir):
			return n
	return -1

## Chemin du fichier publié pour cyberrealm-launch, à côté de
## cyberrealm-session-bus dans $XDG_RUNTIME_DIR.
static func runtime_file(xdg_runtime_dir: String) -> String:
	return xdg_runtime_dir.path_join(RUNTIME_FILE)

## Publie le display du jeu pour que cyberrealm-launch redirige les apps
## lancées depuis Plasma. Refuse un display vide : mieux vaut laisser le
## fallback du launcher que d'écrire un fichier corrompu.
static func write_runtime_file(xdg_runtime_dir: String, display_name: String) -> bool:
	if xdg_runtime_dir.is_empty() or display_name.is_empty():
		return false
	var f := FileAccess.open(runtime_file(xdg_runtime_dir), FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(display_name + "\n")
	f.close()
	return true
