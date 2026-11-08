---
status: accepted
---

# A late status reply does not end Fan Control

The five-second lease, the six-second limit and the second-late-reply rule were replaced on 2026-11-08 by [ADR 0013](0013-a-frozen-app-keeps-fan-control-for-30-seconds.md).

## Context

On 2026-11-03 at 21:11:28 Fan Control ended by itself on the owner's Mac14,9 (macOS 26.6.2), with app and helper build 4. One status reply came back more than three seconds after the app asked for it. The app treated that as a failed connection and dropped the connection, and under SR-Q1 the ending saved off. The saved stop note (ADR 0011) gave the reason. Fan Control stayed off until it was next turned on, across a restart.

The helper kept running. The Mac had no sleep or wake around then. macOS was force-killing background services far more often than usual, and Blender was running, so a memory shortage is the likely cause of the pause. That is not proven, and neither is whether the app or the helper paused.

The three-second limit exists so that only a current status authorizes fan controls. A late reply shows that the status is old. It does not show that the connection or the session has failed.

## Decision

The owner decided on 2026-11-05 that a late reply does not end Fan Control (G-Q3).

- **One late reply is dropped.** It is not applied, and the app asks again at once on the same connection. Fan controls stay locked until a usable reply comes.
- **The first usable reply renews the lease at once.** No renewal goes out while the status is stale, so a pause may have used up most of the five-second lease.
- **Two limits still end Fan Control.** These are a second late reply in a row, and no reply to a request for six seconds. Before this change the second limit was three seconds.

The owner's decision covers the late reply. The two limits were added so that it holds in practice:

- With the old three-second limit, a slow helper would still end Fan Control before its reply arrived.
- Without the second-reply rule, a helper that always replied late would leave Fan Control showing as on after the lease had ended its session, because a dropped reply is never read.

Both limits are longer than the lease, so the app never gives up on a session the helper could still keep.

## Alternatives

- **Accept an older status.** Raising the three-second limit would let an older status authorize fan controls. The limit itself is sound. Only the response to crossing it was wrong.
- **Bring Fan Control back after the ending.** ADR 0011 rejected this because it reverses SR-Q1, and that still stands.

## Consequences

A pause shorter than the five-second lease now leaves Fan Control on. While it lasts, the Overview reads "Checking helper…" and fan controls are locked.

A pause of five seconds or more still ends the session on the helper's lease, and Fan Control stays off. The stop note then gives the helper's reason when a usable reply brings it.

A helper that has stopped answering is now reported six seconds after the unanswered request, not about three or four. The helper's own safety rules do not depend on this, so the only cost is that the app says so later.

A begin whose reply arrives while the status is stale is still treated as failed, as before. Fan Control stays off, and the lease ends the helper's session.
