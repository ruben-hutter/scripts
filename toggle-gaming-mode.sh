#!/usr/bin/env bash

SERVICE_NAME="kanata"

if systemctl --user is-active --quiet "$SERVICE_NAME"; then
    systemctl --user stop "$SERVICE_NAME"
    notify-send \
        --app-name="Gaming Mode" \
        --icon="input-gaming" \
        --urgency=normal \
        --category="device" \
        --transient \
        "Gaming Mode Activated" \
        "Homerow mods disabled"
else
    systemctl --user start "$SERVICE_NAME"
    notify-send \
        --app-name="Gaming Mode" \
        --icon="input-keyboard" \
        --urgency=normal \
        --category="device" \
        --transient \
        "Gaming Mode Deactivated" \
        "Homerow mods enabled"
fi
