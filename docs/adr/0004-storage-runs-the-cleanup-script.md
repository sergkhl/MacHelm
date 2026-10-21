---
status: accepted
---

# Use one cleanup engine for the app and terminal

## Context

Developer-storage cleanup has tool-specific rules: running simulators and emulators must be excluded, runtimes have owning tools, and a cache's apparent size can differ from reclaimable storage. Maintaining separate discovery and deletion implementations in the GUI and terminal would let those rules diverge.

## Decision

Keep `Storage/cleanup-macos-dev.py` as the cleanup engine. The app invokes its structured interface, displays the discovered targets, and passes the user's confirmed selection back to it. The script remains usable on its own in a terminal.

The script and fixture tests live in the repository, and the script is bundled with the app. MacHelm runs it through the user's login shell so it can find the Python and developer tools that the user normally uses. It does not duplicate the removal policy in Swift.

## Alternatives

A complete Swift rewrite would remove the Python runtime requirement but require reproducing every tool-specific rule. A terminal-only integration would keep one engine but leave the app unable to present and confirm individual targets itself.

## Consequences

Python 3 is a runtime requirement. The structured interface must report discovery, progress, failures, and completion independently of the terminal picker. Scanning is read-only; cleanup is an explicit action on a confirmed selection.

A failed probe affects only its own scan. The script withholds that scan's targets and lists in their place one blocked target that names the scan and the failure. Every other scan is reported as usual. A failed probe is never reported as a scan that found nothing. An error event refuses the whole run, so it is not used for one scan's failure; the app needs no separate path for it.

When invoked by the app, the script delegates a permitted root target to the toolkit helper through the app's protocol. In terminal mode it uses its own authorization flow. [ADR 0003](0003-a-toolkit-helper-for-root-tasks-other-than-fans.md) defines the helper's limited removal scope.
