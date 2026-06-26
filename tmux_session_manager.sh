#!/usr/bin/env bash

# Check if tmux is installed
if ! command -v tmux &> /dev/null; then
    echo "tmux is not installed. Please install it first."
    exit 1
fi

# Check if fzf is installed
if ! command -v fzf &> /dev/null; then
    echo "fzf is not installed. Please install it first."
    exit 1
fi

# Check if walrus is installed
if ! command -v walrus &> /dev/null; then
    echo "walrus is not installed. Time tracking will be disabled."
    walrus_available=false
else
    walrus_available=true
fi

# Absolute path to this script (used to re-invoke it from the tmux hook)
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]:-$0}")"

# Record of tmux sessions we have started walrus tracking for (one name per line).
# Used by reconcile() to stop tracking when a session is deleted.
TRACK_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/tmux-walrus/tracked"

# Add a session name to the tracking record (idempotent)
_tracked_add() {
    local name="$1"
    mkdir -p "$(dirname "$TRACK_FILE")"
    touch "$TRACK_FILE"
    grep -qxF -- "$name" "$TRACK_FILE" 2>/dev/null || printf '%s\n' "$name" >> "$TRACK_FILE"
}

# Remove a session name from the tracking record
_tracked_remove() {
    local name="$1"
    [ -f "$TRACK_FILE" ] || return 0
    local tmp="${TRACK_FILE}.tmp.$$"
    grep -vxF -- "$name" "$TRACK_FILE" > "$tmp" 2>/dev/null || true
    mv "$tmp" "$TRACK_FILE"
}

# Stop walrus tracking for any recorded session whose tmux session no longer
# exists. Triggered by the global session-closed hook (see ensure_close_hook).
reconcile() {
    [ "$walrus_available" = true ] || return 0
    [ -f "$TRACK_FILE" ] || return 0
    local name
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        if ! tmux has-session -t "$name" 2>/dev/null; then
            walrus stop "$name" >/dev/null 2>&1
            _tracked_remove "$name"
        fi
    done < "$TRACK_FILE"
}

# Install (idempotently) a global hook so closing ANY tmux session triggers
# reconciliation. This covers deletion paths (kill-session, choose-tree delete,
# last window closed, ...) that never fire client-detached and would otherwise
# leave walrus tracking running forever.
ensure_close_hook() {
    [ "$walrus_available" = true ] || return 0
    tmux set-hook -g session-closed "run-shell 'bash \"$SCRIPT_PATH\" --reconcile >/dev/null 2>&1'" 2>/dev/null
}

# Internal mode: invoked by the session-closed hook to reconcile tracking.
if [ "${1:-}" = "--reconcile" ]; then
    reconcile
    exit 0
fi

# Get session names
get_sessions() {
    tmux list-sessions -F "#S" 2>/dev/null
}

# If inside a tmux session, get the current session name
current_session=""
if [ -n "$TMUX" ]; then
    current_session=$(tmux display-message -p "#S")
fi

# Function to setup walrus detach hook for a session
setup_detach_hook() {
    local session="$1"

    if [ "$walrus_available" = true ]; then
        tmux set-hook -t "$session" client-detached "run-shell 'walrus stop \"$session\" 2>/dev/null'" 2>/dev/null
    fi
}

stop_tracking_and_start_new_session() {
    local new_session="$1"

    # Stop tracking the current session if walrus is available
    if [ "$walrus_available" = true ] && [ -n "$current_session" ]; then
        walrus stop "$current_session" 2>/dev/null
    fi

    # Start tracking the new session
    if [ "$walrus_available" = true ]; then
        walrus start "$new_session" 2>/dev/null
        _tracked_add "$new_session"
        setup_detach_hook "$new_session"
        ensure_close_hook
    fi
}

# Function to handle session transitions with walrus tracking
transition_to_session() {
    local target_session="$1"
    local transition_type="$2"  # "attach" or "switch"

    stop_tracking_and_start_new_session "$target_session"

    # Perform the actual tmux transition
    if [ "$transition_type" = "attach" ]; then
        tmux attach-session -t "$target_session"
    else
        tmux switch-client -t "$target_session"
    fi
}

# Function to determine transition type (attach or switch)
get_transition_type() {
    if [ -n "$TMUX" ]; then
        echo "switch"
    else
        echo "attach"
    fi
}

# Function to create a new session
create_session() {
    local session_name="$1"

    echo "Creating new session: $session_name"
    tmux new-session -d -s "$session_name" 2>/dev/null || true

    stop_tracking_and_start_new_session "$session_name"

    tmux attach-session -t "$session_name"
}

# Function to handle selecting an existing session or creating a new one
handle_session_selection() {
    local session_name="$1"

    # Check if already in this session
    if [ "$session_name" = "$current_session" ]; then
        echo "Already in session '$session_name'"
        return
    fi

    # Check if session exists
    if echo "$sessions" | grep -qxF "$session_name"; then
        transition_to_session "$session_name" "$(get_transition_type)"
    else
        create_session "$session_name"
    fi
}

# Get existing sessions or show a prompt for creating a new one
sessions=$(get_sessions)

if [ -z "$sessions" ]; then
    # No existing sessions, prompt for a new one
    echo "No existing tmux sessions."
    read -p "Enter new session name: " new_session
    if [ -z "$new_session" ]; then
        new_session="home"
    fi
    create_session "$new_session"
else
    # Use fzf to select from existing sessions or enter a new session name
    selected_session=$(echo "$sessions" | fzf --height 40% --reverse --query="$1" --prompt="Select existing session or type new session name: " --print-query)

    # The output of fzf with --print-query gives the query as the first line and the selection as the second
    query=$(echo "$selected_session" | head -1)
    selection=$(echo "$selected_session" | tail -1)

    # Determine which session to use (selected from list or typed query)
    if [ -n "$selection" ] && [ "$selection" != "$query" ]; then
        # A session was selected from the list
        session_to_use="$selection"
    else
        # Use the typed query as the session name
        session_to_use="$query"
    fi

    # Handle the selected/typed session
    if [ -n "$session_to_use" ]; then
        handle_session_selection "$session_to_use"
    fi
fi
