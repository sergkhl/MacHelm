#!/bin/bash
set -euo pipefail

if [[ "${1:-}" == "--help" && $# == 1 ]]; then
    echo "Usage: build-fan-qualification-artifact.sh"
    echo "Builds and verifies an isolated private signed Release with FAN_CONTROL_QUALIFICATION."
    echo "Preserves build logs, source/artifact fingerprints and the fixed-input schema."
    echo "Does not install, register a service, access hardware, inject faults or publish."
    exit 0
fi
if [[ $# != 0 ]]; then
    echo "Usage: build-fan-qualification-artifact.sh" >&2
    exit 2
fi

QUALIFICATION_REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$QUALIFICATION_REPO_ROOT/build"
QUALIFICATION_DERIVED_DIR=$(mktemp -d "$QUALIFICATION_REPO_ROOT/build/fan-qualification-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
QUALIFICATION_EVIDENCE_DIR="$QUALIFICATION_DERIVED_DIR/qualification-evidence"
mkdir "$QUALIFICATION_EVIDENCE_DIR"
cd "$QUALIFICATION_REPO_ROOT"

BUILD_SIGN_ARGS=()
if [[ -n "${MACHELM_DEVELOPMENT_TEAM:-}" ]]; then
    BUILD_SIGN_ARGS+=("DEVELOPMENT_TEAM=$MACHELM_DEVELOPMENT_TEAM")
fi
if [[ -n "${MACHELM_SIGN_IDENTITY:-}" ]]; then
    BUILD_SIGN_ARGS+=("CODE_SIGN_IDENTITY=$MACHELM_SIGN_IDENTITY")
fi
xcodebuild -project MacHelm.xcodeproj -scheme MacHelm \
    -configuration Release -derivedDataPath "$QUALIFICATION_DERIVED_DIR" \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS=FAN_CONTROL_QUALIFICATION \
    ${BUILD_SIGN_ARGS[@]+"${BUILD_SIGN_ARGS[@]}"} build \
    2>&1 | tee "$QUALIFICATION_EVIDENCE_DIR/build.txt"

QUALIFICATION_APP_PATH="$QUALIFICATION_DERIVED_DIR/Build/Products/Release/MacHelm.app"
QUALIFICATION_HELPER_PATH="$QUALIFICATION_APP_PATH/Contents/Library/HelperTools/FanControlHelper"
"$QUALIFICATION_REPO_ROOT/scripts/verify-fan-artifact.sh" "$QUALIFICATION_APP_PATH" \
    2>&1 | tee "$QUALIFICATION_EVIDENCE_DIR/verify.txt"
QUALIFICATION_SIGNING_OUTPUT=$("$QUALIFICATION_HELPER_PATH" --check-signing)
if [[ "$QUALIFICATION_SIGNING_OUTPUT" != *"qualification=enabled"* ]]; then
    echo "Helper did not confirm the qualification compilation condition; artifact rejected." >&2
    exit 1
fi
"$QUALIFICATION_HELPER_PATH" --qualification-schema > "$QUALIFICATION_EVIDENCE_DIR/input-schema.json"

python3 - "$QUALIFICATION_REPO_ROOT" "$QUALIFICATION_APP_PATH" "$QUALIFICATION_EVIDENCE_DIR" <<'PY'
from datetime import datetime, timezone
from pathlib import Path
import hashlib
import json
import subprocess
import sys

repo, app, evidence = map(Path, sys.argv[1:])
schema = json.loads((evidence / 'input-schema.json').read_text())
assert schema['qualificationBuild'] is True
assert schema['fixedInputFile'] == '/Library/Application Support/io.github.sergkhl.MacHelm.FanControlHelper/qualification/scenario.json'
assert schema['maximumScenarioSeconds'] == 60
assert schema['requiredOwner'] == 'root' and schema['fileMode'] == '0600'

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

bundle_files = {
    str(path.relative_to(app)): sha(path)
    for path in sorted(app.rglob('*')) if path.is_file()
}
source_names = [
    'MacHelm.xcodeproj/project.pbxproj', 'Package.swift',
    'Sources/FanControlHardware/FanQualificationHardware.swift',
    'Sources/FanControlHardware/AppleFanHardware.swift',
    'Sources/FanControlRuntime/FanHelperController.swift',
    'Sources/FanControlRuntime/FanRecovery.swift',
    'FanControlHelper/HelperMain.swift',
    'Tests/FanControlTests/FanQualificationTests.swift',
    'scripts/build-fan-qualification-artifact.sh', 'scripts/verify-fan-artifact.sh',
]
manifest = {
    'capturedAt': datetime.now(timezone.utc).isoformat(),
    'scope': 'Private compile-time qualification artifact; build/signature checks only',
    'compilationCondition': 'FAN_CONTROL_QUALIFICATION',
    'appPath': str(app),
    'gitHead': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip(),
    'sourcesSHA256': {name: sha(repo / name) for name in source_names},
    'bundleFilesSHA256': bundle_files,
    'bundleManifestSHA256': hashlib.sha256(json.dumps(bundle_files, sort_keys=True, separators=(',', ':')).encode()).hexdigest(),
    'schemaSHA256': sha(evidence / 'input-schema.json'),
    'qualificationSchema': schema,
    'performed': ['Release build', 'Nested signing/layout verification', 'Qualification marker/schema inspection'],
    'notPerformed': ['Installation', 'Service registration', 'Administrator approval', 'Hardware access',
                     'Native fan writes', 'Fault injection', 'Hardware acceptance', 'Notarization', 'Publishing'],
}
(evidence / 'artifact-manifest.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
PY

echo "Private qualification artifact: $QUALIFICATION_APP_PATH"
echo "Retained qualification evidence: $QUALIFICATION_EVIDENCE_DIR"
