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
        # main() sets these for its run; each test starts from the same instant and setting.
        self.now = time.time()
        self.stack.enter_context(patch.object(cleanup, "AS_OF", self.now))
        self.stack.enter_context(patch.object(cleanup, "IDLE_DAYS", cleanup.IDLE_DAYS_DEFAULT))

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
                     self.root / ".cache/chrome-for-testing", self.root / "hf/hub"):
            path.mkdir(parents=True)
        with patch.dict(os.environ, HF_HOME=str(self.root / "hf"),
                        PLAYWRIGHT_BROWSERS_PATH=str(browsers)):
            targets = []
            cleanup.discover_reported(targets)
        self.assertEqual({t.key for t in targets}, {"playwright-browsers", "xcode-archives",
                                                  "chrome-for-testing", "huggingface-hub"})
        self.assertTrue(all(t.state == cleanup.REPORT_ONLY and t.action is None for t in targets))
        status, _ = self.main(targets, ["--select", "chrome-for-testing"])
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
    # Simulator probe

    def probe(self, runtimes, devices):
        replies = {("list", "runtimes"): runtimes, ("list", "devices"): devices}
        with patch.object(cleanup, "simctl_json", side_effect=lambda *args: replies[args]):
            return cleanup.probe_simulators()

    def test_mac_with_no_simulators_is_an_answer_not_a_failed_probe(self):
        self.assertEqual(self.probe({"runtimes": []}, {"devices": {}}),
                         ({"runtimes": []}, {"devices": {}}))

    def test_devices_stranded_by_removed_runtimes_reach_the_cleanup_row(self):
        stranded = {"devices": {"ios-old": [DEVICES["devices"]["ios-new"][2]]}}
        targets = []
        with patch.object(cleanup, "simctl_json",
                          side_effect=lambda *args: {"runtimes": []} if "runtimes" in args else stranded), \
                patch.object(cleanup, "runtime_images", return_value={}), \
                patch.object(cleanup, "sdk_runtime_versions", return_value=None), \
                patch.object(cleanup, "host_build", return_value=None):
            cleanup.discover_simulators(targets)
        self.assertEqual([t.key for t in targets], ["sim-unavailable-devices"])

    def test_reply_without_its_lists_is_a_failed_probe(self):
        for runtimes, devices in (({}, {"devices": {}}), ({"runtimes": []}, {}),
                                  ([], {"devices": {}}), ({"runtimes": []}, {"devices": {"x": None}})):
            with self.subTest(runtimes=runtimes, devices=devices), \
                    self.assertRaisesRegex(cleanup.ProbeError, "without its runtimes or devices"):
                self.probe(runtimes, devices)

    def test_available_devices_without_runtimes_is_a_failed_probe(self):
        with self.assertRaisesRegex(cleanup.ProbeError, "available devices but no runtimes"):
            self.probe({"runtimes": []}, DEVICES)

    def test_device_folders_simctl_did_not_list_is_a_failed_probe(self):
        folder = self.root / "devices" / FIRST
        folder.mkdir(parents=True)
        (folder / "device.plist").write_bytes(b"")
        with self.assertRaisesRegex(cleanup.ProbeError, "1 folder under .* hold a device.plist"):
            self.probe({"runtimes": []}, {"devices": {}})

    # -----------------------------------------------------------------------------------------
    # A failed probe costs its own scan and stays in view

    def scan(self, discoverers, argv=None):
        """The real discovery behind the named scans: the script's own targets, or main's output."""
        replies = {("list", "runtimes"): {}, ("list", "devices"): DEVICES}  # no runtimes list
        with patch.object(cleanup, "DISCOVERERS", discoverers), \
                patch.object(cleanup, "simctl_json", side_effect=lambda *args: replies[args]), \
                patch.object(cleanup.sys, "platform", "darwin"), \
                patch.object(cleanup.sys, "stdout", new_callable=io.StringIO) as output, \
                patch.object(cleanup.sys, "stderr", new_callable=io.StringIO):
            if argv is None:
                return cleanup.discover()
            return cleanup.main(argv), output.getvalue()

    def test_failed_probe_withholds_only_its_own_scan_and_names_it(self):
        cache = cleanup.Target("cache", cleanup.GROUP_SAFE, "Cache", selected=True,
                               paths=[self.root / "cache"], action=Mock())
        backup = cleanup.Target("backup", cleanup.GROUP_REPORT, "Backup", state=cleanup.REPORT_ONLY,
                                paths=[self.root / "backup"])
        discoverers = [lambda ts: ts.append(cache), cleanup.discover_simulators,
                       lambda ts: ts.append(backup)]
        targets = self.scan(discoverers)
        self.assertEqual([t.key for t in targets], ["scan-failed-simulators", "cache", "backup"])
        failed = targets[0]
        self.assertEqual((failed.state, failed.group, failed.label),
                         (cleanup.BLOCKED, cleanup.GROUP_FAILED, "Simulators and runtimes"))
        self.assertIn("without its runtimes or devices list", failed.detail)
        # Not a scan that found nothing: unknown, never zero, and never selectable.
        self.assertEqual({k: failed.as_json()[k] for k in ("size_kb", "projected_kb", "default_selected")},
                         {"size_kb": None, "projected_kb": None, "default_selected": False})
        self.assertEqual(cleanup.value_of(failed), "unknown")
        self.assertEqual((cache.state, cache.selected, cache.size_kb, backup.size_kb),
                         (cleanup.SELECTABLE, True, 1024, 1024))
        output = io.StringIO()
        cleanup.print_table(targets, output)
        self.assertIn(cleanup.GROUP_FAILED, output.getvalue())
        self.assertIn("Simulators and runtimes: simctl answered without", output.getvalue())

        # MacHelm gets every row in its one targets event, the failed scan among them, instead
        # of an error in place of the whole list.
        status, output = self.scan(discoverers, ["--app"])
        self.assertEqual(status, 0)
        events = [json.loads(line) for line in output.splitlines()]
        # Scanning progress comes first; the rows come in one event.
        self.assertEqual([e["event"] for e in events if e["event"] != "progress"], ["targets"])
        self.assertTrue(all(e["phase"] == "scanning" for e in events if e["event"] == "progress"))
        events = [e for e in events if e["event"] == "targets"]
        listed = {t["key"]: t for t in events[0]["targets"]}
        self.assertEqual(set(listed), {"scan-failed-simulators", "cache", "backup"})
        self.assertEqual(listed["scan-failed-simulators"]["state"], "blocked")
        status, output = self.scan(discoverers, ["--json"])
        self.assertEqual(status, 0)
        self.assertIn("scan-failed-simulators", [t["key"] for t in json.loads(output)])
        cache.action.assert_not_called()

    def test_rows_a_scan_listed_before_its_probe_failed_are_withheld(self):
        def half_done(targets):
            targets.append(cleanup.Target("partial", cleanup.GROUP_SAFE, "Partial", selected=True))
            raise cleanup.ProbeError("simctl stopped answering")

        targets = self.scan([half_done])
        self.assertEqual([(t.key, t.label, t.detail) for t in targets],
                         [("scan-failed-half_done", "half done", "simctl stopped answering")])

    def test_app_refusing_a_key_names_the_scan_that_failed(self):
        # The owner checked a simulator in an earlier scan; the Clean's own scan cannot list it.
        fine = cleanup.Target("fine", cleanup.GROUP_SAFE, "Fine", action=Mock(return_value=8))
        targets = self.scan([cleanup.discover_simulators]) + [fine]
        status, events = self.app(targets, ["--select", f"sim-delete-{FIRST},fine"])
        self.assertEqual(status, 2)
        self.assertEqual([e["event"] for e in events], ["error"])
        self.assertIn(f"Not selectable: sim-delete-{FIRST}.", events[0]["message"])
        self.assertIn("Simulators and runtimes not scanned: simctl answered without",
                      events[0]["message"])
        fine.action.assert_not_called()

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

    def test_a_partly_removed_target_shows_what_it_freed_and_each_line_of_why(self):
        why = "Codex kept 1 of 3 chats.\n“Drain plans”: a chat forked from it is still there."
        part = cleanup.Target("part", cleanup.GROUP_SAFE, "Part", selected=True,
                              action=Mock(side_effect=cleanup.PartlyRemoved(why, 2048)))
        status, output = self.main([part], ["--yes"])
        self.assertEqual(status, 0)
        self.assertIn("partly removed: Codex kept 1 of 3 chats.", output)
        self.assertIn("“Drain plans”: a chat forked from it is still there.", output)
        self.assertIn("1 target did not complete", output)
        # What went counts in the total.
        self.assertRegex(output, r"reclaimed\s+2\.0 MiB")

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
        self.assertEqual({e["event"] for e in events}, {"progress", "working", "result", "done"})
        # Each target is announced before its result, and the count runs to the end.
        for key in ("fine", "broken"):
            started = events.index({"event": "working", "key": key, "detail": ""})
            finished = next(i for i, e in enumerate(events) if e["event"] == "result" and e["key"] == key)
            self.assertLess(started, finished)
        progress = [e for e in events if e["event"] == "progress"]
        self.assertEqual(progress[0], {"event": "progress", "phase": "deleting", "done": 0, "total": 2})
        self.assertEqual(progress[-1], {"event": "progress", "phase": "deleting", "done": 2, "total": 2})

    def test_app_run_counts_what_a_partly_removed_target_freed(self):
        why = "Codex kept 1 of 3 chats.\n“Drain plans”: a chat forked from it is still there."
        part = cleanup.Target("part", cleanup.GROUP_OWN, "Part",
                              action=Mock(side_effect=cleanup.PartlyRemoved(why, 512)))
        fine = cleanup.Target("fine", cleanup.GROUP_SAFE, "Fine", action=Mock(return_value=2048))
        status, events = self.app([part, fine], ["--select", "part,fine"])
        self.assertEqual(status, 0)
        results = {e["key"]: e for e in events if e["event"] == "result"}
        self.assertEqual(results["part"], {"event": "result", "key": "part", "ok": False,
                                           "freed_kb": 512, "error": why})
        self.assertEqual(events[-1], {"event": "done", "reclaimed_kb": 2560, "failures": 1,
                                      "free_kb": 1024 * 1024})

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


DAY = 86400
GIT_ENV = {"GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
           "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
           "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"}
CHAT_IDS = [f"01a00000-0000-7000-8000-{i:012d}" for i in range(1, 6)]
SESSION_IDS = [f"5e5510{i:02d}-0000-4000-8000-000000000000" for i in range(1, 4)]


def age(path, days, now):
    """Set a tree's modification times `days` before `now`."""
    stamp = now - days * DAY
    for root, dirs, files in os.walk(path):
        for name in files + dirs:
            os.utime(os.path.join(root, name), (stamp, stamp), follow_symlinks=False)
    os.utime(path, (stamp, stamp), follow_symlinks=False)


class BeyondDeveloperToolsTests(unittest.TestCase):
    """ADR 0008: app caches, update downloads, chats, sessions, worktrees, backups, the Trash."""

    setUp = CleanupTests.setUp
    main = CleanupTests.main
    app = CleanupTests.app
    pick = CleanupTests.pick

    def tools(self, **answers):
        """`run` answering by command: a callable or a CompletedProcess per program name."""
        def fake(*argv, **_):
            answer = answers.get(argv[0], result())
            return answer(*argv) if callable(answer) else answer
        self.run.side_effect = fake

    def apps(self, **names):
        """Spotlight's answer: Finder, and each app name=bundle identifier given."""
        listed = {"com.apple.finder": [Path("/System/Library/CoreServices/Finder.app")]}
        for name, ident in names.items():
            listed[ident.lower()] = [Path(f"/Applications/{name.replace('_', ' ')}.app")]
        return self.stack.enter_context(patch.object(cleanup, "installed_apps", return_value=listed))

    def discovered(self, discoverer):
        targets = []
        discoverer(targets)
        return {t.key: t for t in targets}

    # Update downloads ---------------------------------------------------------------------

    def test_update_downloads_keep_the_newest_and_what_arrived_after_the_scan(self):
        self.apps(Telegram="ru.keepcoder.Telegram")
        downloads = self.root / "Library/Caches/ru.keepcoder.Telegram/org.sparkle-project.Sparkle/PersistentDownloads"
        for name, days in (("first", 3), ("second", 2), ("newest", 1), ("later", -1)):
            (downloads / name).mkdir(parents=True)
            age(downloads / name, days, self.now)
        pending = self.root / "Library/Application Support/Caches/cursor-updater/pending"
        pending.mkdir(parents=True)
        (pending / "Cursor-1.zip").write_text("x")
        (pending / "update-info.json").write_text("{}")
        targets = self.discovered(cleanup.discover_update_downloads)
        [row] = targets.values()
        self.assertEqual((row.group, row.kind, row.selected), (cleanup.GROUP_SAFE, "Update downloads", True))
        self.assertEqual(row.label, "Telegram: 2 older update downloads")
        row.action(False)
        self.assertEqual(sorted(p.name for p in downloads.iterdir()), ["later", "newest"])

    # App caches ---------------------------------------------------------------------------

    def figma(self):
        self.apps(Figma="com.figma.Desktop")
        caches = self.root / "Library/Caches/com.figma.Desktop"
        caches.mkdir(parents=True)
        support = self.root / "Library/Application Support/Figma"
        for name in ("Cache", "Code Cache", "DesktopProfile/v42/GPUCache",
                     "Service Worker/CacheStorage", "IndexedDB", "Local Storage"):
            (support / name).mkdir(parents=True)
        for marker in ("Preferences", "DesktopProfile/v42/Preferences"):
            (support / marker).write_text("{}")
        return caches, support

    def test_a_folder_named_cache_outside_chromium_is_not_taken(self):
        self.apps(Anki="net.ankiweb.dtop")
        data = self.root / "Library/Application Support/Anki"
        (data / "User 1/Cache").mkdir(parents=True)
        (data / "User 1/collection.anki2").write_text("x")
        self.assertEqual(self.discovered(cleanup.discover_app_caches), {})

    def test_app_cache_takes_only_cache_folders_and_is_checked_while_the_app_is_quit(self):
        caches, support = self.figma()
        self.tools(ps=result("/usr/sbin/cfprefsd agent\n"))
        row = self.discovered(cleanup.discover_app_caches)[
            f"app-cache-{cleanup.stable_id('Figma', 'com.figma.desktop')}"]
        self.assertEqual((row.state, row.selected, row.kind), (cleanup.SELECTABLE, True, "App caches"))
        self.assertEqual(set(row.paths), {caches, support / "Cache", support / "Code Cache",
                                          support / "DesktopProfile/v42/GPUCache"})
        self.assertEqual(row.min_kb, cleanup.MIN_APP_CACHE_KB)
        row.action(False)
        self.assertFalse((support / "Cache").exists())
        self.assertTrue((support / "Service Worker/CacheStorage").is_dir())
        self.assertTrue((support / "IndexedDB").is_dir())

    def test_app_cache_is_blocked_while_its_app_runs_and_checked_again_before_removal(self):
        _, support = self.figma()
        running = result("/Applications/Figma.app/Contents/Frameworks/Figma Helper.app/Contents/MacOS/Figma Helper\n")
        self.tools(ps=running)
        [row] = self.discovered(cleanup.discover_app_caches).values()
        self.assertEqual((row.state, row.selected), (cleanup.BLOCKED, False))
        self.assertIn("Figma is running", row.detail)
        self.tools(ps=result(""))
        [row] = self.discovered(cleanup.discover_app_caches).values()
        self.tools(ps=running)
        with self.assertRaisesRegex(RuntimeError, "Figma is running"):
            row.action(False)
        self.assertTrue((support / "Cache").is_dir())

    def test_app_cache_leaves_update_downloads_and_dot_files_to_others(self):
        self.apps(Brave_Browser="com.brave.Browser")
        folder = self.root / "Library/Caches/com.brave.Browser"
        (folder / "org.sparkle-project.Sparkle").mkdir(parents=True)
        (folder / "WebKit").mkdir()
        (folder / ".DS_Store").write_text("x")
        [row] = self.discovered(cleanup.discover_app_caches).values()
        self.assertEqual(row.paths, [folder / "WebKit"])

    def test_rows_under_their_threshold_are_dropped_unless_a_clean_names_them(self):
        small = cleanup.Target("small", cleanup.GROUP_SAFE, "Small", paths=[self.root],
                               min_kb=2048, selected=True)
        with patch.object(cleanup, "DISCOVERERS", [lambda targets: targets.append(copy.copy(small))]):
            self.assertEqual(cleanup.discover(), [])
            self.assertEqual([t.key for t in cleanup.discover(keep={"small"})], ["small"])

    def test_a_reported_folder_counts_only_what_other_rows_inside_it_do_not(self):
        folder, cache = self.root / "App", self.root / "App/Cache"
        cache.mkdir(parents=True)
        self.size.side_effect = lambda path: {folder: 5000, cache: 3000}[path]
        rows = [cleanup.Target("app-data", cleanup.GROUP_REPORT, "App data", state=cleanup.REPORT_ONLY,
                               paths=[folder], net_of_others=True, min_kb=1000),
                cleanup.Target("app-cache", cleanup.GROUP_SAFE, "App", paths=[cache])]
        with patch.object(cleanup, "DISCOVERERS", [lambda targets: targets.extend(copy.copy(r) for r in rows)]):
            by_key = {t.key: t for t in cleanup.discover()}
        self.assertEqual((by_key["app-data"].size_kb, by_key["app-cache"].size_kb), (2000, 3000))
        self.size.side_effect = lambda path: {folder: 3500, cache: 3000}[path]
        with patch.object(cleanup, "DISCOVERERS", [lambda targets: targets.extend(copy.copy(r) for r in rows)]):
            self.assertEqual([t.key for t in cleanup.discover()], ["app-cache"])
        # A row too small to be listed is not taken out of the folder that holds it.
        small = copy.copy(rows[1])
        small.min_kb = 4000
        with patch.object(cleanup, "DISCOVERERS", [lambda targets: targets.extend([copy.copy(rows[0]), copy.copy(small)])]):
            self.assertEqual([(t.key, t.size_kb) for t in cleanup.discover()], [("app-data", 3500)])

    # Temporary files ----------------------------------------------------------------------

    def test_pytest_runs_wait_for_pytest_and_compiler_caches_are_listed(self):
        temp, cache = self.root / "T", self.root / "C"
        (temp / "pytest-of-owner/pytest-7").mkdir(parents=True)
        (cache / "clang/ModuleCache/x").mkdir(parents=True)
        (cache / "com.apple.dt.Instruments/y").mkdir(parents=True)
        self.stack.enter_context(patch.dict(os.environ, TMPDIR=str(temp), USER="owner"))
        self.tools(getconf=result(f"{cache}\n"), ps=result("/opt/homebrew/bin/python3 -m pytest -q\n"))
        rows = self.discovered(cleanup.discover_temp_files)
        self.assertEqual((rows["pytest-runs"].state, rows["pytest-runs"].selected), (cleanup.BLOCKED, False))
        self.assertTrue(rows["clang-module-cache"].selected)
        self.assertEqual((rows["instruments-cache"].group, rows["instruments-cache"].selected),
                         (cleanup.GROUP_COSTLY, False))
        self.tools(getconf=result(f"{cache}\n"), ps=result("/usr/bin/login\n"))
        runs = self.discovered(cleanup.discover_temp_files)["pytest-runs"]
        self.assertEqual((runs.state, runs.selected), (cleanup.SELECTABLE, True))
        runs.action(False)
        self.assertFalse((temp / "pytest-of-owner").exists())

    # Codex chats --------------------------------------------------------------------------

    def chat(self, folder, ident, cwd, days=0, at="2026-09-01T10-00-00", rollout=None, **meta):
        """A chat file begun `at`; a `rollout` id makes it a later file of the same chat."""
        name = f"rollout-{at}-{ident}" + (f"_{rollout}" if rollout else "") + ".jsonl"
        path = self.root / "codex" / folder / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({"type": "session_meta",
                                    "payload": {"id": ident, "cwd": cwd, **meta}}) + "\n")
        age(path, days, self.now)
        return path

    def codex(self, deletes=None, spawned=None, refuse=()):
        """A `codex` that deletes as Codex 0.162 does. A chat goes with the subagents it `spawned`.
        It stays while a chat forked from it remains, when Codex cannot find it, and when Codex
        will not let it go (`refuse`), and each time Codex says only "failed to delete session"."""
        home = self.root / "codex"
        refused = result(returncode=1, stderr="Error: failed to delete session")

        def files(ident):
            return [p for p in home.rglob("rollout-*.jsonl*")
                    if cleanup.ROLLOUT_ID.search(p.name).group(1) == ident]

        def forks(ident):
            return {cleanup.ROLLOUT_ID.search(p.name).group(1)
                    for p in home.rglob("rollout-*.jsonl")
                    if (json.loads(p.read_text().splitlines()[0])["payload"].get("history_base")
                        or {}).get("thread_id") == ident}

        def answer(*argv):
            if argv[1:3] == ("delete", "--help"):
                return result("      --force\n          Delete without prompting.")
            if argv[1:3] == ("delete", "--force"):
                ident = argv[3]
                if deletes is not None:
                    deletes.append(ident)
                going = {ident, *(spawned or {}).get(ident, ())}
                if ident in refuse or not files(ident) or forks(ident) - going:
                    return refused
                for each in going:
                    for path in files(each):
                        path.unlink()
                return result(f"Deleted session {ident}.")
            return result()
        self.tools(codex=answer)
        self.stack.enter_context(patch.dict(os.environ, CODEX_HOME=str(home)))
        # The scan starts once the chats exist: archiving one set its ctime to the moment it was written.
        self.stack.enter_context(patch.object(cleanup, "AS_OF", time.time() + 1))

    def named(self, names):
        """Codex's session index: the name it shows for each chat, by chat id."""
        index = self.root / "codex/session_index.jsonl"
        index.parent.mkdir(parents=True, exist_ok=True)
        index.write_text("".join(json.dumps({"id": ident, "thread_name": name}) + "\n"
                                 for ident, name in names.items()))

    def test_archived_and_idle_codex_chats_are_grouped_by_folder_and_deleted_by_codex(self):
        archived = self.chat("archived_sessions", CHAT_IDS[0], "/work/app")
        idle = self.chat("sessions/2026/09/01", CHAT_IDS[1], "/work/app", days=8)
        recent = self.chat("sessions/2026/10/14", CHAT_IDS[2], "/work/app", days=1)
        self.chat("sessions/2026/09/02", CHAT_IDS[3], "/other/app", days=30)
        deletes = []
        self.codex(deletes)
        rows = self.discovered(cleanup.discover_codex_chats)
        # Keys come from the folder alone, so they hold when the other "app" folder goes.
        archived_row = rows[f"codex-archived-{cleanup.stable_id('app', '/work/app')}"]
        idle_row = rows[f"codex-idle-{cleanup.stable_id('app', '/work/app')}"]
        self.assertEqual((archived_row.group, archived_row.kind, archived_row.selected),
                         (cleanup.GROUP_OWN, "Codex archived chats", False))
        self.assertEqual(idle_row.kind, "Codex chats idle 7+ days")
        # Two folders named "app": each label says which.
        self.assertEqual(sorted(t.label for t in rows.values()),
                         ["other/app: 1 chat", "work/app: 1 chat", "work/app: 1 chat"])
        archived_row.action(False)
        self.assertEqual(deletes, [CHAT_IDS[0]])
        self.assertFalse(archived.exists())
        self.assertTrue(idle.exists() and recent.exists())

    def test_a_chat_archived_after_the_scan_began_is_not_offered(self):
        self.chat("archived_sessions", CHAT_IDS[0], "/work/app")
        self.codex()
        with patch.object(cleanup, "AS_OF", time.time() - 100):
            self.assertEqual(self.discovered(cleanup.discover_codex_chats), {})

    def test_without_codex_delete_the_chats_are_blocked(self):
        self.chat("archived_sessions", CHAT_IDS[0], "/work/app")
        self.codex()
        self.tools(codex=result(returncode=2, stderr="unrecognized subcommand 'delete'"))
        [row] = self.discovered(cleanup.discover_codex_chats).values()
        self.assertEqual((row.state, row.action), (cleanup.BLOCKED, None))
        self.assertIn("codex delete --force", row.detail)

    def test_chats_go_newest_first_so_subagents_and_forks_go_before_their_parent(self):
        # On 2026-10-15 a Clean went oldest first. Each parent took its subagents with it, and
        # Codex then failed on every subagent, so 17 rows said "not removed" with their chats gone.
        # A chat forked from another kept that one, because it was asked about first.
        parent = self.chat("archived_sessions", CHAT_IDS[0], "/work/app")
        spawn = {"subagent": {"thread_spawn": {"parent_thread_id": CHAT_IDS[0]}}}
        subagents = [self.chat("archived_sessions", ident, "/work/app", at=at, source=spawn)
                     for ident, at in ((CHAT_IDS[1], "2026-09-01T10-05-00"),
                                       (CHAT_IDS[2], "2026-09-01T10-06-00"))]
        fork = self.chat("archived_sessions", CHAT_IDS[3], "/work/app", at="2026-09-02T09-00-00",
                         history_base={"thread_id": CHAT_IDS[0]})
        deletes = []
        self.codex(deletes, spawned={CHAT_IDS[0]: CHAT_IDS[1:3]})
        [row] = self.discovered(cleanup.discover_codex_chats).values()
        self.assertEqual(row.action(False), row.size_kb)
        self.assertEqual(deletes, [CHAT_IDS[3], CHAT_IDS[2], CHAT_IDS[1], CHAT_IDS[0]])
        self.assertFalse([p for p in (parent, fork, *subagents) if p.exists()])

    def test_a_chat_that_went_with_another_counts_as_removed_without_asking_codex(self):
        self.chat("archived_sessions", CHAT_IDS[0], "/work/app")
        subagent = self.chat("archived_sessions", CHAT_IDS[1], "/work/elsewhere",
                             at="2026-09-01T10-05-00")
        packed = self.chat("archived_sessions", CHAT_IDS[2], "/work/elsewhere",
                           at="2026-09-01T11-00-00")
        deletes = []
        self.codex(deletes, spawned={CHAT_IDS[0]: [CHAT_IDS[1]]})
        rows = self.discovered(cleanup.discover_codex_chats)
        first = rows[f"codex-archived-{cleanup.stable_id('app', '/work/app')}"]
        second = rows[f"codex-archived-{cleanup.stable_id('elsewhere', '/work/elsewhere')}"]
        first.action(False)
        self.assertFalse(subagent.exists())
        # Codex compressed this one after the scan: it is still there, so Codex is asked.
        packed.rename(packed.with_name(packed.name + ".zst"))
        self.assertEqual(second.action(False), second.size_kb)
        self.assertEqual(deletes, [CHAT_IDS[0], CHAT_IDS[2]])
        self.assertEqual(list((self.root / "codex/archived_sessions").iterdir()), [])

    def test_a_later_file_of_a_chat_belongs_to_that_chat(self):
        first = self.chat("archived_sessions", CHAT_IDS[0], "/work/app")
        later = self.chat("archived_sessions", CHAT_IDS[0], "/work/app", at="2026-09-03T08-00-00",
                          rollout=CHAT_IDS[4])
        deletes = []
        self.codex(deletes)
        [row] = self.discovered(cleanup.discover_codex_chats).values()
        self.assertEqual(row.label, "app: 1 chat")
        self.assertEqual(row.action(False), row.size_kb)
        # The chat's own id, which Codex knows, not the id of its later file.
        self.assertEqual(deletes, [CHAT_IDS[0]])
        self.assertFalse(first.exists() or later.exists())

    def test_chats_codex_keeps_are_named_with_why_and_what_went_still_counts(self):
        kept = self.chat("archived_sessions", CHAT_IDS[0], "/work/app")
        # A chat forked from it that is in use, so it is not offered.
        self.chat("sessions/2026/10/14", CHAT_IDS[1], "/work/app", days=1, at="2026-10-14T09-00-00",
                  history_base={"thread_id": CHAT_IDS[0]})
        stuck = self.chat("archived_sessions", CHAT_IDS[2], "/work/app", at="2026-09-01T11-00-00")
        gone = self.chat("archived_sessions", CHAT_IDS[3], "/work/app", at="2026-09-01T12-00-00")
        gone_kb = gone.lstat().st_blocks // 2
        self.named({CHAT_IDS[0]: "Drain plans", CHAT_IDS[1]: "Plan fork"})
        deletes = []
        self.codex(deletes, refuse={CHAT_IDS[2]})
        [row] = self.discovered(cleanup.discover_codex_chats).values()
        self.assertEqual(row.label, "app: 3 chats")
        with self.assertRaises(cleanup.PartlyRemoved) as caught:
            row.action(False)
        self.assertEqual(caught.exception.freed_kb, gone_kb)
        self.assertEqual(str(caught.exception).splitlines(), [
            "Codex kept 2 of 3 chats.",
            f"{CHAT_IDS[2]}: Codex refused and gave no reason; the chat may be open in Codex.",
            "“Drain plans”: a chat forked from it is still there (“Plan fork”).",
        ])
        self.assertEqual(deletes, [CHAT_IDS[3], CHAT_IDS[2], CHAT_IDS[0]])
        self.assertTrue(kept.exists() and stuck.exists())
        self.assertFalse(gone.exists())

    def test_a_row_codex_keeps_whole_frees_nothing_and_names_five_chats(self):
        idents = [f"01a00000-0000-7000-8000-{i:012d}" for i in range(1, 8)]
        for index, ident in enumerate(idents):
            self.chat("archived_sessions", ident, "/work/app", at=f"2026-09-01T10-0{index}-00")
        self.codex(refuse=set(idents))
        [row] = self.discovered(cleanup.discover_codex_chats).values()
        with self.assertRaises(RuntimeError) as caught:
            row.action(False)
        self.assertNotIsInstance(caught.exception, cleanup.PartlyRemoved)
        lines = str(caught.exception).splitlines()
        self.assertEqual((lines[0], len(lines), lines[-1]),
                         ("Codex kept 7 of 7 chats.", 7, "And 2 more."))
        # Newest first, as they were asked.
        self.assertTrue(lines[1].startswith(idents[-1]))

    def test_a_chat_codex_hangs_on_fails_alone_and_the_next_is_still_tried(self):
        self.chat("archived_sessions", CHAT_IDS[0], "/work/app")
        self.chat("archived_sessions", CHAT_IDS[1], "/work/app", at="2026-09-01T11-00-00")
        deletes = []
        self.codex()
        [row] = self.discovered(cleanup.discover_codex_chats).values()

        def hangs_once(*argv):
            deletes.append(argv[3])
            if len(deletes) == 1:
                raise subprocess.TimeoutExpired(argv, 300)
            for path in (self.root / "codex").rglob(f"*{argv[3]}.jsonl"):
                path.unlink()
            return result()
        self.tools(codex=hangs_once)
        with self.assertRaises(cleanup.PartlyRemoved) as caught:
            row.action(False)
        self.assertEqual(str(caught.exception).splitlines(),
                         ["Codex kept 1 of 2 chats.",
                          f"{CHAT_IDS[1]}: Codex did not finish within 5 minutes."])
        self.assertEqual(deletes, [CHAT_IDS[1], CHAT_IDS[0]])

    # Claude Code sessions -----------------------------------------------------------------

    def claude(self):
        base = self.root / "claude"
        project = base / "projects/-work-proj"
        (project / "memory").mkdir(parents=True)
        (project / "memory/MEMORY.md").write_text("- kept")
        old, current = SESSION_IDS[0], SESSION_IDS[1]
        (project / f"{old}.jsonl").write_text(json.dumps({"type": "user", "cwd": "/work/proj"}) + "\n")
        (project / old / "subagents").mkdir(parents=True)
        (project / old / "subagents/agent-a.jsonl").write_text("{}\n")
        (base / "file-history" / old).mkdir(parents=True)
        (base / "file-history" / old / "edit@v1").write_text("x")
        (project / f"{current}.jsonl").write_text(json.dumps({"cwd": "/work/proj"}) + "\n")
        for path in (project, base / "file-history" / old):
            age(path, 9, self.now)
        os.utime(project / f"{current}.jsonl", (self.now, self.now))
        self.stack.enter_context(patch.dict(os.environ, CLAUDE_CONFIG_DIR=str(base)))
        return base, project, old, current

    def test_idle_claude_sessions_go_whole_and_memory_stays(self):
        base, project, old, current = self.claude()
        [row] = self.discovered(cleanup.discover_claude_sessions).values()
        self.assertEqual((row.label, row.kind, row.group, row.selected),
                         ("proj: 1 session", "Claude Code sessions idle 7+ days", cleanup.GROUP_OWN, False))
        row.action(False)
        self.assertFalse((project / f"{old}.jsonl").exists() or (project / old).exists())
        self.assertFalse((base / "file-history" / old).exists())
        self.assertEqual((project / "memory/MEMORY.md").read_text(), "- kept")
        self.assertTrue((project / f"{current}.jsonl").exists())

    def test_a_session_resumed_after_the_scan_is_kept(self):
        _, project, old, _ = self.claude()
        [row] = self.discovered(cleanup.discover_claude_sessions).values()
        os.utime(project / f"{old}.jsonl", (self.now, self.now))
        self.assertEqual(row.action(False), 0)
        self.assertTrue((project / f"{old}.jsonl").exists())

    # Worktrees ----------------------------------------------------------------------------

    def git(self, folder, *args):
        return subprocess.run(["git", "-C", str(folder), "-c", "commit.gpgsign=false", *args],
                              check=True, capture_output=True, text=True,
                              env={**GIT_ENV, "HOME": str(self.root)}).stdout.strip()

    def commit(self, folder, name, text="x"):
        (folder / name).write_text(text)
        self.git(folder, "add", name)
        self.git(folder, "commit", "-q", "-m", name)
        return self.git(folder, "rev-parse", "HEAD")

    def repository(self):
        repo = self.root / "dev/app"
        repo.mkdir(parents=True)
        self.git(repo, "init", "-q", "-b", "main")
        self.commit(repo, "README")
        (self.root / ".claude.json").write_text(json.dumps({"projects": {str(repo): {}}}))
        return repo

    def worktree(self, repo, name, branch=None):
        path = repo / ".claude/worktrees" / name
        self.git(repo, "worktree", "add", "-q", *(["-b", branch] if branch else ["--detach"]), str(path))
        return path

    def worktree_rows(self):
        return {t.label.split(": ", 1)[1]: t for t in self.discovered(cleanup.discover_worktrees).values()}

    def test_worktrees_are_merged_idle_or_blocked_with_the_reason(self):
        repo = self.repository()
        merged = self.worktree(repo, "merged", "claude/merged")
        self.commit(merged, "feature")
        self.git(repo, "merge", "-q", "--ff-only", "claude/merged")
        rebased = self.worktree(repo, "rebased")
        work = self.commit(rebased, "rebased-work")
        self.git(repo, "cherry-pick", work)  # in main by content, not by history
        idle = self.worktree(repo, "idle")
        self.commit(idle, "idle-work")
        active = self.worktree(repo, "active")
        self.commit(active, "active-work")
        for path in (merged, rebased, idle):
            age(path, 10, self.now)
        rows = self.worktree_rows()
        self.assertEqual({name: (row.kind, row.state) for name, row in rows.items()}, {
            "merged": ("Merged worktrees", cleanup.SELECTABLE),
            "rebased": ("Merged worktrees", cleanup.SELECTABLE),
            "idle": ("Idle worktrees (7+ days)", cleanup.SELECTABLE),
            "active": ("Idle worktrees (7+ days)", cleanup.BLOCKED),
        })
        self.assertIn("holds work found nowhere else", rows["active"].detail)
        self.assertTrue(all(row.group == cleanup.GROUP_OWN and not row.selected for row in rows.values()))

    def test_a_merged_worktree_with_edits_leaves_a_snapshot_and_loses_its_merged_branch(self):
        repo = self.repository()
        path = self.worktree(repo, "dirty", "claude/dirty")
        self.commit(path, "feature")
        self.git(repo, "merge", "-q", "--ff-only", "claude/dirty")
        (path / "feature").write_text("edited")
        (path / "notes.txt").write_text("untracked")
        row = self.worktree_rows()["dirty"]
        self.assertIn("2 uncommitted files are kept in a snapshot", row.detail)
        row.action(False)
        self.assertFalse(path.exists())
        self.assertEqual(self.git(repo, "branch", "--list", "claude/dirty"), "")
        ref = "refs/machelm/worktrees/claude-dirty"
        self.assertEqual(self.git(repo, "show", f"{ref}:feature"), "edited")
        self.assertEqual(self.git(repo, "show", f"{ref}:notes.txt"), "untracked")
        self.assertEqual(self.git(repo, "worktree", "list", "--porcelain").count("worktree "), 1)

    def test_an_idle_worktree_keeps_its_unmerged_commits_and_branch(self):
        repo = self.repository()
        detached = self.worktree(repo, "detached")
        lost = self.commit(detached, "only-here")
        branched = self.worktree(repo, "branched", "claude/branched")
        kept = self.commit(branched, "on-branch")
        for path in (detached, branched):
            age(path, 30, self.now)
        rows = self.worktree_rows()
        rows["detached"].action(False)
        rows["branched"].action(False)
        self.assertEqual(self.git(repo, "rev-parse", "refs/machelm/worktrees/claude-detached^"), lost)
        self.assertEqual(self.git(repo, "rev-parse", "claude/branched"), kept)
        self.assertFalse(detached.exists() or branched.exists())

    def test_a_worktree_in_use_is_blocked_and_checked_again_before_removal(self):
        repo = self.repository()
        path = self.worktree(repo, "busy")
        listing = result(f"p4242\ncclaude\nn{path.resolve()}/src\n")
        self.tools(lsof=listing)
        row = self.worktree_rows()["busy"]
        self.assertEqual(row.state, cleanup.BLOCKED)
        self.assertIn("in use by claude (process 4242)", row.detail)
        self.tools(lsof=result(""))
        row = self.worktree_rows()["busy"]
        self.tools(lsof=listing)
        with self.assertRaisesRegex(RuntimeError, "in use by claude"):
            row.action(False)
        self.assertTrue(path.is_dir())

    def test_codex_worktrees_are_found_in_codex_home(self):
        repo = self.repository()
        path = self.root / "codex/worktrees/cd3c/app"
        self.git(repo, "worktree", "add", "-q", "--detach", str(path))
        (self.root / "codex/worktrees/empty").mkdir()
        (self.root / "codex/worktrees/empty/.codex-worktree-name").write_text("")
        self.stack.enter_context(patch.dict(os.environ, CODEX_HOME=str(self.root / "codex")))
        rows = self.discovered(cleanup.discover_worktrees)
        self.assertEqual([t.label for t in rows.values()], ["app (Codex cd3c)"])
        self.assertEqual(next(iter(rows.values())).kind, "Merged worktrees")

    # Backups, the Trash, apps that are gone -----------------------------------------------

    def locked(self, folder):
        folder.mkdir(parents=True)
        os.chmod(folder, 0)
        self.addCleanup(os.chmod, folder, 0o755)

    def test_backups_macos_keeps_from_the_script_ask_for_full_disk_access(self):
        self.locked(self.root / "Library/Application Support/MobileSync/Backup")
        [row] = self.discovered(cleanup.discover_device_backups).values()
        self.assertEqual((row.state, row.needs_fda, row.size_kb), (cleanup.BLOCKED, True, None))
        self.assertTrue(row.as_json()["needs_full_disk_access"])

    def test_each_device_backup_is_its_own_unchecked_row(self):
        root = self.root / "Library/Application Support/MobileSync/Backup"
        backup = root / "00008110-000A1B2C3D4E"
        backup.mkdir(parents=True)
        with open(backup / "Info.plist", "wb") as handle:
            plistlib.dump({"Device Name": "Owner's iPhone", "Product Name": "iPhone 15",
                           "Last Backup Date": cleanup.datetime(2026, 9, 1, 8, 0)}, handle)
        [row] = self.discovered(cleanup.discover_device_backups).values()
        self.assertEqual((row.label, row.group, row.kind, row.selected),
                         ("Owner's iPhone (iPhone 15)", cleanup.GROUP_OWN, "iPhone and iPad backups", False))
        self.assertEqual(row.last_used_at, "2026-09-01T08:00:00Z")
        row.action(False)
        self.assertFalse(backup.exists())

    def test_the_trash_is_emptied_by_finder_and_needs_no_access_to_be_chosen(self):
        self.locked(self.root / ".Trash")
        [row] = self.discovered(cleanup.discover_trash).values()
        self.assertEqual((row.state, row.selected, row.needs_fda, row.size_kb),
                         (cleanup.SELECTABLE, False, True, None))
        self.assertIsNone(row.as_json()["projected_kb"])
        row.action(False)
        argv = self.run.call_args.args
        self.assertEqual(argv[:2], ("osascript", "-e"))
        self.assertIn('tell application id "com.apple.finder" to empty trash', argv[2])

    def test_finder_refusing_the_script_points_to_the_automation_setting(self):
        trash = self.root / ".Trash"
        trash.mkdir()
        (trash / "old.pdf").write_text("x")
        [row] = self.discovered(cleanup.discover_trash).values()
        self.run.return_value = result(returncode=1, stderr="Not authorized to send Apple events to Finder. (-1743)")
        with self.assertRaisesRegex(RuntimeError, "Automation"):
            row.action(False)

    def test_a_trash_holding_only_finder_metadata_is_not_listed(self):
        (self.root / ".Trash").mkdir()
        (self.root / ".Trash/.DS_Store").write_text("x")
        self.assertEqual(self.discovered(cleanup.discover_trash), {})

    def test_data_of_apps_spotlight_cannot_find_is_offered_per_app(self):
        self.apps(NordVPN="com.nordvpn.macos")
        library = self.root / "Library"
        for folder in ("Application Support/com.pais.handy", "Application Support/com.isaacmarovitz.Whisky",
                       "Containers/com.isaacmarovitz.Whisky", "Containers/com.nordvpn.macos.teams",
                       "Group Containers/W5364U7YZB.com.nordvpn.macos", "Application Support/com.apple.foo",
                       "Application Support/Slack"):
            (library / folder).mkdir(parents=True)
        # A tool without an app that runs as a launchd job is installed too.
        (library / "Application Support/com.vendor.agent").mkdir(parents=True)
        (library / "LaunchAgents").mkdir(parents=True)
        (library / "LaunchAgents/com.vendor.agent.sync.plist").write_text("x")
        rows = self.discovered(cleanup.discover_leftovers)
        self.assertEqual(set(rows), {"leftover-com-pais-handy", "leftover-com-isaacmarovitz-Whisky"})
        whisky = rows["leftover-com-isaacmarovitz-Whisky"]
        self.assertEqual(len(whisky.paths), 2)
        self.assertEqual((whisky.group, whisky.selected, whisky.min_kb),
                         (cleanup.GROUP_OWN, False, cleanup.MIN_LEFTOVER_KB))
        whisky.action(False)
        self.assertFalse((library / "Containers/com.isaacmarovitz.Whisky").exists())
        self.assertTrue((library / "Containers/com.nordvpn.macos.teams").exists())

    def test_spotlight_that_cannot_find_finder_is_a_failed_scan_not_a_mac_without_apps(self):
        (self.root / "Library/Application Support/com.pais.handy").mkdir(parents=True)
        self.tools(mdfind=result(""))
        [row] = cleanup.run_discoverer(cleanup.discover_leftovers)
        self.assertEqual((row.group, row.state), (cleanup.GROUP_FAILED, cleanup.BLOCKED))
        self.assertIn("Spotlight", row.detail)

    # Emulators -----------------------------------------------------------------------------

    def test_avds_in_the_xdg_folder_are_found_and_one_without_its_image_offers_delete_only(self):
        sdk = self.root / "sdk"
        sdk.mkdir()
        avd_root = self.root / ".config/.android/avd"
        data = avd_root / "Old.avd"
        data.mkdir(parents=True)
        (avd_root / "Old.ini").write_text(f"path={data}\n")
        (data / "config.ini").write_text("image.sysdir.1=system-images/android-35/google_apis/arm64-v8a/\n")
        (data / "userdata-qemu.img").write_text("x")
        self.stack.enter_context(patch.dict(os.environ, ANDROID_HOME=str(sdk)))
        rows = {t.key: t for t in (lambda found: (cleanup.discover_android(found), found)[1])([])}
        self.assertEqual(set(rows), {"avd-delete-Old"})
        row = rows["avd-delete-Old"]
        self.assertEqual((row.kind, row.selected), ("Old", False))
        self.assertIn("cannot start", row.label)
        row.action(False)
        self.assertEqual(list(avd_root.iterdir()), [])

    # The tree, and what MacHelm hears ------------------------------------------------------

    def test_space_on_a_kind_checks_its_rows_and_leaves_the_rest(self):
        rows = [cleanup.Target("a", cleanup.GROUP_SAFE, "A", kind="App caches"),
                cleanup.Target("b", cleanup.GROUP_SAFE, "B", kind="App caches"),
                cleanup.Target("go", cleanup.GROUP_SAFE, "Go")]
        confirmed, lines = self.pick(rows, [ord("j"), ord(" "), 10])
        self.assertTrue(confirmed)
        self.assertEqual([t.selected for t in rows], [True, True, False])
        self.assertTrue(any("▸ [ ] App caches" in line for line in lines))
        self.assertTrue(any("▸ [x] App caches" in line for line in lines))

    def test_the_app_hears_the_kind_the_access_and_the_instant_a_scan_judged_at(self):
        row = cleanup.Target("trash", cleanup.GROUP_OWN, "Empty the Trash", needs_fda=True)
        status, [event] = self.app([row], ["--idle-days", "3", "--as-of", "1000"])
        self.assertEqual(status, 0)
        self.assertEqual((event["as_of"], event["idle_days"]), (1000, 3))
        self.assertEqual((event["targets"][0]["kind"], event["targets"][0]["needs_full_disk_access"]),
                         ("", True))

    def test_what_a_target_is_doing_reaches_the_app_under_its_key_a_few_times_a_second(self):
        def long_step(_dry_run):
            for index in range(1, 101):
                cleanup.PROGRESS.note(f"removing part {index} of 100")
            return 7
        slow = cleanup.Target("slow", cleanup.GROUP_SAFE, "Slow", action=long_step)
        status, events = self.app([slow], ["--select", "slow"])
        self.assertEqual(status, 0)
        working = [e for e in events if e["event"] == "working"]
        self.assertEqual(working[:2], [{"event": "working", "key": "slow", "detail": ""},
                                       {"event": "working", "key": "slow", "detail": "removing part 1 of 100"}])
        # A hundred notes in a moment are not a hundred events.
        self.assertLess(len(working), 5)
        self.assertTrue(all(e["key"] == "slow" for e in working))

    def test_a_terminal_run_sends_no_events(self):
        slow = cleanup.Target("slow", cleanup.GROUP_SAFE, "Slow",
                              action=lambda _: (cleanup.PROGRESS.note("removing part 1 of 1"), 7)[1])
        status, output = self.main([slow], ["--select", "slow"])
        self.assertEqual(status, 0)
        self.assertNotIn('"event"', output)

    def test_uv_cache_held_by_running_uv_processes_is_blocked_rather_than_waited_on(self):
        cache = self.root / "uv"
        cache.mkdir()
        (cache / ".lock").write_text("")
        holders = result("38791\n38801\n")
        self.tools(uv=result(f"{cache}\n"), lsof=holders,
                   ps=result("/opt/homebrew/bin/uv run blender-mcp\n/opt/homebrew/bin/uv run blender-mcp\n"))
        [row] = self.discovered(cleanup.discover_uv).values()
        self.assertEqual((row.state, row.selected), (cleanup.BLOCKED, False))
        self.assertIn("in use by 2 uv processes, such as `uv run blender-mcp`", row.detail)
        # Free at the scan, held again by the clean: refused, and uv is never asked to wait.
        self.tools(uv=result(f"{cache}\n"), lsof=result(returncode=1))
        [row] = self.discovered(cleanup.discover_uv).values()
        self.assertEqual((row.state, row.selected), (cleanup.SELECTABLE, True))
        self.tools(lsof=holders, ps=result("/opt/homebrew/bin/uv run blender-mcp\n"))
        with self.assertRaisesRegex(RuntimeError, "in use by 2 uv processes"):
            row.action(False)
        self.assertNotIn(("uv", "cache", "clean"), [c.args for c in self.run.call_args_list])

    def test_idle_days_outside_one_to_ninety_are_refused(self):
        for days in ("0", "91"):
            with self.subTest(days=days), self.assertRaises(SystemExit):
                self.main([], ["--json", "--idle-days", days])


if __name__ == "__main__":
    unittest.main()
