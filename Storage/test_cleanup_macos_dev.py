"""Cleanup safety checks using fixture directories and mocked tool commands only."""

import copy
import importlib.util
import io
import json
import os
import plistlib
from pathlib import Path
from contextlib import ExitStack
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock, patch


SPEC = importlib.util.spec_from_file_location(
    "cleanup_macos_dev", Path(__file__).with_name("cleanup-macos-dev.py")
)
cleanup = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = cleanup
SPEC.loader.exec_module(cleanup)
REAL_SIZE_KB = cleanup.size_kb
REAL_RUN = cleanup.run

FIRST, SECOND, BOOTED, UNAVAILABLE = [f"00000000-0000-4000-8000-{i:012d}" for i in range(1, 5)]
RUNTIMES = {"runtimes": [{"identifier": "ios-old", "name": "iOS 18.0"},
                         {"identifier": "ios-new", "name": "iOS 26.5"}]}
DEVICES = {"devices": {
    "ios-old": [{"name": "iPhone", "udid": FIRST, "state": "Shutdown", "isAvailable": True,
                 "lastBootedAt": "2026-09-10T23:15:00-02:00"}],
    "ios-new": [{"name": "iPhone", "udid": SECOND, "state": "Shutdown", "isAvailable": True},
                {"name": "Running", "udid": BOOTED, "state": "Booted", "isAvailable": True},
                {"name": "Unavailable", "udid": UNAVAILABLE, "state": "Shutdown",
                 "isAvailable": False}],
}}


def result(stdout="", returncode=0, stderr=""):
    return subprocess.CompletedProcess([], returncode, stdout, stderr)


class CleanupTests(unittest.TestCase):
    def setUp(self):
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.run = self.stack.enter_context(patch.object(cleanup, "run", return_value=result()))
        self.size = self.stack.enter_context(patch.object(cleanup, "size_kb", return_value=1024))
        self.stack.enter_context(patch.object(cleanup, "HOME", self.root))
        self.stack.enter_context(patch.object(cleanup, "SIM_DEVICES_ROOT", self.root / "devices"))
        self.stack.enter_context(patch.object(cleanup, "free_kb", return_value=1024 * 1024))
        self.stack.enter_context(patch.object(cleanup.shutil, "which", return_value="tool"))
        self.stack.enter_context(patch.dict(os.environ, {}, clear=True))

    def simulators(self, kind="erase"):
        targets = []
        cleanup.discover_shutdown_simulators(targets, RUNTIMES, DEVICES)
        return [t for t in targets if kind is None or t.key.startswith(f"sim-{kind}-")]

    def main(self, targets, argv):
        with patch.object(cleanup, "discover", return_value=targets), \
                patch.object(cleanup.sys, "platform", "darwin"), \
                patch.object(cleanup.sys, "stdout", new_callable=io.StringIO) as output, \
                patch.object(cleanup.sys, "stderr", new_callable=io.StringIO):
            return cleanup.main(argv), output.getvalue()

    def pick(self, targets, keys, width=96):
        import curses
        screen = Mock()
        screen.getmaxyx.return_value = (24, width)
        screen.getch.side_effect = keys
        with patch.object(curses, "wrapper", side_effect=lambda fn: fn(screen)), \
                patch.object(curses, "curs_set"), patch.object(curses, "has_colors", return_value=False):
            confirmed = cleanup.pick(targets)
        lines = [call.args[2] for call in screen.addnstr.call_args_list]
        return confirmed, lines

    def test_only_available_shutdown_devices_get_distinct_unchecked_rows(self):
        targets = self.simulators()
        self.assertEqual([t.key for t in targets], [f"sim-erase-{FIRST}", f"sim-erase-{SECOND}"])
        self.assertEqual([t.label for t in targets], ["iPhone (iOS 18.0)", "iPhone (iOS 26.5)"])
        for target, udid in zip(targets, (FIRST, SECOND)):
            self.assertFalse(target.selected)
            self.assertIn(udid, target.detail)
            self.assertEqual(target.paths, [self.root / "devices" / udid])
            self.assertIsNone(target.as_json()["projected_kb"])
            target.size_kb = 1024
            self.assertEqual(cleanup.value_of(target), "1.0 MiB used")
            target.selected = True
        self.assertEqual(cleanup.selected_total(targets), (0, True))

    def test_select_erases_only_named_udid_and_measures_its_actual_delta(self):
        targets = self.simulators()
        self.size.side_effect = [4096, 1024]
        with patch.object(cleanup, "simctl_json", return_value=DEVICES):
            status, output = self.main(targets, ["--select", targets[1].key])
        self.assertEqual(status, 0)
        self.run.assert_called_once_with("xcrun", "simctl", "erase", SECOND)
        self.assertEqual(self.size.call_args_list[0].args, (self.root / "devices" / SECOND,))
        self.assertIn("3.0 MiB", output)

    def test_default_selection_preserves_simulators_and_executes_positive_control(self):
        targets = self.simulators()
        control = Mock(return_value=32)
        targets.append(cleanup.Target("cache", cleanup.GROUP_SAFE, "Cache",
                                      selected=True, action=control))
        status, _ = self.main(targets, ["--yes"])
        self.assertEqual(status, 0)
        control.assert_called_once_with(False)
        self.run.assert_not_called()

    def test_stale_device_state_refuses_erase_but_shutdown_control_succeeds(self):
        target = self.simulators()[0]
        for state in ("Booted", "Booting", "Shutting Down", "missing", "unavailable"):
            with self.subTest(state=state):
                devices = copy.deepcopy(DEVICES)
                current = devices["devices"]["ios-old"][0]
                if state == "missing":
                    devices["devices"]["ios-old"] = []
                elif state == "unavailable":
                    current["isAvailable"] = False
                else:
                    current["state"] = state
                with patch.object(cleanup, "simctl_json", return_value=devices):
                    with self.assertRaisesRegex(RuntimeError, "no longer"):
                        target.action(False)
                self.run.assert_not_called()
        with patch.object(cleanup, "simctl_json", return_value=DEVICES):
            target.action(False)
        self.run.assert_called_once_with("xcrun", "simctl", "erase", FIRST)

    def test_erase_failure_is_reported(self):
        target = self.simulators()[0]
        self.run.return_value = result(returncode=1, stderr="device is busy")
        with patch.object(cleanup, "simctl_json", return_value=DEVICES):
            with self.assertRaisesRegex(RuntimeError, "device is busy"):
                target.action(False)

    def test_invalid_identity_cannot_become_simctl_all_selector(self):
        self.assertEqual(len(self.simulators()), 2)
        devices = copy.deepcopy(DEVICES)
        devices["devices"]["ios-old"][0]["udid"] = "all"
        with self.assertRaises(cleanup.ProbeError):
            cleanup.discover_shutdown_simulators([], RUNTIMES, devices)
        self.run.assert_not_called()

    def test_json_and_dry_run_do_not_erase_even_selected_devices(self):
        targets = self.simulators()
        for target in targets:
            target.selected = True
            self.assertEqual(target.action(True), 0)
        status, output = self.main(targets, ["--json", "--yes"])
        self.assertEqual(status, 0)
        self.assertEqual([t["key"] for t in json.loads(output)], [t.key for t in targets])
        self.run.assert_not_called()

    def test_retired_bulk_erase_key_is_rejected(self):
        targets = self.simulators()
        self.assertTrue(all(t.state == cleanup.SELECTABLE for t in targets))
        status, _ = self.main(targets, ["--select", "sim-erase-shutdown"])
        self.assertEqual(status, 2)
        self.run.assert_not_called()

    def test_picker_toggles_devices_independently(self):
        import curses
        targets = self.simulators()
        confirmed, _ = self.pick(targets, [ord("n"), curses.KEY_DOWN, curses.KEY_DOWN, ord(" "), 10])
        self.assertTrue(confirmed)
        self.assertEqual([t.selected for t in targets], [False, True])
        self.run.assert_not_called()

    def test_last_used_comes_from_boot_metadata_and_missing_is_unknown(self):
        first, second = self.simulators()
        self.assertEqual(first.as_json()["last_used_at"], "2026-09-11T01:15:00Z")
        self.assertIsNone(second.as_json()["last_used_at"])
        self.assertEqual(cleanup.last_used_date(second), "unknown")
        # Set a known display timezone to check conversion across the UTC day boundary.
        try:
            with patch.dict(os.environ, TZ="Etc/GMT+3"):
                time.tzset()
                self.assertEqual(cleanup.last_used_date(first), "2026-09-10")
        finally:
            time.tzset()
        self.assertIn("last boot recorded by CoreSimulator", cleanup.target_detail(first))
        for malformed in (None, "", "yesterday", 123, "2026-09-11T01:15:00"):
            with self.subTest(value=malformed):
                self.assertIsNone(cleanup.simulator_last_used(malformed))

    def test_parent_selects_eligible_simulators_and_leaves_other_groups_alone(self):
        targets = self.simulators()
        blocked = cleanup.Target("blocked", cleanup.GROUP_SIM_ERASE, "Blocked", state=cleanup.BLOCKED)
        report = cleanup.Target("report", cleanup.GROUP_SIM_ERASE, "Report", state=cleanup.REPORT_ONLY)
        cache = cleanup.Target("cache", cleanup.GROUP_SAFE, "Cache")
        targets.extend([blocked, report, cache])
        confirmed, lines = self.pick(targets, [ord(" "), 10])
        self.assertTrue(confirmed)
        self.assertEqual([t.selected for t in targets], [True, True, False, False, False])
        self.assertTrue(any("[x] Erase shutdown simulators" in line for line in lines))
        self.assertEqual(cleanup.selected_total(targets), (0, True))
        self.run.assert_not_called()

    def test_parent_shows_partial_selection_and_toggles_all_then_none(self):
        import curses
        targets = self.simulators()
        confirmed, lines = self.pick(targets, [curses.KEY_DOWN, ord(" "), curses.KEY_UP,
                                               ord(" "), ord(" "), 10])
        self.assertTrue(confirmed)
        for box in ("[ ]", "[-]", "[x]"):
            self.assertTrue(any(f"{box} Erase shutdown simulators" in line for line in lines), box)
        self.assertEqual([t.selected for t in targets], [False, False])
        self.run.assert_not_called()

    def test_collapsed_parent_toggles_children_and_expansion_preserves_selection(self):
        import curses
        targets = self.simulators()
        confirmed, lines = self.pick(targets, [curses.KEY_LEFT, ord(" "), curses.KEY_RIGHT,
                                               curses.KEY_DOWN, ord(" "), curses.KEY_LEFT, 10])
        self.assertTrue(confirmed)
        self.assertEqual([t.selected for t in targets], [False, True])
        self.assertTrue(any("▸ [x] Erase shutdown simulators" in line for line in lines))
        self.assertTrue(any("▾ [-] Erase shutdown simulators" in line for line in lines))
        self.assertTrue(any("├─" in line for line in lines))
        self.assertTrue(any("└─" in line for line in lines))
        self.run.assert_not_called()

    def test_global_all_includes_collapsed_groups_but_excludes_protected_targets(self):
        import curses
        targets = self.simulators()
        targets.extend([cleanup.Target("cache", cleanup.GROUP_SAFE, "Cache"),
                        cleanup.Target("backup", cleanup.GROUP_REPORT, "Backup", state=cleanup.REPORT_ONLY)])
        confirmed, _ = self.pick(targets, [curses.KEY_LEFT, ord("a"), 10])
        self.assertTrue(confirmed)
        self.assertEqual([t.selected for t in targets], [True, True, True, False])
        self.pick(targets, [ord("n"), 10])
        self.assertTrue(all(not t.selected for t in targets))
        self.run.assert_not_called()

    def test_readonly_report_contains_tree_dates_and_partial_parent_state(self):
        targets = self.simulators()
        targets[0].selected = True
        output = io.StringIO()
        cleanup.print_table(targets, output)
        text = output.getvalue()
        self.assertIn("Last used", text)
        self.assertIn("▾ [-] Erase shutdown simulators", text)
        self.assertIn("├─ [x]", text)
        self.assertIn("└─ [ ]", text)
        self.assertIn(cleanup.last_used_date(targets[0]), text)
        self.assertIn("unknown", text)
        self.run.assert_not_called()

    def test_picker_keeps_date_and_size_columns_visible_at_80_columns(self):
        targets = self.simulators()
        targets[0].label = "A long simulator verification name " * 3
        targets[0].size_kb = 1024
        _, lines = self.pick(targets, [ord("q")], width=80)
        first_line = next(line for line in lines if "├─" in line)
        self.assertIn(cleanup.last_used_date(targets[0]), first_line)
        self.assertIn("1.0 MiB used", first_line)
        self.assertEqual(len(first_line), 79)

    def test_npx_only_cache_is_discovered_and_cleanup_is_pinned(self):
        npx = self.root / "npm custom" / "_npx"
        npx.mkdir(parents=True)
        self.run.side_effect = [result(str(npx.parent)), result(), result()]
        targets = []
        cleanup.discover_npm(targets)
        self.assertEqual([t.key for t in targets], ["npm-npx-cache"])
        self.assertFalse(targets[0].selected)
        targets[0].action(False)
        self.run.assert_called_with("npm", "--cache", str(npx.parent), "cache", "npx", "rm", "--force")

    def test_unsupported_npx_cleanup_is_report_only_alongside_working_npm_cache(self):
        for name in ("_npx", "_cacache"):
            (self.root / name).mkdir()
        self.run.side_effect = [result(str(self.root)), result(returncode=1)]
        targets = []
        cleanup.discover_npm(targets)
        self.assertEqual([t.key for t in targets], ["npm-cacache", "npm-npx-cache"])
        self.assertEqual(targets[0].state, cleanup.SELECTABLE)
        self.assertEqual(targets[1].state, cleanup.REPORT_ONLY)
        self.assertIsNone(targets[1].action)

    def test_pip_uses_discovered_cache_and_excludes_unrelated_files(self):
        for name in ("http", "http-v2", "wheels", "selfcheck"):
            (self.root / name).mkdir()
        self.run.side_effect = [result(str(self.root)), result()]
        targets = []
        cleanup.discover_pip(targets)
        self.assertEqual(len(targets), 1)
        target = targets[0]
        self.assertFalse(target.selected)
        self.assertEqual({p.name for p in target.paths}, {"http", "http-v2", "wheels"})
        target.action(False)
        self.run.assert_called_with(sys.executable, "-m", "pip", "--disable-pip-version-check",
                                    "--cache-dir", str(self.root), "cache", "purge")

    def test_new_tool_cleanup_failure_is_not_counted_as_success(self):
        self.run.return_value = result(returncode=1, stderr="cache is locked")
        action = cleanup.clean_with_tool([self.root], ["cache-tool", "purge"])
        self.assertEqual(action(True), 1024)
        self.run.assert_not_called()
        with self.assertRaisesRegex(RuntimeError, "cache is locked"):
            action(False)
        self.run.assert_called_once_with("cache-tool", "purge")

    def test_manual_review_targets_are_measured_but_cannot_be_selected(self):
        browsers = self.root / "custom-browsers"
        for path in (browsers, self.root / "Library/Developer/Xcode/Archives",
                     self.root / "Library/Application Support/MobileSync/Backup",
                     self.root / "hf/hub"):
            path.mkdir(parents=True)
        with patch.dict(os.environ, HF_HOME=str(self.root / "hf"),
                        PLAYWRIGHT_BROWSERS_PATH=str(browsers)):
            targets = []
            cleanup.discover_reported(targets)
        self.assertEqual({t.key for t in targets}, {"playwright-browsers", "xcode-archives",
                                                  "apple-device-backups", "huggingface-hub"})
        self.assertTrue(all(t.state == cleanup.REPORT_ONLY and t.action is None for t in targets))
        status, _ = self.main(targets, ["--select", "apple-device-backups"])
        self.assertEqual(status, 2)
        self.run.assert_not_called()

    def test_hermetic_playwright_setting_omits_shared_browsers(self):
        (self.root / "Library/Caches/ms-playwright").mkdir(parents=True)
        targets = []
        cleanup.discover_reported(targets)
        self.assertEqual([t.key for t in targets], ["playwright-browsers"])
        with patch.dict(os.environ, PLAYWRIGHT_BROWSERS_PATH="0"):
            targets = []
            cleanup.discover_reported(targets)
        self.assertEqual(targets, [])

    def test_relative_playwright_path_uses_package_managers_original_directory(self):
        browsers = self.root / "original" / "browsers"
        browsers.mkdir(parents=True)
        with patch.dict(os.environ, INIT_CWD=str(browsers.parent), PLAYWRIGHT_BROWSERS_PATH="browsers"):
            targets = []
            cleanup.discover_reported(targets)
        self.assertEqual(targets[0].paths, [browsers])

    def test_du_partial_output_is_unknown_while_success_and_absence_remain_distinct(self):
        with patch.object(cleanup.subprocess, "run", return_value=result(f"4\t{self.root}\n")) as du:
            self.assertEqual(REAL_SIZE_KB(self.root), 4)
            self.assertEqual(REAL_SIZE_KB(self.root / "absent"), 0)
            du.assert_called_once()
            for failed in (result(f"0\t{self.root}\n", 1, "Operation not permitted"), result("")):
                du.return_value = failed
                with self.assertRaises(cleanup.ProbeError):
                    REAL_SIZE_KB(self.root)

    def test_failed_measurement_is_unknown_and_cannot_enable_cleanup(self):
        control = cleanup.Target("ok", cleanup.GROUP_REPORT, "Readable", state=cleanup.REPORT_ONLY,
                                 paths=[self.root / "readable"])
        protected = cleanup.Target("backup", cleanup.GROUP_REPORT, "Backup", state=cleanup.REPORT_ONLY,
                                   paths=[self.root / "protected"])
        selectable = cleanup.Target("cache", cleanup.GROUP_SAFE, "Cache", selected=True,
                                    paths=[self.root / "protected"], action=Mock())
        self.size.side_effect = lambda p: 128 if p.name == "readable" else self.raise_probe_error()
        with patch.object(cleanup, "DISCOVERERS", [lambda ts: ts.extend([control, protected, selectable])]):
            targets = cleanup.discover()
        self.assertEqual(control.size_kb, 128)
        self.assertIsNone(protected.as_json()["size_kb"])
        self.assertEqual(cleanup.value_of(protected), "unknown")
        self.assertEqual(selectable.state, cleanup.BLOCKED)
        self.assertFalse(selectable.selected)
        selectable.action.assert_not_called()
        output = io.StringIO()
        cleanup.print_table(targets, output)
        self.assertIn("unknown", output.getvalue())

    # -----------------------------------------------------------------------------------------
    # Delete or erase: one choice per simulator

    def test_each_shutdown_device_offers_delete_and_erase_as_one_choice(self):
        targets = self.simulators(kind=None)
        self.assertEqual(sorted(t.key for t in targets),
                         sorted(f"sim-{verb}-{udid}" for verb in ("delete", "erase")
                                for udid in (FIRST, SECOND)))
        for udid in (FIRST, SECOND):
            delete, erase = (next(t for t in targets if t.key == f"sim-{verb}-{udid}")
                             for verb in ("delete", "erase"))
            self.assertEqual(delete.exclusive, erase.exclusive)
            self.assertEqual(delete.group, cleanup.GROUP_SIM_DELETE)
            self.assertTrue(delete.projectable)
            self.assertFalse(erase.projectable)
            self.assertFalse(delete.selected or erase.selected)

    def test_delete_removes_only_the_named_device(self):
        targets = self.simulators(kind=None)
        self.size.side_effect = [4096, 0]
        with patch.object(cleanup, "simctl_json", return_value=DEVICES):
            status, output = self.main(targets, ["--select", f"sim-delete-{SECOND}"])
        self.assertEqual(status, 0)
        self.run.assert_called_once_with("xcrun", "simctl", "delete", SECOND)
        self.assertIn("4.0 MiB", output)

    def test_delete_refuses_a_device_booted_since_the_scan(self):
        target = next(t for t in self.simulators(kind="delete") if FIRST in t.key)
        devices = copy.deepcopy(DEVICES)
        devices["devices"]["ios-old"][0]["state"] = "Booted"
        with patch.object(cleanup, "simctl_json", return_value=devices):
            with self.assertRaisesRegex(RuntimeError, "no longer"):
                target.action(False)
        self.run.assert_not_called()

    def test_select_refuses_both_treatments_of_one_device(self):
        targets = self.simulators(kind=None)
        status, _ = self.main(targets, ["--select", f"sim-delete-{FIRST},sim-erase-{FIRST}"])
        self.assertEqual(status, 2)
        self.run.assert_not_called()

    def test_choosing_delete_clears_erase_for_that_device_only(self):
        targets = self.simulators(kind=None)
        by_key = {t.key: t for t in targets}
        by_key[f"sim-erase-{FIRST}"].selected = True
        by_key[f"sim-erase-{SECOND}"].selected = True
        cleanup.toggle_selection([by_key[f"sim-delete-{FIRST}"]], targets)
        self.assertTrue(by_key[f"sim-delete-{FIRST}"].selected)
        self.assertFalse(by_key[f"sim-erase-{FIRST}"].selected)
        self.assertTrue(by_key[f"sim-erase-{SECOND}"].selected)

    def test_erase_group_starts_folded_beside_delete_and_select_all_picks_one_each(self):
        targets = sorted(self.simulators(kind=None), key=cleanup.row_order)
        confirmed, lines = self.pick(targets, [ord("a"), 10])
        self.assertTrue(confirmed)
        self.assertTrue(any("▸" in line and "Erase shutdown simulators" in line for line in lines))
        self.assertEqual({t.key for t in targets if t.selected},
                         {f"sim-delete-{FIRST}", f"sim-delete-{SECOND}"})

    # -----------------------------------------------------------------------------------------
    # Orphaned runtimes

    def runtime_fixture(self, *, registered=True, deletable=True, sdk="26.5"):
        image_id = "11111111-2222-4333-8444-555555555555"
        asset = self.root / "assets" / "abc.asset"
        runtimes = {"runtimes": [
            {"identifier": "ios-old", "name": "iOS 18.0", "platform": "iOS", "version": "18.0",
             "buildversion": "22A3351", "lastUsage": {"arm64": "2026-09-04T18:56:58Z",
                                                      "x86_64": "0001-01-01T00:00:00Z"}},
            {"identifier": "ios-new", "name": "iOS 26.5", "platform": "iOS", "version": "26.5",
             "buildversion": "23F77"}]}
        devices = {"devices": {"ios-old": [], "ios-new": DEVICES["devices"]["ios-new"]}}
        images = {image_id: {"identifier": image_id, "runtimeIdentifier": "ios-old",
                             "build": "22A3351", "deletable": deletable,
                             "parentImagePath": str(asset / "AssetData/x.dmg")}}
        replies = {
            ("xcrun", "simctl", "runtime", "list", "-j"): json.dumps(images if registered else {}),
            ("xcrun", "simctl", "runtime", "match", "list", "-j"):
                json.dumps({f"iphoneos{sdk}": {"sdkVersion": f"{sdk}.1"}}),
        }
        self.run.side_effect = lambda *argv, **_: result(replies.get(argv, ""))
        self.stack.enter_context(patch.object(cleanup, "probe_simulators",
                                              return_value=(runtimes, devices)))
        return image_id, asset

    def test_registered_orphan_runtime_is_deleted_by_simctl_not_rm(self):
        image_id, asset = self.runtime_fixture()
        targets = []
        cleanup.discover_simulators(targets)
        runtime = next(t for t in targets if t.key == "sim-runtime-22A3351")
        self.assertEqual((runtime.state, runtime.group, runtime.selected),
                         (cleanup.SELECTABLE, cleanup.GROUP_SAFE, True))
        self.assertEqual(runtime.paths, [asset])
        self.assertFalse(runtime.needs_sudo)
        self.assertEqual(runtime.last_used_at, "2026-09-04T18:56:58Z")
        runtime.action(False)
        argvs = [call.args for call in self.run.call_args_list]
        self.assertIn(("xcrun", "simctl", "runtime", "delete", image_id), argvs)
        self.assertFalse(any("rm" in argv for argv in argvs))

    def test_dead_runtime_the_sdk_still_matches_starts_unchecked(self):
        self.runtime_fixture(sdk="18.0")
        targets = []
        cleanup.discover_simulators(targets)
        runtime = next(t for t in targets if t.key == "sim-runtime-22A3351")
        self.assertEqual((runtime.group, runtime.selected), (cleanup.GROUP_COSTLY, False))
        self.assertIn("download it again", runtime.detail)

    def test_bundled_runtime_is_not_offered(self):
        self.runtime_fixture(deletable=False)
        targets = []
        cleanup.discover_simulators(targets)
        self.assertFalse(any(t.key.startswith("sim-runtime-") for t in targets))

    def test_unregistered_sip_restricted_runtime_stays_blocked(self):
        _, asset = self.runtime_fixture(registered=False)
        (asset).mkdir(parents=True)
        with (asset / "Info.plist").open("wb") as handle:
            plistlib.dump({"MobileAssetProperties": {"Build": "22A3351"}}, handle)
        with patch.object(cleanup, "SIM_ASSETS_ROOT", asset.parent), \
                patch.object(cleanup, "is_sip_restricted", return_value=True):
            targets = []
            cleanup.discover_simulators(targets)
        runtime = next(t for t in targets if t.key == "sim-runtime-22A3351")
        self.assertEqual((runtime.state, runtime.group), (cleanup.BLOCKED, cleanup.GROUP_BLOCKED))
        self.assertIn("registry", runtime.detail)

    def test_dyld_caches_for_other_builds_and_removed_runtimes_are_stale(self):
        root = self.root / "dyld"
        for name in ("25A1/com.apple.CoreSimulator.SimRuntime.iOS-18-0.22A3351",
                     "25G83/com.apple.CoreSimulator.SimRuntime.iOS-18-0.22A3351",
                     "25G83/com.apple.CoreSimulator.SimRuntime.iOS-17-0.21A1",
                     "25G83/inc"):
            (root / name).mkdir(parents=True)
        runtimes = {"runtimes": [{"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-0",
                                  "buildversion": "22A3351"}]}
        with patch.object(cleanup, "SIM_DYLD_ROOT", root):
            stale = cleanup.stale_dyld_caches(runtimes, "25G83")
        self.assertEqual(stale, [root / "25A1",
                                 root / "25G83/com.apple.CoreSimulator.SimRuntime.iOS-17-0.21A1"])

    # -----------------------------------------------------------------------------------------
    # Android emulators

    def android_fixture(self, sysdir="system-images/android-36/google_apis/arm64-v8a/"):
        sdk = self.root / "sdk"
        for image in ("android-36/google_apis/arm64-v8a", "android-35/google_apis/arm64-v8a"):
            (sdk / "system-images" / image).mkdir(parents=True)
        avd_root = self.root / ".android/avd"
        data = avd_root / "Pixel.avd"
        (data / "snapshots/default_boot").mkdir(parents=True)
        (avd_root / "Pixel.ini").write_text(f"path={data}\ntarget=android-36\n")
        (data / "config.ini").write_text(f"image.sysdir.1={sysdir}\n" if sysdir else "x=1\n")
        for name in ("userdata-qemu.img", "userdata-qemu.img.qcow2", "encryptionkey.img.qcow2",
                     "cache.img", "sdcard.img", "hardware-qemu.ini",
                     "snapshots/default_boot/ram.bin"):
            (data / name).write_text("x")
        self.stack.enter_context(patch.dict(os.environ, ANDROID_HOME=str(sdk)))
        return sdk, avd_root, data

    def android_targets(self, ps=""):
        self.run.return_value = result(ps)
        targets = []
        cleanup.discover_android(targets)
        return {t.key: t for t in targets}

    def test_avd_offers_delete_wipe_or_snapshots_as_one_choice(self):
        self.android_fixture()
        targets = self.android_targets()
        rows = [targets[f"avd-{verb}-Pixel"] for verb in ("delete", "wipe", "snapshots")]
        self.assertTrue(all(r.state == cleanup.SELECTABLE and not r.selected for r in rows))
        self.assertEqual(len({r.exclusive for r in rows}), 1)
        self.assertEqual(sorted(rows, key=cleanup.row_order), rows)

    def test_wipe_keeps_the_avd_and_its_base_images(self):
        _, _, data = self.android_fixture()
        self.android_targets()["avd-wipe-Pixel"].action(False)
        self.assertEqual(sorted(p.name for p in data.iterdir()),
                         ["cache.img", "config.ini", "hardware-qemu.ini", "sdcard.img"])

    def test_snapshots_only_drop_the_snapshot_directory(self):
        _, _, data = self.android_fixture()
        self.android_targets()["avd-snapshots-Pixel"].action(False)
        self.assertFalse((data / "snapshots").exists())
        self.assertTrue((data / "userdata-qemu.img.qcow2").exists())

    def test_delete_removes_the_ini_and_its_data(self):
        _, avd_root, _ = self.android_fixture()
        self.android_targets()["avd-delete-Pixel"].action(False)
        self.assertEqual(list(avd_root.iterdir()), [])

    def test_running_emulator_blocks_its_avd_but_other_apps_mentioning_emulators_do_not(self):
        self.android_fixture()
        bystander = 'Claude Helper --desktop-features={"androidEmulator":{"status":"x"}} -avd Pixel'
        self.assertEqual(self.android_targets(bystander)["avd-wipe-Pixel"].state,
                         cleanup.SELECTABLE)
        qemu = "/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64 -netdelay none -avd Pixel"
        rows = self.android_targets(qemu)
        self.assertTrue(all(rows[f"avd-{v}-Pixel"].state == cleanup.BLOCKED
                            for v in ("delete", "wipe", "snapshots")))

    def test_avd_launched_after_the_scan_is_refused(self):
        _, _, data = self.android_fixture()
        wipe = self.android_targets()["avd-wipe-Pixel"]
        self.run.return_value = result("/sdk/emulator/emulator @Pixel -no-window")
        with self.assertRaisesRegex(RuntimeError, "close the emulator"):
            wipe.action(False)
        self.assertTrue((data / "userdata-qemu.img.qcow2").exists())

    def test_only_system_images_no_avd_uses_are_offered(self):
        sdk, _, _ = self.android_fixture()
        targets = self.android_targets()
        unused = targets["android-image-android-35-google_apis-arm64-v8a"]
        self.assertEqual((unused.state, unused.selected), (cleanup.SELECTABLE, False))
        self.assertEqual(targets["android-system-images"].paths,
                         [sdk / "system-images/android-36/google_apis/arm64-v8a"])
        unused.action(False)
        self.assertFalse((sdk / "system-images/android-35").exists())
        self.assertTrue((sdk / "system-images/android-36/google_apis/arm64-v8a").exists())

    def test_an_avd_without_a_system_image_makes_every_image_unprovable(self):
        self.android_fixture(sysdir=None)
        targets = self.android_targets()
        self.assertFalse(any(k.startswith("android-image-") for k in targets))
        self.assertEqual(targets["android-system-images"].state, cleanup.REPORT_ONLY)

    def test_android_studio_keeps_installed_version_and_newest_settings_until_imported(self):
        google = {base: self.root / "Library" / base / "Google"
                  for base in ("Caches", "Logs", "Application Support")}
        for base in google.values():
            for version in ("AndroidStudio2024.1", "AndroidStudio2025.3.3"):
                (base / version).mkdir(parents=True)
        with patch.object(cleanup, "android_studio_data_names",
                          return_value={"AndroidStudio2026.1.4"}):
            targets = []
            cleanup.discover_android_studio(targets)
        removed = set(targets[0].paths)
        self.assertIn(google["Caches"] / "AndroidStudio2025.3.3", removed)
        self.assertIn(google["Application Support"] / "AndroidStudio2024.1", removed)
        self.assertNotIn(google["Application Support"] / "AndroidStudio2025.3.3", removed)

    # -----------------------------------------------------------------------------------------
    # Discovery and execution plumbing

    def test_shared_paths_are_measured_once_and_projection_needs_no_second_walk(self):
        shared = self.root / "shared"
        first = cleanup.Target("a", cleanup.GROUP_SAFE, "A", paths=[shared], action=Mock())
        second = cleanup.Target("b", cleanup.GROUP_SAFE, "B", paths=[shared], action=Mock())
        with patch.object(cleanup, "DISCOVERERS", [lambda ts: ts.extend([first, second])]):
            cleanup.discover()
        self.size.assert_called_once_with(shared)
        self.assertEqual((first.projected_kb, second.projected_kb), (1024, 1024))
        first.action.assert_not_called()

    def test_slow_projection_reads_measuring_until_settled(self):
        future = cleanup.concurrent.futures.Future()
        brew = cleanup.Target("brew", cleanup.GROUP_SAFE, "Brew", projectable=False,
                              selected=True, pending=future)
        self.assertEqual(cleanup.value_of(brew), "measuring…")
        self.assertFalse(cleanup.settle([brew], wait=False))
        future.set_result(2048)
        self.assertTrue(cleanup.settle([brew], wait=False))
        self.assertEqual((cleanup.value_of(brew), cleanup.selected_total([brew])),
                         ("2.0 MiB", (2048, False)))

    def test_lanes_keep_their_order_and_one_failure_stops_nothing_else(self):
        calls = []

        def step(name, fail=False):
            def action(dry_run):
                calls.append(name)
                if fail:
                    raise RuntimeError(f"{name} failed")
                return 1
            return action

        targets = [cleanup.Target(n, cleanup.GROUP_SAFE, n, selected=True, lane=lane,
                                  action=step(n, fail=n == "s1"))
                   for n, lane in (("s1", "sim"), ("s2", "sim"), ("s3", "sim"), ("x", ""))]
        status, output = self.main(targets, ["--yes"])
        self.assertEqual(status, 0)
        self.assertEqual([c for c in calls if c.startswith("s")], ["s1", "s2", "s3"])
        self.assertIn("x", calls)
        self.assertIn("s1 failed", output)
        self.assertIn("1 target did not complete", output)

    def test_write_protected_tree_is_removed_without_following_links(self):
        cache = self.root / "dotslash"
        artifact = cache / "46/a2fd/Tool.app/Contents/MacOS"
        artifact.mkdir(parents=True)
        (artifact / "tool").write_text("x")
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "keep").write_text("x")
        (artifact.parent / "link").symlink_to(outside, target_is_directory=True)
        outside.chmod(0o555)
        self.addCleanup(outside.chmod, 0o755)
        for directory in (artifact, artifact.parent, artifact.parent.parent, cache / "46/a2fd"):
            directory.chmod(0o555)
        cleanup.remove_tree(cache / "46", cache, sudo=False)
        self.assertEqual(list(cache.iterdir()), [])
        self.assertEqual(outside.stat().st_mode & 0o777, 0o555)
        self.assertTrue((outside / "keep").exists())

    def test_tool_cleaners_that_fail_are_reported_not_counted(self):
        self.run.return_value = result(returncode=1, stderr="cache is in use")
        for discover, which in ((cleanup.discover_uv, "uv"), (cleanup.discover_brew, "brew")):
            with self.subTest(tool=which):
                cache = self.root / which
                cache.mkdir()
                self.run.side_effect = [result(str(cache))] if which == "uv" else None
                targets = []
                discover(targets)
                self.run.side_effect = None
                cleanup.settle(targets)
                with self.assertRaisesRegex(RuntimeError, "cache is in use|failed"):
                    targets[0].action(False)

    # -----------------------------------------------------------------------------------------
    # Run by MacHelm (--app): one JSON object per line, and a root target's removal handed to
    # the app instead of sudo

    def app(self, targets, argv, replies=""):
        with patch.object(cleanup.sys, "stdin", io.StringIO(replies)):
            status, output = self.main(targets, ["--app", *argv])
        return status, [json.loads(line) for line in output.splitlines()]

    def root_target(self, key="sim-dyld-stale"):
        root = self.root / "dyld"
        stale = root / "25A1"
        stale.mkdir(parents=True)
        target = cleanup.Target(key, cleanup.GROUP_SAFE, "Stale caches", needs_sudo=True,
                                paths=[stale], action=cleanup.delete_paths([stale], root, sudo=True))
        return target, stale

    def test_json_names_the_alternative_treatments_of_one_device(self):
        by_key = {t.key: t.as_json() for t in self.simulators(None)}
        self.assertTrue(by_key[f"sim-delete-{FIRST}"]["exclusive"])
        self.assertEqual(by_key[f"sim-delete-{FIRST}"]["exclusive"],
                         by_key[f"sim-erase-{FIRST}"]["exclusive"])
        self.assertNotEqual(by_key[f"sim-delete-{FIRST}"]["exclusive"],
                            by_key[f"sim-delete-{SECOND}"]["exclusive"])
        self.assertEqual(cleanup.Target("cache", cleanup.GROUP_SAFE, "Cache").as_json()["exclusive"], "")

    def test_app_scan_is_one_line_with_every_target_and_removes_nothing(self):
        control = Mock(return_value=32)
        targets = self.simulators(None) + [cleanup.Target("cache", cleanup.GROUP_SAFE, "Cache",
                                                          selected=True, action=control)]
        status, events = self.app(targets, [])
        self.assertEqual(status, 0)
        self.assertEqual([e["event"] for e in events], ["targets"])
        self.assertEqual(events[0]["free_kb"], 1024 * 1024)
        self.assertEqual({t["key"] for t in events[0]["targets"]}, {t.key for t in targets})
        self.assertEqual({t["key"]: t["default_selected"] for t in events[0]["targets"]}["cache"], True)
        control.assert_not_called()
        self.run.assert_not_called()

    def test_app_run_reports_each_target_and_the_total_as_events(self):
        fine = cleanup.Target("fine", cleanup.GROUP_SAFE, "Fine", action=Mock(return_value=2048))
        broken = cleanup.Target("broken", cleanup.GROUP_SAFE, "Broken",
                                action=Mock(side_effect=RuntimeError("cache is in use")))
        other = cleanup.Target("other", cleanup.GROUP_SAFE, "Other", selected=True,
                               action=Mock(return_value=1))
        status, events = self.app([fine, broken, other], ["--select", "fine,broken"])
        self.assertEqual(status, 0)
        results = {e["key"]: e for e in events if e["event"] == "result"}
        self.assertEqual(results["fine"], {"event": "result", "key": "fine", "ok": True,
                                           "freed_kb": 2048, "error": None})
        self.assertFalse(results["broken"]["ok"])
        self.assertIn("cache is in use", results["broken"]["error"])
        self.assertEqual(events[-1], {"event": "done", "reclaimed_kb": 2048, "failures": 1,
                                      "free_kb": 1024 * 1024})
        # Only what was named runs, whatever the script would check by default.
        other.action.assert_not_called()
        self.assertEqual({e["event"] for e in events}, {"result", "done"})

    def test_app_run_hands_a_root_removal_to_the_app_and_never_calls_sudo(self):
        target, stale = self.root_target()
        status, events = self.app([target], ["--select", target.key], replies='{"ok": true}\n')
        self.assertEqual(status, 0)
        self.assertIn({"event": "remove-root", "path": str(stale)}, events)
        self.assertEqual([e["ok"] for e in events if e["event"] == "result"], [True])
        self.assertFalse([c for c in self.run.call_args_list if c.args[:1] == ("sudo",)])
        # The app's helper removes it; the script does not touch the folder itself.
        self.assertTrue(stale.exists())

    def test_app_refusing_a_root_removal_fails_that_target_and_nothing_else(self):
        target, stale = self.root_target()
        fine = cleanup.Target("fine", cleanup.GROUP_SAFE, "Fine", action=Mock(return_value=8))
        refusal = '{"ok": false, "error": "Not directly inside a folder the helper may clean"}\n'
        status, events = self.app([target, fine], ["--select", f"{target.key},fine"], replies=refusal)
        self.assertEqual(status, 0)
        results = {e["key"]: e for e in events if e["event"] == "result"}
        self.assertFalse(results[target.key]["ok"])
        self.assertIn("Not directly inside", results[target.key]["error"])
        self.assertTrue(results["fine"]["ok"])
        self.assertEqual(events[-1]["failures"], 1)
        self.assertTrue(stale.exists())

    def test_app_that_does_not_answer_fails_the_root_removal(self):
        target, stale = self.root_target()
        for replies in ("", "not json\n"):
            with self.subTest(replies=replies):
                _, events = self.app([target], ["--select", target.key], replies=replies)
                result_event = [e for e in events if e["event"] == "result"][0]
                self.assertFalse(result_event["ok"])
                self.assertIn("MacHelm", result_event["error"])
        self.assertTrue(stale.exists())

    def test_app_names_an_unknown_key_as_an_error_and_removes_nothing(self):
        fine = cleanup.Target("fine", cleanup.GROUP_SAFE, "Fine", action=Mock(return_value=8))
        blocked = cleanup.Target("blocked", cleanup.GROUP_BLOCKED, "Blocked", state=cleanup.BLOCKED,
                                 action=Mock(return_value=8))
        for keys in ("nope", "fine,blocked"):
            with self.subTest(keys=keys):
                status, events = self.app([fine, blocked], ["--select", keys])
                self.assertEqual(status, 2)
                self.assertEqual([e["event"] for e in events], ["error"])
                self.assertIn("Not selectable", events[0]["message"])
        fine.action.assert_not_called()
        blocked.action.assert_not_called()

    def test_app_names_two_treatments_of_one_device_as_an_error(self):
        targets = self.simulators(None)
        status, events = self.app(targets, ["--select", f"sim-delete-{FIRST},sim-erase-{FIRST}"])
        self.assertEqual(status, 2)
        self.assertEqual([e["event"] for e in events], ["error"])
        self.run.assert_not_called()

    def test_app_reports_a_scan_that_could_not_run_as_an_error(self):
        with patch.object(cleanup, "discover", side_effect=cleanup.ProbeError("simctl did not answer")), \
                patch.object(cleanup.sys, "platform", "darwin"), \
                patch.object(cleanup.sys, "stdout", new_callable=io.StringIO) as output, \
                patch.object(cleanup.sys, "stderr", new_callable=io.StringIO):
            status = cleanup.main(["--app"])
        self.assertEqual(status, 1)
        self.assertEqual(json.loads(output.getvalue()), {"event": "error", "message": "simctl did not answer"})

    def test_under_the_app_no_tool_can_take_the_answer_meant_for_the_script(self):
        # The answers to root removals come on the script's input. A tool the script starts
        # inherits that input unless it is given none.
        target, _ = self.root_target()
        seen = []

        def action(dry_run):
            with patch.object(cleanup.subprocess, "run", return_value=result("12\t/x\n")) as started:
                REAL_RUN("brew", "cleanup")
                REAL_SIZE_KB(self.root)
            seen.extend(call.kwargs.get("stdin") for call in started.call_args_list)
            return 1

        probe = cleanup.Target("probe", cleanup.GROUP_SAFE, "Probe", action=action)
        status, _ = self.app([probe, target], ["--select", "probe"])
        self.assertEqual(status, 0)
        self.assertEqual(seen, [subprocess.DEVNULL, subprocess.DEVNULL])
        # In a terminal the tools keep the terminal, as before.
        seen.clear()
        status, _ = self.main([probe], ["--select", "probe"])
        self.assertEqual(status, 0)
        self.assertEqual(seen, [None, None])

    def test_outside_the_app_a_root_removal_still_asks_sudo(self):
        target, stale = self.root_target()
        status, _ = self.main([target], ["--select", target.key])
        self.assertEqual(status, 0)
        self.run.assert_any_call("sudo", "-v", timeout=120)
        self.run.assert_any_call("sudo", "rm", "-rf", str(stale))
        self.assertIsNone(cleanup.ROOT_REMOVER)

    @staticmethod
    def raise_probe_error():
        raise cleanup.ProbeError("Operation not permitted")


if __name__ == "__main__":
    unittest.main()
