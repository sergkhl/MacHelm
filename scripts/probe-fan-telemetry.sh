#!/bin/bash
# Read-only comparison of normal-user and root sensor visibility.
# No helper registration, fan writes, resets, or utility installation.
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO_ROOT"
PROBE_MODE="${1:---user}"
if [[ "$PROBE_MODE" != "--user" && "$PROBE_MODE" != "--root" ]]; then
    echo "Usage: probe-fan-telemetry.sh [--user|--root]" >&2
    exit 2
fi
swift build --scratch-path build/swift-fan --product fan-control-probe
PROBE_BINARY="$REPO_ROOT/build/swift-fan/debug/fan-control-probe"
PROBE_COMMAND=("$PROBE_BINARY")
if [[ "$PROBE_MODE" == "--root" ]]; then
    # Authentication occurs in the user's Terminal. Never store a password.
    sudo -v
    PROBE_COMMAND=(sudo -n "$PROBE_BINARY")
fi
PROBE_OUTPUT="$REPO_ROOT/build/fan-control/telemetry/$(date -u +%Y%m%dT%H%M%SZ)-${PROBE_MODE#--}"
mkdir -p "$PROBE_OUTPUT"
shasum -a 256 "$PROBE_BINARY" > "$PROBE_OUTPUT/probe.sha256"
for PROBE_CASE in telemetry hid-inventory fan-state; do
    PROBE_ARGS=(--read-only)
    if [[ "$PROBE_CASE" != "telemetry" ]]; then
        PROBE_ARGS+=("--$PROBE_CASE")
    fi
    if "${PROBE_COMMAND[@]}" "${PROBE_ARGS[@]}" > "$PROBE_OUTPUT/$PROBE_CASE.json" 2> "$PROBE_OUTPUT/$PROBE_CASE.err"; then
        echo 0 > "$PROBE_OUTPUT/$PROBE_CASE.exit"
    else
        echo "$?" > "$PROBE_OUTPUT/$PROBE_CASE.exit"
    fi
done
echo "Read-only $PROBE_MODE probe saved: $PROBE_OUTPUT"
cat "$PROBE_OUTPUT/telemetry.err"
