#!/bin/bash
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO_ROOT"
CONFIGURATION="${1:-Debug}"
if [[ "$CONFIGURATION" != "Debug" && "$CONFIGURATION" != "Release" ]]; then
    echo "Usage: build-fan-artifact.sh [Debug|Release]" >&2
    exit 2
fi
ARTIFACT_DERIVED_DIR="$REPO_ROOT/build/fan-artifact"
BUILD_SIGN_ARGS=()
if [[ -n "${MACHELM_DEVELOPMENT_TEAM:-}" ]]; then
    BUILD_SIGN_ARGS+=("DEVELOPMENT_TEAM=$MACHELM_DEVELOPMENT_TEAM")
fi
if [[ -n "${MACHELM_SIGN_IDENTITY:-}" ]]; then
    BUILD_SIGN_ARGS+=("CODE_SIGN_IDENTITY=$MACHELM_SIGN_IDENTITY")
fi
xcodebuild -project MacHelm.xcodeproj -scheme MacHelm \
    -configuration "$CONFIGURATION" -derivedDataPath "$ARTIFACT_DERIVED_DIR" \
    ${BUILD_SIGN_ARGS[@]+"${BUILD_SIGN_ARGS[@]}"} build
"$REPO_ROOT/scripts/verify-fan-artifact.sh" "$ARTIFACT_DERIVED_DIR/Build/Products/$CONFIGURATION/MacHelm.app"
"$REPO_ROOT/scripts/verify-toolkit-artifact.sh" "$ARTIFACT_DERIVED_DIR/Build/Products/$CONFIGURATION/MacHelm.app"
echo "Built artifact: $ARTIFACT_DERIVED_DIR/Build/Products/$CONFIGURATION/MacHelm.app"
