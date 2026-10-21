#!/bin/bash
# Ships a new version of Lunchbox to everyone who has it:
#   scripts/ship.sh 1.0.1 "What changed, in a sentence or two."            offered within about an hour
#   scripts/ship.sh 1.0.2 "Fixes a crash on wake." --critical               the same, and can't be skipped
# 1. Builds, signs and notarizes it (scripts/release.sh), with the notes for the update prompt.
# 2. Deploys the site, so the download and the update feed (appcast.xml) carry it.
# 3. Commits the feed, tags v<version> and pushes.
# Running copies check the feed about once an hour (SUScheduledCheckInterval) and ask to install;
# Settings › Check for Updates… finds it straight away.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: scripts/ship.sh <version> \"<what changed>\" [--critical]}"
NOTES="${2:?Say what changed, for the update prompt.}"
CRITICAL=""
[[ "${3:-}" == "--critical" ]] && CRITICAL=1
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || { echo "A version looks like 1.0.1."; exit 1; }
[[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || { echo "Ship from main."; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Commit your changes first: a release is built from what's committed."; exit 1; }
git pull -q --ff-only
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then echo "v$VERSION was already shipped."; exit 1; fi

notes="$(mktemp -d)/notes.html"
escaped="$(printf '%s' "$NOTES" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')"
printf '<h2>What’s new in Lunchbox %s</h2>\n<p>%s</p>\n' "$VERSION" "$escaped" > "$notes"

RELEASE_NOTES="$notes" CRITICAL="$CRITICAL" bash scripts/release.sh "$VERSION"
CI=1 npx -y wrangler@4 pages deploy --project-name lunchbox --branch main
# The download and the feed are live: check before calling it shipped.
curl -fsS "https://lunchboxwm.com/appcast.xml" | grep -q "<sparkle:shortVersionString>$VERSION<" \
  || { echo "The live update feed doesn't list $VERSION yet. Check the deploy."; exit 1; }

git add site/appcast.xml
# GIT_TRAILER: an extra last paragraph for the release commit (a Co-Authored-By line, say).
git commit -q -m "Release Lunchbox $VERSION" -m "$NOTES" ${GIT_TRAILER:+-m "$GIT_TRAILER"}
git tag "v$VERSION"
git push -q
git push -q origin "v$VERSION"
echo "Shipped Lunchbox $VERSION. Running copies offer it within about an hour${CRITICAL:+ (critical: no skipping)}."
