#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP_PATH="${1:?Usage: build-fan-acceptance.sh /path/MacHelm.app 'Apple Development: identity' [--fixtures --wrong-team-identity 'Apple Development: other-team identity']}"
SIGNING_IDENTITY="${2:?Explicit local Apple signing identity is required}"
shift 2
BUILD_FIXTURES=false
WRONG_TEAM_IDENTITY=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --fixtures) BUILD_FIXTURES=true; shift ;;
        --wrong-team-identity)
            [[ $# -ge 2 ]] || { echo "Missing --wrong-team-identity value" >&2; exit 2; }
            WRONG_TEAM_IDENTITY="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done
if [[ "$BUILD_FIXTURES" == true && -z "$WRONG_TEAM_IDENTITY" ]]; then
    echo "--fixtures requires an explicit available --wrong-team-identity." >&2
    exit 2
fi
if [[ "$BUILD_FIXTURES" == false && -n "$WRONG_TEAM_IDENTITY" ]]; then
    echo "--wrong-team-identity requires --fixtures." >&2
    exit 2
fi

test -d "$APP_PATH"
test -x "$APP_PATH/Contents/Library/HelperTools/FanControlHelper"
codesign --verify --strict "$APP_PATH"
codesign --verify --strict "$APP_PATH/Contents/Library/HelperTools/FanControlHelper"
PRIVATE_PARENT="$REPO_ROOT/build/fan-acceptance-private"
mkdir -p "$PRIVATE_PARENT"
PRIVATE_OUTPUT=$(mktemp -d "$PRIVATE_PARENT/run.XXXXXXXX")
SIGNATURE_INFO="$PRIVATE_OUTPUT/app-signature.txt"
codesign -d --verbose=4 "$APP_PATH" 2> "$SIGNATURE_INFO"
EXPECTED_TEAM=$(sed -n 's/^TeamIdentifier=//p' "$SIGNATURE_INFO")
[[ "$EXPECTED_TEAM" =~ ^[A-Z0-9]{10}$ ]] || { echo "App requires a real Apple signing team." >&2; exit 1; }
HELPER_REQUIREMENT="anchor apple generic and identifier \"io.github.sergkhl.MacHelm.FanControlHelper\" and certificate leaf[subject.OU] = \"$EXPECTED_TEAM\""
APP_REQUIREMENT="anchor apple generic and identifier \"io.github.sergkhl.MacHelm\" and certificate leaf[subject.OU] = \"$EXPECTED_TEAM\""
codesign --verify --strict -R "=$APP_REQUIREMENT" "$APP_PATH"
codesign --verify --strict -R "=$HELPER_REQUIREMENT" "$APP_PATH/Contents/Library/HelperTools/FanControlHelper"

SCRATCH_PATH="$REPO_ROOT/build/fan-acceptance-swift"
swift build --package-path "$REPO_ROOT" --scratch-path "$SCRATCH_PATH" -c release --product fan-control-acceptance
BIN_PATH=$(swift build --package-path "$REPO_ROOT" --scratch-path "$SCRATCH_PATH" -c release --show-bin-path)
PRIVATE_CLI="$PRIVATE_OUTPUT/fan-control-acceptance"
install -m 755 "$BIN_PATH/fan-control-acceptance" "$PRIVATE_CLI"
codesign --force --sign "$SIGNING_IDENTITY" --identifier io.github.sergkhl.MacHelm \
    --options runtime --timestamp=none "$PRIVATE_CLI"
codesign --verify --strict -R "=$APP_REQUIREMENT" "$PRIVATE_CLI"
codesign -d --verbose=4 "$PRIVATE_CLI" 2> "$PRIVATE_OUTPUT/cli-signature.txt"

if [[ "$BUILD_FIXTURES" == true ]]; then
    ADHOC_CLI="$PRIVATE_OUTPUT/fan-control-acceptance-adhoc"
    WRONG_ID_CLI="$PRIVATE_OUTPUT/fan-control-acceptance-wrong-identifier"
    WRONG_TEAM_CLI="$PRIVATE_OUTPUT/fan-control-acceptance-wrong-team"
    install -m 755 "$BIN_PATH/fan-control-acceptance" "$ADHOC_CLI"
    install -m 755 "$BIN_PATH/fan-control-acceptance" "$WRONG_ID_CLI"
    install -m 755 "$BIN_PATH/fan-control-acceptance" "$WRONG_TEAM_CLI"
    codesign --force --sign - --identifier io.github.sergkhl.MacHelm --timestamp=none "$ADHOC_CLI"
    codesign --force --sign "$SIGNING_IDENTITY" --identifier io.github.sergkhl.MacHelm.AcceptanceWrongIdentifier \
        --options runtime --timestamp=none "$WRONG_ID_CLI"
    codesign --force --sign "$WRONG_TEAM_IDENTITY" --identifier io.github.sergkhl.MacHelm \
        --options runtime --timestamp=none "$WRONG_TEAM_CLI"
    for FIXTURE_PATH in "$ADHOC_CLI" "$WRONG_ID_CLI" "$WRONG_TEAM_CLI"; do
        codesign --verify --strict "$FIXTURE_PATH"
        if codesign --verify --strict -R "=$APP_REQUIREMENT" "$FIXTURE_PATH"; then
            echo "Negative signing fixture unexpectedly matches the production client requirement: $FIXTURE_PATH" >&2
            exit 1
        fi
        codesign -d --verbose=4 "$FIXTURE_PATH" 2> "$FIXTURE_PATH.signature.txt"
    done
fi

python3 - "$PRIVATE_OUTPUT" "$APP_PATH" "$EXPECTED_TEAM" <<'PY'
import datetime, hashlib, json, pathlib, sys
directory = pathlib.Path(sys.argv[1])
manifest = {
    "capturedUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "privateBuild": True,
    "appPath": sys.argv[2],
    "expectedHelperTeam": sys.argv[3],
    "executables": [{"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
                    for path in sorted(directory.glob("fan-control-acceptance*")) if not path.name.endswith(".txt")],
    "scope": "Private signed client and negative fixtures only. No installation, service request, native write, credentials acquisition, notarization or publishing."
}
(directory / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
PY
echo "Private CLI and optional fixtures: $PRIVATE_OUTPUT"
echo "No acceptance command was executed. Use a fresh JSONL path and the explicit selected command."
