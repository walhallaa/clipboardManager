#!/bin/bash
# Ships dev: bumps the marketing version and the build number, commits, merges dev
# into main and pushes main. Pushing main starts the TestFlight workflow.
# macOS build numbers must keep increasing across versions, so the build is never reset.
#
# Every release needs fresh App Store "What's New" text in fastlane/release_notes/, because App
# Store review refuses a version without it. If the notes haven't changed since the last deploy,
# the script offers to draft them with Claude from the commits going out, and you approve the text.
#
# usage: scripts/deploy.sh [minor|major|patch] [-y]
#   minor (default)  3.2.0 -> 3.3.0
#   major            3.2.0 -> 4.0.0
#   patch            3.2.0 -> 3.2.1
#   -y               skip the confirmation prompt (release notes must already be updated and committed)
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

# main can be ahead of dev (merged PRs), so the next build follows whichever is higher.
build_of() { sed -nE 's/.*CURRENT_PROJECT_VERSION = ([0-9]+);.*/\1/p' | head -1; }
DEV_BUILD="$(build_of < "$PBXPROJ")"
MAIN_BUILD="$(git show "origin/main:$PBXPROJ" 2>/dev/null | build_of)"
[ -n "$DEV_BUILD" ] || fail "Couldn't read CURRENT_PROJECT_VERSION from $PBXPROJ"
CURRENT_BUILD=$(( ${MAIN_BUILD:-0} > DEV_BUILD ? ${MAIN_BUILD:-0} : DEV_BUILD ))
NEXT_BUILD=$((CURRENT_BUILD + 1))

IFS=. read -r MAJOR MINOR PATCH <<<"$CURRENT"
MINOR="${MINOR:-0}"; PATCH="${PATCH:-0}"
case "$LEVEL" in
    major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
    minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
    patch) PATCH=$((PATCH + 1)) ;;
esac
NEXT="$MAJOR.$MINOR.$PATCH"

echo "Deploy: $CURRENT ($CURRENT_BUILD) -> $NEXT ($NEXT_BUILD), merge dev into main, push main"
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

# Bring in anything merged straight into main (PRs, bot fixes) so the merge below is clean.
git merge origin/main --no-edit --quiet || fail "Merging origin/main into dev conflicted. Resolve it on dev, then run the deploy again."

NOTES_DIR="fastlane/release_notes"
NOTES_CHECK=".github/scripts/release_notes.py"
NOTES_HINT="Update $NOTES_DIR/default.txt (rules are in CLAUDE.md), commit it, then run the deploy again."

if git diff --quiet origin/main -- "$NOTES_DIR"; then
    echo "✖ $NOTES_DIR hasn't changed since the last deploy, so it still describes the previous release." >&2
    if [ "$ASSUME_YES" -eq 1 ] || ! command -v claude >/dev/null 2>&1; then
        fail "$NOTES_HINT"
    fi
    read -r -p "Draft them with Claude from the commits going out? [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]] || fail "$NOTES_HINT"

    COMMITS="$(git log origin/main..dev --no-merges --pretty='- %s')"
    echo "Asking Claude for a draft..."
    DRAFT="$(claude -p "Write the App Store 'What's New' text for version $NEXT of this app, following the release notes rules in CLAUDE.md. Base it only on the commits below and leave out anything internal (CI, scripts, refactors, docs). One short plain sentence per change, one per line, no title, no bullets, no markdown. Reply with the text only.

Commits going out:
$COMMITS")" || fail "Claude couldn't draft the notes. $NOTES_HINT"
    [ -n "$DRAFT" ] || fail "Claude returned nothing. $NOTES_HINT"
    printf '%s\n' "$DRAFT" > "$NOTES_DIR/default.txt"

    python3 "$NOTES_CHECK" check "$NOTES_DIR" || fail "The draft is saved in $NOTES_DIR/default.txt but breaks the rules above. Fix it, commit it, then run the deploy again."
    echo "---- Draft release notes ----"; cat "$NOTES_DIR/default.txt"; echo "-----------------------------"
    read -r -p "Use these release notes? [y/N] " reply
    if [[ ! "$reply" =~ ^[Yy]$ ]]; then
        git checkout -- "$NOTES_DIR"
        fail "Discarded the draft. $NOTES_HINT"
    fi
fi
python3 "$NOTES_CHECK" check "$NOTES_DIR" || fail "$NOTES_HINT"

sed -i '' -E "s/MARKETING_VERSION = [0-9.]+;/MARKETING_VERSION = $NEXT;/; s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = $NEXT_BUILD;/" "$PBXPROJ"
git add "$PBXPROJ" "$NOTES_DIR"
git commit --quiet -m "Release $NEXT"

git checkout main --quiet
git merge --ff-only "origin/main" --quiet || fail "Local main has diverged from origin/main. Sort that out first."
git merge dev --no-edit --quiet
git push origin main

git checkout dev --quiet
trap - EXIT
echo "✔ Pushed main with $NEXT ($NEXT_BUILD). TestFlight workflow is starting. You're back on dev."
