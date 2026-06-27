#!/usr/bin/env bash
#
# walrus time tracking, driven by tmux hooks (configured in ~/.tmux.conf).
#
# Invariant: a tmux session is tracked in walrus iff it currently has at least
# one attached client. Every relevant tmux event (switch, attach, detach,
# session closed) triggers a reconcile that syncs walrus to that invariant, so
# tracking follows the real state of sessions no matter how it changed —
# including several clients attached to several sessions at the same time.
#
# Usage (from tmux set-hook):  tmux_walrus_hook.sh
#
# State file: the set of sessions currently believed to be tracked (one/line).

set -u

STATE_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/tmux-walrus/tracked"
mkdir -p "$(dirname "$STATE_FILE")"
[ -f "$STATE_FILE" ] || : > "$STATE_FILE"

# Sessions that currently have >=1 attached client (unique, one per line).
attached_sessions() {
    tmux list-clients -F "#{session_name}" 2>/dev/null | sort -u
}

track_add() {
    local name="$1"
    grep -qxF -- "$name" "$STATE_FILE" 2>/dev/null || printf '%s\n' "$name" >> "$STATE_FILE"
}

track_remove() {
    local name="$1"
    local tmp="${STATE_FILE}.tmp.$$"
    grep -vxF -- "$name" "$STATE_FILE" > "$tmp" 2>/dev/null || true
    mv "$tmp" "$STATE_FILE"
}

# Sync the tracked set to the set of sessions that have an attached client.
reconcile() {
    local attached
    attached="$(attached_sessions)"

    local s
    # Start tracking sessions that have a client but aren't tracked yet.
    while IFS= read -r s; do
        [ -z "$s" ] && continue
        if ! grep -qxF -- "$s" "$STATE_FILE" 2>/dev/null; then
            walrus start "$s" >/dev/null 2>&1
            track_add "$s"
        fi
    done <<< "$attached"

    # Stop tracking sessions that are tracked but no longer have a client.
    while IFS= read -r s; do
        [ -z "$s" ] && continue
        if ! grep -qxF -- "$s" <<< "$attached" 2>/dev/null; then
            walrus stop "$s" >/dev/null 2>&1
            track_remove "$s"
        fi
    done < "$STATE_FILE"
}

reconcile
