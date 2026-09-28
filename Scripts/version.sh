#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

CHANNEL="${MACPILOT_CHANNEL:-stable}"
TAG_FILTER=()
if [[ "$CHANNEL" == "stable" ]]; then
    TAG_FILTER+=(--exclude '*-*')
fi
TAG="$(git describe "${TAG_FILTER[@]}" --tags --match 'v[0-9]*.[0-9]*.[0-9]*' --abbrev=0 2>/dev/null || true)"

# In CI, GITHUB_REF_NAME gives the exact tag being built; prefer it over git describe
# when multiple tags point at the same commit (e.g. v1.1.8 and v1.1.9 on one commit).
if [[ -n "${GITHUB_REF_NAME:-}" && "${GITHUB_REF_NAME}" == v[0-9]*.[0-9]*.[0-9]* ]]; then
    TAG="${GITHUB_REF_NAME}"
fi

if [[ -n "$TAG" ]]; then
    BASE_VERSION="${TAG#v}"
    COMMITS_SINCE_TAG="$(git rev-list --count "$TAG"..HEAD)"
else
    BASE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
    COMMITS_SINCE_TAG="$(git rev-list --count HEAD)"
fi

# Exact release tags carry their prerelease suffix unchanged.
if [[ "$COMMITS_SINCE_TAG" == "0" && ( "$CHANNEL" != "beta" || "$BASE_VERSION" == *-beta.* || -n "${GITHUB_REF_NAME:-}" ) ]]; then
    print "$BASE_VERSION"
    exit 0
fi
CORE_VERSION="${BASE_VERSION%%-*}"
IFS='.' read -r MAJOR MINOR PATCH <<< "$CORE_VERSION"
if [[ ! "$MAJOR" =~ ^[0-9]+$ || ! "$MINOR" =~ ^[0-9]+$ || ! "$PATCH" =~ ^[0-9]+$ ]]; then
    print -u2 "Invalid semantic version: $BASE_VERSION"
    exit 1
fi
if [[ "$BASE_VERSION" == *-beta.* ]]; then
    print "$CORE_VERSION-beta.$(( ${BASE_VERSION##*.} + COMMITS_SINCE_TAG ))"
elif [[ "$CHANNEL" == "beta" ]]; then
    INCREMENT="$COMMITS_SINCE_TAG"
    (( INCREMENT > 0 )) || INCREMENT=1
    print "$MAJOR.$MINOR.$((PATCH + INCREMENT))-beta.1"
else
    print "$MAJOR.$MINOR.$((PATCH + COMMITS_SINCE_TAG))"
fi
