# MacHelm terminology

These terms connect the interface, shared code, and documentation. The design rationale is recorded in [docs/adr](docs/adr).

## Application

**Tool** is one operation or feature: cursor hiding, Fan Control, Keep Awake, sleep timers, Activity, Storage, or a startup service. Each keeps its own state and cleanup behavior.

**Tool group** is the collection shown on a dashboard page. **Dashboard** is the app's main window. **Overview** is its first page, with quick controls and live readings; a group's **page** holds its details.

**Tweaks** is the last tool group, after Startup Services in the sidebar and at the bottom of Overview. It currently contains Cursor hide. Settings stays at the bottom of the sidebar. Overview card headings open their detail pages; contextual info buttons hold general explanations while readings, current state and problems remain visible.

**Quit MacHelm** follows the application's normal termination path. It attempts to restore an owned cursor hide request, requests automatic fan control, and releases Keep Awake. It retains saved preferences and leaves startup services and the macOS sleep timers in place. This differs from Activity's Quit action for another app and from forcefully terminating MacHelm.

**Fan helper** is the privileged process dedicated to fan control. **Toolkit helper** is the separate privileged process for the power settings and narrowly permitted root cleanup requests. Neither is a general command executor.

**Service runner** is the program embedded in MacHelm that launchd uses to execute a managed startup service's definition. It also provides command-line management through the shared service controller.

## Cursor

**Cursor hide** is the experimental control for the system pointer. Its fixed global shortcut is **Ctrl+Option+Command+H** (`⌃⌥⌘H`). The dashboard's Tweaks and Overview pages offer the same toggle.

**Hide requested** means the owner asked for the system pointer to be hidden and has not restored it. While the request stands, MacHelm checks every 100 ms whether macOS shows the pointer and, if it does, hides it again; it owns at most one hide accepted by its private WindowServer backend. It says nothing about a pointer drawn inside a game.

**Restore** ends the request and sends a matching show request only when MacHelm owns an accepted hide. A successful request clears ownership; a failed restore retains it for a later retry, and the controls keep offering Restore until then. Normal Quit follows this same restoration path. See [Cursor hide](docs/cursor-hide.md) for compatibility limits.

## Cooling

**Start temperature** is the profile's lower threshold: **Start** under Temperatures on the Cooling page, 70 °C by default. Fan Control takes the fans when the smoothed CPU die average reaches it, and keeps them until the average has stayed below it for ten seconds. There is no separate release temperature. **Maximum**, 85 °C by default, is where demand reaches its maximum.

**Release** gives MacHelm's fans back to Apple's automatic control. Each fan MacHelm set to manual mode is set back to automatic, and nothing else is written. It follows ten seconds below the start temperature. It happens at once when Fan Control is turned off, and on quit, sleep, a lost connection or an expired lease.

**Recovery hold** follows a fan command the helper could not confirm. Fan Control, saving temperatures and helper removal stay locked, and a fan may be left as that command left it. The helper makes one attempt by itself to return its own fans to automatic, unless the fans changed in a way it cannot explain. **Restore automatic now** and **Verify external recovery** on the Cooling page also end a hold. A hold raises a macOS notification and a warning sign on the menu bar item. See [Fan Control](docs/fan-control.md) and [ADR 0009](docs/adr/0009-release-by-mode-and-recover-an-unpredicted-entry.md).

## Activity

**Activity** is MacHelm's process view. **Activity Monitor** is Apple's separate application, which MacHelm can open for the full process table.

**Measure** is CPU, memory, GPU, energy, or disk. Process CPU uses the percentage of one core. Memory uses the process footprint. GPU uses GPU time; energy uses watts; disk uses bytes read and written per second.

**Process group** is one ranked row: an app and its helpers, a startup service and its descendants, a Windows executable under Wine, Wine's background processes, or otherwise matching program names. An app copy started by another program can form its own row with an origin.

**Heaviest processes** are the five groups with the highest average for a measure over the selected **window**. The available windows are 5, 10, or 30 seconds, 1 minute, and 5 minutes; the default is 10 seconds.

**Whole-Mac figure** is the latest system reading beside a measure's title. It is neither the sum of the visible rows nor their windowed average. Whole-Mac CPU uses the rows' scale, the percentage of one core, and names the number of cores: every core at work reads as 100% times that number. macOS's whole-Mac power reading updates less often than the process samples.

**Reading pace** is the sampling interval: one pace in the background and another, which can be set quicker, while the lists or menu are open. Both are five seconds by default. A pace cannot exceed the selected window.

**Activity menu group** is a clickable Activity row followed by the five heaviest CPU groups. The row and each process open the Activity page. The menu uses the same averaging window and retains its displayed snapshot until closed, so rows do not move under the pointer.

**Own process** belongs to the current user. **System process** belongs to root or another system user; its available measures are limited to CPU and GPU, and it has no control actions in Activity.

**Starter** is the first parent observed for a process, retained after that parent exits. **Responsible app** is the application macOS associates with a process. **Origin** is the starter chain for an app copy, with incidental shell and package-runner steps omitted. **Process kind** describes a helper's role, such as browser tab, extension, GPU, or network; it does not identify the web page shown by a browser tab.

**Protected row** has no process actions: a system process, `loginwindow`, MacHelm, or a startup service the catalog only observes. **Ended row** has no live processes and remains visible until its readings leave the window.

**Quit** asks an application to quit or sends a terminate signal to a program without an app interface. **Force Quit** terminates the selected processes and requires confirmation. **Stop service** uses Startup Services' current-session Stop action and leaves its login preference unchanged.

## Power

**Keep Awake** is the remembered preference to prevent sleep. The toolkit helper adds the system hold used for lid sleep; without it, the app prevents idle sleep only. The display can still turn off according to its timer.

**Battery level** is the threshold at or below which Keep Awake pauses on battery. The default is 20%; connecting the power adapter allows it to resume.

**Sleep timers** are macOS's display and system sleep settings for battery and power-adapter use. MacHelm reads them and, with the toolkit helper, updates them. They persist after the app quits.

## Storage

**Storage** shows available startup-disk space and offers its cleanup: developer tools, app caches, update downloads, AI-tool history, worktrees, device backups, and the Trash. **Available space** includes space macOS reports as reclaimable, as Finder does.

The Storage menu item refreshes available space when the menu opens and links to the Storage page. Reading available space does not run a cleanup scan.

**Cleanup script** is `Storage/cleanup-macos-dev.py`, the authority for discovery and cleanup rules. **Scan** lists and measures targets without deleting them. It runs only when requested.

**Target** is one listed item that can be cleaned, such as a cache, simulator, emulator, runtime, chat, session, worktree, or backup. A target is selectable, blocked, or report-only. **Clean** removes the confirmed selection permanently. **Last Clean** reports what the latest Clean reclaimed and each target it did not remove, or removed only in part, with the reason, until the next Scan or Clean.

**Group** is a target's risk class, such as restored by a re-download or **cannot be restored**. **Kind** is what a target is within its group, such as App caches or Merged worktrees; it is the level between a group and its targets. A checkbox on a group or kind checks or clears every selectable target below it.

**Idle** means left alone for at least the idle setting, from 1 to 90 days and 7 by default: no file of a Codex chat, a Claude Code session, or a worktree changed in that time. The script applies it at the next Scan.

**Merged worktree** has every commit's change in its repository's main branch, or on a remote. **Idle worktree** is not merged and is idle. **Worktree snapshot** is the commit the script keeps under `refs/machelm/worktrees/<name>` before removing a worktree that holds anything found nowhere else.

**Full Disk Access** is the macOS permission that device backups, the Trash, and other apps' containers require. MacHelm detects it from what a scan could list and opens System Settings for the owner to grant it.

**Root target** needs elevated rights. The app delegates only permitted root removals to the toolkit helper; unsupported removals remain blocked or show the relevant terminal command.

## Startup Services

**Observed service** is imported for viewing while its original LaunchAgent retains registration ownership. **Managed service** has its registration controlled by MacHelm and, when imported, an exact original backup.

**At login** controls the next login. **Start**, **Stop**, **Run Now**, and **Resume Schedule** control the current session. **Take over** means install the managed definition without changing the running job. **Revert** restores a stopped imported service's original definition.

**Owner lock** is a file lock held by a service while it owns its data. MacHelm's supported integration checks use it to avoid a second owner, independently of the process ID launchd reports.
