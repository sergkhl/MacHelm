# The cleanup script

`cleanup-macos-dev.py` reclaims the disk space developer tools, apps, and AI tools leave behind on a Mac: caches, update downloads, simulators and emulators, Codex chats and Claude Code sessions, worktrees, device backups, and the Trash. MacHelm's Storage page runs it ([ADR 0004](../docs/adr/0004-storage-runs-the-cleanup-script.md), [ADR 0008](../docs/adr/0008-storage-reclaims-app-data-and-ai-tool-history.md)), and it works by itself in a terminal, as described here.

The cleanup utility uses Python 3's standard library and requires the macOS tools `xcrun`,
`hdiutil`, and `du`. No dependency installation is needed.

Run the interactive cleanup tree from this repository, or from the installed app:

```sh
Storage/cleanup-macos-dev.py
/Applications/MacHelm.app/Contents/Resources/cleanup-macos-dev.py
```

The list has three levels: a group (how risky removal is), a kind inside it (App caches, Merged
worktrees, one AVD), and the rows. Space on a group or kind selects or clears every selectable row
below it; Space on a row toggles that row alone. Parents show `[ ]`, `[-]`, or `[x]` for none, some,
or all selected. Kinds start folded, with their totals. Use Up/Down to navigate and Left/Right to
collapse or expand; `a` selects all selectable targets across groups, `n` clears the selection, and
Enter applies it. The picker opens before Homebrew has finished estimating its cleanup; that row
reads `measuring…` until the number arrives.

The group **cannot be restored** holds what nothing downloads or rebuilds again: chats, sessions,
worktrees, device backups, the Trash, and data left by apps that are gone. Every row in it starts
unchecked.

### Simulators

Each shutdown simulator appears twice, as a choice:

- **Delete shutdown simulators** removes the device with `xcrun simctl delete <UDID>`. This is the
  option that makes a device go away; the reclaim is its measured size.
- **Erase shutdown simulators (keeps the device)** resets apps and settings with
  `xcrun simctl erase <UDID>` but keeps the device, so it is listed again on the next scan. This
  group starts folded.

Choosing one for a device clears the other, and `a` picks delete. Rows show the device name,
runtime, last-used date, and occupied size; the detail area includes the UDID. Last used is
CoreSimulator's `lastBootedAt`, shown as a local calendar date, with its UTC timestamp in JSON's
`last_used_at`. Missing or invalid boot metadata is unknown (`null` in JSON). A device that has
started running since discovery is refused.

A runtime with no devices left is removed with `xcrun simctl runtime delete`, which also removes its
MobileAsset under `/System/Library/AssetsV2`, together with its dyld shared cache. If the selected
Xcode's SDK still matches that runtime, the row starts unchecked, because Xcode would download it
again. Only runtimes missing from CoreSimulator's disk-image registry (`xcrun simctl runtime list`)
fall back to removing the asset by hand. On a SIP-enabled Mac that fails, so they are listed under
**cannot be removed from here**. Dyld caches built for an earlier macOS build or an uninstalled
runtime, SwiftUI Previews simulators, and parallel-testing clones are offered as well.

### Android emulators

Each AVD offers one of three treatments: **delete AVD**, **wipe data** (a factory reset matching
Device Manager's Wipe Data: the user-data image, `*.qcow2` overlays, and snapshots go; config, base
images, and `sdcard.img` stay), or **quick-boot snapshots** (next launch cold-boots; apps and data
are kept). An AVD that an emulator is running is blocked, and is checked again just before anything
is removed. System images that no AVD's `config.ini` names are offered individually, unchecked.
AVDs are found via `ANDROID_AVD_HOME`, `ANDROID_USER_HOME`, `ANDROID_EMULATOR_HOME`, or
`~/.android/avd`, in that order, and in `~/.config/.android/avd`, where tools that follow the XDG
layout leave them. An AVD whose system image is not installed cannot start; it is labelled so and
offers delete only.

### Idle

Codex chats, Claude Code sessions, and worktrees count as idle when nothing in them changed for
`--idle-days` days (1 to 90, 7 by default). A clean judges idleness at the instant its scan did
(`--as-of`), so something that went idle in between is not swept up with what was listed.

### Codex and Claude Code

- **Codex archived chats**, and **Codex chats idle** for the set days, grouped by the folder each
  chat ran in. Each chat is removed with `codex delete --force <id>`, which keeps Codex's index
  whole. Codex also removes the subagents a chat spawned, and keeps a chat while a chat forked
  from it remains, so a row's chats go newest first: every subagent and fork before the chat it
  came from. A chat whose files went with one deleted in another row counts as removed. When Codex
  keeps some, the row reports what the others freed and names each kept chat with the reason: a
  chat forked from it is still there, Codex did not finish, or Codex refused without one (all
  `codex delete` ever says is "failed to delete session"). Without a `codex` that has
  `delete --force` (Codex 0.140 or later), the rows are blocked. A chat archived after the scan
  began is not included.
- **Claude Code sessions idle** for the set days, grouped by the folder each session worked in: the
  transcript, its folder of subagent transcripts and tool results, and its file history. Memory
  folders are never touched. A session resumed after the scan is left alone. Claude Code itself
  still deletes sessions after its `cleanupPeriodDays`.

### Worktrees

Worktrees of Codex (in `$CODEX_HOME/worktrees`) and of Claude (in `.claude/worktrees` of every
folder in Claude Code's project list, `~/.claude.json`) are listed as two kinds, all unchecked:

- **Merged worktrees**: every commit's change is in the repository's main branch, by `git cherry`
  so rebased work counts, or the commit is on a remote. At any age, also with uncommitted files.
- **Idle worktrees**: not merged, and no file outside `.git` and `node_modules` changed for the set
  days. One that changed more recently is listed blocked, with the reason.

A worktree a running program works in, or one locked with `git worktree lock`, is blocked, and that
is checked again just before removal. Before removing a worktree that holds anything found nowhere
else (uncommitted or untracked files, or commits in neither the main branch nor a remote), the
script keeps a snapshot commit of it in the repository. Restore one with:

```sh
git worktree add ../restored refs/machelm/worktrees/<name>
```

and delete one with `git update-ref -d refs/machelm/worktrees/<name>`. Ignored files are not kept,
and more than 100 MB of untracked files is refused rather than copied into the repository. The
worktree goes with `git worktree remove`; its branch is deleted when its work is merged and kept
otherwise. Codex's empty `.codex-worktree-name` folders are left alone.

### Apps, backups, and the Trash

- **Update downloads**: copies of updates that apps downloaded with Sparkle or electron-updater,
  all but the newest for each app. Checked.
- **App caches**: one row per app with 100 MB or more in its `~/Library/Caches` folder and in the
  Chromium cache folders of its data folder (`Cache`, `Code Cache`, `GPUCache` and the like). Site
  data and Service Worker storage are kept, and a folder merely named `Cache` counts only beside
  Chromium's own files. A row is blocked while its app runs, and that is
  checked again before removal. Checked.
- **Temporary files**: pytest's kept runs (not while pytest runs) and the clang module cache are
  checked; the Instruments cache is offered unchecked. Shader caches are left alone, because games
  stutter while they rebuild them.
- **iPhone and iPad backups**, one unchecked row each, as Finder's Manage Backups lists them.
- **Empty the Trash**, unchecked. Finder empties it, on every disk, and macOS asks once whether
  MacHelm (or your terminal) may control Finder.
- **Left by apps no longer installed**: folders named after an app identifier that neither Spotlight
  nor a launchd job on this Mac accounts for, one unchecked row per app with 50 MB or more. An app on a disk Spotlight does not
  index looks uninstalled; when Spotlight cannot find Finder, that scan fails instead.

macOS keeps device backups, the Trash, and some app containers behind **Full Disk Access**. Without
it, those rows say "Needs Full Disk Access", and their sizes are unknown. The Trash can still be
chosen, because Finder empties it.

Folders of 1 GB or more that only their own app can clean are reported, never modified: Claude's
virtual machine, CrossOver bottles, Telegram media, Aerial wallpapers, Downloads, and large app data
folders. Each is measured net of the rows inside it.

### Other targets

Android Studio caches, logs, and settings for versions no longer installed (the newest settings
directory is kept until a newly installed version has imported it), Gradle daemon logs, the Go
build cache, the React Native, DotSlash, node-gyp, Electron, Bun, and Yarn download caches, and the
temporary git folders Codex leaves in its `.tmp` are selected by default. Optional
cleaners cover the separate [npm npx cache](https://docs.npmjs.com/cli/v11/commands/npm-cache)
(requires a working npm 11.2+ cache command) and [pip HTTP/wheel caches](https://pip.pypa.io/en/stable/topics/caching/).
Stop the corresponding tools/installations before choosing those cleaners. The report also measures
Playwright, Puppeteer, and Chrome for Testing browsers, the Hugging Face model cache, Android NDKs,
and Xcode archives for manual review through their owning tools. Docker's row shows allocated host
storage; its apparent maximum size is not a reclaim estimate, as explained in [Docker's storage guidance](https://docs.docker.com/desktop/troubleshoot-and-support/faqs/macfaqs/).
Unreadable sizes display as unknown (`null` in JSON), and cleanup targets whose measurement fails
are blocked for that scan.

### When a check fails

Each tool is scanned separately. When a scan cannot get a usable answer, for example
`xcrun simctl` replies without its runtimes list, that scan loses its rows, including any it had
already listed. Every other scan still lists its rows. In place of the missing rows, one blocked row
under **not scanned: its check failed**, first in the list, names the scan and the reason. Its size
is unknown (`null` in JSON), never 0. `--app` and `--json` report it like any other target, with the
key `scan-failed-<scan>`. `--select` with a key that the failed scan would have listed is refused,
and the refusal gives the reason.

### Non-interactive use

For a read-only inventory, run:

```sh
Storage/cleanup-macos-dev.py --json
```

Its target keys also work with `--select KEY,...`: `sim-delete-<UDID>` or `sim-erase-<UDID>` for a
simulator, and `avd-delete-<NAME>`, `avd-wipe-<NAME>`, or `avd-snapshots-<NAME>` for an AVD. Naming
two treatments of the same device is rejected. `--yes` uses the default selection, which leaves
every simulator, AVD, system image, and row of **cannot be restored** unchecked. JSON names each
row's `kind`, and `needs_full_disk_access` where macOS kept a folder from the script.

Scans run concurrently and measure each path once. Selected targets run in parallel lanes, one per
tool, with CoreSimulator and the emulator each kept to a single lane.

### Run by MacHelm

`--app` is for MacHelm. The script then prints one JSON object per line and nothing for a person:
alone it lists the targets and removes nothing, and with `--select` it removes those and reports each
result. A target in a folder only root can change is not removed with `sudo` then: the script names
the path and waits for the app's answer, and the app asks its toolkit helper. In a terminal it
calls `sudo` as before. The scan's `targets` event carries `as_of` and `idle_days`; the app passes
them back with `--select` as `--as-of` and `--idle-days`.

While it works, the script reports how far it has got, a few times a second: `progress` events
name the phase (`scanning` or `deleting`) with a count of what is done and the total, and a
`working` event names each target as a lane starts on it and then its latest step, such as
`deleting chat 12 of 190`. The app shows them on the Storage page; the terminal shows the same on
its progress bar.

A target that removes part of what it holds and then fails, such as a row of Codex chats of which
Codex kept some, reports `ok: false` with the `freed_kb` of the part that went, and the `done`
total counts it. A failure's `error` starts with a line that says what happened and may add a line
for each part that stayed. The app lists every target not removed, or removed only in part, with
its reason under **Last Clean**, because the scan that follows a Clean no longer lists a row whose
files all went.

## Safety checks

Keep `test_cleanup_macos_dev.py` beside `cleanup-macos-dev.py`. Run the fixture-backed safety tests
from any directory:

```sh
python3 -B -m unittest discover -s Storage -p 'test_cleanup_macos_dev.py'
```

The tests use temporary directories and mocked tool commands; the worktree tests create throwaway
git repositories there. They do not clean host caches, erase or delete simulators, touch AVDs, run
`codex delete`, or ask Finder for anything.
