#!/usr/bin/env bash
# Sync the public subset of this repo into a persistent clone of the public repo and commit it.
#
#   scripts/export-public.sh <public-clone> [-m "commit message"]
#
# - Whitelist only: anything not listed below never leaves the private repo.
# - rsync --delete keeps the clone an exact mirror, but never touches its .git.
# - git init only the first time; afterwards plain commits (never rewrite history:
#   the plugin marketplace clones this repo and a rewritten history breaks updates).
# - Author and committer come from PUBLIC_GIT_NAME / PUBLIC_GIT_EMAIL (a noreply address).
# Run scripts/pii-gate.sh on the clone before pushing anything.
set -euo pipefail

WHITELIST=(
    .claude-plugin
    .github
    .gitignore
    LICENSE
    Package.swift
    README.md
    README.es.md
    Sources
    assets
    build-app.sh
    docs
    install.sh
    plugin
    scripts
    tests
)

dest="" msg="Sync from development repo"
while [ $# -gt 0 ]; do
    case "$1" in
        -m) msg="${2:?-m needs a message}"; shift 2 ;;
        *) [ -z "$dest" ] || { echo "usage: $0 <public-clone> [-m msg]" >&2; exit 2; }; dest="$1"; shift ;;
    esac
done
[ -n "$dest" ] || { echo "usage: $0 <public-clone> [-m msg]" >&2; exit 2; }
: "${PUBLIC_GIT_NAME:?set PUBLIC_GIT_NAME}" "${PUBLIC_GIT_EMAIL:?set PUBLIC_GIT_EMAIL (noreply)}"
case "$PUBLIC_GIT_EMAIL" in
    *@users.noreply.github.com) ;;
    *) echo "export-public: PUBLIC_GIT_EMAIL must be a users.noreply.github.com address" >&2; exit 2 ;;
esac

src="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$dest"
dest="$(cd "$dest" && pwd)"
[ "$dest" != "$src" ] || { echo "export-public: destination is the source repo" >&2; exit 2; }

# Only tracked files are exported: untracked scratch in a whitelisted folder stays behind.
list="$(mktemp)"; trap 'rm -f "$list"' EXIT
for entry in "${WHITELIST[@]}"; do
    git -C "$src" ls-files -- "$entry"
done > "$list"
[ -s "$list" ] || { echo "export-public: nothing to export" >&2; exit 1; }

rm -rf "$dest/.export-staging"
rsync -a --files-from="$list" "$src/" "$dest/.export-staging/"
rsync -a --delete --exclude=.git --exclude=.export-staging "$dest/.export-staging/" "$dest/"
rm -rf "$dest/.export-staging"

export GIT_AUTHOR_NAME="$PUBLIC_GIT_NAME" GIT_AUTHOR_EMAIL="$PUBLIC_GIT_EMAIL"
export GIT_COMMITTER_NAME="$PUBLIC_GIT_NAME" GIT_COMMITTER_EMAIL="$PUBLIC_GIT_EMAIL"
if [ ! -d "$dest/.git" ]; then
    git -C "$dest" init -q -b main
fi
git -C "$dest" add -A
if git -C "$dest" diff --cached --quiet; then
    echo "export-public: no changes"
else
    git -C "$dest" commit -q -m "$msg"
    echo "export-public: committed $(git -C "$dest" rev-parse --short HEAD) in $dest (not pushed)"
fi
