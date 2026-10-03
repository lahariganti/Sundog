#!/bin/sh
# Fails when Git tracks a file that must stay out of the public repository:
# a file that matches .gitignore or the local .git/info/exclude.
set -eu

cd "$(dirname "$0")/.."

exclude="$(git rev-parse --git-path info/exclude)"
blocked=$(
    {
        git ls-files --cached --ignored --exclude-standard
        if [ -f "$exclude" ]; then
            git ls-files --cached --ignored --exclude-from="$exclude"
        fi
    } | sort -u
)

if [ -n "$blocked" ]; then
    echo "These files must not be in Git:" >&2
    echo "$blocked" >&2
    exit 1
fi

echo "Repository check passed."
