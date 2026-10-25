# Cursor hide

Press **Ctrl+Option+Command+H** (`⌃⌥⌘H`) to hide the system pointer while MacHelm runs, including while another application is active, and press it again to restore it. The shortcut is fixed. The dashboard's Tweaks and Overview pages expose the same control.

The shortcut uses an exclusive global hot-key registration and does not require Accessibility permission. If another application already owns that combination, MacHelm reports that the shortcut is unavailable; the dashboard controls remain available. Holding the keys does not repeatedly toggle the state.

## Keeping the pointer hidden

A hide stays requested until the shortcut, the dashboard's Restore, or Quit: through Escape, game menus, mouse movement, screen edges, app switches, and the game's exit. Other software can make macOS show the pointer again, such as a game that changes its cursor or the Dock. While the request stands, MacHelm reads every 100 ms whether macOS reports the system pointer visible and, if it does, hides it again. While no hide is requested, nothing runs. [ADR 0007](adr/0007-keep-a-requested-cursor-hide-in-force.md) records the decision.

The reading is `CGCursorIsVisible`, which reports the pointer for the whole system, whichever application showed it. One reading costs well under a microsecond; a timer that reads every 100 ms took about 0.06% of one core in a command-line measurement on a Mac14,9 with macOS 26.6.2. A pointer that macOS shows again can stay visible for up to about a tenth of a second. The pointer stays hidden over MacHelm's own windows too; the shortcut restores it.

## Request ownership

WindowServer counts hide requests for each connection, so MacHelm owns at most one accepted hide. To hide a pointer that macOS showed again, MacHelm shows the hide it owns and then sends a new one, so the count never passes one. Repeated hide or restore calls do not add extra requests, and MacHelm never sends a show for a hide it did not successfully request.

**Hide requested** in the interface means the owner's request stands. It does not measure whether the system pointer is currently visible. A failed first hide creates no request. A failed re-hide keeps the request: the interface shows the error and the next reading tries again. If the show half of a re-hide is refused, MacHelm keeps the hide it owns and sends no new one in that round. A failed restore ends the request but keeps ownership, so a later Restore or normal-Quit cleanup can retry; until then the controls still offer Restore.

On normal Quit, MacHelm stops the shortcut, the readings, and new hide requests, then attempts to restore its owned hide before releasing the helpers. Its final termination cleanup retries restoration if ownership remains. This balances its own successful requests without assuming ownership of requests made by another application. A rejected restore remains an error; the app cannot guarantee a visible pointer after an API failure, crash, or force quit.

## Experimental compatibility

The backend dynamically loads the private WindowServer functions `CGSMainConnectionID`, `CGSSetConnectionProperty`, `CGSHideCursor`, and `CGSShowCursor`, and the deprecated public function `CGCursorIsVisible`. It sets `SetsCursorInBackground` on MacHelm's own connection so that connection can request hiding while MacHelm is inactive. It does not inspect or modify another application's connection. Missing symbols or rejected calls are reported as unavailable or failed cursor control; there is no alternative backend.

Apple does not provide a supported background-visibility or process-exit contract for these functions. A re-hide takes effect only where WindowServer lets a background connection control the pointer. According to [Apple Developer Technical Support](https://developer.apple.com/forums/thread/756199), WindowServer keeps control with the Dock whenever the Dock would be the pointer's target, so a pointer over a revealed Dock stays visible until it leaves; the menu bar of a full-screen space may behave the same way. Whether a re-hide holds while a game has captured the display, as Wine does with `CaptureDisplaysForFullscreen`, has not been established. Games that render their own pointer may continue showing it regardless of the system-pointer request. Compatibility must be observed with the specific game, macOS version, and display setup in use.

## Verification

The `CursorVisibilityTests` in the Swift package verify balanced ownership, the re-hide order, failed hide, re-hide, and restore behavior, restoration retries, and stopping without adding unmatched show requests. They use a recording backend that counts accepted hides as WindowServer does for one connection, and they do not call WindowServer:

```sh
swift test --scratch-path build/swift-tests --filter CursorVisibilityTests
```

A build proves that the backend and shortcut compile. An accepted native API call proves only that the call was accepted. To establish visible behavior, observe the pointer in the foreground application or game, exercise hide, a reappearance, and restore, and check normal Quit separately. No game-compatibility or force-quit recovery guarantee follows from the source tests or the published 0.1 source tag.
