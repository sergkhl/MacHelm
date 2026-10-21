---
status: accepted
---

# Keep a requested cursor hide in force

## Context

Until development build 5, MacHelm sent one hide request on its own WindowServer connection and never looked at the pointer again. On 2026-10-14 the owner reported the system pointer coming back while the controls showed *Hide requested*. The game was Skyrim Special Edition under CrossOver, played with the mouse, with the dashboard closed and the bottle's `CaptureDisplaysForFullscreen` on. WindowServer gives the pointer to whatever software updates it next. Wine's macOS driver sets or shows the cursor when the Windows program changes its cursor, for each frame of an animated cursor, and when the pointer leaves the game's window. Apple Developer Technical Support says the Dock keeps control whenever it would be the pointer's target. Nothing re-applied MacHelm's hide, so the pointer stayed visible until the shortcut was pressed twice.

Measured on a Mac14,9 with macOS 26.6.2:

- `CGCursorIsVisible` reports the pointer for the whole system: a second process saw it hidden and visible again across another process's 0.3-second hide.
- WindowServer counts hide requests per connection: hide, hide, show left the pointer hidden.
- One reading costs about 7 ns. A timer that only reads costs about 3.0% of one core every millisecond, 0.64% every 8 ms, and 0.06% every 100 ms.

## Decision

A hide stays requested until the shortcut, Restore, or Quit, in every application: through Escape, game menus, mouse movement, screen edges, app switches, and the game's exit.

- While the request stands, MacHelm reads `CGCursorIsVisible` every 100 ms. When the pointer is visible, it shows the hide it owns and sends a new one, so it never owns more than one.
- A refused re-hide keeps the request and is tried again at the next reading. A refused first hide still creates no request.
- *Hide requested* now means the owner's request, not an accepted hide.
- Nothing runs while no hide is requested.

## Alternatives

Reading every millisecond would keep a reappearance under one frame, at about fifty times the cost. The owner accepted 100 ms or longer.

Hiding only while the application in front at the press stays in front would show the pointer in other applications. The owner chose a hide that lasts across app switches.

Hiding through the game's own connection, at the display, or at the HID level could reach where MacHelm's connection cannot, but it would act on another application's state. It waits until an in-game check shows it is needed.

Keeping the single request and documenting the limit would leave the reported fault.

## Consequences

A pointer that macOS shows again can stay visible for up to about a tenth of a second, and over a revealed Dock until it leaves. The pointer is also hidden over MacHelm's own windows; the shortcut restores it. Whether the hide holds while a game has captured the display has not been established.

The readings run only while a hide is requested. With Keep Awake off, App Nap may stretch their interval; an in-game check measures it before any exemption is added.
