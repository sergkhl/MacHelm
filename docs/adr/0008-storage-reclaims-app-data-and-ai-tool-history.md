---
status: accepted
---

# Storage reclaims app data and AI-tool history

## Context

Storage began as developer-storage cleanup ([ADR 0004](0004-storage-runs-the-cleanup-script.md)). By 2026-10-15 the owner's developer caches were already clean: a scan offered 0.66 GB, while 49 GB of 494 GB was available. The space had moved elsewhere. Telegram kept eleven copies of one update download (5.6 GB). Codex held 10.5 GB of chats, Claude Code 4.0 GB of sessions, and worktrees of both 10.8 GB. Two AVDs (7.4 GB) sat in a folder the script never looked in. App caches came to about 17 GB, and data left by uninstalled apps to 3.1 GB. Device backups and the Trash could not be measured, because macOS protects them behind Full Disk Access. The owner asked for "unused cache, backups, etc" and for old Codex and Claude sessions, AVDs and worktrees, and settled the rules below in three rounds of questions.

Unlike a cache, much of this cannot be downloaded or rebuilt: a chat, a session, uncommitted work in a worktree, a device backup.

## Decision

The cleanup script stays the only engine, and the app shows one list.

- **Groups.** The risk groups stay. A new group holds what cannot be restored: chats, sessions, worktrees, device backups, the Trash and data left by apps that are gone. Everything in it starts unchecked.
- **A tree.** Each row has a kind: the middle level between its group and the row. A checkbox at every level shows none, some or all of what is below it. Kinds start folded, with their totals. Sessions and chats are grouped by project folder. A parent over alternative treatments checks the script's preferred one.
- **Idle.** One setting, from 1 to 90 days and 7 by default, says how long a Codex chat, a Claude Code session or a worktree must have been left alone. The app passes it to the script at each Scan, so the rule stays in the script.
- **Owning tools.** A Codex chat is removed by `codex delete --force`, which keeps Codex's index whole. A worktree is removed by `git worktree remove`, and the Trash is emptied by Finder. Files are deleted directly only where no tool owns them.
- **Worktrees.** A worktree whose every commit's change is in the main branch (`git cherry`) or on a remote is **merged** and can be removed at any age, also with uncommitted files. Otherwise it is **idle** once no file outside `.git` and `node_modules` has changed for the idle setting. Any other worktree is listed blocked with the reason, and so is one a running program works in. Before removing a worktree that holds anything found nowhere else, the script commits a snapshot of it, untracked files included, to `refs/machelm/worktrees/<name>` in its repository. The worktree's branch is deleted when its work is merged and kept otherwise.
- **Running apps.** A cache whose app is running, pytest runs while pytest runs, and a worktree in use are blocked, and each is checked again just before removal.
- **Full Disk Access.** The script reports a folder it cannot list for want of the access. The app then says what it cannot measure and opens the right pane of System Settings. Nothing asks for the access before a scan meets such a folder.
- **Never touched.** Claude Code's `memory/` folders, Service Worker storage, shader caches, Codex's databases, Apple's own caches, and the newest update download of each app.

## Alternatives

A second script or a second panel for app data would split one Scan and one Clean into two. Deleting chat and session files directly would be faster than `codex delete`, but it would leave Codex's index pointing at chats that no longer exist. Leaving worktrees to Codex's own limit of 15 would leave Claude's worktrees and the owner's 10.8 GB as they were. Removing worktrees without a snapshot would lose uncommitted work and commits made without a branch, so the snapshot costs almost no space in exchange. Asking for Full Disk Access at the first Scan would interrupt owners who never keep device backups. Emptying the Trash by unlinking files would miss the Trash on other disks and items Finder handles specially.

## Consequences

A confirmed Clean can now remove the owner's own data, not just downloads. Such rows start unchecked, and the Clean confirmation names them. Removing one Codex chat takes a fraction of a second, so the 911 archived chats on the owner's Mac take minutes.

Removing through Codex also brings Codex's own rules. It removes a chat together with the subagents it spawned, and keeps a chat while a chat forked from it remains. A row's chats therefore go newest first. On 2026-10-15 a Clean that went oldest first reported 17 rows of chats as not removed when nearly all their chats had gone: each parent took its subagents with it, and Codex then failed on every subagent, saying only "failed to delete session".

Snapshots stay in the repository until the owner removes them, with `git update-ref -d refs/machelm/worktrees/<name>`. They cost almost no space, because worktrees share their repository's objects. Untracked files in a snapshot do add to the repository.

The app gains an Apple Events entitlement and a usage description, so that Finder can be asked to empty the Trash; macOS asks the owner once. Full Disk Access, once granted, also lets MacHelm and every program it starts read Mail, Messages and Safari data.

Data left by apps that are gone is recognised through Spotlight's index of applications. An app on a disk that Spotlight does not index looks uninstalled; when Spotlight cannot find Finder itself, that scan fails rather than offering every folder.
