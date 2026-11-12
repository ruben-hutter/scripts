#!/usr/bin/env bash

# tq — pi attention queue picker. The "db" of pi sessions that finished or need
# input while you were elsewhere: a spool dir (~/.local/state/pi/attention,
# written by pi's notify.ts, deleted by tmux hooks + this script), surfaced as
# an fzf list oldest-first. Pick one to jump to its exact pane; visiting a pane
# by any means dequeues it (tmux pane-focus-in hook). Dead entries (pi process
# or pane gone) are pruned on every run — the list can never show corpses.
#
# Sibling of tmux_session_manager.sh (tm): alt+q opens this in a popup, alt+f
# opens tm. Unlike tm it targets panes, not sessions, and it mutates state.
#
# Usage: tq                          interactive fzf picker (enter: go, del: dismiss)
#        tq --list                   print the queue, oldest-first, one line each
#        tq --json                   same, as JSON lines

SPOOL_DIR="$HOME/.local/state/pi/attention"

command -v jq &>/dev/null || {
	echo "tq: jq is required" >&2
	exit 1
}

# --- pruning -----------------------------------------------------------------
# Invariant: a spool file exists only while its pi process AND its tmux pane
# are alive. Killing a pane/session drops exactly that entry (pane-granular);
# the same is enforced here at read time as the safety net.

prune() {
	local f pid pane
	local -a dead
	local panes
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

# --- listing -----------------------------------------------------------------
# One tab-separated row per entry: display | session_id | session | window | pane | kind
# (display is the only visible field; the rest is metadata for the actions).

rows() {
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
		# Sort oldest-first by timestamp; the ts is a leading sort key only, cut
		# before consumers see the rows (they expect display|sid|session|win|pane|kind).
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$ts" "$icon $label ($age, $kind)" "$sid" "$sname" "$win" "$pane" "$kind"
	done | sort -t$'\t' -k1,1n | cut -f2-
}

count_rows() {
	rows | wc -l
}

# --- non-interactive ---------------------------------------------------------

case "${1:-}" in
--list)
	rows | cut -f1
	exit 0
	;;
--json)
	rows | while IFS=$'\t' read -r _ sid _ _ _ kind; do
		jq -c --arg sid "$sid" --arg kind "$kind" \
			'{session_id: $sid, kind: $kind, timestamp: .timestamp, label: .label}' \
			"$SPOOL_DIR/$sid.json" 2>/dev/null
	done
	exit 0
	;;
esac

# --- interactive picker ------------------------------------------------------

command -v fzf &>/dev/null || {
	echo "tq: fzf is required" >&2
	exit 1
}

# Interactive picker needs a real terminal (pi's bash tool, cron, etc. don't
# have one — use --list/--json there).
if [[ ! -t 0 ]]; then
	echo "tq: interactive picker needs a terminal; use 'tq --list'"
	rows | cut -f1
	exit 1
fi

if ! command -v tmux &>/dev/null; then
	echo "tq: tmux is required" >&2
	exit 1
fi

# Resolve the entry's CURRENT session name at pick time (renames happen): the
# stored window id is the stable handle; fall back to the stored name.
current_session_of() {
	local win=$1 stored_sname=$2 found
	found=$(tmux list-windows -a -F '#{window_id}	#{session_name}' 2>/dev/null |
		awk -F'\t' -v w="$win" '$1 == w {print $2; exit}')
	echo "${found:-$stored_sname}"
}

# Switch (inside tmux) or attach (from a plain terminal) to the entry's pane.
go_to() {
	local sname win pane
	sname=$1
	win=$2
	pane=$3
	if [[ -n ${TMUX:-} ]]; then
		tmux switch-client -t "$sname" \; select-window -t "$win" \; select-pane -t "$pane"
	else
		tmux attach-session -t "$sname" \; select-window -t "$win" \; select-pane -t "$pane"
	fi
}

dismiss() {
	local sid=$1
	rm -f "$SPOOL_DIR/$sid.json"
}

while true; do
	n=$(count_rows)
	if ((n == 0)); then
		if [[ -t 1 ]]; then
			echo "Attention queue is empty."
			sleep 1
		else
			echo "Attention queue is empty."
		fi
		exit 0
	fi

	fzf_output=$(rows | fzf \
		--height=~95% --reverse \
		--delimiter=$'\t' --with-nth=1 \
		--expect=enter,del \
		--header="enter: go to pane | del: dismiss | esc: cancel — $n waiting" \
		--prompt="Waiting: ")
	fzf_status=$?

	key=$(sed -n '1p' <<<"$fzf_output")
	selection=$(sed -n '2p' <<<"$fzf_output")

	# 130 = interrupted with esc/ctrl-c
	if [[ $fzf_status -eq 130 ]]; then
		exit 0
	fi

	IFS=$'\t' read -r _ sid sname win pane _ <<<"$selection"
	if [[ -z $sid ]]; then
		exit 0
	fi

	if [[ $key == "del" ]]; then
		# Triage loop: dismiss and re-render.
		dismiss "$sid"
		continue
	fi

	sname=$(current_session_of "$win" "$sname")
	dismiss "$sid"
	go_to "$sname" "$win" "$pane"
	exit 0
done
