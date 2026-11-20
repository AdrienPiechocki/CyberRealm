#!/usr/bin/env bash
# Régénère kms-display-driver.patch depuis un arbre Godot de travail.
#
#   compositors/godot-patches/make-patch.sh [arbre-godot]
#
# Arbre par défaut : build/godot-kms-src (le worktree de test). Passer
# build/godot-src pour partir de l'arbre principal. Le patch ne couvre QUE les
# fichiers du driver KMS (pas les autres patchs locaux de godot-src, comme
# fix-wayland-shm-fd-leak). Avant d'écrire, on vérifie que le patch s'applique
# sur un Godot propre (git apply --check sur le commit de base de l'arbre).
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TREE="${1:-$ROOT/build/godot-kms-src}"
OUT="$HERE/kms-display-driver.patch"

PATHS=(
    platform/linuxbsd/kms
    platform/linuxbsd/detect.py
    platform/linuxbsd/SCsub
    platform/linuxbsd/os_linuxbsd.cpp
    drivers/vulkan
)

[[ -d "$TREE/.git" || -f "$TREE/.git" ]] || { echo "make-patch: $TREE n'est pas un arbre git Godot." >&2; exit 1; }
cd "$TREE"

# Fichiers neufs (kms/) : « intent to add » pour qu'ils apparaissent dans le diff.
git add -N -- platform/linuxbsd/kms
TMP="$(mktemp)"
trap 'rm -f "$TMP"; rm -rf "${CHECK_DIR:-}"' EXIT
git diff -- "${PATHS[@]}" > "$TMP"
[[ -s "$TMP" ]] || { echo "make-patch: aucun changement à exporter." >&2; exit 1; }

# Vérification : le patch doit s'appliquer sur le commit de base, tel quel.
CHECK_DIR="$(mktemp -d)"
# kms/ est neuf : absent du commit de base, donc exclu de l'archive.
git archive HEAD -- "${PATHS[@]:1}" | tar -x -C "$CHECK_DIR"
( cd "$CHECK_DIR" && git init -q && git apply --check "$TMP" ) \
    || { echo "make-patch: le patch ne s'applique pas sur $(git rev-parse --short HEAD) — rien écrit." >&2; exit 1; }

cp "$TMP" "$OUT"
echo "make-patch: $OUT ($(git diff --shortstat -- "${PATHS[@]}"))"
