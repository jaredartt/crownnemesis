#!/usr/bin/env bash
# Build and publish to https://jaredartt.github.io/tactica/
#
# Publishes the built output to the gh-pages branch. That branch is
# generated, never edited by hand.
#
# Incremental since 2026-09: this used to `git init` a brand new orphan
# history and force-push the ENTIRE build output every single deploy --
# ~155MB, most of it /music, which barely ever changes. That meant every
# deploy re-uploaded music that was already sitting on GitHub from the
# deploy before, and on a slow connection or a tool with a hard per-call
# timeout that upload could simply not finish in time. Now this clones the
# CURRENT gh-pages, overlays the new build on top of it, and commits/pushes
# normally -- git only ever transfers objects that actually changed, so a
# typical deploy (a few source files, no new assets) is small and fast. The
# one-time cost is the very first run of this version, which still has to
# pull the existing ~155MB tree down before it can diff against it.
set -euo pipefail
cd "$(dirname "$0")"

# Built outside the project tree on purpose: on a synced/managed folder Vite
# can be refused permission to empty ./dist, and the build dies on a stale
# hashed asset it cannot unlink.
OUT="$(mktemp -d)"
./node_modules/.bin/tsc -b
./node_modules/.bin/vite build --outDir "$OUT" --emptyOutDir

REMOTE="${TACTICA_REMOTE:-https://github.com/jaredartt/tactica.git}"
WORK="$(mktemp -d)"

# The scratch repo has no identity of its own; borrow the project's, and fall
# back to a placeholder so this works on a machine with no global git config.
NAME="$(git -C "$OLDPWD" config user.name  || echo 'Crown Nemesis deploy')"
MAIL="$(git -C "$OLDPWD" config user.email || echo 'deploy@localhost')"

if git ls-remote --exit-code --heads "$REMOTE" gh-pages >/dev/null 2>&1; then
  # Shallow: one commit's worth of history is all a diff against the
  # current tree ever needs, and it's what keeps this fast on every deploy
  # after the first -- a full clone would re-download nothing we use.
  git clone --quiet --depth 1 --branch gh-pages "$REMOTE" "$WORK"
else
  # First deploy ever, or the branch was deleted -- start fresh.
  git init -q -b gh-pages "$WORK"
fi

# Mirror the new build into place: drop everything gh-pages currently has
# (stale hashed assets, files the build no longer produces) except .git,
# then copy the fresh build over it.
find "$WORK" -mindepth 1 -maxdepth 1 -not -name '.git' -exec rm -rf {} +
cp -R "$OUT/." "$WORK/"
rm -rf "$OUT"
touch "$WORK/.nojekyll"         # stop Pages running the output through Jekyll

cd "$WORK"
git add -A
if git diff --cached --quiet; then
  echo "Nothing changed -- gh-pages already matches this build."
else
  git -c user.name="$NAME" -c user.email="$MAIL" commit -q -m "Deploy $(date -u +%Y-%m-%dT%H:%MZ)"
  if ! git push -q "$REMOTE" gh-pages; then
    # gh-pages moved out from under us (a deploy from elsewhere, or this
    # script's first run raced a manual push) -- this branch is always
    # meant to just be "the latest build", so force is the right recovery,
    # not a merge.
    git push -q --force "$REMOTE" gh-pages
  fi
  echo "Deployed. Live in ~1 min: https://jaredartt.github.io/tactica/"
fi
cd - >/dev/null
rm -rf "$WORK"
