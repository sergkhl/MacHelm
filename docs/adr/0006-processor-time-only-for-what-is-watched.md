---
status: accepted
---

# Spend processor time only on what is watched

## Context

On 2026-10-13 the owner reported processor spikes from MacHelm and from the fan helper, and read the Activity lists' one-second refresh as a fault beside a five-second averaging window. Development build 3 was measured on a Mac14,9 running macOS 26.6.2 with about 700 processes; figures are percentages of one core.

| State | MacHelm | Fan helper |
| --- | --- | --- |
| Dashboard closed, fans automatic | 2.1, with a 5–8 second at each read | 1.5–2.5 |
| Fans held, no write | | 4.5–6 |
| One fan target written | | 15–21 |
| Both fans written | | 34–40 |
| Activity page open | 8.5, peaks of 13–15 | |

The helper's cost was almost entirely the check for a competing fan utility, which read the path of every process: about 15 ms on efficiency cores, once a second while observing, four times while holding the fans, and about ten more times for each fan write. MacHelm's cost on the Activity page was the one-second read, ranking and redraw. Closed, it also asked Service Management for the helper's approval every second, a round trip that held the main thread for about 26 ms and kept `smd` and `backgroundtaskmanagementd` at about 2% between them.

## Decision

Periodic work follows what something is watching.

- The on-screen Activity pace is five seconds by default, as the background pace is. Settings still offers one, two and five seconds. This replaces the one-second default of [ADR 0005](0005-activity-reads-in-the-background.md) and of the table in [ADR 0002](0002-process-data-without-root.md). Activity still reads in the background, and a pace is still never longer than the window.
- A reading taken while no list is on screen and the menu is shut is kept but not ranked or published. It is ranked when something starts to look: before the menu is built, and when the lists come on screen.
- The fan status that arrives every second is not announced to the views while the dashboard is off screen. The menu bar readout is fed separately.
- The helper's approval is asked for when it can have changed: at launch, when the dashboard or the menu opens, when MacHelm becomes active, after waking, after setting up or removing the helper, and when its connection is lost. It is asked for every second only while the dashboard is on screen and the helper is not approved.
- The competing-utility check reads a process's path only when the kernel's short name for it can be the utility's executable name. Every checkpoint stays where it was, and the path still decides.

## Alternatives

Reading every 30 seconds while hidden, whatever the window, would cost less; the owner kept the five-second reads so that the menu's figures are never older than the window. Checking for the competing utility once for each control cycle would also end the spikes, but it would notice a utility that appears during a write up to two seconds later and would move checkpoints that the helper's tests pin. Leaving the helper's 200-line log out of its per-second reply would save a further 0.4% and needs a protocol change; it was left for a release that changes the protocol anyway.

## Consequences

The lists move every five seconds unless the owner chooses a quicker pace. An approval given or withdrawn in System Settings while MacHelm is in the background shows at the next of the events above, not within a second. The short name and the path can disagree for a hard-linked executable, where the path alone already named either link; such a copy of the utility can be missed, as a renamed one always could.

The acceptable level is the owner's: no five-second average above 10% of one core for either process. The one-second burst when the dashboard opens is left as it is.

Development build 4 was measured the same way on the same Mac. With the dashboard closed MacHelm took 1.4% and the helper 0.9% over two minutes, and the two system daemons nothing measurable. In seconds with a fan write the helper averaged 4.3%, with a worst five-second average of 3.6% and a worst second of 12.7%. With the Activity page visible MacHelm averaged 2.5%, with a worst five-second average of 3.8%; with the Overview visible, 2.0%. The `ps` listing for system processes still costs about 0.6% in its own process.
