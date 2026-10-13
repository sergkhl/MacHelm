#!/bin/bash
set -euo pipefail

APP_PATH="${1:?Usage: verify-fan-artifact.sh /path/to/MacHelm.app [--distribution]}"
if [[ $# -gt 2 || ( $# -eq 2 && "$2" != "--distribution" ) ]]; then
    echo "Usage: verify-fan-artifact.sh /path/to/MacHelm.app [--distribution]" >&2
    exit 2
fi
HELPER_PATH="$APP_PATH/Contents/Library/HelperTools/FanControlHelper"
PLIST_PATH="$APP_PATH/Contents/Library/LaunchDaemons/io.github.sergkhl.MacHelm.FanControlHelper.plist"
CHECK_DIR=$(mktemp -d)
trap 'rm -rf "$CHECK_DIR"' EXIT

test -x "$HELPER_PATH"
test -f "$PLIST_PATH"
test -f "$APP_PATH/Contents/Resources/ThirdPartyNotices.txt"
codesign --verify --strict "$APP_PATH"
codesign --verify --strict "$HELPER_PATH"
codesign -d --verbose=4 "$APP_PATH" 2> "$CHECK_DIR/app.txt"
codesign -d --verbose=4 "$HELPER_PATH" 2> "$CHECK_DIR/helper.txt"
APP_TEAM=$(sed -n 's/^TeamIdentifier=//p' "$CHECK_DIR/app.txt")
HELPER_TEAM=$(sed -n 's/^TeamIdentifier=//p' "$CHECK_DIR/helper.txt")
test -n "$APP_TEAM"
test "$APP_TEAM" != "not set"
test "$APP_TEAM" = "$HELPER_TEAM"
grep -Eq '^Identifier=io\.github\.sergkhl\.MacHelm$' "$CHECK_DIR/app.txt"
grep -Eq '^Identifier=io\.github\.sergkhl\.MacHelm\.FanControlHelper$' "$CHECK_DIR/helper.txt"
grep -Eq 'flags=.*runtime' "$CHECK_DIR/app.txt"
grep -Eq 'flags=.*runtime' "$CHECK_DIR/helper.txt"
codesign --verify --strict -R "=anchor apple generic and identifier \"io.github.sergkhl.MacHelm\" and certificate leaf[subject.OU] = \"$APP_TEAM\"" "$APP_PATH"
codesign --verify --strict -R "=anchor apple generic and identifier \"io.github.sergkhl.MacHelm.FanControlHelper\" and certificate leaf[subject.OU] = \"$APP_TEAM\"" "$HELPER_PATH"

python3 - "$PLIST_PATH" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as source:
    service = plistlib.load(source)
identifier = 'io.github.sergkhl.MacHelm.FanControlHelper'
assert service['Label'] == identifier
assert service['BundleProgram'] == 'Contents/Library/HelperTools/FanControlHelper'
assert service['MachServices'] == {identifier: True}
assert service['UserName'] == 'root'
assert service['RunAtLoad'] is True and service['KeepAlive'] is True
assert service['ThrottleInterval'] == 10
assert 'Program' not in service and 'ProgramArguments' not in service
PY

if [[ "${2:-}" == "--distribution" ]]; then
    grep -Eq '^Authority=Developer ID Application:' "$CHECK_DIR/app.txt"
    grep -Eq '^Authority=Developer ID Application:' "$CHECK_DIR/helper.txt"
    grep -Eq '^Timestamp=.+$' "$CHECK_DIR/app.txt" || { echo "Distribution app lacks a secure timestamp." >&2; exit 1; }
    grep -Eq '^Timestamp=.+$' "$CHECK_DIR/helper.txt" || { echo "Distribution helper lacks a secure timestamp." >&2; exit 1; }
    codesign -d --entitlements - --xml "$APP_PATH" > "$CHECK_DIR/app-entitlements.plist"
    codesign -d --entitlements - --xml "$HELPER_PATH" > "$CHECK_DIR/helper-entitlements.plist"
    python3 - "$CHECK_DIR/app-entitlements.plist" "$CHECK_DIR/helper-entitlements.plist" <<'PY'
import plistlib, sys
from pathlib import Path

for filename in sys.argv[1:]:
    contents = Path(filename).read_bytes()
    entitlements = plistlib.loads(contents) if contents.strip() else {}
    value = entitlements.get('com.apple.security.get-task-allow')
    if value is not None and value is not False:
        raise SystemExit('Distribution app/helper must not allow debugger attachment (get-task-allow).')
PY
fi

# This mode inspects the executable's own signature and never opens SMC,
# registers a daemon, accesses a recovery record, or changes fan settings.
"$HELPER_PATH" --check-signing 2>&1 | tee "$CHECK_DIR/helper-self-check.txt"
if [[ "${2:-}" == "--distribution" ]] && grep -Fq 'qualification=enabled' "$CHECK_DIR/helper-self-check.txt"; then
    echo "A qualification-enabled helper cannot be distributed or submitted for notarization." >&2
    exit 1
fi
echo "App/helper signatures, signing team, Hardened Runtime, daemon layout and notices verified."
