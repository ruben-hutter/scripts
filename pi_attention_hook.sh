#!/usr/bin/env bash

# tmux hook handler for the pi attention queue (see pi_attention_queue.sh). DELETE-ONLY: it never
# creates entries (that is notify.ts inside pi). Registered in .tmux.conf:
#
#   pane-focus-in           user is looking at that pane  -> dequeue (visit = read)
#   client-session-changed  focus follows the switched-to session's active pane
#   pane-died|pane-exited|  work is dead: sweep entries whose pane is gone
#   after-kill-pane |
#   window-closed           (covers kill-window, session close, last pane exit)
#   session-closed          whole tmux session gone -> drop by session name
#
# WHY NO FORMAT ARGS on the death hooks: tmux 3.8 quirks, all verified live —
#   * hook format vars are NOT exported to run-shell's environment;
#   * a tmux-level `A \; B` chain only executes A;
#   * run-shell's extra args become #{1}/#{2} substitution sources, NOT argv —
#     `run-shell -b 'script' arg` runs script with EMPTY argv;
#   * #{hook_pane} is EMPTY for after-kill-pane (pane already destroyed) and
#     #{hook_session} is an unrelated counter.
# The only reliable hook identities are #{hook_pane} on pane-focus-in and
# #{hook_session_name} on session events; death events are identity-free and
# use a liveness sweep (tmux never reuses pane ids, so this is exact).
# Errors are swallowed: a queue bug must never surface in the terminal.

SPOOL_DIR="$HOME/.local/state/pi/attention"

hook_name=${1:-${hook:-}}
hook_id=${2:-${pane_id:-${session_id:-}}}

# Delete every entry whose tmux_pane equals $1.
remove_by_pane() {
	local pane=$1 f
	[[ -n $pane ]] || return 0
	for f in "$SPOOL_DIR"/*.json; do
		[[ -e $f ]] || return 0
		[[ $(jq -r '.tmux_pane // empty' "$f" 2>/dev/null) == "$pane" ]] && rm -f "$f"
	done
}

# Delete every entry whose tmux_session equals $1 (NAME match — #{hook_session}
# is an unrelated counter; read-time pruning backstops renames).
remove_by_session_name() {
	local sname=$1 f
	[[ -n $sname ]] || return 0
	for f in "$SPOOL_DIR"/*.json; do
		[[ -e $f ]] || return 0
		[[ $(jq -r '.tmux_session // empty' "$f" 2>/dev/null) == "$sname" ]] && rm -f "$f"
	done
}

# Drop every entry whose tmux_pane no longer exists anywhere on the server.
# Exact for every death path (kill-window, kill-pane, session close, process
# exit) because pane ids are monotonic and never reused. Surviving entries are
# untouched, which makes this pane-granular for free.
prune_dead_panes() {
	local f pane
	local panes
	panes=$(tmux list-panes -a -F '#{pane_id}' 2>/dev/null)
	for f in "$SPOOL_DIR"/*.json; do
		[[ -e $f ]] || return 0
		pane=$(jq -r '.tmux_pane // empty' "$f" 2>/dev/null)
		[[ -n $pane ]] || continue
		grep -Fxq "$pane" <<<"$panes" || rm -f "$f"
	done
}

case "$hook_name" in
pane-focus-in)
	remove_by_pane "$hook_id"
	;;
prune-dead-panes | pane-died | pane-exited | after-kill-pane | window-closed)
	prune_dead_panes
	;;
# Switching sessions lands focus on the target's active pane; dequeue it
# directly in case the pane-focus-in event is not delivered on session switch.
client-session-changed)
	active=$(tmux display-message -p -t "$hook_id" '#{pane_id}' 2>/dev/null)
	remove_by_pane "$active"
	;;
session-closed)
	remove_by_session_name "$hook_id"
	;;
esac

exit 0
