---
status: accepted
---

# Separate power and storage privileges from fan control

## Context

Keep Awake's lid behavior, system sleep-timer changes, and some cleanup targets need root privileges. The fan helper already runs a time-sensitive control loop with a lease and recovery journal. Putting unrelated filesystem work into that process would couple fan availability to slow removals and unrelated failures.

## Decision

Keep the fan helper dedicated to fans. Use a separate toolkit helper with a small fixed interface:

| Request | Allowed effect |
| --- | --- |
| Read power state | Return the sleep timers and stay-awake state. |
| Hold stay-awake | Manage the system `SleepDisabled` setting for the connected client. |
| Set a sleep timer | Update one battery or power-adapter display/system timer within the supported range. |
| Remove a directory | Remove a directory at most two levels below `/Library/Developer/CoreSimulator/Caches/dyld`, after path and ownership checks. |

The helper authenticates the app by its MacHelm identifier and matching Apple signing team. It starts on demand and may exit when idle. The interface contains no arbitrary command execution.

The removal operation accepts a path only under its fixed root. The path and its ancestors must satisfy the implementation's checks for real directories, ownership, permissions, traversal, and mount boundaries. Two levels cover both a macOS build's cache directory and the individual runtime directory below it. The app requests removal only for a root target returned by the scan and included in the user's confirmed selection.

The helper journals a `SleepDisabled` change that it owns. It releases that hold when the client turns it off, disconnects, quits, or crashes, and when the helper stops or is removed. At its next start, the journal allows it to clear a hold left after its own interruption. A setting already established outside this helper is left under that outside ownership.

## Alternatives

Extending the fan helper would combine unrelated work in the process responsible for fan release. Running the full cleanup script as root would expose a much larger privileged surface. Asking for administrator authorization separately for each action would avoid a persistent helper but interrupt routine power controls and each cleanup.

## Consequences

Future root-only tools need a narrowly scoped request in this helper, not a general shell entry point. System Integrity Protection still limits what root can remove; this interface does not bypass it. Without the toolkit helper, Keep Awake provides idle-sleep prevention, timers are read-only, and unsupported root cleanup targets remain unavailable through the app.

`SleepDisabled` is undocumented. Its behavior must be verified on the operating system in use rather than inferred from a successful helper build.
