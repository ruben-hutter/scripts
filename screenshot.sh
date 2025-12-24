#!/usr/bin/env bash

action="$1"
filename="$(xdg-user-dir PICTURES)/$(date +%Y-%m-%d_%H-%M-%S).png"

case "$action" in
    full)
        grim "$filename"
        ;;
    area)
        grim -g "$(slurp)" "$filename"
        ;;
    clipboard)
        grim -g "$(slurp)" - | wl-copy
        ;;
    *)
        echo "Usage: $0 {full|area|clipboard}"
        exit 1
        ;;
esac
