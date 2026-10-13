# The cleanup script

`cleanup-macos-dev.py` reclaims the disk space developer tools leave behind on a Mac. MacHelm's Storage page runs it ([ADR 0004](../docs/adr/0004-storage-runs-the-cleanup-script.md)), and it works by itself in a terminal, as described here.

The cleanup utility uses Python 3's standard library and requires the macOS tools `xcrun`,
`hdiutil`, and `du`. No dependency installation is needed.

Run the interactive cleanup tree from this repository, or from the installed app:

```sh
Storage/cleanup-macos-dev.py
/Applications/MacHelm.app/Contents/Resources/cleanup-macos-dev.py
```

Space on a group header selects or clears every selectable row in that group; Space on a child
toggles that row alone. Parents show `[ ]`, `[-]`, or `[x]` for none, some, or all selected. Use
Up/Down to navigate and Left/Right to collapse or expand groups; `a` selects all selectable targets
across groups, `n` clears the selection, and Enter applies it. The picker opens before Homebrew has
finished estimating its cleanup; that row reads `measuring…` until the number arrives.

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
`~/.android/avd`, in that order.

### Other targets

Android Studio caches, logs, and settings for versions no longer installed (the newest settings
directory is kept until a newly installed version has imported it), Gradle daemon logs, the Go
build cache, and the React Native and DotSlash download caches are selected by default. Optional
cleaners cover the separate [npm npx cache](https://docs.npmjs.com/cli/v11/commands/npm-cache)
(requires a working npm 11.2+ cache command) and [pip HTTP/wheel caches](https://pip.pypa.io/en/stable/topics/caching/).
Stop the corresponding tools/installations before choosing those cleaners. The report also measures
Playwright browser binaries, the Hugging Face model cache, Android NDKs, Xcode archives, and
iPhone/iPad backups for manual review through their owning tools. Docker's row shows allocated host
storage; its apparent maximum size is not a reclaim estimate, as explained in [Docker's storage guidance](https://docs.docker.com/desktop/troubleshoot-and-support/faqs/macfaqs/).
Unreadable sizes display as unknown (`null` in JSON), and cleanup targets whose measurement fails
are blocked for that scan.

### Non-interactive use

For a read-only inventory, run:

```sh
Storage/cleanup-macos-dev.py --json
```

Its target keys also work with `--select KEY,...`: `sim-delete-<UDID>` or `sim-erase-<UDID>` for a
simulator, and `avd-delete-<NAME>`, `avd-wipe-<NAME>`, or `avd-snapshots-<NAME>` for an AVD. Naming
two treatments of the same device is rejected. `--yes` uses the default selection, which leaves
every simulator, AVD, and system image unchecked.

Scans run concurrently and measure each path once. Selected targets run in parallel lanes, one per
tool, with CoreSimulator and the emulator each kept to a single lane.

### Run by MacHelm

`--app` is for MacHelm. The script then prints one JSON object per line and nothing for a person:
alone it lists the targets and removes nothing, and with `--select` it removes those and reports each
result. A target in a folder only root can change is not removed with `sudo` then: the script names
the path and waits for the app's answer, and the app asks its toolkit helper. In a terminal it
calls `sudo` as before.

## Safety checks

Keep `test_cleanup_macos_dev.py` beside `cleanup-macos-dev.py`. Run the fixture-backed safety tests
from any directory:

```sh
python3 -B -m unittest discover -s Storage -p 'test_cleanup_macos_dev.py'
```

The tests use temporary directories and mocked tool commands. They do not clean host caches, erase
or delete simulators, or touch AVDs.
