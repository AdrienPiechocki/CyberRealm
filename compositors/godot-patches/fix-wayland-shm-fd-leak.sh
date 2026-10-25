#!/usr/bin/env bash
# Godot 4.7.2 (Wayland) : le fd renvoyé par _allocate_shm_file() n'est jamais
# fermé après wl_shm_create_pool (icône de fenêtre x2, curseur custom). Chaque
# appel de Input.set_custom_mouse_cursor() perd un fd -> EMFILE à 1024.
# Idempotent. Usage : fix-wayland-shm-fd-leak.sh <godot-src>
set -euo pipefail
f="$1/platform/linuxbsd/wayland/wayland_thread.cpp"
perl -0pi -e 's/^([ \t]*)(wl_shm_pool_destroy\((?:shm_pool|wl_shm_pool)\);)\n(?![ \t]*close\(fd\);)/$1$2\n$1close(fd);\n/mg' "$f"
n_pool=$(grep -c 'wl_shm_pool_destroy(' "$f")
n_fix=$(grep -A1 'wl_shm_pool_destroy(' "$f" | grep -c 'close(fd);')
[[ "$n_pool" -eq "$n_fix" ]] || { echo "shm-fd-fix: $n_fix/$n_pool close(fd) — fichier inattendu" >&2; exit 1; }
