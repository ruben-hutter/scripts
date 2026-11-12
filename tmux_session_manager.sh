#!/usr/bin/env bash

# Unified tmux jump box (alt+f popup). One list, two kinds of rows — pi
# attention entries FIRST (oldest-first, the exact order the former standalone
# pi_attention_queue.sh used), then plain tmux sessions:
#
#   🔔/❓ pi attention entries — pi sessions that finished or need input while
#      you were elsewhere. Backed by a spool dir (~/.local/state/pi/attention,
#      written by pi's notify.ts) surfaced oldest-first. Enter: jump to the
#      exact pane and dequeue; del: dismiss. Dead entries (pi process or pane
#      gone) are pruned on every run — the list can never show corpses.
#      Visiting a pane by any means also dequeues it (tmux pane-focus-in hook,
#      see pi_attention_hook.sh).
#   sessions — every tmux session; pick one, or type a new name to create.
#
# Sibling: pi_attention_hook.sh — the DELETE-only tmux hook handler (dequeue-
# on-view, dead-pane sweep). It runs in tmux's background run-shell context
# (no TTY), so it stays a separate file on purpose.
#
# Usage: tmux_session_manager.sh [initial-query]   unified picker (alt+f)
#        tmux_session_manager.sh -l|--list         all sessions, one line each
#        tmux_session_manager.sh --queue-list      pi attention queue, oldest-first
#        tmux_session_manager.sh --queue-json      same, as JSON lines

SPOOL_DIR="$HOME/.local/state/pi/attention"
TAB=$'\t'

# tmux is needed everywhere (even -l lists live sessions)
if ! command -v tmux &> /dev/null; then
    echo "tmux is not installed. Please install it first."
    exit 1
fi

# jq is only needed once attention entries exist — but require it BEFORE any
# prune can run: prune treats an unreadable pid as dead and would silently eat
# real entries without jq.
if compgen -G "$SPOOL_DIR/*.json" &> /dev/null && ! command -v jq &> /dev/null; then
    echo "tmux_session_manager.sh: jq is required (attention entries present)"
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

# --- pi attention queue ------------------------------------------------------
# Invariant: a spool file exists only while its pi process AND its tmux pane
# are alive. Killing a pane/session drops exactly that entry (pane-granular);
# the same is enforced here at read time as the safety net.
prune() {
    local f pid pane panes
    panes=$(tmux list-panes -a -F '#{pane_id}' 2>/dev/null) # empty = no server/panes
    for f in "$SPOOL_DIR"/*.json; do
        [[ -e $f ]] || return 0
        pid=$(jq -r '.pid // empty' "$f" 2>/dev/null)
        pane=$(jq -r '.tmux_pane // empty' "$f" 2>/dev/null)
        if [[ -z $pid ]] || ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$f"
        elif ! grep -Fxq "$pane" <<<"$panes"; then
            rm -f "$f"
        fi
    done
}

# One tab-separated row per entry: Q | display | session_id | session | window |
# pane | kind. Display is the only visible field (--with-nth=2); the rest is
# metadata for the actions. Sorted oldest-first by timestamp; the ts is a
# leading sort key only, cut before consumers see the rows.
queue_rows() {
    prune
    local f ts sid sname win pane kind label age now s icon
    now=$(date +%s)
    for f in "$SPOOL_DIR"/*.json; do
        [[ -e $f ]] || return 0
        ts=$(jq -r '.timestamp // empty' "$f" 2>/dev/null)
        sid=$(jq -r '.session_id // empty' "$f" 2>/dev/null)
        sname=$(jq -r '.tmux_session // empty' "$f" 2>/dev/null)
        win=$(jq -r '.tmux_window // empty' "$f" 2>/dev/null)
        pane=$(jq -r '.tmux_pane // empty' "$f" 2>/dev/null)
        kind=$(jq -r '.kind // empty' "$f" 2>/dev/null)
        label=$(jq -r '.label // empty' "$f" 2>/dev/null)
        [[ -n $ts && -n $sid && -n $sname && -n $win && -n $pane ]] || continue
        s=$((now - ts / 1000))
        ((s < 0)) && s=0
        if ((s < 60)); then
            age="now"
        elif ((s < 3600)); then
            age="$((s / 60))m"
        elif ((s < 86400)); then
            age="$((s / 3600))h"
        else
            age="$((s / 86400))d"
        fi
        if [[ $kind == "input" ]]; then
            icon="❓"
        else
            icon="🔔"
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$ts" "Q" "$icon $label ($age, $kind)" "$sid" "$sname" "$win" "$pane" "$kind"
    done | sort -t"$TAB" -k1,1n | cut -f2-
}

# Session rows below the queue: S | session name
session_rows() {
    tmux list-sessions -F "S${TAB}#S" 2>/dev/null
}

# Resolve the entry's CURRENT session name at pick time (renames happen): the
# stored window id is the stable handle; fall back to the stored name.
current_session_of() {
    local win=$1 stored_sname=$2 found
    found=$(tmux list-windows -a -F "#{window_id}${TAB}#{session_name}" 2>/dev/null |
        awk -F"$TAB" -v w="$win" '$1 == w {print $2; exit}')
    echo "${found:-$stored_sname}"
}

# Switch (inside tmux) or attach (from a plain terminal) to the entry's pane.
go_to() {
    local target_session="$1" win=$2 pane=$3
    if [ -n "$TMUX" ]; then
        tmux switch-client -t "$target_session" \; select-window -t "$win" \; select-pane -t "$pane"
    else
        tmux attach-session -t "$target_session" \; select-window -t "$win" \; select-pane -t "$pane"
    fi
}

dismiss() {
    rm -f "$SPOOL_DIR/$1.json"
}

# --- session handling --------------------------------------------------------

# Function to handle session transitions
transition_to_session() {
    local target_session="$1"
    local transition_type="$2" # "attach" or "switch"

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

# --- non-interactive modes ---------------------------------------------------

sessions=$(get_sessions)

# -l / --list: print all sessions and exit (fzf only shows what fits on screen;
# this always shows everything)
case "$1" in
-l | --list)
    if [ -z "$sessions" ]; then
        echo "No tmux sessions."
        exit 0
    fi
    tmux list-sessions -F "#{session_name}${TAB}#{session_windows}${TAB}#{session_attached}" |
    while IFS="$TAB" read -r name windows attached; do
        marker=" "
        [ "$name" = "$current_session" ] && marker="*"
        suffix=""
        [ "${attached:-0}" -gt 0 ] && suffix=" [attached]"
        printf '%s %-30s %3s window(s)%s\n' "$marker" "$name" "$windows" "$suffix"
    done
    exit 0
    ;;
--queue-list)
    queue_rows | cut -f2
    exit 0
    ;;
--queue-json)
    queue_rows | while IFS="$TAB" read -r _ _ sid _ _ _ kind; do
        jq -c --arg sid "$sid" --arg kind "$kind" \
            '{session_id: $sid, kind: $kind, timestamp: .timestamp, label: .label}' \
            "$SPOOL_DIR/$sid.json" 2>/dev/null
    done
    exit 0
    ;;
esac

# --- interactive unified picker ----------------------------------------------

if ! command -v fzf &> /dev/null; then
    echo "fzf is not installed. Please install it first."
    exit 1
fi

# The picker needs a real terminal (pi's bash tool, cron, etc. don't have one —
# use --queue-list/--queue-json/-l there).
if [[ ! -t 0 ]]; then
    echo "tmux_session_manager.sh: interactive picker needs a terminal; queue:"
    queue_rows | cut -f2
    exit 1
fi

if [ -z "$sessions" ] && [ -z "$(queue_rows)" ]; then
    # No existing sessions and nothing waiting: prompt for a new one
    echo "No existing tmux sessions."
    read -r -p "Enter new session name: " new_session
    if [ -z "$new_session" ]; then
        new_session="home"
    fi
    create_session "$new_session"
    exit 0
fi

# Triage loop: del dismisses a pi entry and re-renders; any other action exits.
while true; do
    n=$(queue_rows | wc -l)
    header="enter: go | ctrl-n: create session from typed name | esc: cancel"
    if [ "$n" -gt 0 ]; then
        header="enter: go | del: dismiss pi entry | ctrl-n: create session | esc: cancel — $n waiting"
    fi

    # Output lines: 1 = typed query, 2 = key pressed, 3 = selection (if any)
    # (fzf >= 0.48 prints query first, then the expect-key line)
    # Adaptive height (~): shrink to fit when the list is short, grow to 95% of
    # the terminal when it is long so as much as possible is visible without
    # scrolling. Matching is restricted to the visible field (--with-nth=2).
    fzf_output=$(
        {
            queue_rows
            session_rows
        } | fzf \
            --height=~95% --reverse \
            --query="$1" \
            --delimiter="$TAB" --with-nth=2 \
            --print-query \
            --expect=enter,del,ctrl-n \
            --header="$header" \
            --prompt="Jump: ")
    fzf_status=$?

    query=$(sed -n '1p' <<<"$fzf_output")
    fzf_key=$(sed -n '2p' <<<"$fzf_output")
    selection=$(sed -n '3p' <<<"$fzf_output")

    # 130 = interrupted with esc/ctrl-c: cancelled, do nothing
    if [ "$fzf_status" -eq 130 ]; then
        exit 0
    fi

    IFS="$TAB" read -r tag display sid sname win pane kind <<<"$selection"

    if [ "$fzf_key" = "del" ]; then
        # Dismiss a pi entry and re-render; del on anything else does nothing
        if [ "$tag" = "Q" ] && [ -n "$sid" ]; then
            dismiss "$sid"
            continue
        fi
        exit 0
    fi

    if [ "$fzf_key" = "ctrl-n" ]; then
        # Explicitly create a new session from the typed name, even when that
        # name fuzzy-matches an existing session or pi entry
        [ -n "$query" ] && handle_session_selection "$query"
        exit 0
    fi

    if [ -n "$selection" ]; then
        if [ "$tag" = "Q" ]; then
            # pi attention entry: jump to its exact pane; visiting dequeues it
            sname=$(current_session_of "$win" "$sname")
            dismiss "$sid"
            go_to "$sname" "$win" "$pane"
        else
            handle_session_selection "$display"
        fi
        exit 0
    elif [ -n "$query" ]; then
        # Enter with no matching row: treat the typed name as a new session
        handle_session_selection "$query"
        exit 0
    fi

    exit 0
done
