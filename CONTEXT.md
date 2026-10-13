# MacHelm terminology

These terms connect the interface, shared code, and documentation. The design rationale is recorded in [docs/adr](docs/adr).

## Application

**Tool** is one operation or feature: cursor hiding, Fan Control, Keep Awake, Sleep Now, sleep timers, Activity, Storage, or a startup service. Each keeps its own state and cleanup behavior.

**Tool group** is the collection shown on a dashboard page. **Dashboard** is the app's main window. **Overview** is its first page, with quick controls and live readings; a group's **page** holds its details.

**Quit MacHelm** follows the application's normal termination path. It attempts to restore an owned cursor hide request, requests automatic fan control, and releases Keep Awake. It retains saved preferences and leaves startup services and the macOS sleep timers in place. This differs from Activity's Quit action for another app and from forcefully terminating MacHelm.

**Fan helper** is the privileged process dedicated to fan control. **Toolkit helper** is the separate privileged process for the power settings and narrowly permitted root cleanup requests. Neither is a general command executor.

**Service runner** is the program embedded in MacHelm that launchd uses to execute a managed startup service's definition. It also provides command-line management through the shared service controller.

## Cursor

**Cursor hide** is the experimental control for the system pointer. Its fixed global shortcut is **Ctrl+Option+Command+H** (`⌃⌥⌘H`). The dashboard's Cursor and Overview pages offer the same toggle.

**Hide requested** means MacHelm owns one hide request accepted by its private WindowServer backend. It is not a measurement of visible pointer state and says nothing about a pointer drawn inside a game.

**Restore** sends a matching show request only when MacHelm owns an accepted hide. A successful request clears ownership; a failed restore retains it for a later retry. Normal Quit follows this same restoration path. See [Cursor hide](docs/cursor-hide.md) for compatibility limits.

## Activity

**Activity** is MacHelm's process view. **Activity Monitor** is Apple's separate application, which MacHelm can open for the full process table.

**Measure** is CPU, memory, GPU, energy, or disk. Process CPU uses the percentage of one core. Memory uses the process footprint. GPU uses GPU time; energy uses watts; disk uses bytes read and written per second.

**Process group** is one ranked row: an app and its helpers, a startup service and its descendants, a Windows executable under Wine, Wine's background processes, or otherwise matching program names. An app copy started by another program can form its own row with an origin.

**Heaviest processes** are the five groups with the highest average for a measure over the selected **window**. The available windows are 5, 10, or 30 seconds, 1 minute, and 5 minutes; the default is 10 seconds.

**Whole-Mac figure** is the latest system reading beside a measure's title. It is neither the sum of the visible rows nor their windowed average. Whole-Mac CPU uses all cores as its denominator. macOS's whole-Mac power reading updates less often than the process samples.

**Reading pace** is the sampling interval, by default five seconds in the background and one second while the lists or menu are open. A pace cannot exceed the selected window.

**Own process** belongs to the current user. **System process** belongs to root or another system user; its available measures are limited to CPU and GPU, and it has no control actions in Activity.

**Starter** is the first parent observed for a process, retained after that parent exits. **Responsible app** is the application macOS associates with a process. **Origin** is the starter chain for an app copy, with incidental shell and package-runner steps omitted. **Process kind** describes a helper's role, such as browser tab, extension, GPU, or network; it does not identify the web page shown by a browser tab.

**Protected row** has no process actions: a system process, `loginwindow`, MacHelm, or a startup service the catalog only observes. **Ended row** has no live processes and remains visible until its readings leave the window.

**Quit** asks an application to quit or sends a terminate signal to a program without an app interface. **Force Quit** terminates the selected processes and requires confirmation. **Stop service** uses Startup Services' current-session Stop action and leaves its login preference unchanged.

## Power

**Keep Awake** is the remembered preference to prevent sleep. The toolkit helper adds the system hold used for lid sleep; without it, the app prevents idle sleep only. The display can still turn off according to its timer.

**Battery level** is the threshold at or below which Keep Awake pauses on battery. The default is 20%; connecting the power adapter allows it to resume.

**Sleep Now** requests system sleep, including while Keep Awake is enabled. The app waits briefly for input to become idle; input around the sleep transition can cause macOS to wake again. Keep Awake can resume after wake.

**Sleep timers** are macOS's display and system sleep settings for battery and power-adapter use. MacHelm reads them and, with the toolkit helper, updates them. They persist after the app quits.

## Storage

**Storage** shows available startup-disk space and offers developer-storage cleanup. **Available space** includes space macOS reports as reclaimable, as Finder does.

**Cleanup script** is `Storage/cleanup-macos-dev.py`, the authority for discovery and cleanup rules. **Scan** lists and measures targets without deleting them. It runs only when requested.

**Target** is one listed cache, simulator, emulator, or runtime. A target is selectable, blocked, or report-only. **Clean** removes the confirmed selection permanently.

**Root target** needs elevated rights. The app delegates only permitted root removals to the toolkit helper; unsupported removals remain blocked or show the relevant terminal command.

## Startup Services

**Observed service** is imported for viewing while its original LaunchAgent retains registration ownership. **Managed service** has its registration controlled by MacHelm and, when imported, an exact original backup.

**At login** controls the next login. **Start**, **Stop**, **Run Now**, and **Resume Schedule** control the current session. **Take over** means install the managed definition without changing the running job. **Revert** restores a stopped imported service's original definition.

**Owner lock** is a file lock held by a service while it owns its data. MacHelm's supported integration checks use it to avoid a second owner, independently of the process ID launchd reports.
