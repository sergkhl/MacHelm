#!/bin/bash
set -euo pipefail

# Verifies the MacHelm identity of a built app and its embedded Startup
# Services runner. It reads the artifact only: nothing is installed or
# registered, and the user's catalog and LaunchAgents are not read.
APP_PATH="${1:?Usage: verify-toolkit-artifact.sh /path/to/MacHelm.app [--distribution]}"
if [[ $# -gt 2 || ( $# -eq 2 && "$2" != "--distribution" ) ]]; then
    echo "Usage: verify-toolkit-artifact.sh /path/to/MacHelm.app [--distribution]" >&2
    exit 2
fi
RUNNER_PATH="$APP_PATH/Contents/Library/HelperTools/MacHelmServiceRunner"
CHECK_DIR=$(mktemp -d)
trap 'rm -rf "$CHECK_DIR"' EXIT

# Verify the public MacHelm product and its own internal identity.
test "$(basename "$APP_PATH")" = "MacHelm.app"
python3 - "$APP_PATH/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as source:
    info = plistlib.load(source)
assert info['CFBundleIdentifier'] == 'io.github.sergkhl.MacHelm', info['CFBundleIdentifier']
assert info['CFBundleName'] == 'MacHelm', info['CFBundleName']
assert info['CFBundleDisplayName'] == 'MacHelm', info['CFBundleDisplayName']
assert info['CFBundleExecutable'] == 'MacHelm', info['CFBundleExecutable']
PY
test -x "$APP_PATH/Contents/MacOS/MacHelm"

# Apple attributes a LaunchAgent to the app only when its program is signed
# by the same team as the app named in AssociatedBundleIdentifiers.
test -x "$RUNNER_PATH"
codesign --verify --strict "$RUNNER_PATH"
codesign -d --verbose=4 "$APP_PATH" 2> "$CHECK_DIR/app.txt"
codesign -d --verbose=4 "$RUNNER_PATH" 2> "$CHECK_DIR/runner.txt"
APP_TEAM=$(sed -n 's/^TeamIdentifier=//p' "$CHECK_DIR/app.txt")
RUNNER_TEAM=$(sed -n 's/^TeamIdentifier=//p' "$CHECK_DIR/runner.txt")
test -n "$APP_TEAM"
test "$APP_TEAM" != "not set"
test "$APP_TEAM" = "$RUNNER_TEAM"
grep -Eq '^Identifier=io\.github\.sergkhl\.MacHelm\.ServiceRunner$' "$CHECK_DIR/runner.txt"
grep -Eq 'flags=.*runtime' "$CHECK_DIR/runner.txt"
codesign --verify --strict -R "=anchor apple generic and identifier \"io.github.sergkhl.MacHelm.ServiceRunner\" and certificate leaf[subject.OU] = \"$APP_TEAM\"" "$RUNNER_PATH"

if [[ "${2:-}" == "--distribution" ]]; then
    grep -Eq '^Authority=Developer ID Application:' "$CHECK_DIR/runner.txt"
    grep -Eq '^Timestamp=.+$' "$CHECK_DIR/runner.txt" || { echo "Distribution runner lacks a secure timestamp." >&2; exit 1; }
    codesign -d --entitlements - --xml "$RUNNER_PATH" > "$CHECK_DIR/runner-entitlements.plist"
    python3 - "$CHECK_DIR/runner-entitlements.plist" <<'PY'
import plistlib, sys
from pathlib import Path
contents = Path(sys.argv[1]).read_bytes()
entitlements = plistlib.loads(contents) if contents.strip() else {}
value = entitlements.get('com.apple.security.get-task-allow')
if value is not None and value is not False:
    raise SystemExit('Distribution runner must not allow debugger attachment (get-task-allow).')
PY
fi

# The toolkit helper (ADR 0003): signed by the app's team under its own
# identity, with a launch daemon that names it and does not keep it alive.
HELPER_PATH="$APP_PATH/Contents/Library/HelperTools/ToolkitHelper"
HELPER_JOB="$APP_PATH/Contents/Library/LaunchDaemons/io.github.sergkhl.MacHelm.ToolkitHelper.plist"
test -x "$HELPER_PATH"
codesign --verify --strict "$HELPER_PATH"
codesign -d --verbose=4 "$HELPER_PATH" 2> "$CHECK_DIR/helper.txt"
test "$APP_TEAM" = "$(sed -n 's/^TeamIdentifier=//p' "$CHECK_DIR/helper.txt")"
grep -Eq '^Identifier=io\.github\.sergkhl\.MacHelm\.ToolkitHelper$' "$CHECK_DIR/helper.txt"
grep -Eq 'flags=.*runtime' "$CHECK_DIR/helper.txt"
codesign --verify --strict -R "=anchor apple generic and identifier \"io.github.sergkhl.MacHelm.ToolkitHelper\" and certificate leaf[subject.OU] = \"$APP_TEAM\"" "$HELPER_PATH"
python3 - "$HELPER_JOB" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as source:
    job = plistlib.load(source)
label = 'io.github.sergkhl.MacHelm.ToolkitHelper'
assert job['Label'] == label, job
assert job['BundleProgram'] == 'Contents/Library/HelperTools/ToolkitHelper', job
assert job['MachServices'] == {label: True}, job
assert job['UserName'] == 'root' and job['RunAtLoad'] is True, job
# It leaves when it is idle and holds nothing; launchd must not start it again by itself.
assert 'KeepAlive' not in job, job
PY
# Started by hand it refuses and exits. As root it would start for real, so
# this part is skipped there.
if [[ $EUID -ne 0 ]]; then
    set +e
    "$HELPER_PATH" > /dev/null 2> "$CHECK_DIR/helper-refusal.txt"
    HELPER_STATUS=$?
    set -e
    test "$HELPER_STATUS" = 1
    grep -q 'approved root launch daemon' "$CHECK_DIR/helper-refusal.txt"
fi

# Without a command the runner prints its usage and exits 2.
set +e
"$RUNNER_PATH" > /dev/null 2> "$CHECK_DIR/usage.txt"
USAGE_STATUS=$?
set -e
test "$USAGE_STATUS" = 2
grep -q 'install-definition' "$CHECK_DIR/usage.txt"

# In a folder of its own, the runner renders a job that names this very
# runner and the app's bundle identifier. Nothing is registered with launchd.
ROOT="$CHECK_DIR/root"
cat > "$CHECK_DIR/definition.json" <<'JSON'
{"label": "io.github.sergkhl.MacHelm.artifactcheck", "program": "/usr/bin/true",
 "arguments": ["/usr/bin/true"], "runAtLoad": true, "keepAlive": "afterFailure", "throttleInterval": 30}
JSON
"$RUNNER_PATH" --root "$ROOT" install-definition "$CHECK_DIR/definition.json" > /dev/null
"$RUNNER_PATH" --root "$ROOT" set-automatic io.github.sergkhl.MacHelm.artifactcheck on > /dev/null
python3 - "$ROOT" "$RUNNER_PATH" <<'PY'
import os, plistlib, sys
root, runner = os.path.realpath(sys.argv[1]), os.path.realpath(sys.argv[2])
label = 'io.github.sergkhl.MacHelm.artifactcheck'
with open(os.path.join(root, 'LaunchAgents', label + '.plist'), 'rb') as source:
    job = plistlib.load(source)
assert job['ProgramArguments'] == [runner, '--root', root, 'run', label], job['ProgramArguments']
assert job['AssociatedBundleIdentifiers'] == ['io.github.sergkhl.MacHelm'], job
assert job['KeepAlive'] == {'SuccessfulExit': False} and job['ThrottleInterval'] == 30 and job['RunAtLoad'] is True, job
PY
# The job's own entry point runs the definition's command in the same process.
"$RUNNER_PATH" --root "$ROOT" run io.github.sergkhl.MacHelm.artifactcheck

echo "MacHelm name, bundle identifier, runner and toolkit helper signatures, signing team, Hardened Runtime, the helper's launch daemon and the rendered job verified."
