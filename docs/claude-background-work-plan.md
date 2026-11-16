# Claude background work in MacHelm

The Claude sidebar page shows background work across local Claude Code conversations. Open the owning conversation to inspect output or stop work through Claude Desktop’s Background tasks pane or the terminal’s `/tasks` view. [Desktop background tasks](https://code.claude.com/docs/en/desktop#watch-background-tasks) · [Claude Code commands](https://code.claude.com/docs/en/commands)

## Page behavior

- Place **Claude** before **Tweaks** in the sidebar, with its own page and store for future Claude controls. Preserve the existing keyboard shortcuts.
- Group by conversation. Show the session title, project and Claude state. Expand the row for jobs and any associated PIDs. When two sessions share a working directory, render them as two rows. Reveal the full path and session ID in details where available.
- Show detached sessions while their worker is alive or Claude reports them working or waiting for input. Include a **Needs input** session without a PID. Show other conversations when they own identified background work or are waiting for input. Once a job finishes, remove it on the next successful refresh.
- Keep an independently running process visible after its conversation closes. Show **Session closed**, the known owner, and the PID. Put work with proven Claude origin and an unresolved owner under **Session unknown**.
- Refresh immediately when the Claude page opens and periodically while it is visible. Distinguish an empty list from unavailable or stale data. Use concise source-specific status when a failed read limits what the page can show.

## Session and job discovery

1. Read `claude agents --json` off the main thread with a bounded runtime. Decode optional fields, keeping the background attach ID, conversation UUID, and PID distinct. Resolve the user’s Claude executable and honor the configured Claude directory. Verify that listing in an isolated configuration works without starting a session or changing Claude settings. [Agent view JSON schema](https://code.claude.com/docs/en/agent-view#list-sessions-as-json)
2. Reuse Activity’s latest raw current-user process sample and its PID plus process start identity. Join it with verified Claude process registrations and ancestry. When needed, use the specific `CLAUDE_CODE_SESSION_ID` marker or a live task output descriptor tied to a known session. Treat project path and process name as display details. Carry a confirmed relationship forward while the same process identity survives reparenting. [Activity sampler](../MacHelm/ActivityStore.swift) · [Process identity](../Sources/ActivityCore/ProcessModels.swift) · [Claude session environment marker](https://code.claude.com/docs/en/env-vars)
3. Use proven live task records for Claude-managed background shell jobs and in-process subagents. Group worker processes under the associated job when the relationship is known. Treat an output file alone as historical evidence. Check a disposable subagent’s start, finish and restart behavior before using version-dependent task records to report live state. When a Claude version exposes only a process or the owning session, show the verified information and limited task coverage. [Claude task lifecycle](https://code.claude.com/docs/en/agent-sdk/typescript#sdkbackgroundtaskschangedmessage)
4. Keep the Claude-specific metadata readers separate from Activity’s ranking logic. Query the sources once per refresh, coalesce overlapping requests, and publish an updated snapshot only when it changes. Tie refreshes to the dashboard’s existing page and window visibility. Keep independently verified rows available if another source fails. [Dashboard visibility](../MacHelm/DashboardView.swift)

## Opening sessions

Resolve the target again when the user clicks. Use validated identifiers and explicit command arguments. Request macOS Automation on a user action that needs it and describe terminal use in the app’s generated permission text.

| Session or job | Action |
| --- | --- |
| Existing Claude Desktop conversation | **Open Session** uses the verified Desktop session identifier and the version-dependent route after native verification. If that route is unavailable, **Open Claude** brings the app forward and the row gives the session name. |
| Existing terminal conversation | **Open Session** focuses the original tab or pane when the terminal exposes an exact match. When the match is unavailable or Automation is declined, identify the terminal and offer **Copy Session ID** where available. |
| Detached Claude-managed session | **Open Session** runs `claude attach <id>` in Ghostty when a new terminal is needed. Offer **Copy Attach Command** if Ghostty is unavailable or the launch fails. An attachable session waiting for input can be opened even if Claude has stopped its worker. |
| Independently running process with a closed conversation | Show the owner and PID. |
| Job with an unknown session | Show the job and any known PID under **Session unknown**. |

The inspected Desktop build routes `claude://claude.ai/epitaxy/<hostSessionId>` to an existing conversation. Match the live process registration to the CLI conversation to obtain the separate Desktop identifier. Keep the route in the Desktop adapter so a Claude update can fall back to **Open Claude**. Use terminal device or pane identity to focus a terminal session. The installed Ghostty 1.3.1 exposes scripted terminal creation, and Ghostty 1.4 adds PID and TTY fields for exact pane matching. [Published Desktop links](https://support.claude.com/en/articles/14729294-open-claude-desktop-with-a-link) · [Attach and session states](https://code.claude.com/docs/en/agent-view#manage-sessions-from-the-shell) · [Ghostty scripting](https://ghostty.org/docs/features/applescript) · [Ghostty 1.4 release notes](https://ghostty.org/docs/install/release-notes/1-4-0)

## Implementation order

1. Prove the Desktop route and Ghostty attach on temporary test conversations. Capture the minimum fields needed for realistic fixtures, including an in-process task if a reliable live record is available.
2. Implement the read-only discovery and attribution as Swift logic testable without launching Claude. Adapt the existing process sampler to hand over its current-user observation. Keep provider file reads and terminal or Desktop actions behind the feature’s own interfaces.
3. Wire the Claude store and page into the sidebar. Add the visible-only refresh, state display and expanded rows. Verify refresh and expansion using fixtures before connecting the opening actions.
4. Connect the session-opening actions and their fallbacks. Update the project generator for source membership and the Automation description, then regenerate the Xcode files. [MacHelm contribution workflow](../CONTRIBUTING.md)

## Verification

| Evidence | Acceptance |
| --- | --- |
| Swift tests | Run `swift test --scratch-path build/swift-tests`. Two sessions in the same project retain their own jobs. A PID-less waiting session is visible. PID reuse, stale task records and conflicting ownership evidence produce no false match. A surviving independent job keeps its confirmed owner and PID. Partial discovery, a failed read, and a successful empty read produce distinct states. |
| Generated project and Xcode build | Run `python3 scripts/generate-xcode-project.py --check` and build the MacHelm scheme in Xcode. Run both artifact verification scripts for any signed build used. Record these results separately from native behavior. |
| Native Mac run | Start harmless jobs in two temporary conversations in the same project. Open the exact Desktop conversation from MacHelm, stop its job in Claude, and observe that only its job row disappears. Attach the exact detached session in Ghostty, including a waiting session without a worker. Verify terminal focus where supported, permission refusal, and the Ghostty and Desktop fallbacks. Check a surviving independent process and confirm Claude discovery pauses when the page is hidden. Record versions and observed behavior. |

Read-only checks on November 16, 2026 verified the CLI session inventory and live process-to-session attribution on Claude Code 2.1.318. Inspection of Claude Desktop 5.11492.5 verified its session route and identifier mapping.

## Implementation verification on November 16, 2026

- **Swift and project generation.** `swift test --scratch-path build/swift-tests` passed 745 tests. `python3 scripts/generate-xcode-project.py --check` passed. The MacHelm Debug scheme built with Xcode 26.6 and both signed-artifact verification scripts passed.
- **Native Mac.** Tested on Mac14,9 with macOS 26.7.3 (25G342), Claude Desktop 5.11492.5, Claude Code 2.1.318 and 2.1.325, Ghostty 1.3.1, and Terminal 2.15. An isolated CLI inventory returned an empty list, created its bootstrap metadata, and preserved the test settings file byte for byte.
- **Desktop sessions and jobs.** Two conversations in the same folder appeared as separate rows with their own session IDs and job PIDs. MacHelm opened the exact Desktop conversation. Stopping one job in Claude removed only that row. An independent process kept its PID and owner under **Session closed** after the second conversation closed. An isolated registration with a missing host ID exercised **Open Claude**.
- **Detached sessions and terminals.** A real CLI session stayed visible as **Needs input** after its worker exited. **Open Session** launched a dedicated Ghostty window using `-e` and explicit attach arguments. The same conversation acquired a new worker. The row offered **Copy Attach Command**. The Terminal script selected the tab with the verified TTY from two disposable TTYs. An isolated registration and a process sandbox that denied Apple events exercised the app’s refusal message and **Copy Session ID**. Exact Ghostty pane focus requires 1.4, and an absent Ghostty installation was outside this native run. [Ghostty command arguments](https://ghostty.org/docs/config/reference#command) · [Ghostty 1.4 TTY support](https://ghostty.org/docs/install/release-notes/1-4-0)
- **Refresh and source status.** Command-7 opened Tweaks and Command-8 opened Claude. The test CLI recorded zero discovery calls during seven seconds on Overview. Verified registration rows remained visible when the CLI listing failed. A subsequent successful empty read showed the empty state.
- **In-process task coverage.** The disposable subagent appeared in Claude’s Background tasks pane while active and disappeared at completion. Transcript and output files were still present after the session’s worker restarted. MacHelm uses a structured background receipt and live writer for shell jobs and directs users to Claude for in-process tasks. [Claude SDK background task lifecycle](https://code.claude.com/docs/en/agent-sdk/typescript#sdkbackgroundtaskschangedmessage)
