#!/usr/bin/env bash
set -euo pipefail

MODE="clone"
if [ "${1:-}" = "--new" ] || [ "${1:-}" = "-n" ]; then
    MODE="init"
    shift
fi

ARG=${1:-}

if [ -z "$ARG" ]; then
    echo "Usage:"
    echo "  $0 <repo-url>           # clone existing repo into worktree setup"
    echo "  $0 --new <repo-name>    # init a new bare repo worktree setup"
    exit 1
fi

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
echo "Next step: cd $REPO_NAME && git worktree add main"
