#!/usr/bin/env bash
set -euo pipefail

REPO_URL=${1:-}

if [ -z "$REPO_URL" ]; then
    echo "❌ Error: Missing repository URL."
    echo "Usage: $0 <repo-url>"
    exit 1
fi

REPO_NAME=$(basename "$REPO_URL" .git)

if [ -d "$REPO_NAME" ]; then
    echo "❌ Error: Directory '$REPO_NAME' already exists!"
    exit 1
fi

mkdir "$REPO_NAME"
cd "$REPO_NAME"

echo "🚀 Initializing Pro Git Worktree setup for '$REPO_NAME'..."

git clone --bare "$REPO_URL" .bare
echo "gitdir: ./.bare" > .git
git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
git fetch --all

echo "✅ Setup complete!"
echo "Next step: cd $REPO_NAME && git worktree add main"
