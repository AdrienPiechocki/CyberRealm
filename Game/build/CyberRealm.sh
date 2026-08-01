#!/bin/sh
printf '\033c\033]0;%s\a' CyberRealm
base_path="$(dirname "$(realpath "$0")")"
"$base_path/CyberRealm.x86_64" "$@"
