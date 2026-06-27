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
    read -r -p "Enter new session name: " new_session
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
