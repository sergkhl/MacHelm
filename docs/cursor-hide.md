# Cursor hide

Press **Ctrl+Option+Command+H** (`⌃⌥⌘H`) to toggle a system-pointer hide request while MacHelm runs, including while another application is active. The shortcut is fixed. The dashboard's Cursor and Overview pages expose the same control.

The shortcut uses an exclusive global hot-key registration and does not require Accessibility permission. If another application already owns that combination, MacHelm reports that the shortcut is unavailable; the dashboard controls remain available. Holding the keys does not repeatedly toggle the state.

## Request ownership

MacHelm owns at most one accepted hide request. The next toggle sends a matching show request. Repeated hide or restore calls do not add extra requests, and MacHelm never sends a show for a hide it did not successfully request.

**Hide requested** in the interface means the backend accepted MacHelm's request. It does not measure whether the system pointer is currently visible. A failed hide does not create ownership. A failed restore keeps ownership so a later Restore or normal-Quit cleanup can retry.

On normal Quit, MacHelm stops the shortcut and new hide requests, then attempts to restore its owned hide before releasing the helpers. Its final termination cleanup retries restoration if ownership remains. This balances its own successful requests without assuming ownership of requests made by another application. A rejected restore remains an error; the app cannot guarantee a visible pointer after an API failure, crash, or force quit.

## Experimental compatibility

The backend dynamically loads the private WindowServer functions `CGSMainConnectionID`, `CGSSetConnectionProperty`, `CGSHideCursor`, and `CGSShowCursor`. It sets `SetsCursorInBackground` on MacHelm's own connection so that connection can request hiding while MacHelm is inactive. It does not inspect or modify another application's connection. Missing symbols or rejected calls are reported as unavailable or failed cursor control; there is no alternative backend.

Apple does not provide a supported background-visibility or process-exit contract for these private functions. macOS or another app can reveal the system pointer. Games that render their own pointer may continue showing it regardless of the system-pointer request. Compatibility must be observed with the specific game, macOS version, and display setup in use.

## Verification

The `CursorVisibilityTests` in the Swift package verify balanced ownership, failed hide and restore behavior, restoration retries, and stopping without adding unmatched show requests. They use a recording backend and do not call WindowServer:

```sh
swift test --scratch-path build/swift-tests --filter CursorVisibilityTests
```

A build proves that the backend and shortcut compile. An accepted native API call proves only that the call was accepted. To establish visible behavior, observe the pointer in the foreground application or game, exercise hide and restore, and check normal Quit separately. No game-compatibility or force-quit recovery guarantee follows from the source tests or the published 0.1 source tag.
