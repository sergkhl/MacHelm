#!/usr/bin/env python3
"""Reclaim developer-toolchain disk space on a macOS host, interactively.

Every run is a negotiation — which of a dozen targets do I want *this* time — so the interface is a
checkbox tree rather than a flag per target. Parents select their children; nothing is removed
until you confirm.

The reason this exists rather than a documented `rm -rf` is the simulator half. Xcode leaves whole
runtimes behind long after their last device is gone, and their bytes sit where `rm` cannot reach:
the backing asset lives in /System/Library/AssetsV2, which SIP marks `restricted`. CoreSimulator can
remove it — `simctl runtime delete` goes through simdiskimaged, the entitled writer, and takes the
MobileAsset with it — but only for runtimes registered as disk images. So this tool DERIVES what is
dead instead of naming it, and asks CoreSimulator which of those it can delete itself:

    `simctl list runtimes -j` reports bundlePath + buildversion for every runtime, `simctl list
    devices -j` gives the device count per runtime, and `simctl runtime list -j` is the registry
    of disk images `simctl runtime delete` accepts. Zero devices means dead. A dead runtime the
    selected Xcode's SDK still matches is offered unchecked, because Xcode would download it again.

A runtime missing from that registry was installed under the older download scheme: its asset sits
in AssetsV2 marked `NeverCollected`, invisible to `simctl runtime` and to Storage Management alike.
The asset's MobileAssetProperties.Build joins it back to its runtime; the image chain over it is
detached depth-first and the asset removed. On a SIP-enabled machine that final removal fails, so
such targets are shown as blocked rather than sold as a reclaim they cannot deliver.

What is never measured is the tree under CoreSimulator/Volumes: those are sealed read-only APFS
volumes mounted from the asset's DMG, so measuring there counts decompressed contents that occupy no
bytes of their own.

Devices get a choice rather than a verdict. Each shutdown simulator can be deleted (gone, with its
apps and data) or erased (apps and settings reset, the device kept — so it appears again on the next
scan). Each Android AVD can lose its quick-boot snapshots, be wiped back to factory state, or be
deleted. Choosing one treatment for a device clears the others. Everything that costs real rebuild
time starts unchecked. SDKs, archives, backups, shared browser binaries, models, and Docker are
reported for manual review. A sparse Docker.raw file's apparent maximum is not its allocated disk
usage or a cleanup estimate.

Standard library only: no install step or third-party dependencies.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import textwrap
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Iterable, Sequence
from uuid import UUID

HOME = Path.home()
DATA_VOLUME = "/System/Volumes/Data"

SIM_VOLUMES_ROOT = Path("/Library/Developer/CoreSimulator/Volumes")
SIM_ASSETS_ROOT = Path("/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime")
SIM_DYLD_ROOT = Path("/Library/Developer/CoreSimulator/Caches/dyld")
SIM_DEVICES_ROOT = HOME / "Library/Developer/CoreSimulator/Devices"
DERIVED_DATA = HOME / "Library/Developer/Xcode/DerivedData"
DEVICE_SUPPORT = HOME / "Library/Developer/Xcode/iOS DeviceSupport"

SELECTABLE = "selectable"
BLOCKED = "blocked"
REPORT_ONLY = "report_only"

GROUP_SAFE = "restored by a lockfile or a re-download, or no longer used"
GROUP_COSTLY = "correct to remove, but real rebuild time"
GROUP_SIM_DELETE = "Delete shutdown simulators"
GROUP_SIM_ERASE = "Erase shutdown simulators (keeps the device)"
GROUP_AVD = "Android emulators"
GROUP_BLOCKED = "cannot be removed from here"
GROUP_REPORT = "reported, never modified"

GROUP_ORDER = [GROUP_SAFE, GROUP_COSTLY, GROUP_SIM_DELETE, GROUP_SIM_ERASE, GROUP_AVD,
               GROUP_BLOCKED, GROUP_REPORT]

#: Lanes run concurrently during execution; more than this mostly contends for the same SSD.
EXECUTE_WORKERS = 4
#: Discovery is dominated by waiting on subprocesses, not CPU.
DISCOVER_WORKERS = 12
#: Projections too slow to hold the picker for. `brew cleanup --dry-run` takes 2-4 s, longer than
#: every other scan combined, so its number arrives after the picker has opened.
SLOW_PROBES = concurrent.futures.ThreadPoolExecutor(max_workers=2)


class ProbeError(RuntimeError):
    """A required probe failed. Distinct from a probe that legitimately found nothing."""


# ---------------------------------------------------------------------------------------------
# Measurement
#
# Sizes are per-path, never per-filesystem. Sampling free space around an operation looks obvious
# and is wrong on a working machine: anything else writing or freeing moves it while the tool runs,
# in either direction and by GB. A run that deleted nothing has been observed losing 48 MiB to
# background writes and, on another occasion, gaining 16 GiB because an emulator wipe was running in
# a second terminal. Free space is therefore reported as a fact about the disk, with any movement
# named as drift rather than claimed as this run's result.
# ---------------------------------------------------------------------------------------------


def free_kb() -> int:
    return shutil.disk_usage(DATA_VOLUME).free // 1024


def human(kb: float) -> str:
    sign = "-" if kb < 0 else ""
    kb = abs(kb)
    for unit in ("KiB", "MiB", "GiB", "TiB"):
        if kb < 1024 or unit == "TiB":
            return f"{sign}{kb:.1f} {unit}"
        kb /= 1024
    return f"{sign}{kb:.1f} TiB"


def size_kb(path: Path | str) -> int:
    """Disk usage in KiB, 0 for an absent path, or ProbeError when measurement fails.

    `du` rather than an os.walk: it is C, and these trees run to tens of GB. A mountpoint returns 0
    deliberately — measuring through a mount counts the decompressed contents of a disk image, which
    is how a mounted 8 GiB DMG once got reported as a reclaimable 17 GiB of files.
    """
    path = Path(path)
    try:
        path.lstat()
        if os.path.ismount(path):
            return 0
    except FileNotFoundError:
        return 0
    except OSError as exc:
        raise ProbeError(f"cannot measure {path}: {exc.strerror}") from exc
    try:
        proc = subprocess.run(
            ["du", "-sk", str(path)], capture_output=True, text=True, timeout=900, stdin=TOOL_STDIN
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise ProbeError(f"cannot measure {path}: {exc}") from exc
    # du may print a partial total even when a protected subtree could not be read.
    # https://pubs.opengroup.org/onlinepubs/9699919799/utilities/du.html
    if proc.returncode != 0:
        raise ProbeError(proc.stderr.strip() or f"du failed for {path}")
    first = proc.stdout.split("\n", 1)[0].split("\t", 1)[0].strip()
    if not first.isdigit():
        raise ProbeError(f"du returned no size for {path}")
    return int(first)


def is_sip_restricted(path: Path) -> bool:
    try:
        return bool(os.stat(path).st_flags & stat.SF_RESTRICTED)
    except (OSError, AttributeError):
        return False


def run(*argv: str, check: bool = False, timeout: int = 900) -> subprocess.CompletedProcess:
    return subprocess.run(
        argv, capture_output=True, text=True, check=check, timeout=timeout, stdin=TOOL_STDIN
    )


def utc_stamp(value: object) -> str | None:
    """Normalize an ISO timestamp to UTC; absent or invalid metadata means unknown, not never."""
    if not isinstance(value, str):
        return None
    try:
        instant = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if instant.utcoffset() is None or instant.year < 2000:  # CoreSimulator writes 0001-01-01
            return None
        return instant.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    except (ValueError, OverflowError):
        return None


def file_stamp(path: Path) -> str | None:
    try:
        return utc_stamp(datetime.fromtimestamp(path.stat().st_mtime, timezone.utc).isoformat())
    except (OSError, OverflowError, ValueError):
        return None


# ---------------------------------------------------------------------------------------------
# Targets
# ---------------------------------------------------------------------------------------------


@dataclass
class Target:
    key: str
    group: str
    label: str
    state: str = SELECTABLE
    detail: str = ""
    #: None means a measurement failed, not that the directory is empty.
    size_kb: int | None = 0
    #: KiB this target frees if run. Equals size_kb for a plain delete; differs where an operation
    #: resets rather than removes (simulator erase), or where a tool reports its own estimate.
    projected_kb: int = 0
    #: None when the reclaim genuinely cannot be known in advance, which renders as "unknown"
    #: rather than a zero indistinguishable from "nothing to do".
    projectable: bool = True
    needs_sudo: bool = False
    selected: bool = False
    #: UTC timestamp from the owning tool's own record of use, not filesystem access time.
    last_used_at: str | None = None
    paths: list[Path] = field(default_factory=list)
    action: Callable[[bool], int] | None = None
    #: Targets sharing a tag are alternative treatments of one thing (delete or erase this
    #: simulator); selecting one clears the others.
    exclusive: str = ""
    #: Targets in one lane run one after another; lanes run concurrently. CoreSimulator and the
    #: emulator each get a single lane, so their own bookkeeping never sees two writers at once.
    lane: str = ""
    #: Sorts ahead of size inside a group, keeping one device's alternatives together.
    order: str = ""
    #: A projection still being computed in the background; the row reads "measuring" until
    #: settle() folds the result in.
    pending: concurrent.futures.Future | None = None

    def as_json(self) -> dict:
        return {
            "key": self.key,
            "group": self.group,
            "label": self.label,
            "state": self.state,
            "detail": self.detail,
            "size_kb": self.size_kb,
            "projected_kb": self.projected_kb if self.projectable else None,
            "needs_sudo": self.needs_sudo,
            "default_selected": self.selected,
            "last_used_at": self.last_used_at,
            "paths": [str(p) for p in self.paths],
            # Targets sharing this tag are treatments of one thing; choosing one excludes the others.
            "exclusive": self.exclusive,
        }


#: What a tool the script starts gets as its input. None leaves it the terminal's, as it always was.
#: Under MacHelm the script's own input carries the app's answers to root removals, and a tool
#: that read its input would take one, so there the tools get none.
TOOL_STDIN: int | None = None

#: Set when MacHelm runs the script (--app): a root target's removal is handed to the app, which
#: asks its root helper, instead of calling sudo. A terminal run leaves it None and uses sudo.
ROOT_REMOVER: Callable[[Path], None] | None = None


class AppChannel:
    """The script's side of being run by MacHelm: one JSON object per line on stdout.

    A root removal is a question: the script names the path and reads one line back on stdin,
    `{"ok": true}` or `{"ok": false, "error": "..."}`. Lanes run concurrently, so one lock keeps
    lines whole and keeps each answer with its question.
    """

    def __init__(self) -> None:
        self._lock = threading.Lock()

    def send(self, **event: object) -> None:
        with self._lock:
            sys.stdout.write(json.dumps(event) + "\n")
            sys.stdout.flush()

    def remove_root(self, path: Path) -> None:
        with self._lock:
            sys.stdout.write(json.dumps({"event": "remove-root", "path": str(path)}) + "\n")
            sys.stdout.flush()
            line = sys.stdin.readline()
        if not line:
            raise RuntimeError(f"MacHelm did not answer the removal of {path}")
        try:
            answer = json.loads(line)
        except ValueError as exc:
            raise RuntimeError(f"MacHelm's answer about {path} could not be read") from exc
        if not isinstance(answer, dict) or answer.get("ok") is not True:
            reason = answer.get("error") if isinstance(answer, dict) else None
            raise RuntimeError(reason or f"MacHelm refused the removal of {path}")


def remove_tree(target: Path, expected_root: Path, sudo: bool) -> None:
    """Delete `target`, refusing anything that is not genuinely inside `expected_root`.

    The single choke point for destruction. A derivation bug aborts the run here rather than
    widening an `rm -rf` into whatever a short or empty string resolved to.
    """
    target = Path(target)
    root = Path(expected_root)
    if not target.is_absolute() or root not in target.parents:
        raise RuntimeError(f"refusing to remove {target!s}: not under {root!s}")
    if os.path.ismount(target):
        raise RuntimeError(f"refusing to remove {target!s}: it is a mountpoint")
    if not (target.exists() or target.is_symlink()):
        return
    if sudo:
        if ROOT_REMOVER is not None:
            ROOT_REMOVER(target)
            return
        proc = run("sudo", "rm", "-rf", str(target))
        if proc.returncode != 0:
            raise RuntimeError((proc.stderr or "permission denied").strip())
    elif target.is_dir() and not target.is_symlink():
        try:
            shutil.rmtree(target, ignore_errors=False)
        except PermissionError:
            # Some tools write-protect what they unpack: DotSlash leaves every directory of an
            # extracted artifact r-x so nothing edits it in place. Unlinking an entry needs write
            # permission on its directory, so the first attempt dies inside the first such
            # directory. The tree is the user's own and is going anyway, so restore owner access
            # throughout it and try once more.
            grant_owner_access(target)
            shutil.rmtree(target, ignore_errors=False)
    else:
        # Not every entry in a cache directory is a directory. shutil.rmtree raises ENOTDIR on a
        # plain file, and a lone .DS_Store — which sorts ahead of every letter — was enough to
        # abort the whole DerivedData target before it removed anything.
        target.unlink()


def grant_owner_access(directory: Path) -> None:
    """Give the owner rwx on `directory` and every directory beneath it, never following links.

    Parent before children: a directory has to be readable before its entries can be listed.
    """
    os.chmod(directory, stat.S_IMODE(os.lstat(directory).st_mode) | stat.S_IRWXU)
    with os.scandir(directory) as entries:
        for entry in entries:
            if entry.is_dir(follow_symlinks=False):
                grant_owner_access(Path(entry.path))


def checked(*argv: str) -> subprocess.CompletedProcess:
    """Run a cleaner whose failure must surface as a failed row, never as a ✓ that freed 0."""
    proc = run(*argv)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or f"{' '.join(argv)} failed")
    return proc


def delete_under(removals: Sequence[tuple[Path, Path]], sudo: bool = False) -> Callable[[bool], int]:
    """Remove each (path, root) pair, where root is the directory the path must stay inside."""
    def action(dry_run: bool) -> int:
        freed = 0
        for path, root in removals:
            before = size_kb(path)
            if not dry_run:
                PROGRESS.note(f"removing {path.name}")
                remove_tree(path, root, sudo)
            freed += before
        return freed

    return action


def delete_paths(paths: Sequence[Path], root: Path, sudo: bool = False) -> Callable[[bool], int]:
    return delete_under([(path, root) for path in paths], sudo)


def clean_with_tool(paths: Sequence[Path], argv: Sequence[str]) -> Callable[[bool], int]:
    """Measure only the command's cache scope, and surface tool failures to the caller."""
    def action(dry_run: bool) -> int:
        before = sum(size_kb(path) for path in paths)
        if dry_run:
            return before
        checked(*argv)
        return before - sum(size_kb(path) for path in paths)

    return action


# ---------------------------------------------------------------------------------------------
# Discovery — simulators
# ---------------------------------------------------------------------------------------------


def simctl_json(*args: str) -> dict:
    proc = run("xcrun", "simctl", *args, "-j")
    if proc.returncode != 0:
        raise ProbeError(f"`xcrun simctl {' '.join(args)}` failed: {proc.stderr.strip()}")
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise ProbeError(f"`xcrun simctl {' '.join(args)}` returned no JSON: {exc}") from exc


def optional_json(*argv: str) -> object | None:
    """A probe whose failure only withholds an optimisation or a protection, never a verdict."""
    proc = run(*argv, timeout=120)
    if proc.returncode != 0:
        return None
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None


def probe_simulators() -> tuple[dict, dict]:
    """Probe once, validate once.

    "No orphans found" and "the probe returned nothing" are indistinguishable downstream, and the
    second silently converts a broken query into a clean bill of health. Validating inside the first
    consumer is too late: an earlier consumer of the same broken response dies on a type error and
    the caller sees that instead of the real diagnosis.
    """
    runtimes = simctl_json("list", "runtimes")
    devices = simctl_json("list", "devices")
    n_runtimes = len(runtimes.get("runtimes") or [])
    n_groups = len(devices.get("devices") or {})
    if n_runtimes < 1 or n_groups < 1:
        raise ProbeError(
            f"simctl reported {n_runtimes} runtimes and {n_groups} device groups. That is a failed "
            "probe, not an empty result — check `xcode-select -p` and that "
            "`xcrun simctl list runtimes -j` returns JSON."
        )
    return runtimes, devices


def unavailable_devices(devices: dict) -> list[dict]:
    """Devices stranded on a runtime that is no longer installed.

    Availability is read off the device, never off the group key. `simctl list devices` prints a
    header reading "-- Unavailable: com.apple…iOS-26-4 --", but that word exists only in the human
    output: the JSON key is the bare runtime identifier, so matching /unavailable/ on it returns
    zero on every machine and the row reads "none" while GBs of stranded devices sit there.
    """
    return [
        device
        for group in (devices.get("devices") or {}).values()
        for device in group
        if device.get("isAvailable") is False
    ]


def runtime_images() -> dict[tuple[str, str], dict]:
    """CoreSimulator's disk-image registry, keyed by (runtime identifier, build).

    These are exactly the runtimes `simctl runtime delete` accepts. Treating an unregistered runtime
    as the only kind there is — and reaching for `rm` — is what once filed a registered, deletable
    8 GiB runtime under "cannot be removed": its asset is SIP-restricted to `rm`, not to simctl.
    """
    listing = optional_json("xcrun", "simctl", "runtime", "list", "-j")
    images = {}
    for image in listing.values() if isinstance(listing, dict) else []:
        if isinstance(image, dict) and image.get("runtimeIdentifier") and image.get("build"):
            images[(image["runtimeIdentifier"], image["build"])] = image
    return images


#: `simctl runtime match list` names SDKs by canonical name; runtimes name their platform.
SDK_PLATFORMS = {"iphoneos": "iOS", "appletvos": "tvOS", "watchos": "watchOS", "xros": "visionOS"}


def sdk_runtime_versions() -> set[tuple[str, str]] | None:
    """(platform, major.minor) of every SDK in the selected Xcode, or None when Xcode won't say.

    A runtime with no devices left can still be the one Xcode runs that SDK's builds and previews
    against; deleting it buys a multi-GB download on the next run.
    """
    matches = optional_json("xcrun", "simctl", "runtime", "match", "list", "-j")
    if not isinstance(matches, dict):
        return None
    versions = set()
    for name, info in matches.items():
        platform = SDK_PLATFORMS.get(name.rstrip("0123456789."))
        version = info.get("sdkVersion") if isinstance(info, dict) else None
        if platform and version:
            versions.add((platform, ".".join(str(version).split(".")[:2])))
    return versions or None


def host_build() -> str | None:
    proc = run("sw_vers", "-buildVersion", timeout=30)
    return (proc.stdout.strip() or None) if proc.returncode == 0 else None


def dyld_cache_for(identifier: str, build: str | None, host: str | None) -> Path | None:
    """The shared cache dyld built for one runtime on this macOS build, if there is one."""
    if not (host and build):
        return None
    path = SIM_DYLD_ROOT / host / f"{identifier}.{build}"
    return path if path.is_dir() else None


def stale_dyld_caches(runtimes: dict, host: str | None) -> list[Path]:
    """Shared caches nothing reads again.

    The cache is keyed by host build, then runtime: a macOS update orphans every cache built for the
    previous build, and an uninstalled runtime orphans its own. dyld rebuilds a missing cache on
    demand, so the worst case of a wrong call here is a slower first boot.
    """
    if not host or not SIM_DYLD_ROOT.is_dir():
        return []
    installed = {f"{r.get('identifier')}.{r.get('buildversion')}" for r in runtimes["runtimes"]}
    stale = []
    for build_dir in sorted(SIM_DYLD_ROOT.iterdir()):
        if not build_dir.is_dir():
            continue
        if build_dir.name != host:
            stale.append(build_dir)
            continue
        stale.extend(cache for cache in sorted(build_dir.iterdir())
                     if cache.is_dir() and cache.name.startswith("com.apple.CoreSimulator.")
                     and cache.name not in installed)
    return stale


def volume_root_of(bundle_path: str) -> Path | None:
    """The `/Library/Developer/CoreSimulator/Volumes/<name>` prefix a runtime bundle hangs off."""
    parts = Path(bundle_path).parts
    if len(parts) < 6:
        return None
    root = Path(*parts[:6])
    return root if SIM_VOLUMES_ROOT in root.parents or root.parent == SIM_VOLUMES_ROOT else None


def asset_dir_of(image_path: str | None) -> Path | None:
    """The `<hash>.asset` directory a disk image lives in, when MobileAsset owns it."""
    if not image_path:
        return None
    return next((parent for parent in Path(image_path).parents if parent.suffix == ".asset"), None)


def asset_build(asset: Path) -> str | None:
    try:
        with (asset / "Info.plist").open("rb") as handle:
            plist = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException):
        return None
    return (plist.get("MobileAssetProperties") or {}).get("Build")


def attached_images() -> list[tuple[str, str]]:
    """(mount-point, backing image path) for every attached disk image."""
    proc = run("hdiutil", "info", "-plist")
    if proc.returncode != 0:
        return []
    try:
        info = plistlib.loads(proc.stdout.encode())
    except plistlib.InvalidFileException:
        return []
    pairs = []
    for image in info.get("images") or []:
        path = image.get("image-path")
        for entity in image.get("system-entities") or []:
            mount = entity.get("mount-point")
            if mount and path:
                pairs.append((mount, path))
    return pairs


def detach_chain_for(asset: Path) -> list[str]:
    """Mountpoints backed by `asset`, transitively, in the order they must be detached.

    The asset's DMG mounts somewhere, and that mount contains a further DMG that mounts again. The
    fixpoint below discovers an outer mount before the inner one whose image lives inside it, so the
    list is reversed: detaching the outer first fails while the inner still holds it open. Path
    depth is NOT the ordering — here the inner mount has the shorter path of the two.
    """
    images = attached_images()
    roots = [str(asset)]
    for _ in range(4):
        grew = False
        for mount, image in images:
            if mount in roots:
                continue
            if any(image.startswith(root.rstrip("/") + "/") for root in roots):
                roots.append(mount)
                grew = True
        if not grew:
            break
    return list(reversed(roots[1:]))


def wait_until_gone(paths: Sequence[Path], timeout: float = 30) -> None:
    """simdiskimaged can finish removing an asset after `simctl runtime delete` has returned."""
    deadline = time.monotonic() + timeout
    while any(p.exists() for p in paths) and time.monotonic() < deadline:
        time.sleep(0.5)


def registered_runtime_target(runtime: dict, image: dict, dyld: Path | None,
                              sdk_versions: set[tuple[str, str]] | None) -> Target:
    identifier = runtime.get("identifier", "")
    build = runtime.get("buildversion") or ""
    name = runtime.get("name", identifier)
    image_id = image.get("identifier", "")
    # A cryptex runtime's own image can sit inside its mounted parent bundle, where a measurement
    # counts decompressed contents. The bytes are in the parent image, usually a MobileAsset.
    source = image.get("parentImagePath") or image.get("path")
    storage = (asset_dir_of(source) or Path(source)) if source else None
    paths = [p for p in (storage, dyld) if p]
    version = (runtime.get("platform"), ".".join(str(runtime.get("version", "")).split(".")[:2]))
    needed = sdk_versions is None or version in sdk_versions

    def collect(dry_run: bool) -> int:
        before = sum(size_kb(p) for p in paths)
        if dry_run:
            return before
        if dyld:
            # Ask simctl first; the directory is only removed by hand when simctl leaves it.
            PROGRESS.note(f"removing the dyld cache of {name}")
            run("xcrun", "simctl", "runtime", "dyld_shared_cache", "remove", identifier)
            remove_tree(dyld, SIM_DYLD_ROOT, sudo=True)
        PROGRESS.note(f"deleting {name}")
        proc = run("xcrun", "simctl", "runtime", "delete", image_id)
        if proc.returncode != 0:
            raise RuntimeError(proc.stderr.strip() or f"simctl runtime delete {image_id} failed")
        wait_until_gone(paths)
        return before - sum(size_kb(p) for p in paths)

    detail = "0 devices; `xcrun simctl runtime delete`, which also removes its MobileAsset"
    if dyld:
        detail += ", plus its dyld shared cache"
    if needed:
        detail += ("; Xcode's SDK matches this runtime and would download it again"
                   if sdk_versions is not None
                   else "; Xcode did not say which runtimes its SDKs need")
    return Target(
        key=f"sim-runtime-{build}",
        group=GROUP_COSTLY if needed else GROUP_SAFE,
        label=f"Orphaned simulator runtime {name}",
        detail=detail,
        needs_sudo=dyld is not None,
        selected=not needed,
        last_used_at=runtime_last_used(runtime),
        paths=paths,
        action=collect,
        lane="coresimulator",
    )


def legacy_runtime_targets(runtime: dict, registered_assets: set[Path]) -> list[Target]:
    """A runtime outside the disk-image registry, collected by hand from AssetsV2."""
    identifier = runtime.get("identifier", "")
    build = runtime.get("buildversion")
    found = []
    for asset in sorted(SIM_ASSETS_ROOT.glob("*.asset")):
        if asset_build(asset) != build or asset in registered_assets:
            continue
        chain = detach_chain_for(asset)
        restricted = is_sip_restricted(asset)
        volume_root = volume_root_of(runtime.get("bundlePath", "") or "")

        def collect(dry_run: bool, _asset=asset, _chain=chain, _root=volume_root) -> int:
            freed = size_kb(_asset)
            if dry_run:
                return freed
            for mount in _chain:
                # No -force: a clean detach failing means something still holds the volume open,
                # and forcing it there risks the process, not just the mount.
                proc = run("hdiutil", "detach", mount, "-quiet")
                if proc.returncode != 0:
                    raise RuntimeError(f"detach failed (still in use): {mount}")
            remove_tree(_asset, SIM_ASSETS_ROOT, sudo=True)
            if _root and not os.path.ismount(_root):
                remove_tree(_root, SIM_VOLUMES_ROOT, sudo=True)
            return freed

        found.append(
            Target(
                key=f"sim-runtime-{build}",
                group=GROUP_BLOCKED if restricted else GROUP_SAFE,
                label=f"Orphaned simulator runtime {runtime.get('name', identifier)}",
                state=BLOCKED if restricted else SELECTABLE,
                detail=(
                    "0 devices; not in CoreSimulator's disk-image registry, so `simctl runtime "
                    "delete` refuses it, and its asset is SIP-restricted to everything but "
                    "simdiskimaged"
                    if restricted
                    else f"0 devices; detaches {len(chain)} image(s), then removes the asset"
                ),
                needs_sudo=True,
                selected=not restricted,
                last_used_at=runtime_last_used(runtime),
                paths=[asset],
                action=collect,
                lane="coresimulator",
            )
        )
    return found


def runtime_last_used(runtime: dict) -> str | None:
    usage = runtime.get("lastUsage")
    stamps = [utc_stamp(v) for v in usage.values()] if isinstance(usage, dict) else []
    return max((s for s in stamps if s), default=None)


def discover_simulators(targets: list[Target]) -> None:
    runtimes, devices = probe_simulators()

    stranded = unavailable_devices(devices)
    if stranded:
        udids = [d["udid"] for d in stranded if d.get("udid")]
        paths = [SIM_DEVICES_ROOT / udid for udid in udids]

        def delete_unavailable(dry_run: bool, _paths=paths) -> int:
            # simctl reports nothing about what it freed, so size the directories while they exist.
            freed = sum(size_kb(p) for p in _paths)
            if not dry_run:
                proc = run("xcrun", "simctl", "delete", "unavailable")
                if proc.returncode != 0:
                    raise RuntimeError(proc.stderr.strip() or "simctl delete unavailable failed")
            return freed

        targets.append(
            Target(
                key="sim-unavailable-devices",
                group=GROUP_SAFE,
                label="Simulator devices on uninstalled runtimes",
                detail=f"{plural(len(stranded), 'device')}; `xcrun simctl delete unavailable`",
                selected=True,
                paths=paths,
                action=delete_unavailable,
                lane="coresimulator",
            )
        )

    counts: dict[str, int] = {
        identifier: len(group) for identifier, group in (devices.get("devices") or {}).items()
    }
    # The keep-set is built before anything is removed: builds still backing a runtime with
    # devices, and every asset the disk-image registry owns.
    keep_builds = {
        r.get("buildversion")
        for r in runtimes["runtimes"]
        if counts.get(r.get("identifier", ""), 0) > 0
    }
    images = runtime_images()
    registered_assets = {
        asset
        for image in images.values()
        for asset in (asset_dir_of(image.get("path")), asset_dir_of(image.get("parentImagePath")))
        if asset
    }
    sdk_versions = sdk_runtime_versions()
    host = host_build()

    for runtime in runtimes["runtimes"]:
        identifier = runtime.get("identifier", "")
        build = runtime.get("buildversion")
        if counts.get(identifier, 0) > 0 or build in keep_builds:
            continue
        image = images.get((identifier, build))
        if image is None:
            targets.extend(legacy_runtime_targets(runtime, registered_assets))
        elif image.get("deletable") and is_uuid(image.get("identifier")):
            # The UUID check keeps a malformed identity from becoming simctl's `all` alias.
            dyld = dyld_cache_for(identifier, build, host)
            targets.append(registered_runtime_target(runtime, image, dyld, sdk_versions))
        # A registered runtime that is not deletable ships inside Xcode and leaves with it.

    stale = stale_dyld_caches(runtimes, host)
    if stale:
        targets.append(
            Target(
                key="sim-dyld-stale",
                group=GROUP_SAFE,
                label="Simulator dyld caches nothing reads",
                detail=f"{plural(len(stale), 'cache')} for an earlier macOS build or an "
                "uninstalled runtime; dyld rebuilds them on demand",
                needs_sudo=True,
                selected=True,
                paths=stale,
                action=delete_paths(stale, SIM_DYLD_ROOT, sudo=True),
                lane="coresimulator",
            )
        )

    stubs = (
        [
            d
            for d in sorted(SIM_DEVICES_ROOT.iterdir())
            if d.is_dir() and not (d / "device.plist").exists()
        ]
        if SIM_DEVICES_ROOT.is_dir()
        else []
    )
    if stubs:
        targets.append(
            Target(
                key="sim-device-stubs",
                group=GROUP_SAFE,
                label="Simulator device stubs",
                detail=f"{plural(len(stubs), 'directory', 'directories')} with no device.plist",
                selected=True,
                paths=stubs,
                action=delete_paths(stubs, SIM_DEVICES_ROOT),
                lane="coresimulator",
            )
        )

    discover_shutdown_simulators(targets, runtimes, devices)


def is_uuid(value: object) -> bool:
    try:
        UUID(str(value))
    except ValueError:
        return False
    return True


def simulator_last_used(value: object) -> str | None:
    """Normalize simctl's lastBootedAt; absent/invalid metadata does not mean never used."""
    return utc_stamp(value)


def require_shutdown(udid: str) -> None:
    """The picker may have stayed open while another task booted or removed this device."""
    current = [d for group in simctl_json("list", "devices").get("devices", {}).values()
               for d in group if d.get("udid") == udid]
    if (len(current) != 1 or current[0].get("isAvailable") is not True
            or current[0].get("state") != "Shutdown"):
        raise RuntimeError(f"{udid} is no longer an available shutdown simulator; "
                           "scan again before changing it")


def simulator_action(verb: str, udid: str, path: Path, label: str) -> Callable[[bool], int]:
    """`simctl delete` or `simctl erase` one device, measuring what actually left the disk."""
    def action(dry_run: bool) -> int:
        if dry_run:
            # A delete frees the device; the size of a newly erased device is not known in advance.
            return size_kb(path) if verb == "delete" else 0
        before = size_kb(path)
        require_shutdown(udid)
        PROGRESS.note(f"{'deleting' if verb == 'delete' else 'erasing'} {label}")
        proc = run("xcrun", "simctl", verb, udid)
        if proc.returncode != 0:
            raise RuntimeError(proc.stderr.strip() or f"simctl {verb} {udid} failed")
        return before - size_kb(path)

    return action


def discover_shutdown_simulators(targets: list[Target], runtimes: dict, devices: dict) -> None:
    runtime_names = {r["identifier"]: r.get("name", r["identifier"])
                     for r in runtimes["runtimes"]}
    for identifier, group in devices["devices"].items():
        for device in group:
            if device.get("isAvailable") is not True or device.get("state") != "Shutdown":
                continue
            udid = device.get("udid", "")
            try:
                UUID(udid)
            except (ValueError, AttributeError, TypeError) as exc:
                # Never let a malformed identity become simctl's broad `all` selector.
                raise ProbeError(f"Invalid simulator UDID: {udid!r}") from exc
            path = SIM_DEVICES_ROOT / udid
            label = f"{device.get('name', udid)} ({runtime_names.get(identifier, identifier)})"
            common = dict(
                label=label,
                last_used_at=simulator_last_used(device.get("lastBootedAt")),
                paths=[path],
                exclusive=f"sim:{udid}",
                lane="coresimulator",
            )
            # Not simctl's dataPathSize: that counts logical bytes, and on a device holding many
            # small files it reads 12% under the blocks a delete actually returns.

            targets.append(
                Target(
                    key=f"sim-delete-{udid}",
                    group=GROUP_SIM_DELETE,
                    detail=f"{udid}; `xcrun simctl delete`; removes the device with its apps "
                    "and data",
                    action=simulator_action("delete", udid, path, label),
                    **common,
                )
            )
            targets.append(
                Target(
                    key=f"sim-erase-{udid}",
                    group=GROUP_SIM_ERASE,
                    detail=f"{udid}; wipes apps and settings; retains device and runtime; "
                    "reclaim is unknown until erasure",
                    projectable=False,
                    action=simulator_action("erase", udid, path, label),
                    **common,
                )
            )


def discover_simulator_sets(targets: list[Target]) -> None:
    """Device sets Xcode keeps outside the main one, and recreates whenever it needs them."""
    sets = [
        ("sim-set-previews", "SwiftUI Previews simulators",
         HOME / "Library/Developer/Xcode/UserData/Previews/Simulator Devices",
         GROUP_COSTLY, "Xcode recreates them on the next preview; close Xcode first"),
        ("sim-set-testing", "Parallel-testing simulator clones",
         HOME / "Library/Developer/XCTestDevices",
         GROUP_SAFE, "cloned per test run"),
    ]
    for key, label, root, group, note in sets:
        devices = [d for d in sorted(root.iterdir()) if d.is_dir()] if root.is_dir() else []
        if not devices:
            continue
        targets.append(
            Target(
                key=key,
                group=group,
                label=label,
                detail=f"{plural(len(devices), 'device')}; `xcrun simctl --set <set> delete all`; "
                f"{note}",
                selected=group == GROUP_SAFE,
                paths=devices,
                action=clean_with_tool(devices, ["xcrun", "simctl", "--set", str(root),
                                                 "delete", "all"]),
                lane="coresimulator",
            )
        )


# ---------------------------------------------------------------------------------------------
# Discovery — Android emulators and SDK
# ---------------------------------------------------------------------------------------------


def android_sdk() -> Path:
    for env in ("ANDROID_HOME", "ANDROID_SDK_ROOT"):
        value = os.environ.get(env)
        if value:
            return Path(value)
    return HOME / "Library/Android/sdk"


def avd_home() -> Path:
    """Where the emulator looks for AVDs, in the emulator's own order of precedence.

    Getting this wrong is not just a missed row: every system image would then look unused.
    """
    if os.environ.get("ANDROID_AVD_HOME"):
        return Path(os.environ["ANDROID_AVD_HOME"])
    for env in ("ANDROID_USER_HOME", "ANDROID_EMULATOR_HOME"):
        if os.environ.get(env):
            return Path(os.environ[env]) / "avd"
    return HOME / ".android/avd"


def has_entries(path: Path) -> bool:
    try:
        return path.is_dir() and any(path.iterdir())
    except OSError:
        return False


def read_ini(path: Path) -> dict[str, str]:
    try:
        text = path.read_text(errors="replace")
    except OSError:
        return {}
    values = {}
    for line in text.splitlines():
        key, sep, value = line.partition("=")
        if sep:
            values[key.strip()] = value.strip()
    return values


@dataclass
class Avd:
    name: str
    ini: Path
    data_dir: Path
    config: dict[str, str]


def list_avds(root: Path) -> list[Avd]:
    """AVDs as the emulator enumerates them.

    An AVD is named by its .ini file, and that .ini's `path=` points wherever the data actually
    lives — the two need not agree. Reading the name off the directory produces an AVD name the
    emulator rejects with "Unknown AVD name".
    """
    avds = []
    for ini in sorted(root.glob("*.ini")) if root.is_dir() else []:
        meta = read_ini(ini)
        data_dir = Path(meta["path"]) if meta.get("path") else root / f"{ini.stem}.avd"
        avds.append(Avd(ini.stem, ini, data_dir, read_ini(data_dir / "config.ini")))
    return avds


#: The emulator's qemu child carries `-avd <name>`; a launcher invocation may carry `@<name>`.
#: The executable is matched as a path component, because other apps mention "emulator" in their
#: arguments — one desktop app passes a JSON blob containing "androidEmulator".
EMULATOR_PROCESS = re.compile(r"(?:^|/)(?:qemu-system-\S+|emulator)(?:\s|$)")
EMULATOR_AVD = re.compile(r"(?:\s-avd\s+|\s@)(\S+)")


def running_avds() -> set[str] | None:
    """Names of AVDs an emulator has open, or None when the process table cannot be read."""
    proc = run("ps", "-axww", "-o", "command=", timeout=30)
    if proc.returncode != 0:
        return None
    return {
        name
        for line in proc.stdout.splitlines()
        if EMULATOR_PROCESS.search(line)
        for name in EMULATOR_AVD.findall(" " + line)
    }


def avd_busy(avd: Avd, running: set[str] | None) -> str:
    """Why this AVD must not be touched right now, or "" when it is safe to."""
    if running is None:
        return "the process list could not be read"
    if avd.name in running:
        return "an emulator is running it"
    # The emulator locks hardware-qemu.ini for the lifetime of the instance. multiinstance.lock is
    # deliberately not consulted: it is flock()ed, so the file itself outlives every run.
    if os.path.lexists(avd.data_dir / "hardware-qemu.ini.lock"):
        return "an emulator lock is present (hardware-qemu.ini.lock)"
    return ""


def avd_wipe_paths(data_dir: Path) -> list[Path]:
    """What a factory reset discards, as Device Manager's Wipe Data does.

    userdata-qemu.img is the user-data partition, every *.qcow2 is a copy-on-write overlay holding
    one partition's changes over its base image, and snapshots capture that state. The emulator
    recreates all of them from the system image on the next boot. config.ini, the base images it
    created at first boot, and sdcard.img are left alone.
    """
    candidates = [data_dir / "userdata-qemu.img", *sorted(data_dir.glob("*.qcow2")),
                  data_dir / "snapshots"]
    return [p for p in candidates if p.exists()]


def avd_action(avd: Avd, removals: Sequence[tuple[Path, Path]]) -> Callable[[bool], int]:
    remove = delete_under(removals)

    def action(dry_run: bool) -> int:
        if not dry_run:
            # The picker may have stayed open while the emulator was launched.
            reason = avd_busy(avd, running_avds())
            if reason:
                raise RuntimeError(f"{avd.name}: {reason}; close the emulator and scan again")
        return remove(dry_run)

    return action


def avd_targets(avd: Avd, root: Path, running: set[str] | None) -> list[Target]:
    data = avd.data_dir
    if not data.is_dir():
        return []
    busy = avd_busy(avd, running)
    common = dict(
        group=GROUP_AVD,
        state=BLOCKED if busy else SELECTABLE,
        last_used_at=file_stamp(data / "hardware-qemu.ini"),  # rewritten on every launch
        exclusive=f"avd:{avd.name}",
        lane="android",
    )
    rows = []
    if root in data.parents:
        rows.append(Target(
            key=f"avd-delete-{avd.name}",
            label=f"{avd.name}: delete AVD",
            detail="removes the AVD and all of its data; recreate it in Device Manager; costs "
            "any provisioning done on it",
            paths=[data, avd.ini],
            action=avd_action(avd, [(data, root), (avd.ini, root)]),
            order=f"{avd.name}/0",
            **common,
        ))
    wipe = avd_wipe_paths(data)
    if wipe:
        rows.append(Target(
            key=f"avd-wipe-{avd.name}",
            label=f"{avd.name}: wipe data",
            detail="factory reset, as Device Manager's Wipe Data: drops user data, overlays and "
            "snapshots; keeps the AVD; costs any provisioning done on it",
            paths=wipe,
            action=avd_action(avd, [(p, data) for p in wipe]),
            order=f"{avd.name}/1",
            **common,
        ))
    snapshots = data / "snapshots"
    if has_entries(snapshots):
        rows.append(Target(
            key=f"avd-snapshots-{avd.name}",
            label=f"{avd.name}: quick-boot snapshots",
            detail="next launch cold-boots; apps and data are kept",
            paths=[snapshots],
            action=avd_action(avd, [(snapshots, data)]),
            order=f"{avd.name}/2",
            **common,
        ))
    for row in rows:
        if busy:
            row.detail = f"{busy}; close the emulator and scan again. {row.detail}"
        if root not in data.parents:
            row.detail += f"; data lives outside {root}, so delete the AVD in Device Manager"
    return rows


def delete_system_image(image: Path, root: Path) -> Callable[[bool], int]:
    def action(dry_run: bool) -> int:
        freed = size_kb(image)
        if dry_run:
            return freed
        remove_tree(image, root, sudo=False)
        # <api>/<tag>/<abi>: leave no empty <api>/<tag> shells behind for SDK Manager to list.
        for parent in (image.parent, image.parent.parent):
            try:
                parent.rmdir()
            except OSError:
                break
        return freed

    return action


def discover_android(targets: list[Target]) -> None:
    sdk = android_sdk()
    root = avd_home()
    avds = list_avds(root)
    running = running_avds() if avds else set()
    for avd in avds:
        targets.extend(avd_targets(avd, root, running))

    # A system image no AVD names in image.sysdir.1 is derivably unused. One AVD without that key
    # makes every image's status unknowable, so then nothing is offered.
    images_root = sdk / "system-images"
    images = ([p for p in sorted(images_root.glob("*/*/*")) if p.is_dir()]
              if images_root.is_dir() else [])
    if not images:
        return
    sysdirs = [avd.config.get("image.sysdir.1") for avd in avds]
    if all(sysdirs):
        wanted = {(sdk / d).resolve() for d in sysdirs if d}
        used = [p for p in images if p.resolve() in wanted]
        unused = [p for p in images if p.resolve() not in wanted]
    else:
        used, unused = images, []
    for image in unused:
        api, tag, abi = image.relative_to(images_root).parts
        targets.append(
            Target(
                key=f"android-image-{api}-{tag}-{abi}",
                group=GROUP_COSTLY,
                label=f"Android system image {api} {tag} {abi}",
                detail="no AVD uses it; reinstall from SDK Manager when an AVD needs it",
                paths=[image],
                action=delete_system_image(image, images_root),
            )
        )
    if used:
        targets.append(
            Target(
                key="android-system-images",
                group=GROUP_REPORT,
                label="Android SDK system images in use",
                state=REPORT_ONLY,
                detail="an AVD boots from each of these" if all(sysdirs)
                else "an AVD names no system image, so none can be proven unused",
                paths=used,
            )
        )


def version_key(name: str) -> tuple[int, ...]:
    return tuple(int(part) for part in re.findall(r"\d+", name))


def android_studio_data_names() -> set[str] | None:
    """`dataDirectoryName` of every installed Android Studio, or None when one cannot be read."""
    names = set()
    for apps in (Path("/Applications"), HOME / "Applications"):
        for app in sorted(apps.glob("Android Studio*.app")):
            try:
                info = json.loads((app / "Contents/Resources/product-info.json").read_text())
                names.add(info["dataDirectoryName"])
            except (OSError, ValueError, KeyError, TypeError):
                return None
    return names or None


def discover_android_studio(targets: list[Target]) -> None:
    """Caches, logs, and settings Android Studio left behind for versions no longer installed.

    Each version writes its own `AndroidStudio<version>` directory and an upgrade never removes the
    previous one. Settings are the exception worth care: a version launched for the first time
    imports them from the newest older directory, so that one is kept until it has.
    """
    current = android_studio_data_names()
    if not current:
        return
    removals: list[tuple[Path, Path]] = []
    for base in (HOME / "Library/Caches/Google", HOME / "Library/Logs/Google"):
        removals += [(p, base) for p in sorted(base.glob("AndroidStudio*"))
                     if p.is_dir() and p.name not in current]
    config_base = HOME / "Library/Application Support/Google"
    configs = sorted((p for p in config_base.glob("AndroidStudio*") if p.is_dir()),
                     key=lambda p: version_key(p.name))
    if configs and not any(p.name in current for p in configs):
        configs = configs[:-1]
    removals += [(p, config_base) for p in configs if p.name not in current]
    if not removals:
        return
    targets.append(
        Target(
            key="android-studio-old-versions",
            group=GROUP_SAFE,
            label="Android Studio data from older versions",
            detail=f"{', '.join(sorted({p.name for p, _ in removals}))}; installed: "
            f"{', '.join(sorted(current))}",
            selected=True,
            paths=[p for p, _ in removals],
            action=delete_under(removals),
        )
    )


# ---------------------------------------------------------------------------------------------
# Discovery — build products and package caches
# ---------------------------------------------------------------------------------------------


def discover_xcode(targets: list[Target]) -> None:
    entries = sorted(DERIVED_DATA.iterdir()) if DERIVED_DATA.is_dir() else []
    if entries:
        targets.append(
            Target(
                key="xcode-derived-data",
                group=GROUP_SAFE,
                label="Xcode DerivedData",
                detail=f"{plural(len(entries), 'entry', 'entries')}; next build is a cold one",
                selected=True,
                paths=entries,
                action=delete_paths(entries, DERIVED_DATA),
            )
        )

    supports = sorted(DEVICE_SUPPORT.iterdir()) if DEVICE_SUPPORT.is_dir() else []
    if supports:
        targets.append(
            Target(
                key="xcode-device-support",
                group=GROUP_COSTLY,
                label="iOS DeviceSupport",
                detail=", ".join(p.name for p in supports[:2])
                + "; re-extracted on next physical device attach",
                paths=supports,
                action=delete_paths(supports, DEVICE_SUPPORT),
            )
        )


def discover_pnpm(targets: list[Target]) -> None:
    if not shutil.which("pnpm"):
        return
    proc = run("pnpm", "store", "path", timeout=120)
    live = proc.stdout.strip()
    if proc.returncode != 0 or not live:
        return
    live_path = Path(live)
    parent = live_path.parent
    # Superseded majors only. The live store hardlinks into every workspace node_modules, so it is
    # compacted by `pnpm store prune`, never by rm.
    stale = [p for p in sorted(parent.glob("v*")) if p.is_dir() and p != live_path]
    if stale:
        targets.append(
            Target(
                key="pnpm-stale-stores",
                group=GROUP_SAFE,
                label="pnpm stores from superseded majors",
                detail=f"{', '.join(p.name for p in stale)} (live store is {live_path.name})",
                selected=True,
                paths=stale,
                action=delete_paths(stale, parent),
            )
        )

    def prune(dry_run: bool, _live=live_path) -> int:
        if dry_run:
            return 0
        before = size_kb(_live)
        checked("pnpm", "store", "prune")
        return before - size_kb(_live)

    targets.append(
        Target(
            key="pnpm-store-prune",
            group=GROUP_SAFE,
            label="pnpm store prune",
            # No --dry-run, and the answer is not derivable from the store: prune drops what no
            # project references, which depends on every node_modules on the machine. Reported as
            # unknown rather than guessed.
            detail="drops unreferenced packages from the live store",
            projectable=False,
            selected=True,
            paths=[live_path],
            action=prune,
        )
    )


def discover_npm(targets: list[Target]) -> None:
    if not shutil.which("npm"):
        return
    proc = run("npm", "config", "get", "cache", timeout=120)
    root = Path(proc.stdout.strip()) if proc.returncode == 0 and proc.stdout.strip() else None
    if not root or not root.is_absolute() or not root.is_dir():
        return
    # `npm cache clean` empties _cacache and nothing else, so the target is _cacache alone. Sizing
    # the whole cache root would overstate it by the _npx tree, which this never touches.
    cacache = root / "_cacache"
    if cacache.is_dir():
        targets.append(
            Target(
                key="npm-cacache",
                group=GROUP_SAFE,
                label="npm _cacache",
                detail="`npm cache clean --force`; excludes the separate npx cache",
                selected=True,
                paths=[cacache],
                action=clean_with_tool([cacache],
                                      ["npm", "--cache", str(root), "cache", "clean", "--force"]),
            )
        )

    npx = root / "_npx"
    if npx.is_dir():
        # npm >=11.2 owns this cleanup. A read-only capability probe also handles older npm.
        # https://docs.npmjs.com/cli/v11/commands/npm-cache
        supported = run("npm", "--cache", str(root), "cache", "npx", "ls",
                        timeout=120).returncode == 0
        targets.append(
            Target(
                key="npm-npx-cache",
                group=GROUP_COSTLY if supported else GROUP_REPORT,
                label="npm npx downloaded tools",
                state=SELECTABLE if supported else REPORT_ONLY,
                detail=("`npm cache npx rm --force`; stop npx tools first; re-downloads on next use"
                        if supported else "npx cleanup unavailable; npm 11.2+ supports "
                        "`npm cache npx rm --force`"),
                paths=[npx],
                action=(clean_with_tool([npx], ["npm", "--cache", str(root), "cache", "npx",
                                                "rm", "--force"]) if supported else None),
            )
        )


def discover_pip(targets: list[Target]) -> None:
    # Ask this interpreter's pip so PIP_CACHE_DIR and pip configuration remain authoritative.
    # https://pip.pypa.io/en/stable/topics/caching/
    proc = run(sys.executable, "-m", "pip", "--disable-pip-version-check", "cache", "dir",
               timeout=120)
    cache = Path(proc.stdout.strip()) if proc.returncode == 0 and proc.stdout.strip() else None
    if not cache or not cache.is_absolute() or not cache.is_dir():
        return
    # purge clears HTTP and wheel caches, not every other file under the cache root.
    paths = [cache / name for name in ("http", "http-v2", "wheels")
             if (cache / name).is_dir()]
    if paths:
        targets.append(
            Target(
                key="pip-cache",
                group=GROUP_COSTLY,
                label="pip HTTP and wheel caches",
                detail="`python -m pip cache purge`; stop installs first; packages re-download "
                "and wheels may rebuild",
                projectable=False,
                paths=paths,
                action=clean_with_tool(paths, [sys.executable, "-m", "pip",
                                               "--disable-pip-version-check", "--cache-dir",
                                               str(cache), "cache", "purge"]),
            )
        )


def discover_uv(targets: list[Target]) -> None:
    if not shutil.which("uv"):
        return
    proc = run("uv", "cache", "dir", timeout=120)
    cache = Path(proc.stdout.strip()) if proc.returncode == 0 and proc.stdout.strip() else None
    if not cache or not cache.is_dir():
        return

    targets.append(
        Target(
            key="uv-cache",
            group=GROUP_SAFE,
            label="uv cache",
            detail="`uv cache clean`; waits for running uv processes to release the cache",
            selected=True,
            paths=[cache],
            action=clean_with_tool([cache], ["uv", "cache", "clean"]),
        )
    )


def discover_go(targets: list[Target]) -> None:
    if not shutil.which("go"):
        return
    proc = run("go", "env", "GOCACHE", timeout=120)
    cache = Path(proc.stdout.strip()) if proc.returncode == 0 and proc.stdout.strip() else None
    if not cache or not cache.is_absolute() or not cache.is_dir():  # GOCACHE=off is not a path
        return
    targets.append(
        Target(
            key="go-build-cache",
            group=GROUP_SAFE,
            label="Go build cache",
            detail="`go clean -cache`; next build recompiles",
            selected=True,
            paths=[cache],
            action=clean_with_tool([cache], ["go", "clean", "-cache"]),
        )
    )


def discover_download_caches(targets: list[Target]) -> None:
    """Caches that hold nothing but downloads, so removing one costs a re-download and no more."""
    caches = [
        ("react-native-cache", "React Native prebuilt artifacts",
         HOME / "Library/Caches/ReactNative",
         "Hermes and React Native core tarballs; re-downloaded by the next pod install"),
        ("dotslash-cache", "DotSlash downloads",
         Path(os.environ.get("DOTSLASH_CACHE") or HOME / "Library/Caches/dotslash"),
         "binaries fetched for DotSlash files; re-downloaded on next run"),
    ]
    for key, label, path, detail in caches:
        if path.is_absolute() and has_entries(path):
            targets.append(
                Target(
                    key=key,
                    group=GROUP_SAFE,
                    label=label,
                    detail=detail,
                    selected=True,
                    paths=[path],
                    action=delete_paths([path], path.parent),
                )
            )


def brew_projected_kb() -> int | None:
    """Homebrew's own estimate.

    It is the only cleaner here that can cost its own work up front, and its estimate spans outdated
    kegs and logs as well as the download cache — measuring `brew --cache` would miss most of what
    it actually removes.
    """
    proc = run("brew", "cleanup", "--prune=all", "--dry-run")
    if proc.returncode != 0:
        return None  # could not be asked — genuinely unknown
    multipliers = {"B": 1 / 1024, "KB": 1, "MB": 1024, "GB": 1024**2, "TB": 1024**3}
    for line in proc.stdout.splitlines():
        if "would free approximately" not in line:
            continue
        for word in line.split():
            for suffix, multiplier in multipliers.items():
                head = word.removesuffix(suffix)
                if head != word and head.replace(".", "", 1).isdigit():
                    return int(float(head) * multiplier)
    # Asked, answered, nothing to do: brew prints no estimate at all once it is clean. That is a
    # zero, not an unknown — reporting it as unknown makes a finished job look unmeasurable.
    return 0


def discover_brew(targets: list[Target]) -> None:
    if not shutil.which("brew"):
        return
    target = Target(
        key="brew-cleanup",
        group=GROUP_SAFE,
        label="Homebrew cleanup",
        detail="`brew cleanup --prune=all` (outdated kegs, logs, download cache)",
        projectable=False,
        selected=True,
        pending=SLOW_PROBES.submit(brew_projected_kb),
    )
    target.action = lambda dry_run, _t=target: (
        _t.projected_kb if dry_run else (checked("brew", "cleanup", "--prune=all"), _t.projected_kb)[1]
    )
    targets.append(target)


def settle(targets: Iterable[Target], wait: bool = True) -> bool:
    """Fold finished background projections into their rows; True when one changed."""
    changed = False
    for target in targets:
        if target.pending is None or not (wait or target.pending.done()):
            continue
        try:
            projected = target.pending.result()
        except Exception:  # a projection must never abort the run
            projected = None
        target.pending = None
        target.projected_kb = (projected or 0) if target.state == SELECTABLE else 0
        target.projectable = projected is not None
        changed = True
    return changed


def discover_cocoapods(targets: list[Target]) -> None:
    cache = HOME / "Library/Caches/CocoaPods"
    if cache.is_dir():
        targets.append(
            Target(
                key="cocoapods-cache",
                group=GROUP_SAFE,
                label="CocoaPods cache",
                detail="re-downloaded on next pod install",
                selected=True,
                paths=[cache],
                action=delete_paths([cache], cache.parent),
            )
        )


def discover_codex(targets: list[Target]) -> None:
    """Abandoned Codex runtime install staging.

    Derived, not hardcoded: an install directory is temp-suffixed staging holding the downloaded
    archive and an extracted payload, left behind after the runtime was promoted. The live runtime
    is `codex-primary-runtime` and is never a target.
    """
    root = HOME / ".cache/codex-runtimes"
    if not root.is_dir():
        return
    staging = [p for p in sorted(root.glob("codex-runtime-install-*")) if p.is_dir()]
    if not staging:
        return
    targets.append(
        Target(
            key="codex-install-staging",
            group=GROUP_SAFE,
            label="Codex abandoned install staging",
            detail=f"{', '.join(p.name for p in staging)}; codex-primary-runtime is left alone",
            selected=True,
            paths=staging,
            action=delete_paths(staging, root),
        )
    )


def discover_gradle(targets: list[Target]) -> None:
    """One row per Gradle cache, because none of them is derivably dead.

    A `caches/<version>` directory belongs to a Gradle version that may still have an installed
    distribution and a project pinning it, and this tool cannot see every project on the machine.
    Rather than guess, each is offered separately with its last-modified date.
    """
    # Daemon logs are the exception: nothing reads a finished daemon's log, and a running daemon
    # keeps writing to its unlinked file until it exits.
    daemon = HOME / ".gradle/daemon"
    logs = sorted(daemon.glob("*/daemon-*.out.log")) if daemon.is_dir() else []
    if logs:
        targets.append(
            Target(
                key="gradle-daemon-logs",
                group=GROUP_SAFE,
                label="Gradle daemon logs",
                detail=f"{plural(len(logs), 'log')} across "
                f"{plural(len({p.parent for p in logs}), 'Gradle version')}",
                selected=True,
                paths=logs,
                action=delete_paths(logs, daemon),
            )
        )

    caches = HOME / ".gradle/caches"
    if not caches.is_dir():
        return
    # ~/.gradle/jdks is deliberately absent: a JDK swapped under a warm Gradle daemon produces
    # failures that read as missing tooling somewhere else entirely.
    dists = HOME / ".gradle/wrapper/dists"
    for entry in sorted(caches.iterdir()):
        if not entry.is_dir():
            continue
        if entry.name == "modules-2":
            detail = "downloaded dependencies; re-downloaded on next build"
        elif entry.name.startswith("build-cache"):
            detail = "task output cache; rebuilt on next build"
        elif entry.name[0].isdigit():
            installed = (dists / f"gradle-{entry.name}-bin").exists()
            when = datetime.fromtimestamp(entry.stat().st_mtime).strftime("%Y-%m-%d")
            detail = f"Gradle {entry.name} cache, last used {when}"
            detail += "; distribution still installed" if installed else "; no distribution left"
        else:
            continue
        targets.append(
            Target(
                key=f"gradle-{entry.name}",
                group=GROUP_COSTLY,
                label=f"Gradle caches/{entry.name}",
                detail=detail,
                paths=[entry],
                action=delete_paths([entry], caches),
            )
        )


# ---------------------------------------------------------------------------------------------
# Discovery — reported, never modified
# ---------------------------------------------------------------------------------------------


def discover_reported(targets: list[Target]) -> None:
    sdk = android_sdk()
    ndk_root = sdk / "ndk"
    if ndk_root.is_dir():
        versions = [p for p in sorted(ndk_root.iterdir()) if p.is_dir()]
        if versions:
            targets.append(
                Target(
                    key="android-ndk",
                    group=GROUP_REPORT,
                    label=f"Android NDK ({plural(len(versions), 'version')})",
                    state=REPORT_ONLY,
                    detail="Expo resolves ndkVersion at build time; which one is required "
                    "cannot be proven from here",
                    paths=versions,
                )
            )

    # Shared browser installs and model caches need project-aware review; archives and backups may
    # be unique.
    # https://playwright.dev/docs/browsers#managing-browser-binaries
    # https://developer.apple.com/documentation/xcode/building-your-app-to-include-debugging-information
    # https://support.apple.com/en-us/108809
    # https://huggingface.co/docs/huggingface_hub/guides/manage-cache
    hf_home = Path(os.environ.get("HF_HOME") or HOME / ".cache/huggingface")
    reports = [
        ("xcode-archives", "Xcode Archives", HOME / "Library/Developer/Xcode/Archives",
         "review in Xcode Organizer; preserve release archives and their matching dSYMs"),
        ("apple-device-backups", "iPhone/iPad local backups",
         HOME / "Library/Application Support/MobileSync/Backup",
         "review in Finder > device > General > Manage Backups; these are personal restore data"),
        ("huggingface-hub", "Hugging Face model cache",
         Path(os.environ.get("HF_HUB_CACHE") or hf_home / "hub"),
         "downloaded models and datasets; review with the Hugging Face CLI (`hf cache --help`)"),
    ]
    browser_path = os.environ.get("PLAYWRIGHT_BROWSERS_PATH")
    if browser_path != "0":  # 0 opts into project-local installs, not a global cache.
        browser_root = (Path(browser_path) if browser_path
                        else HOME / "Library/Caches/ms-playwright")
        if not browser_root.is_absolute():
            browser_root = Path(os.environ.get("INIT_CWD") or os.getcwd()) / browser_root
        reports.append(
            ("playwright-browsers", "Playwright browser binaries",
             browser_root,
             "shared across projects; review with the installed Playwright CLI; "
             "uninstall --all affects every Playwright version")
        )
    for key, label, path, detail in reports:
        if path.is_dir():
            targets.append(Target(key=key, group=GROUP_REPORT, label=label, state=REPORT_ONLY,
                                  detail=detail, paths=[path]))

    raw = HOME / "Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"
    if raw.exists():
        apparent = raw.stat().st_size // 1024
        # https://docs.docker.com/desktop/troubleshoot-and-support/faqs/macfaqs/
        detail = (f"{human(apparent)} apparent maximum; row shows allocated host space; with "
                  "Docker running, review `docker system df` before `docker system prune`")
        targets.append(
            Target(
                key="docker-raw",
                group=GROUP_REPORT,
                label="Docker.raw",
                state=REPORT_ONLY,
                detail=detail,
                paths=[raw],
            )
        )


DISCOVERERS: list[Callable[[list[Target]], None]] = [
    discover_brew,
    discover_simulators,
    discover_simulator_sets,
    discover_android,
    discover_android_studio,
    discover_xcode,
    discover_pnpm,
    discover_npm,
    discover_pip,
    discover_uv,
    discover_go,
    discover_download_caches,
    discover_cocoapods,
    discover_codex,
    discover_gradle,
    discover_reported,
]


class Progress:
    """A single-line progress bar for the seconds discovery spends walking tens of GB.

    Writes to stderr, never stdout: --json has to stay pipeable into jq, and a bar interleaved with
    the document would corrupt it. Silent when stderr is not a terminal, so redirected output stays
    a clean log. Discovery and execution both report from thread pools, so counters are taken under
    one lock and terminal writes under another.
    """

    BAR_WIDTH = 24

    def __init__(self) -> None:
        self.enabled = sys.stderr.isatty()
        self._lock = threading.Lock()
        self._out = threading.RLock()
        self._phase = ""
        self._done = 0
        self._total = 0
        self._last_label = ""

    def phase(self, name: str, total: int) -> None:
        with self._lock:
            self._phase, self._done, self._total = name, 0, max(total, 1)
            self._last_label = ""
        self._draw("")

    def grow(self, extra: int) -> None:
        """More work turned up mid-phase: each finished scan queues its own measurements."""
        with self._lock:
            self._total += extra

    def advance(self, label: str = "") -> None:
        with self._lock:
            self._done += 1
        self._draw(label)

    def note(self, label: str) -> None:
        """Redraw with a new label without advancing — what a long step is currently working on."""
        self._draw(label)

    def write(self, text: str) -> None:
        """Print a result line without the bar smearing into it.

        Both streams land on the same terminal, so a `\r`-drawn bar and a `\n`-terminated print
        interleave into wreckage unless the bar is erased first and redrawn after.
        """
        with self._out:
            self.clear()
            print(text)
            sys.stdout.flush()
            self._draw(self._last_label)

    def _draw(self, label: str) -> None:
        if not self.enabled:
            return
        with self._lock:
            self._last_label = label or self._last_label
            done, total, phase, label = self._done, self._total, self._phase, self._last_label
        filled = round(self.BAR_WIDTH * min(done, total) / total)
        bar = "█" * filled + "·" * (self.BAR_WIDTH - filled)
        width = shutil.get_terminal_size((100, 24)).columns
        line = f" {phase:<11} [{bar}] {done:>2}/{total:<2}  {label}"
        with self._out:
            sys.stderr.write("\r\033[2K" + line[: width - 1])
            sys.stderr.flush()

    def clear(self) -> None:
        if self.enabled:
            with self._out:
                sys.stderr.write("\r\033[2K")
                sys.stderr.flush()


#: Actions are closures built during discovery, long before execution has a reporter to hand them.
#: A single shared instance lets them report progress without threading a parameter through every
#: signature.
PROGRESS: Progress = Progress()


def run_discoverer(discoverer: Callable[[list[Target]], None]) -> list[Target]:
    found: list[Target] = []
    discoverer(found)
    return found


def discover(progress: Progress | None = None) -> list[Target]:
    """Scan everything at once, and measure each path as soon as its scan reports it.

    The scans are mostly waits on other tools, so running them one after another made the wall
    clock the sum of every wait instead of the longest one. A path two targets share (a simulator's
    delete and erase rows, an AVD and its snapshots) is measured once. Projections slower than all
    of that together are left pending for settle().
    """
    progress = progress or PROGRESS
    progress.phase("scanning", len(DISCOVERERS))
    found: dict[int, list[Target]] = {}
    sizes: dict[Path, concurrent.futures.Future] = {}
    pool = concurrent.futures.ThreadPoolExecutor(max_workers=DISCOVER_WORKERS)
    try:
        scans = {pool.submit(run_discoverer, d): i for i, d in enumerate(DISCOVERERS)}
        for future in concurrent.futures.as_completed(scans):
            index = scans[future]
            found[index] = future.result()
            for target in found[index]:
                for path in target.paths:
                    if path not in sizes:
                        sizes[path] = pool.submit(size_kb, path)
                        progress.grow(1)
            progress.advance(getattr(DISCOVERERS[index], "__name__", "")
                             .removeprefix("discover_"))
        names = {future: path.name for path, future in sizes.items()}
        for future in concurrent.futures.as_completed(names):
            progress.advance(names[future])
    finally:
        pool.shutdown(wait=False, cancel_futures=True)

    targets = [t for index in sorted(found) for t in found[index]]
    for target in targets:
        if target.paths:
            try:
                target.size_kb = sum(sizes[path].result() for path in target.paths)
            except ProbeError as exc:
                target.size_kb = None
                target.projectable = False
                target.detail = f"size unavailable: {exc}; {target.detail}"
                if target.state == SELECTABLE:
                    target.state, target.group, target.selected = BLOCKED, GROUP_BLOCKED, False
        # Every plain removal frees what it occupies, so the projection is the measurement rather
        # than a second walk of the same tree. Tools that know better set projected_kb themselves.
        if target.state != SELECTABLE:
            target.projected_kb = 0
        elif target.projectable and not target.projected_kb:
            target.projected_kb = target.size_kb or 0
    progress.clear()
    targets.sort(key=row_order)
    return targets


def row_order(target: Target) -> tuple:
    return (GROUP_ORDER.index(target.group), target.order, -sort_weight(target), target.label)


# ---------------------------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------------------------


class Style:
    """ANSI attributes, or nothing at all when the destination is not a terminal.

    Colour is applied only after a string has been padded to width. Escape sequences count toward
    len() but occupy no columns, so colouring first and aligning second silently shreds every
    column in the table.
    """

    def __init__(self, enabled: bool) -> None:
        self.on = enabled

    def _wrap(self, code: str, text: str) -> str:
        return f"\033[{code}m{text}\033[0m" if self.on else text

    def bold(self, text: str) -> str:
        return self._wrap("1", text)

    def dim(self, text: str) -> str:
        return self._wrap("2", text)

    def green(self, text: str) -> str:
        return self._wrap("32", text)

    def red(self, text: str) -> str:
        return self._wrap("31", text)

    def yellow(self, text: str) -> str:
        return self._wrap("33", text)

    def cyan(self, text: str) -> str:
        return self._wrap("36", text)


#: Wide terminals should not stretch a two-column table across the whole screen.
MAX_WIDTH = 96
VALUE_WIDTH = 12


def layout_width() -> int:
    return max(60, min(shutil.get_terminal_size((MAX_WIDTH, 24)).columns - 1, MAX_WIDTH))


def plural(count: int, singular: str, plural_form: str | None = None) -> str:
    if count == 1:
        return f"{count} {singular}"
    return f"{count} {plural_form or singular + 's'}"


def wrap_detail(text: str, width: int, limit: int = 2) -> list[str]:
    """Detail lines wrap rather than truncate — the useful half is often at the end."""
    lines = textwrap.wrap(text, width, break_long_words=False, break_on_hyphens=False)
    if len(lines) <= limit:
        return lines
    kept = lines[:limit]
    kept[-1] = ellipsize(kept[-1] + " " + lines[limit], width)
    return kept


def ellipsize(text: str, width: int) -> str:
    if width <= 1:
        return ""
    return text if len(text) <= width else text[: width - 1] + "…"


def sort_weight(target: Target) -> int:
    """Rank a row by what it displays, not by what it occupies.

    They differ: Homebrew owns no paths at all (size 0) yet projects GiB, and `pnpm store prune`
    is sized by the live store it prunes rather than by the unknown amount it releases.
    """
    if target.state == REPORT_ONLY:
        return target.size_kb or 0
    return target.projected_kb if target.projectable else target.size_kb or 0


def value_of(target: Target) -> str:
    """What this row contributes, never a bare 0 that could mean four different things."""
    if target.pending is not None:
        return "measuring…"
    if target.state == BLOCKED:
        return "blocked"
    if target.state == REPORT_ONLY:
        return human(target.size_kb) if target.size_kb is not None else "unknown"
    if target.group == GROUP_SIM_ERASE:
        return f"{human(target.size_kb)} used" if target.size_kb is not None else "unknown"
    if not target.projectable:
        return "unknown"
    return human(target.projected_kb)


def selected_total(targets: Iterable[Target]) -> tuple[int, bool]:
    total, has_unknown = 0, False
    for target in targets:
        if target.state != SELECTABLE or not target.selected:
            continue
        if target.projectable:
            total += target.projected_kb
        else:
            has_unknown = True
    return total, has_unknown


def rule(width: int, title: str = "", value: str = "") -> str:
    """A horizontal rule, optionally captioned on the left and valued on the right."""
    left = f"── {title} " if title else "──"
    right = f" {value}" if value else ""
    fill = max(width - len(left) - len(right), 2)
    return left + "─" * fill + right


@dataclass
class TargetGroup:
    label: str
    children: list[Target] = field(default_factory=list)
    expanded: bool = True


def target_groups(targets: Sequence[Target]) -> list[TargetGroup]:
    groups: dict[str, TargetGroup] = {}
    for target in targets:
        groups.setdefault(target.group, TargetGroup(target.group)).children.append(target)
    return list(groups.values())


def selection_box(targets: Sequence[Target]) -> str:
    selectable = [target for target in targets if target.state == SELECTABLE]
    if not selectable:
        return " · "
    count = sum(target.selected for target in selectable)
    return "[x]" if count == len(selectable) else "[-]" if count else "[ ]"


def select(chosen: Sequence[Target], universe: Sequence[Target] = ()) -> None:
    """Select `chosen`, one per exclusive tag (the first wins), clearing its rivals in `universe`."""
    claimed: dict[str, Target] = {}
    for target in chosen:
        if target.state != SELECTABLE:
            continue
        if target.exclusive:
            if target.exclusive in claimed:
                target.selected = False
                continue
            claimed[target.exclusive] = target
        target.selected = True
    for target in universe:
        if claimed.get(target.exclusive, target) is not target:
            target.selected = False


def toggle_selection(targets: Sequence[Target], universe: Sequence[Target] = ()) -> None:
    selectable = [target for target in targets if target.state == SELECTABLE]
    if all(target.selected for target in selectable):
        for target in selectable:
            target.selected = False
    else:
        select(selectable, universe)


#: Key prefix → what the "Last used" column means for that kind of row.
LAST_USED_SOURCES = {
    "sim-erase-": "last boot recorded by CoreSimulator",
    "sim-delete-": "last boot recorded by CoreSimulator",
    "sim-runtime-": "CoreSimulator's last use of the runtime",
    "avd-": "last emulator launch",
}


def last_used_source(target: Target) -> str | None:
    return next((source for prefix, source in LAST_USED_SOURCES.items()
                 if target.key.startswith(prefix)), None)


def last_used_date(target: Target) -> str:
    if last_used_source(target) is None:
        return ""
    if not target.last_used_at:
        return "unknown"
    return datetime.fromisoformat(target.last_used_at.replace("Z", "+00:00")).astimezone().strftime(
        "%Y-%m-%d"
    )


def target_detail(target: Target) -> str:
    detail = f"{target.label}: {target.detail}"
    source = last_used_source(target)
    if source:
        detail += f"; last used = {source}: {target.last_used_at or 'unknown'}"
    return detail


def group_value(group: TargetGroup) -> str:
    if group.label == GROUP_SIM_ERASE:
        total = sum(target.size_kb or 0 for target in group.children)
        unknown = any(target.size_kb is None for target in group.children)
        return human(total) + ("+" if unknown else "") + " used"
    # Alternatives for one device count once, at their largest: deleting an AVD already includes
    # wiping it and dropping its snapshots.
    total, unknown, best = 0, False, {}
    for target in group.children:
        if target.state == SELECTABLE:
            value = target.projected_kb if target.projectable else 0
            unknown |= not target.projectable
        else:
            value = target.size_kb or 0
            unknown |= target.size_kb is None
        if target.exclusive:
            best[target.exclusive] = max(best.get(target.exclusive, 0), value)
        else:
            total += value
    return human(total + sum(best.values())) + ("+" if unknown else "")


def tree_columns(label: str, date: str, value: str, width: int) -> str:
    label_width = max(width - 28, 1)
    return f"{ellipsize(label, label_width):<{label_width}}  {date:>10}  {value:>14}"


def tree_label(group: TargetGroup, target: Target | None = None) -> str:
    if target is None:
        return f" {'▾' if group.expanded else '▸'} {selection_box(group.children)} {group.label}"
    branch = "└─" if target is group.children[-1] else "├─"
    return f"   {branch} {selection_box([target])} {target.label}"


def print_table(targets: Sequence[Target], stream=None) -> None:
    stream = stream or sys.stdout
    style = Style(stream.isatty())
    width = layout_width()
    label_width = width - VALUE_WIDTH - 7

    print(style.dim(tree_columns(" Cleanup target", "Last used", "Size / reclaim", width)), file=stream)
    for group in target_groups(targets):
        print("\n" + style.cyan(tree_columns(tree_label(group), "", group_value(group), width)),
              file=stream)
        for row in group.children:
            line = tree_columns(tree_label(group, row), last_used_date(row), value_of(row), width)
            if row.state != SELECTABLE:
                print(style.dim(line), file=stream)
            elif row.selected:
                print(style.green(line), file=stream)
            else:
                print(line, file=stream)
            for detail_line in wrap_detail(target_detail(row), width - 6, limit=4):
                print(style.dim(f"      {detail_line}"), file=stream)

    total, unknown = selected_total(targets)
    label = "selected (at least)" if unknown else "selected"
    print("\n" + style.dim(rule(width)), file=stream)
    print(style.bold(f"  {label:<{label_width + 4}}{human(total):>{VALUE_WIDTH}}"), file=stream)
    print(style.dim(f"  {'free on ' + DATA_VOLUME:<{label_width + 4}}"
                    f"{human(free_kb()):>{VALUE_WIDTH}}"), file=stream)


def describe_error(exc: BaseException) -> str:
    """A reason a person can act on.

    The default repr of an OSError leads with `[Errno 20]` and ends in `PosixPath(...)`, so the
    part that identifies the offending file is the first thing a narrow column truncates away.
    """
    if isinstance(exc, OSError):
        name = getattr(exc, "filename", None)
        reason = exc.strerror or exc.__class__.__name__
        return f"{reason}: {name}" if name else reason
    return str(exc) or exc.__class__.__name__


# ---------------------------------------------------------------------------------------------
# Interactive picker
# ---------------------------------------------------------------------------------------------


GROUP_HINTS = {
    GROUP_SIM_DELETE: " Delete removes the device for good; the erase group below keeps it.",
    GROUP_SIM_ERASE: " Erase wipes apps and settings but keeps the device, so it is listed "
    "again on the next scan. Last used shows the last boot date.",
    GROUP_AVD: " Each AVD offers delete, wipe data, or snapshots; choosing one clears the others.",
}


def pick(targets: list[Target]) -> bool:
    """Checkbox tree. Parents select children; arrows fold branches without changing selection."""
    import curses

    groups = target_groups(targets)
    if not groups:
        return False
    # Erase is the rarer alternative to delete for the same devices; folded, the list shows each
    # device once instead of twice.
    if any(group.label == GROUP_SIM_DELETE for group in groups):
        for group in groups:
            if group.label == GROUP_SIM_ERASE:
                group.expanded = False
    display_order = [child for group in groups for child in group.children]

    def draw(screen) -> bool:
        curses.curs_set(0)
        has_colors = curses.has_colors()
        if has_colors:
            curses.use_default_colors()
            for index, colour in enumerate(
                (curses.COLOR_CYAN, curses.COLOR_GREEN, curses.COLOR_YELLOW), start=1
            ):
                curses.init_pair(index, colour, -1)
        dim = curses.A_DIM
        cursor, top = 0, 0
        rows: list[tuple[TargetGroup, Target | None]] = []

        while True:
            if settle(targets, wait=False) and rows:
                # A late number can move its row; keep the cursor on the row it was on.
                held = rows[cursor]
                for group in groups:
                    group.children.sort(key=row_order)
                display_order[:] = [child for group in groups for child in group.children]
            else:
                held = None
            # Wake periodically only while a background projection is still out.
            screen.timeout(250 if any(t.pending for t in targets) else -1)
            rows = []
            for group in groups:
                rows.append((group, None))
                if group.expanded:
                    rows.extend((group, target) for target in group.children)
            if held:
                cursor = next((i for i, (g, t) in enumerate(rows)
                               if g is held[0] and t is held[1]), cursor)
            cursor = min(cursor, len(rows) - 1)
            screen.erase()
            height, width = screen.getmaxyx()
            if height < 8 or width < 40:
                screen.addnstr(0, 0, "Enlarge terminal to 40x8; q quits", max(width - 1, 0))
                screen.refresh()
                if screen.getch() in (ord("q"), 27):
                    return False
                continue
            total, unknown = selected_total(targets)
            header = (f" macOS cleanup · free {human(free_kb())} · "
                      f"selected {'≥ ' if unknown else ''}{human(total)}")
            screen.addnstr(0, 0, header.ljust(width - 1), width - 1, curses.A_BOLD)
            screen.addnstr(1, 0, tree_columns(" Cleanup target", "Last used", "Size / reclaim",
                                             width - 1), width - 1, dim)

            body_height = height - 6
            if cursor < top:
                top = cursor
            elif cursor >= top + body_height:
                top = cursor - body_height + 1

            for offset in range(body_height):
                index = top + offset
                if index >= len(rows):
                    break
                group, target = rows[index]
                y = offset + 2
                if target is None:
                    line = tree_columns(tree_label(group), "", group_value(group), width - 1)
                    attr = curses.A_BOLD | (curses.color_pair(1) if has_colors else 0)
                else:
                    line = tree_columns(tree_label(group, target), last_used_date(target),
                                        value_of(target), width - 1)
                    attr = curses.A_NORMAL
                    if target.state != SELECTABLE:
                        attr |= dim
                    elif target.selected and has_colors:
                        attr |= curses.color_pair(2)
                if index == cursor:
                    attr |= curses.A_REVERSE
                screen.addnstr(y, 0, line.ljust(width - 1)[: width - 1], width - 1, attr)

            group, target = rows[cursor]
            if target is None:
                selectable = [child for child in group.children if child.state == SELECTABLE]
                detail = (f"{group.label}: {sum(child.selected for child in selectable)}/"
                          f"{len(selectable)} selected. Space selects or clears all selectable "
                          "children. [-] means partially selected; left/right folds the group.")
                detail += GROUP_HINTS.get(group.label, "")
            else:
                detail = target_detail(target)
            for offset, line in enumerate(wrap_detail(detail, width - 2, limit=3)):
                screen.addnstr(height - 4 + offset, 1, line, width - 2, dim)
            footer = " space toggle · ←/→ fold · a all · n none · ↵ apply · q quit"
            screen.addnstr(height - 1, 0, footer.ljust(width - 1)[: width - 1], width - 1,
                           curses.A_BOLD)
            screen.refresh()

            key = screen.getch()
            if key in (ord("q"), 27):
                return False
            if key in (curses.KEY_ENTER, 10, 13):
                return True
            if key in (curses.KEY_DOWN, ord("j")):
                cursor = min(cursor + 1, len(rows) - 1)
            elif key in (curses.KEY_UP, ord("k")):
                cursor = max(cursor - 1, 0)
            elif key in (curses.KEY_LEFT, ord("h")):
                if target is None:
                    group.expanded = False
                else:
                    cursor = next(i for i, (parent, child) in enumerate(rows)
                                  if parent is group and child is None)
            elif key in (curses.KEY_RIGHT, ord("l")) and target is None:
                if group.expanded and group.children:
                    cursor += 1
                else:
                    group.expanded = True
            elif key in (ord(" "), ord("x")):
                toggle_selection(group.children if target is None else [target], targets)
            elif key == ord("a"):
                # One treatment per device: the first in display order, which is the largest.
                select(display_order, targets)
            elif key == ord("n"):
                for target in targets:
                    target.selected = False

    return curses.wrapper(draw)


# ---------------------------------------------------------------------------------------------
# Execution
# ---------------------------------------------------------------------------------------------


def execute(targets: Sequence[Target], channel: AppChannel | None = None) -> None:
    """Run the selection, one lane per independent tool, several lanes at once.

    Most of the wall clock here is other programs — brew, uv, pnpm, simctl — each working through
    its own tree, so running them side by side rather than in turn is where the time goes. Within a
    lane order is kept: CoreSimulator gets one lane, and so does the emulator.

    With a channel the run is reported to MacHelm as events and nothing is printed for a person.
    """
    chosen = [t for t in targets if t.state == SELECTABLE and t.selected and t.action]
    if not chosen:
        if channel:
            channel.send(event="done", reclaimed_kb=0, failures=0, free_kb=free_kb())
        else:
            print("\nNothing selected — nothing was removed.")
        return

    if ROOT_REMOVER is None and any(t.needs_sudo for t in chosen):
        # Establish the credential before the first deletion rather than stalling for a password
        # prompt partway through a multi-step run.
        if run("sudo", "-v", timeout=120).returncode != 0:
            print("sudo credentials are required for the selected simulator targets.",
                  file=sys.stderr)
            raise SystemExit(1)

    style = Style(sys.stdout.isatty())
    width = layout_width()
    label_width = width - VALUE_WIDTH - 7

    start = free_kb()
    tally = {"total": 0, "unknown": False, "failures": 0}
    lock = threading.Lock()
    stop = threading.Event()
    lanes: dict[str, list[Target]] = {}
    for target in chosen:
        lanes.setdefault(target.lane or target.key, []).append(target)

    def run_target(target: Target) -> None:
        PROGRESS.note(target.label)
        try:
            freed = target.action(False)  # type: ignore[misc]
        except Exception as exc:
            with lock:
                tally["failures"] += 1
            if channel:
                channel.send(event="result", key=target.key, ok=False, freed_kb=None,
                             error=describe_error(exc))
                PROGRESS.advance(target.label)
                return
            # Label on the row and reason on the detail line below, matching every other row in
            # the tool. The reason then gets the full width instead of a 14-column value cell,
            # which is what cut the offending path out of the message that reported it.
            line = f"  {style.red('✗')} {ellipsize(target.label, label_width):<{label_width}}"
            lines = [line + style.red(f"{'not removed':>{VALUE_WIDTH}}")]
            lines += [style.dim(f"      {d}") for d in wrap_detail(describe_error(exc), width - 6)]
        else:
            with lock:
                if target.projectable or freed:
                    tally["total"] += freed
                    value = human(freed)
                else:
                    tally["unknown"] = True
                    value = "done"
            if channel:
                # None where the reclaim could not be known, as in the inventory.
                channel.send(event="result", key=target.key, ok=True,
                             freed_kb=freed if target.projectable or freed else None, error=None)
                PROGRESS.advance(target.label)
                return
            line = f"  {style.green('✓')} {ellipsize(target.label, label_width):<{label_width}}"
            lines = [line + style.green(f"{value:>{VALUE_WIDTH}}")]
        PROGRESS.write("\n".join(lines))  # one write, so a target's lines stay together
        PROGRESS.advance(target.label)

    def run_lane(lane: list[Target]) -> None:
        for target in lane:
            if stop.is_set():
                return
            run_target(target)

    if not channel:
        print("\n" + style.cyan(rule(width, "removing", plural(len(chosen), "target"))))
    PROGRESS.phase("deleting", len(chosen))
    pool = concurrent.futures.ThreadPoolExecutor(max_workers=min(EXECUTE_WORKERS, len(lanes)))
    try:
        for future in [pool.submit(run_lane, lane) for lane in lanes.values()]:
            future.result()
    except KeyboardInterrupt:
        # Targets already running finish (half a tree is worse than either state); nothing new
        # starts.
        stop.set()
        if not channel:
            PROGRESS.write(style.yellow("  interrupted: finishing the targets already running"))
        pool.shutdown(wait=True, cancel_futures=True)
        raise
    finally:
        pool.shutdown(wait=True)
    PROGRESS.clear()

    total, has_unknown, failures = tally["total"], tally["unknown"], tally["failures"]
    label = "reclaimed (at least)" if has_unknown else "reclaimed"
    end = free_kb()
    if channel:
        channel.send(event="done", reclaimed_kb=total, failures=failures, free_kb=end)
        return
    print(style.dim(rule(width)))
    print(style.bold(f"  {label:<{label_width + 4}}{human(total):>{VALUE_WIDTH}}"))
    print(style.dim(f"  {'free on ' + DATA_VOLUME:<{label_width + 4}}"
                    f"{human(end):>{VALUE_WIDTH}}"))
    if failures:
        print(style.yellow(f"  {plural(failures, 'target')} did not complete; "
                          "nothing else was affected"))
    drift = end - start
    if abs(drift - total) > 262144:
        print(style.dim(f"  free space moved {human(drift)} overall, which also includes "
                        "other processes"))


# ---------------------------------------------------------------------------------------------


def main(argv: Sequence[str] | None = None) -> int:
    global PROGRESS
    PROGRESS = Progress()
    parser = argparse.ArgumentParser(
        prog="cleanup-macos-dev.py",
        description="Reclaim developer-toolchain disk space on macOS. Nothing is removed until you "
        "confirm.",
    )
    parser.add_argument("--yes", action="store_true",
                        help="skip the picker and act on the default selection")
    parser.add_argument("--select", metavar="KEY,...",
                        help="skip the picker and act on the named targets; use --json to find "
                        "keys, including sim-delete-<UDID> / sim-erase-<UDID> for shutdown "
                        "simulators and avd-{delete,wipe,snapshots}-<NAME> for Android emulators")
    parser.add_argument("--json", action="store_true",
                        help="print the discovered targets as JSON and exit; never removes anything")
    parser.add_argument("--app", action="store_true",
                        help="for MacHelm: report as one JSON object per line; alone it lists the "
                        "targets and removes nothing, with --select it removes those and asks the "
                        "app, not sudo, for a root target")
    args = parser.parse_args(argv)
    if args.app and (args.yes or args.json):
        parser.error("--app goes alone or with --select")
    channel = AppChannel() if args.app else None
    global ROOT_REMOVER, TOOL_STDIN
    ROOT_REMOVER = channel.remove_root if channel else None
    TOOL_STDIN = subprocess.DEVNULL if channel else None

    def refuse(message: str, status: int) -> int:
        if channel:
            channel.send(event="error", message=message)
        else:
            print(message, file=sys.stderr)
        return status

    if sys.platform != "darwin":
        return refuse(f"Refusing to run: this targets macOS developer toolchains, found {sys.platform}.", 1)
    for tool in ("xcrun", "hdiutil", "du"):
        if not shutil.which(tool):
            return refuse(f"Refusing to run: {tool} is required and is not on PATH.", 1)

    try:
        targets = discover()
    except ProbeError as exc:
        return refuse(str(exc) if channel else f"Refusing to continue: {exc}", 1)
    if args.app or args.json or args.yes or args.select is not None or not (
            sys.stdout.isatty() and sys.stdin.isatty()):
        # Only the picker can show a row before its number is in.
        settle(targets)
        targets.sort(key=row_order)

    if args.json:
        json.dump([t.as_json() for t in targets], sys.stdout, indent=2)
        sys.stdout.write("\n")
        return 0
    if channel and args.select is None:
        channel.send(event="targets", free_kb=free_kb(), targets=[t.as_json() for t in targets])
        return 0

    if args.select is not None:
        wanted = {k.strip() for k in args.select.split(",") if k.strip()}
        # Only selectable keys are offered: naming a blocked or report-only target would otherwise
        # be accepted and then silently do nothing.
        known = {t.key for t in targets if t.state == SELECTABLE}
        unknown_keys = wanted - known
        if unknown_keys:
            if channel:
                return refuse(f"Not selectable: {', '.join(sorted(unknown_keys))}", 2)
            print(f"Not selectable: {', '.join(sorted(unknown_keys))}", file=sys.stderr)
            print(f"Selectable: {', '.join(sorted(known))}", file=sys.stderr)
            return 2
        rivals: dict[str, list[str]] = {}
        for target in targets:
            if target.key in wanted and target.exclusive:
                rivals.setdefault(target.exclusive, []).append(target.key)
        conflicts = [keys for keys in rivals.values() if len(keys) > 1]
        if conflicts:
            if channel:
                return refuse("Choose one of: " + "; ".join(", ".join(sorted(keys)) for keys in conflicts), 2)
            for keys in conflicts:
                print(f"Choose one of: {', '.join(sorted(keys))}", file=sys.stderr)
            return 2
        for target in targets:
            target.selected = target.state == SELECTABLE and target.key in wanted
    elif not args.yes:
        if not (sys.stdout.isatty() and sys.stdin.isatty()):
            # Piped or redirected: report and exit without touching anything, so
            # `./cleanup-macos-dev.py | less` stays safe.
            print_table(targets)
            print("\nNot a terminal — nothing was removed. Re-run in a terminal, "
                  "or pass --yes / --select.")
            return 0
        if not pick(targets):
            print("Aborted; nothing was removed.")
            return 0

    settle(targets)
    targets.sort(key=row_order)
    if not channel:
        print_table(targets)
    execute(targets, channel)
    return 0


if __name__ == "__main__":
    sys.exit(main())
