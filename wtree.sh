#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage:"
    echo "  $0 <repo-url>           # clone existing repo into worktree setup"
    echo "  $0 --new <repo-name>    # init a new bare repo worktree setup"
    echo "  $0 feature <name>       # create worktree <name> on feat/<name>; inside tmux opens a pi window there"
    echo "  $0 finish <name>       # rebase feat/<name> onto the default branch, ff-merge, remove worktree"
}

MODE="clone"
if [ "${1:-}" = "--new" ] || [ "${1:-}" = "-n" ]; then
    MODE="init"
    shift
fi

case "${1:-}" in
    feature) MODE="feature"; shift ;;
    finish)  MODE="finish";  shift ;;
esac

ARG=${1:-}

find_repo_root() {
    local dir="$PWD"
    while [ "$dir" != "/" ]; do
        if [ -d "$dir/.bare" ]; then
            printf '%s\n' "$dir"
            return 0
        fi
        dir=$(dirname "$dir")
    done
    return 1
}

# Resolve the repo's default branch without hardcoding names:
# origin/HEAD if set, else the bare repo's own HEAD (set at clone/init time
# to the remote's default), else the user's configured default, else main.
default_branch() {
    local repo="$1" b
    if b=$(git -C "$repo" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null); then
        printf '%s\n' "${b#origin/}"
        return 0
    fi
    if b=$(git -C "$repo" symbolic-ref --short HEAD 2>/dev/null); then
        printf '%s\n' "$b"
        return 0
    fi
    if b=$(git config --get init.defaultbranch 2>/dev/null) && [ -n "$b" ]; then
        printf '%s\n' "$b"
        return 0
    fi
    printf 'main\n'
}

# Print the worktree directory that has the given branch checked out.
worktree_dir_for_branch() {
    local repo="$1" branch="$2" wt="" b bare=0
    while IFS= read -r line; do
        case "$line" in
            worktree*) wt=${line#worktree } ; bare=0 ;;
            bare)      bare=1 ;;
            branch*)
                b=${line#branch refs/heads/}
                if [ "$b" = "$branch" ] && [ "$bare" -eq 0 ] && [ -n "$wt" ] \
                   && [ "${wt##*/}" != ".bare" ]; then
                    printf '%s\n' "$wt"
                    return 0
                fi
                ;;
        esac
    done < <(git -C "$repo" worktree list --porcelain 2>/dev/null)
    return 1
}

if [ -z "$ARG" ]; then
    usage
    exit 1
fi

# --- feature: create a worktree on a new feat/<name> branch -----------------
if [ "$MODE" = "feature" ]; then
    REPO_ROOT=$(find_repo_root) || { echo "❌ Not inside a wtree repo (no .bare directory found)"; exit 1; }
    NAME="$ARG"
    BRANCH="feat/$NAME"
    WORKTREE="$REPO_ROOT/$NAME"

    if [ -e "$WORKTREE" ]; then
        echo "❌ Directory '$WORKTREE' already exists!"
        exit 1
    fi
    if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$BRANCH"; then
        echo "❌ Branch '$BRANCH' already exists but has no worktree."
        echo "   Recover it with: git -C \"$REPO_ROOT\" worktree add \"$WORKTREE\" \"$BRANCH\""
        exit 1
    fi

    git -C "$REPO_ROOT" worktree add "$WORKTREE" -b "$BRANCH"
    echo "✅ Feature worktree ready: $WORKTREE (branch $BRANCH)"

    # tmux: when already inside tmux, open a background window per feature
    # rooted in the worktree, running pi (the window closes when pi exits).
    # Focus stays on the current window. Outside tmux nothing is created.
    if [ -z "${TMUX:-}" ]; then
        echo "Next: cd $WORKTREE"
        exit 0
    fi

    if tmux new-window -d -c "$WORKTREE" pi >/dev/null 2>&1; then
        echo "🪟 tmux window opened in background at $WORKTREE"
    else
        echo "⚠️  Could not open a tmux window — cd manually: cd $WORKTREE"
    fi
    exit 0
fi

# --- finish: rebase onto main, ff-merge, clean up ----------------------------
if [ "$MODE" = "finish" ]; then
    REPO_ROOT=$(find_repo_root) || { echo "❌ Not inside a wtree repo (no .bare directory found)"; exit 1; }
    NAME="$ARG"
    BRANCH="feat/$NAME"
    WORKTREE="$REPO_ROOT/$NAME"

    MAIN_BRANCH=$(default_branch "$REPO_ROOT")
    MAIN_WT=$(worktree_dir_for_branch "$REPO_ROOT" "$MAIN_BRANCH" || true)
    if [ -z "${MAIN_WT:-}" ]; then
        # last resort: a worktree directory named main/ or master/
        for d in main master; do
            if [ -d "$REPO_ROOT/$d" ] \
               && b=$(git -C "$REPO_ROOT/$d" branch --show-current 2>/dev/null) \
               && [ -n "$b" ]; then
                MAIN_WT="$REPO_ROOT/$d"
                break
            fi
        done
    fi
    if [ -z "${MAIN_WT:-}" ]; then
        echo "❌ No worktree for default branch '$MAIN_BRANCH' found in $REPO_ROOT"
        echo "   Create it with: git -C \"$REPO_ROOT\" worktree add <dir> $MAIN_BRANCH"
        exit 1
    fi
    # the merge target is whatever branch the main worktree actually holds
    MAIN_BRANCH=$(git -C "$MAIN_WT" branch --show-current)
    if [ ! -d "$WORKTREE" ]; then
        echo "❌ No worktree at $WORKTREE"
        exit 1
    fi
    case "$PWD" in
        "$WORKTREE"|"$WORKTREE"/*)
            echo "❌ You are inside the worktree being finished. cd out first (e.g. cd \"$MAIN_WT\")"
            exit 1
            ;;
    esac

    CURRENT_BRANCH=$(git -C "$WORKTREE" branch --show-current)
    if [ "$CURRENT_BRANCH" != "$BRANCH" ]; then
        echo "❌ Worktree '$NAME' is on branch '$CURRENT_BRANCH', expected '$BRANCH'."
        exit 1
    fi
    if [ -n "$(git -C "$WORKTREE" status --porcelain)" ]; then
        echo "❌ '$NAME' has uncommitted changes. Commit or stash them first."
        exit 1
    fi
    if [ -n "$(git -C "$MAIN_WT" status --porcelain)" ]; then
        echo "❌ The main worktree has uncommitted changes. Clean it up first."
        exit 1
    fi

    cd "$MAIN_WT"

    echo "🔁 Rebasing $BRANCH onto $MAIN_BRANCH..."
    if ! git -C "$WORKTREE" rebase "$MAIN_BRANCH"; then
        git -C "$WORKTREE" rebase --abort
        echo "❌ Rebase had conflicts — nothing was changed. Resolve them manually or ask the user."
        exit 1
    fi

    echo "🔀 Fast-forwarding $MAIN_BRANCH..."
    if ! git -C "$MAIN_WT" merge --ff-only "$BRANCH"; then
        echo "❌ Fast-forward merge failed. Nothing destructive was done."
        exit 1
    fi

    echo "🧹 Removing worktree and branch..."
    git worktree remove "$WORKTREE"
    git branch -d "$BRANCH"

    echo "✅ Feature '$NAME' merged into $(basename "$MAIN_WT")"

    if [ -n "${TMUX:-}" ]; then
        LEFTOVER=$(tmux list-panes -a -F '#{pane_current_path}|#{window_id}' 2>/dev/null | awk -F'|' -v w="$WORKTREE" 'index($1, w) == 1 {print $2; exit}')
        if [ -n "$LEFTOVER" ]; then
            echo "🪟 tmux window $LEFTOVER still runs in $WORKTREE — close it: tmux kill-window -t $LEFTOVER"
        fi
    fi
    exit 0
fi

# --- clone / init (original behavior) ----------------------------------------

if [ "$MODE" = "clone" ]; then
    REPO_NAME=$(basename "$ARG" .git)
    SOURCE_URL="$ARG"
else
    REPO_NAME="$ARG"
    SOURCE_URL=""
fi

if [ -d "$REPO_NAME" ]; then
    echo "❌ Error: Directory '$REPO_NAME' already exists!"
    exit 1
fi

mkdir "$REPO_NAME"
cd "$REPO_NAME"

echo "🚀 Initializing Pro Git Worktree setup for '$REPO_NAME'..."

if [ "$MODE" = "clone" ]; then
    git clone --bare "$SOURCE_URL" .bare
    echo "gitdir: ./.bare" > .git
    git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
    git fetch --all
else
    git init --bare .bare
    echo "gitdir: ./.bare" > .git
fi

echo "✅ Setup complete!"
DEFAULT_BRANCH=$(default_branch .)
echo "Next step: cd $REPO_NAME && git worktree add $DEFAULT_BRANCH"
