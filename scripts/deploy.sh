#!/bin/bash
# Ships dev: bumps the marketing version (build stays 1), commits, merges dev into
# main and pushes main. Pushing main starts the TestFlight workflow.
#
# usage: scripts/deploy.sh [minor|major|patch] [-y]
#   minor (default)  3.2.0 -> 3.3.0
#   major            3.2.0 -> 4.0.0
#   patch            3.2.0 -> 3.2.1
#   -y               skip the confirmation prompt
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PBXPROJ="$(ls -d ./*.xcodeproj | head -1)/project.pbxproj"
LEVEL="minor"
ASSUME_YES=0
for arg in "$@"; do
    case "$arg" in
        major|minor|patch) LEVEL="$arg" ;;
        -y|--yes) ASSUME_YES=1 ;;
        *) echo "Unknown argument: $arg (expected major|minor|patch|-y)" >&2; exit 2 ;;
    esac
done

fail() { echo "✖ $*" >&2; exit 1; }

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = "dev" ] || fail "You are on '$BRANCH'. Deploys only run from 'dev', so switch with: git checkout dev"
[ -z "$(git status --porcelain)" ] || fail "Working tree isn't clean. Commit or stash your changes first."

git fetch origin --quiet

CURRENT="$(grep -m1 'MARKETING_VERSION = ' "$PBXPROJ" | sed -E 's/.*= ([0-9.]+);.*/\1/')"
[ -n "$CURRENT" ] || fail "Couldn't read MARKETING_VERSION from $PBXPROJ"

IFS=. read -r MAJOR MINOR PATCH <<<"$CURRENT"
MINOR="${MINOR:-0}"; PATCH="${PATCH:-0}"
case "$LEVEL" in
    major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
    minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
    patch) PATCH=$((PATCH + 1)) ;;
esac
NEXT="$MAJOR.$MINOR.$PATCH"

echo "Deploy: $CURRENT -> $NEXT (build 1), merge dev into main, push main"
if [ "$ASSUME_YES" -ne 1 ]; then
    read -r -p "Continue? [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]] || fail "Cancelled."
fi

# From here on, a failure leaves you on dev rather than stranded on main mid-merge.
restore() {
    git merge --abort 2>/dev/null || true
    git checkout dev --quiet 2>/dev/null || true
}
trap restore EXIT

sed -i '' -E "s/MARKETING_VERSION = [0-9.]+;/MARKETING_VERSION = $NEXT;/; s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = 1;/" "$PBXPROJ"
git add "$PBXPROJ"
git commit --quiet -m "Release $NEXT"

git checkout main --quiet
git merge --ff-only "origin/main" --quiet || fail "Local main has diverged from origin/main. Sort that out first."
git merge dev --no-edit --quiet
git push origin main

git checkout dev --quiet
trap - EXIT
echo "✔ Pushed main with $NEXT. TestFlight workflow is starting. You're back on dev."
