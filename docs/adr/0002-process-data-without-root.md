---
status: accepted
---

# Read Activity process data without a privileged helper

## Context

Activity needs periodic measurements of processes while keeping the graphical app unprivileged. macOS allows detailed resource readings for the current user's processes but limits access to system processes. Available sources also have different costs and update rates.

## Decision

Use a dedicated process-reading interface with these sources:

| Data | Source | Default pace while visible |
| --- | --- | --- |
| Current-user CPU, memory footprint, energy, and disk counts | `proc_pid_rusage` | Once per second |
| System-process CPU counts | `/bin/ps` | Every five seconds, with an earlier second reading |
| Process GPU time | GPU user-client `AppUsage` properties in the IORegistry | Once per second |

Rank groups by averages over the selected window. Keep system processes under CPU and GPU only, with no termination action. Do not treat unavailable resource fields as zero usage. Activity also samples in the background as described in [ADR 0005](0005-activity-reads-in-the-background.md).

Keep the transport behind an interface so a future data source can be added without changing grouping and ranking. If a future capability needs root, place the narrowly defined request in the toolkit helper described in [ADR 0003](0003-a-toolkit-helper-for-root-tasks-other-than-fans.md).

## Alternatives

A privileged process collector would expose more fields but require a broader helper interface and installed-helper availability for a primarily observational view. Sampling `ps` on every foreground tick would perform more subprocess work without improving the endpoints of most averaging windows.

## Consequences

The view is intentionally incomplete for system processes. `ps` does not provide `kernel_task` in this listing, so it is absent. IORegistry GPU fields are undocumented; changes can make GPU readings unavailable independently of the other measures. Native performance measurements must identify their Mac, operating system, and build rather than being assumed from the sampling schedule.
