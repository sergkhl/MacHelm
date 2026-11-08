---
status: accepted
---

# A frozen app keeps Fan Control for 30 seconds

## Context

On 2026-11-08 Fan Control ended by itself twice on the owner's Mac14,9 (macOS 26.6.2), with app build 5 and helper build 5. Both times the helper's five-second app lease ran out. The stop note from 16:01:16 read "The app lease expired after five seconds." The one from 15:54:02 was cleared when the owner turned Fan Control back on, but the logs show the same pattern.

A Blender job and a model training run were going. A JetsamEvent report at 16:01:42 shows Python holding about 11.7 GB of 16 GB, about 200 MB free, and 7.6 GB of swap in use. MacHelm's main thread posts a menu bar update every second. Gaps in those updates show the main thread stopped for 5.1 s before 15:54:02, 5.0 s before 15:59:08 (Fan Control survived that one), and 8.2 s before 16:01:16. Lease renewals come from that main-thread timer, so none went out. The helper kept reading sensors through the freezes, with short stalls of its own.

ADR 0012 kept Fan Control through a pause shorter than the lease. These pauses were longer. A longer lease alone would not have been enough. When the app came back after more than six seconds, its own limits counted the freeze against the helper: an unanswered status request was overdue after six seconds, and an operation timed out after six.

Just before the 15:54 freeze the main thread was checking helper registration and free disk space. Whether that work made the freeze longer under paging is not known. This change does not depend on it.

## Decision

The owner decided on 2026-11-08 (L-Q1 to L-Q7):

- **The lease stays, at 30 seconds (L-Q1).** A lost connection still ends the session at once, and the helper runs its fan curve and protection rules whatever the app does. The lease ends a session whose app is still connected but no longer renewing, so a stuck app still hands the fans back to Apple. Thirty seconds is more than three times the longest freeze seen.
- **The app's own limits count only time the app was running (L-Q2).** The one-second tick reads a clock that counts at most two seconds for any step between reads. The status wait and the six-second operation timer use it. Freshness is still real time: a status older than three seconds still authorizes nothing and is asked for again (G-Q3).
- **A slow helper gets the same time as a frozen app (L-Q3).** The app gives up only after 32 seconds of its own running time without a usable status, whether no reply came or every reply was late. The second-late-reply rule and the six-second no-reply limit are gone. Fan controls stay locked, showing "Checking helper…", until a usable reply comes.
- **Renewals stay on the main-thread timer (L-Q4).** A background renewer would keep renewing for an app whose interface had stopped for good, and that would defeat the lease.
- **An ending still saves off (L-Q6).** SR-Q1 stands, as in ADR 0011 and 0012. The stop note and "Fan Control stopped" are unchanged.

The 32-second limit is the lease plus two seconds. The app's running clock never runs ahead of real time, so the app never gives up on a session the helper could still keep.

## Alternatives

- **Remove the lease.** A stuck app would then keep the owner's curve running with no working Off button until MacHelm was force-quit.
- **15 seconds.** The 2026-11-03 pause may have been up to 15 seconds.
- **Renew from a background thread.** Rejected for the reason above.
- **Keep the six-second limits and the second-late-reply rule.** A freeze or a slow helper would still end Fan Control before the lease did.
- **Bring Fan Control back after a lease expiry.** It would reverse SR-Q1.

## Consequences

A freeze of the app, or a slow helper, shorter than 30 seconds now leaves Fan Control on. While a freeze lasts, nothing in MacHelm moves. Afterwards the Overview reads "Checking helper…" until a usable reply comes, and the first one renews the lease.

A stuck app now gives the fans back to Apple after 30 seconds, not five. Until then the helper keeps following the curve with all its safety rules.

A helper that has stopped answering is now reported after 32 seconds of the app's running time, not six. The helper's own safety rules do not depend on this.

The helper's lease is a helper change, so an installed helper must be restarted to get it. Its `--check-signing` line now ends its policy with `app-lease=30s`. Tests that check how an expiring lease stops work in progress keep a five-second lease through `FanSafetyGate(leaseSeconds:)`.
