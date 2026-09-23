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
# A single user action fires several tmux hooks (attaching fires both
# client-attached and client-session-changed), so instances of this script
# run concurrently. No locking is needed for that: walrus refuses to open a
# second session for an already-active topic, and the remaining races
# self-heal on the next reconcile.
#
# Usage (from tmux set-hook):  tmux_walrus_hook.sh
#
# State file: the set of sessions currently believed to be tracked (one/line).
# Log file:   walrus start/stop failures, for debugging drift.

set -u

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/tmux-walrus"
STATE_FILE="$STATE_DIR/tracked"
LOG_FILE="$STATE_DIR/log"
mkdir -p "$STATE_DIR"
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

logf() {
    printf '%s %s\n' "$(date -Is)" "$*" >> "$LOG_FILE"
}

# Sync the tracked set to the set of sessions that have an attached client.
reconcile() {
    local attached
    attached="$(attached_sessions)"

    local s out
    # Start tracking sessions that have a client but aren't tracked yet.
    while IFS= read -r s; do
        [ -z "$s" ] && continue
        if ! grep -qxF -- "$s" "$STATE_FILE" 2>/dev/null; then
            # A failed start is still marked tracked: either walrus already
            # has it active (fine) or a later reconcile stops it again.
            if ! out="$(walrus start "$s" 2>&1)"; then
                logf "walrus start '$s' failed: $out"
            fi
            track_add "$s"
        fi
    done <<< "$attached"

    # Stop tracking sessions that are tracked but no longer have a client.
    while IFS= read -r s; do
        [ -z "$s" ] && continue
        if ! grep -qxF -- "$s" <<< "$attached" 2>/dev/null; then
            if out="$(walrus stop "$s" 2>&1)"; then
                track_remove "$s"
            elif printf '%s' "$out" | grep -q "No active session"; then
                # Walrus has nothing open for it: benign state drift.
                track_remove "$s"
            else
                # Real failure: keep it tracked so a later reconcile retries.
                logf "walrus stop '$s' failed: $out"
            fi
        fi
    done < "$STATE_FILE"
}

reconcile
