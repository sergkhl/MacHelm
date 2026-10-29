---
status: accepted
---

# Watch through a sensor gap, and say why Fan Control stopped

## Context

On 2026-10-28 Fan Control turned itself off at 04:23 on the owner's Mac14,9 (macOS 26.6.2), with app build 3 and helper build 2. It had been on since 19:50 the evening before. From 01:45:57 it held no fans: the smoothed CPU die average was below the start temperature, so it only watched. The owner found it off the next day, after a restart, with no explanation anywhere.

The helper keeps its log only in memory, and the app writes no log, so the cause was rebuilt from the system log. Each AppleSMC read by the helper leaves a kernel line, which gives its reads per second:

- **51** for a usable frame.
- **73** for a frame skipped because a reading was out of range: the frame, then a fan-state check.

From 04:23:21 to 04:23:24 four seconds in a row show 73. The firmware's CPU die maximum `TCMz` returned values between 255 and 260 °C, as it does now and then. The complete-frame limit of H-Q4 ended the session about four seconds after the last usable frame. Nothing was released, because nothing was held. The app's next lease renewal was refused, and it treated that as Fan Control ending. Under SR-Q1 an ending the owner did not choose saves off, so Fan Control did not come back at launch either.

From 01:46 to 04:23, 5.7% of frames were skipped this way: 492 alone, 19 in pairs, one run of four. At that rate a run of four comes about once a day of watching. The reason was shown only on the Cooling page, and only until the app restarted. No notification was posted.

## Decision

The owner decided on 2026-10-29.

- **A session that only watches outlasts the complete-frame limit (G-Q1).** The helper's safety gate applies the four-second limit only while the helper holds an override.
  - The limit applies again from the durable intent of a session's first write. It is checked at that moment, so an entry never follows a stale frame. The frame behind the decision is fresh, so in practice the check passes.
  - After a release that does not end the session, the session watches again.
  - The five-second app lease is unchanged.
  - Every frame failure other than an out-of-range reading still ends the session at once: a missing or invalid reading, a changed sensor set, an unexplained fan mode, a competing utility.
- **Fan Control says why it stopped (G-Q2).** When Fan Control ends without the owner turning it off, the app keeps why and when it ended.
  - **What counts:** the helper ending the session, a failed connection or reply while it is on, a wake that does not bring it back, and a release at quit the helper did not confirm.
  - **Whose words:** when the helper ended the session, the helper's own reason replaces the app's as soon as a status gives it, or after five seconds at most.
  - **Kept across launches:** the note is saved. The Overview reads "Stopped by itself, see Cooling", and the Cooling page gives the time and the reason. The note stays until the next press, or until Fan Control is on again.
  - **One notification:** "Fan Control stopped", posted once. It is skipped when a hold, fans left in manual, or the helper's own recovery already has an alert (Z-Q5, Z-Q7, Z-Q8).

## Alternatives

- **Bring Fan Control back by itself after a fault ending.** The app would use the rule that follows a wake: three healthy readings in a row, every fan automatic, no hold. That reverses SR-Q1 for every kind of ending, including ones the owner should look at, such as another fan utility or a fan that changed by itself. The owner kept SR-Q1.
- **Lengthen the complete-frame limit.** That also lengthens how long the helper holds fans without knowing the temperature. Watching holds none, so it alone can drop the limit at no cost.
- **Control on the CPU die average when only `TCMz` is out of range.** This substitutes for an unusable frame, which the helper never does (H-Q2), and protection depends on `TCMz`.

## Consequences

While watching, a long run of unusable frames leaves the menu bar readout showing dashes and the Cooling page without fresh readings. Fan Control stays on, and Apple's automatic control has the fans throughout. Control starts on the first usable frame at or above the start temperature, and the policy's smoothing catches up across the gap.

A run of four or more unusable frames while the helper holds fans still ends Fan Control, with a release. It is now told and announced, but not undone.

The release at quit still races launchd at shutdown. On 2026-10-28 launchd stopped the fan helper 120 ms after the app began to quit, and the helper has no SIGTERM handler. If Fan Control is on at shutdown, it is likely to stay off after the restart. It now says so. This case has not been observed with Fan Control on.
