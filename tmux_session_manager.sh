#!/usr/bin/env bash

# tmux session selector / creator. Pure UI: pick, create, or switch sessions.
# Time tracking is handled independently by tmux hooks (see tmux_walrus_hook.sh).

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

# Get session names
get_sessions() {
    tmux list-sessions -F "#S" 2>/dev/null
}

# If inside a tmux session, get the current session name
current_session=""
if [ -n "$TMUX" ]; then
    current_session=$(tmux display-message -p "#S")
fi

# Function to handle session transitions
transition_to_session() {
    local target_session="$1"
    local transition_type="$2"  # "attach" or "switch"

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
    # Attach when outside tmux, switch client when inside (attach fails nested)
    transition_to_session "$session_name" "$(get_transition_type)"
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
    read -r -p "Enter new session name: " new_session
    if [ -z "$new_session" ]; then
        new_session="home"
    fi
    create_session "$new_session"
else
    # Use fzf to select an existing session or type a new session name.
    # --expect=ctrl-n lets the user explicitly create a session from the typed
    # name, even when that name fuzzy-matches an existing session (e.g. typing
    # "home" when "homelab" exists and Enter would select "homelab").
    # Output lines: 1 = typed query, 2 = key pressed, 3 = selection (if any)
    # (fzf >= 0.48 prints query first, then the expect-key line)
    fzf_output=$(echo "$sessions" | fzf \
        --height 40% --reverse \
        --query="$1" \
        --print-query \
        --expect=ctrl-n \
        --header="enter: select session | ctrl-n: create from typed name | esc: cancel" \
        --prompt="Session: ")
    fzf_status=$?

    query=$(echo "$fzf_output" | sed -n '1p')
    fzf_key=$(echo "$fzf_output" | sed -n '2p')
    selection=$(echo "$fzf_output" | sed -n '3p')

    # 130 = interrupted with esc/ctrl-c: cancelled, do nothing
    if [ "$fzf_status" -eq 130 ]; then
        exit 0
    fi

    if [ "$fzf_key" = "ctrl-n" ]; then
        # Explicitly create a new session from the typed name
        if [ -n "$query" ]; then
            handle_session_selection "$query"
        fi
    elif [ -n "$selection" ]; then
        # A session was selected from the list
        handle_session_selection "$selection"
    elif [ -n "$query" ]; then
        # Enter with no matching session: treat the typed name as a new session
        handle_session_selection "$query"
    fi
fi
