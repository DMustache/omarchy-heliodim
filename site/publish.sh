#!/bin/bash
# Build the site and push it to the gh-pages branch, which GitHub Pages serves.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -I assets/gen.py

dir=$(mktemp -d)
trap 'git worktree remove --force "$dir" 2>/dev/null || true; rm -rf "$dir"' EXIT
if git ls-remote --exit-code --heads origin gh-pages >/dev/null; then
  git fetch -q origin +refs/heads/gh-pages:refs/remotes/origin/gh-pages
  git worktree add -q "$dir" origin/gh-pages --detach
else
  git worktree add -q --detach "$dir"
  git -C "$dir" checkout -q --orphan gh-pages-tmp
  git -C "$dir" rm -rq --cached . && git -C "$dir" clean -fdxq
fi
cp site/dist/index.html "$dir/index.html"
touch "$dir/.nojekyll"
git -C "$dir" add index.html .nojekyll
if git -C "$dir" diff --cached --quiet; then echo "site unchanged"; exit 0; fi
git -C "$dir" commit -qm "site: publish from $(git rev-parse --short HEAD)"
git -C "$dir" push -q origin HEAD:gh-pages
echo "pushed to gh-pages"
