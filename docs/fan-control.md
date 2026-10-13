# Fan Control

Fan Control is an opt-in temperature policy with a signed root helper. The app presents the profile, state, and recovery actions; the helper owns fan commands and verifies their effects. This document describes the 0.1 source behavior. It does not certify a built artifact or a Mac model.

## Behavior

The default ramp starts at **70 °C** and reaches maximum demand at **85 °C**. The firmware CPU die average (`TCMb`) drives the ramp with five-second elapsed-time smoothing. Each fan receives the same normalized demand through its own RPM range; speed decreases are limited to 300 RPM per second. Once custom control has begun, demand returns to automatic below the start temperature minus 5 °C.

Protection requests maximum demand when the CPU die maximum (`TCMz`) stays at or above 90 °C for three usable readings spanning at least 1.9 seconds, a monitored GPU temperature reaches 85 °C, or macOS reports serious or critical thermal pressure. Protection remains active until ten seconds of cool CPU/GPU readings and nominal or fair pressure. A missing or invalid frame never supplies a replacement temperature for control.

The Cooling page shows the current state, readings, ramp settings, and helper controls. The Overview exposes the main switch and any recovery requirement. The optional menu bar readout shows CPU temperature and the faster fan's speed while fresh readings are available.

The enabled setting is remembered. At launch or after wake, resumption requires three healthy readings, automatic fan state, no retained override or recovery hold, and no detected competing utility. Turning Fan Control off or quitting requests release; the helper also handles sleep, a lost client connection, and expiration of the client's five-second lease.

## Ownership and recovery

One authenticated XPC connection owns a control session. Another client cannot renew, update, or stop it. The interface accepts validated profiles and session/recovery identifiers; it does not accept arbitrary SMC keys, commands, sensor values, or target speeds. App and helper must agree on protocol version 4. Protocol and recovery-record versions are independent of the app's 0.1 version.

Before each hardware write, the helper records durable intent under `/Library/Application Support/io.github.sergkhl.MacHelm.FanControlHelper/`. A command is acknowledged only after the required native readbacks agree. An uncertain write remains a recovery requirement rather than being treated as a successful release.

Where its ownership and journal checks permit, the helper can make one bounded attempt to return its own fans to automatic after an unconfirmed operation. An unresolved hold keeps activation and helper removal blocked. The Cooling page offers **Restore automatic now** and **Verify external recovery**. The latter checks automatic state after recovery performed outside MacHelm and issues no fan writes. Records from another boot or helper build require the supported external-verification path.

The conflict check recognizes Macs Fan Control. It cannot identify every possible writer. A changed fan mode or target causes the controller to stop its ordinary control path rather than repeatedly overwrite another controller's state.

## Build and signing

Use the MacHelm scheme in `MacHelm.xcodeproj`. The app and `FanControlHelper` must be signed by the same real Apple team. The other embedded targets should use that team too. An ad-hoc signature does not satisfy helper authentication.

```sh
MACHELM_DEVELOPMENT_TEAM=YOURTEAMID \
  ./scripts/build-fan-artifact.sh Debug
```

Set `MACHELM_SIGN_IDENTITY` if a specific installed signing identity is needed. The script builds the complete app and runs the fan and toolkit artifact checks. It does not register a helper, approve a background item, or activate Fan Control.

After placing a signed app in `/Applications/MacHelm.app`, use its helper setup control and complete macOS's background-item approval. Check the state shown by the app before enabling Fan Control. The fresh MacHelm namespace does not adopt helpers or recovery records from earlier private installations.

For a local Release build, use the same build command with `Release` in place of `Debug`, or select the Release configuration in Xcode. Developer ID signing, Apple notarization, and binary publication are separate distribution steps. They are not established by the 0.1 source release.

## Verification and limits

- **Source tests:** `swift test --scratch-path build/swift-tests` exercises policies, lease ownership, recovery, native-adapter behavior over fake transports, and acceptance-client logic. These tests do not command physical fans.
- **Artifact checks:** `scripts/verify-fan-artifact.sh <app>` and `scripts/verify-toolkit-artifact.sh <app>` inspect bundle structure, identity, signatures, and embedded components. They do not prove that an installed helper is approved or reachable.
- **Native checks:** the [acceptance client](../Sources/FanControlAcceptance/README.md) can observe an authenticated installed helper or run a separately selected bounded control trial. Native evidence belongs to the exact app/helper build, model, OS, and action that was exercised.

The source has an explicit M2-family sensor map and rejects unsupported model identities or missing required telemetry. Inclusion in that map is not hardware qualification. Earlier development work observed ordinary control and selected recovery cases on one M2 Pro; those observations are historical and do not establish the renamed 0.1 artifact's behavior or support for every listed Mac. Fanless models cannot provide controllable fans.

AppleSMC and the thermal interfaces used here are undocumented and may change with macOS. Already-issued synchronous kernel or filesystem calls cannot be preempted. The helper's deadlines restrict admission and confirmation of operations; they do not guarantee a hard wall-clock restoration deadline. A successful build, source test, or signature inspection cannot substitute for native release and recovery checks.

The AppleSMC and HID thermal adapters contain adaptations from Stats; [ThirdPartyNotices.txt](../ThirdPartyNotices.txt) retains the component's MIT notice.
