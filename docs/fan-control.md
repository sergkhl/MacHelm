# Fan Control

Fan Control is an opt-in temperature policy with a signed root helper. The app presents the profile, state, and recovery actions; the helper owns fan commands and verifies their effects. This document describes the 0.1 source behavior and the selected local checks below. It does not establish general hardware or distribution qualification.

## Behavior

The default ramp starts at **65 °C** and reaches maximum demand at **85 °C**. The firmware CPU die average (`TCMb`) drives both the start threshold and the ramp with five-second elapsed-time smoothing. Each fan receives the same normalized demand through its own RPM range; speed decreases are limited to 300 RPM per second. Normal custom control ends when the smoothed average falls below the start temperature; there is no additional 5 °C release margin.

Enabling the policy below the start temperature observes the fans without issuing fan writes. Crossing the threshold acquires manual control; cooling below it releases an existing override once, while the enabled policy continues observing. It does not repeatedly reset fans that Apple already controls. Apple automatic does not mean stopped fans: [Apple describes temperature-driven cooling](https://support.apple.com/en-us/101576) for multiple internal components. MacHelm does not force zero RPM below the threshold. The separate protection rules below can require cooling even when the CPU average is low.

Protection requests maximum demand when the CPU die maximum (`TCMz`) stays at or above 90 °C for three usable readings spanning at least 1.9 seconds, a monitored GPU temperature reaches 85 °C, or macOS reports serious or critical thermal pressure. Protection remains active until ten seconds of cool CPU/GPU readings and nominal or fair pressure. A missing or invalid frame never supplies a replacement temperature for control.

The Cooling page shows the current state, readings, ramp settings, and helper controls. The Overview exposes the main switch and any recovery requirement. The optional menu bar readout shows CPU temperature and the faster fan's speed while fresh readings are available.

The enabled setting is remembered. At launch or after wake, resumption requires three healthy readings, automatic fan state, no retained override or recovery hold, and no detected competing utility. Turning Fan Control off or quitting requests release; the helper also handles sleep, a lost client connection, and expiration of the client's five-second lease.

## Ownership and recovery

One authenticated XPC connection owns a control session. Another client cannot renew, update, or stop it. The interface accepts validated profiles and session/recovery identifiers; it does not accept arbitrary SMC keys, commands, sensor values, or target speeds. App and helper must agree on protocol version 4. Protocol and recovery-record versions are independent of the app's 0.1 version.

Before each hardware write, the helper records durable intent under `/Library/Application Support/io.github.sergkhl.MacHelm.FanControlHelper/`. A command is acknowledged only after the required native readbacks agree. An uncertain write remains a recovery requirement rather than being treated as a successful release.

Manual entry allows the firmware-selected target to differ from the last automatic target for the fan being acquired. Two distinct probes must confirm a stable manual target before it becomes the owned baseline; other owned fans and the global unlock must still match. Once acquired, ordinary target ownership stays strict.

During acknowledgement, the helper exclusively renames the already-durable pending record into its conservative crash marker, then saves the acknowledged record. This avoids a duplicate file rewrite and sync inside the unchanged one-second native confirmation/publication deadline. Failed publication still leaves the original pending intent available on restart; only successful publication permits marker retirement.

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

On **2026-10-13**, the signed universal **Release version 0.1, build 2** was installed and checked on **Mac14,9 (M2 Pro, two fans)** running **macOS 26.6.2 (25G83)**. The final Swift suite passed **681 tests with zero failures**; the Xcode project generator check and both signed-artifact checks passed. Installed fan-helper approval, authenticated reachability, and the running executable's installed-bundle path were checked separately from the artifact inspections.

Selected native GUI checks covered two 30-sample protection windows, verified release to effective Apple automatic, and 30 fresh below-threshold samples with the policy still enabled. During the latter window there was no owned override or recovery hold, and the last native-write timestamp stayed unchanged. Restoring the saved **65/85 °C** profile produced an enabled session that entered ordinary control at the smoothed threshold. One normal quit/relaunch check verified automatic release on quit and remembered resumption; a further 12-sample observation included ordinary control, cooling release, and continued enabled automatic observation without a new recovery hold or acknowledgement deadline overrun.

A separate ordinary native acceptance trial used a temporary **45/85 °C** profile and a **30-second maximum bound**, completing successfully in **6.56 seconds**. Both native target registers matched the request within 2 RPM, and both measured fan speeds met the ±10% convergence criterion after two stable fresh frames. A second authenticated connection could not acquire, renew, update, or stop the first connection's lease. Final release verified both effective fan modes as automatic with no lease, owned override, or recovery hold. This was a short bounded trial, not a sustained 30-second run; it did not change the saved GUI profile.

The source has an explicit M2-family sensor map and rejects unsupported model identities or missing required telemetry. Inclusion in that map is not hardware qualification, and fanless models cannot provide controllable fans. These checks qualify only the selected actions on the exact local build, model, and OS above. Other models, broad fault/sleep/disconnect scenarios, sustained operation, Developer ID signing, notarization, and binary distribution remain unqualified for build 2. Historical checks from earlier installations do not extend this scope.

AppleSMC and the thermal interfaces used here are undocumented and may change with macOS. Already-issued synchronous kernel or filesystem calls cannot be preempted. The helper's deadlines restrict admission and confirmation of operations; they do not guarantee a hard wall-clock restoration deadline. A successful build, source test, or signature inspection cannot substitute for native release and recovery checks.

The AppleSMC and HID thermal adapters contain adaptations from Stats; [ThirdPartyNotices.txt](../ThirdPartyNotices.txt) retains the component's MIT notice.
