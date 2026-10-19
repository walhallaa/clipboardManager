#!/bin/bash
# Prints KEY=VALUE lines (for $GITHUB_ENV) read from the Xcode project, so the
# workflows never hard-code the bundle ID, version, build number or team.
set -euo pipefail

PROJECT="$(ls -d ./*.xcodeproj | head -1 | sed 's|^\./||')"
SCHEME="${SCHEME:-${PROJECT%.xcodeproj}}"

xcodebuild -resolvePackageDependencies -project "$PROJECT" -scheme "$SCHEME" >/dev/null 2>&1

# Package-resolution chatter can precede the JSON, which starts on a line of its own.
SETTINGS="$(xcodebuild -showBuildSettings -json -project "$PROJECT" -scheme "$SCHEME" \
    -configuration Release -skipMacroValidation 2>/dev/null | sed -n '/^\[$/,$p' \
    | jq -c '[.[] | select(.buildSettings.WRAPPER_EXTENSION == "app")][0].buildSettings')"

echo "PROJECT=$PROJECT"
echo "SCHEME=$SCHEME"
echo "BUNDLE_ID=$(jq -r .PRODUCT_BUNDLE_IDENTIFIER <<<"$SETTINGS")"
echo "MARKETING_VERSION=$(jq -r .MARKETING_VERSION <<<"$SETTINGS")"
echo "PROJECT_BUILD=$(jq -r .CURRENT_PROJECT_VERSION <<<"$SETTINGS")"
echo "TEAM_ID=$(jq -r .DEVELOPMENT_TEAM <<<"$SETTINGS")"
