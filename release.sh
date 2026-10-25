#!/usr/bin/env bash
# Builds the version in macos/Info.plist, has Apple notarize it and publishes it as a GitHub
# release. Needs a "Developer ID Application" identity and a notarytool keychain profile
# (NOTARY_PROFILE, default "notary"; create it with `xcrun notarytool store-credentials`).
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' macos/Info.plist)
TAG="v$VERSION"
APP="build/Agents Monitor.app"
ZIP="build/AgentsMonitor-$VERSION.zip"
NOTARY_PROFILE="${NOTARY_PROFILE:-notary}"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Commit or stash your changes first." >&2
  exit 1
fi
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || git ls-remote --exit-code --tags origin "$TAG" >/dev/null; then
  echo "$TAG already exists. Bump CFBundleShortVersionString in macos/Info.plist first." >&2
  exit 1
fi
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  echo "No Developer ID Application identity in the keychain." >&2
  exit 1
fi

./build.sh

# Apple notarizes a zip of the app. The ticket is then stapled to the app, so it opens offline too.
ditto -c -k --keepParent "$APP" "$ZIP"
STATUS=$(xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json | plutil -extract status raw -)
if [[ "$STATUS" != Accepted ]]; then
  echo "Notarization failed with status $STATUS. Run xcrun notarytool log <id> for details." >&2
  exit 1
fi
xcrun stapler staple "$APP"
rm "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

git tag -a "$TAG" -m "Agents Monitor $VERSION"
git push origin "$TAG"
gh release create "$TAG" "$ZIP" --title "Agents Monitor $VERSION" \
  --notes "Unzip it, move **Agents Monitor.app** to \`/Applications\` and open it from there. Signed with a Developer ID and notarized by Apple. Requires macOS 14 or later."
echo "Released $TAG"
