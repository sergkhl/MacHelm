# Fan Control acceptance client

This developer tool exercises the authenticated XPC interface of an installed Fan Control helper. Building it does not install a helper or run a native test. Its isolated Swift package tests use fake or local-only dependencies and do not register a service or command fans.

## Build

Supply an absolute path to a signed MacHelm app and an available signing identity from the same Apple team:

```sh
./scripts/build-fan-acceptance.sh /absolute/path/MacHelm.app 'Apple Development: your identity'
```

The script produces a new ignored directory under `build/fan-acceptance-private/`. It verifies the app and helper requirements, signs the client with the app's identifier, and records a manifest. The optional `--fixtures --wrong-team-identity 'Apple Development: other team identity'` creates separate ad-hoc, wrong-identifier, and wrong-team fixtures. A successful build or signature check is not evidence of installed-service approval or connectivity.

## Commands

Every invocation needs explicit absolute `--app` and `--output` paths. The output must be a new file: existing files and symlinks are refused. JSONL records use mode 0600 and synchronized writes.

| Command | Scope |
| --- | --- |
| `status` | Collect 1–30 fresh observation frames, 12 by default. Reports telemetry validity, automatic state, and known conflicts separately. |
| `hostile-inputs` | Require an idle automatic baseline and send malformed, oversized, out-of-range, or invalid-session inputs. It sends no valid activation or stop. |
| `rejected-client --expected-team YOURTEAMID` | Use an explicitly selected untrusted fixture to send one non-observing status request and retain its transport result. |
| `round-trip --allow-native-writes --duration SECONDS` | Explicitly run a native control trial lasting 1–60 seconds with a temporary 45/85 °C profile. It leaves the GUI's saved profile unchanged. |

A status-only example, using the executable returned by the build:

```sh
/path/to/fan-control-acceptance status \
  --app /Applications/MacHelm.app \
  --output /absolute/path/to/new-status.jsonl --samples 12
```

A rejected connection alone does not prove authentication works: an unavailable helper also rejects connections. Corroborate a working trusted client separately.

## Native trial behavior

A round trip requires a fresh automatic frame, no known conflicting utility, CPU die maximum below 85 °C, GPU temperature below 80 °C, and nominal or fair thermal pressure before it sends a native begin. Failed entry conditions are recorded as unqualified, with no begin sent.

The client maintains the owner lease separately from status and second-owner checks. It records rejection of a competing authenticated owner, effective fan mode/target/unlock state, requested and actual RPM, and verified release. Target acknowledgement and physical speed response are different checks: the latter needs a stable target window and measured convergence within its allowed interval.

The test sends one stop on success, the first failure, or its selected bound. It does not retry activation, clear a recovery hold, or request `restoreAutomatic`. A helper self-recovery receipt makes the ordinary trial fail even if the helper subsequently reports clean release fields. Cleanup failures do not overwrite the first failure.

The selected bound limits test activity; it cannot preempt a stalled synchronous kernel operation or guarantee a hardware restoration deadline. The helper's fixed protection remains active during the test.

The client negotiates the helper's protocol on the authenticated connection before mutation. A protocol mismatch refuses control. App version 0.1 is separate from protocol version 4 and the recovery-data schema.

## Interpreting evidence

A capture identifies the expected app and helper and the authenticated peer PID. Verify the actual running helper artifact, registration, approval, lifecycle behavior, and any recovery action separately. A successful trial applies to its exact artifact, model, operating system, and observed conditions. Keep private paths, process details, and local captures out of public reports unless reduced to the relevant redacted evidence.
