#!/usr/bin/env bash
# Tags the version in VERSION and pushes it, which starts the release workflow.
# Update VERSION and CHANGELOG.md and commit them first. See CONTRIBUTING.md.
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="$(tr -d '[:space:]' < VERSION)"
TAG="v$VERSION"

fail() { echo "error: $1" >&2; exit 1; }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "VERSION must look like 1.2.3, not '$VERSION'"
[[ "$(git branch --show-current)" == "main" ]] || fail "release from main"
[[ -z "$(git status --porcelain)" ]] || fail "commit your changes first"
grep -q "^## \[$VERSION\]" CHANGELOG.md || fail "CHANGELOG.md has no section for $VERSION"

git fetch --quiet --tags origin
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "main isn't in sync with origin"
git rev-parse --quiet --verify "refs/tags/$TAG" >/dev/null && fail "$TAG already exists"

if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p)" == *CommandLineTools* ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
swift test

git tag -a "$TAG" -m "Tack $VERSION"
git push origin "$TAG"
echo "Pushed $TAG. Follow the release at: gh run watch"
