#!/usr/bin/env bash
set -euo pipefail

REPO_URL=${1:-}

if [ -z "$REPO_URL" ]; then
    echo "❌ Error: Missing repository URL."
    echo "Usage: $0 <repo-url>"
    exit 1
fi

for f in .* *; do
    [ "$f" = "." ] || [ "$f" = ".." ] || [ "$f" = ".git" ] && continue
    if [ -e "$f" ]; then
        echo "❌ Error: Current directory is not empty!"
        echo "To keep your worktree setup clean, please run this in a fresh folder."
        exit 1
    fi
done

echo "🚀 Initializing Pro Git Worktree setup..."

git clone --bare "$REPO_URL" .bare
echo "gitdir: ./.bare" > .git
git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
git fetch --all

echo "✅ Setup complete!"
echo "Next step: git worktree add main"
