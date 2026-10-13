---
status: accepted
---

# Sample Activity in the background

## Context

Activity offers averaging windows up to five minutes, and the menu bar should have recent process rankings when opened. Sampling only while the dashboard is visible would repeatedly discard useful history and leave the menu without measurements. Process origin also benefits from observing a starter before it exits.

## Decision

Sample processes whenever MacHelm runs. Use a default pace of five seconds in the background and one second while an Activity list or the menu is open. Allow both paces to be changed in Settings, with neither interval longer than the selected averaging window.

## Alternatives

Restarting measurements on every appearance avoids background work but leaves each long window incomplete. Retaining old readings without collecting new ones preserves part of the window while allowing it to go stale. Sampling every second all the time uses more resources when no one is looking at the view.

## Consequences

The menu and newly opened dashboard can use the retained window immediately. A process that begins and ends between samples will not be observed. Sampling cost depends on the machine, process count, operating system, and chosen pace; unit tests of ranking do not measure that native overhead.

The fan and startup-service views retain their own polling conditions. Activity's pace does not alter the fan helper's control loop.
