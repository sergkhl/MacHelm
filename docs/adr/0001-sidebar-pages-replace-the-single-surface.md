---
status: accepted
---

# Use a dashboard with sidebar pages

## Context

MacHelm presents several tools with different kinds of detail. Fan Control needs readings, profile settings, and recovery actions; Activity needs room for process lists; Startup Services needs an expandable list. A single surface becomes hard to scan as those lists grow.

## Decision

Use one dashboard window with an Overview and a page for each tool group. Open the window on Overview, which presents quick controls and current readings. Put the fuller configuration and longer lists on their group pages. Keep app-wide settings, including opening at login and the menu bar readout, in Settings.

Closing the dashboard hides the window while the app remains available from the menu bar. Quitting the app performs each tool's cleanup.

## Alternatives

A single dashboard with more stacked panels would keep every tool visible but force frequent scrolling and compress important details. Toolbar tabs would provide separate pages but leave less space for readable group names as the tool set grows.

## Consequences

Fan recovery state is visible from Overview; its recovery actions live on Cooling alongside the associated readings. Navigation does not itself enable a tool. The menu bar continues to offer immediate access to the dashboard and a small set of common operations.
