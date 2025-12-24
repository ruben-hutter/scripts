#!/usr/bin/env bash

set -euo pipefail

# Service names
MAC_SERVICE="kanata-mac.service"
STD_SERVICE="kanata-std.service"


# Check which service is currently running
get_active_service() {
    if systemctl --user is-active --quiet "$MAC_SERVICE"; then
        echo "$MAC_SERVICE"
    elif systemctl --user is-active --quiet "$STD_SERVICE"; then
        echo "$STD_SERVICE"
    else
        echo "none"
    fi
}

# Get the other service (toggle)
get_other_service() {
    local current=$1
    if [[ "$current" == "$MAC_SERVICE" ]]; then
        echo "$STD_SERVICE"
    else
        echo "$MAC_SERVICE"
    fi
}

# Get friendly name for service
get_service_name() {
    case "$1" in
        "$MAC_SERVICE")
            echo "Mac keyboard"
            ;;
        "$STD_SERVICE")
            echo "Standard keyboard"
            ;;
        *)
            echo "Unknown"
            ;;
    esac
}

# Main logic
main() {
    local active_service
    active_service=$(get_active_service)

    if [[ "$active_service" == "none" ]]; then
        systemctl --user enable "$STD_SERVICE"
        systemctl --user start "$STD_SERVICE"
    else
        local other_service
        other_service=$(get_other_service "$active_service")

        local other_name
        other_name=$(get_service_name "$other_service")

        # Stop the active service
        systemctl --user stop "$active_service"

        # Start the other service
        systemctl --user start "$other_service"
        notify-send \
            --app-name="Kanata" \
            --icon="input-keyboard" \
            --urgency=normal \
            --category="device" \
            --transient \
            "Keyboard Config Switched" \
            "Now using: $other_name"
    fi
}

main "$@"
