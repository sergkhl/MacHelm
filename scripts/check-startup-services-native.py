#!/usr/bin/env python3
"""Checks the Startup Services runner against the real launchd of this login session.

Usage: check-startup-services-native.py /path/to/MacHelmServiceRunner [evidence-folder]

Every job it registers is a throwaway shell script with a label under
io.github.sergkhl.MacHelm.selftest, loaded from a folder of its own
(--root) and removed again before the script ends. It never reads the user's
catalog, never writes to ~/Library/LaunchAgents and never touches another job.
"""

import json
import os
import plistlib
import signal
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

PREFIX = "io.github.sergkhl.MacHelm.selftest"
DOMAIN = f"gui/{os.getuid()}"


class Check:
    def __init__(self, runner, evidence):
        self.runner = str(Path(runner).resolve())
        self.run_id = uuid.uuid4().hex[:8]
        # launchd refuses long socket-like paths nowhere here, but keep the root short and private.
        self.root = Path(tempfile.mkdtemp(prefix="machelm-selftest-")).resolve()
        self.data = self.root / "data"
        self.work = self.root / "work"
        self.work.mkdir()
        self.evidence = Path(evidence) if evidence else None
        self.labels = []
        self.results = []

    # --- helpers -----------------------------------------------------------
    def label(self, name):
        label = f"{PREFIX}.{name}.{self.run_id}"
        self.labels.append(label)
        return label

    def cli(self, *arguments, expect=0):
        result = subprocess.run([self.runner, "--root", str(self.data), *arguments],
                                capture_output=True, text=True, timeout=120)
        if expect is not None and result.returncode != expect:
            raise AssertionError(f"{' '.join(arguments)} exited {result.returncode}: {result.stdout} {result.stderr}")
        return result

    def status(self, label):
        return json.loads(self.cli("status", label, "--json").stdout)

    def launchd(self, label):
        result = subprocess.run(["/bin/launchctl", "print", f"{DOMAIN}/{label}"], capture_output=True, text=True)
        if result.returncode != 0:
            return None
        fields = {}
        for line in result.stdout.splitlines():
            if line.startswith("\t") and not line.startswith("\t\t") and " = " in line:
                key, _, value = line.strip().partition(" = ")
                fields.setdefault(key, value)
        return fields

    def script(self, name, body):
        path = self.work / name
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(0o755)
        return str(path)

    def install(self, label, program, arguments=(), **fields):
        definition = {"label": label, "name": label.split(".")[-2], "program": program,
                      "arguments": [program, *arguments], "workingDirectory": str(self.work),
                      "standardOutPath": str(self.work / f"{label}.log"),
                      "standardErrorPath": str(self.work / f"{label}.log"), **fields}
        path = self.work / f"{label}.json"
        path.write_text(json.dumps(definition))
        self.cli("install-definition", str(path))

    def lines(self, name):
        path = self.work / name
        return path.read_text().split("\n")[:-1] if path.exists() else []

    def wait(self, what, condition, timeout=30.0, poll=0.1):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = condition()
            if value:
                return value
            time.sleep(poll)
        raise AssertionError(f"Timed out after {timeout:g} s waiting for {what}")

    @staticmethod
    def alive(pid):
        try:
            os.kill(int(pid), 0)
            return True
        except (ProcessLookupError, ValueError):
            return False
        except PermissionError:
            return True

    def record(self, label):
        path = self.data / "Run" / f"{label}.json"
        return json.loads(path.read_text()) if path.exists() else None

    def passed(self, name, detail=""):
        self.results.append({"check": name, "result": "pass", "detail": detail})
        print(f"PASS  {name}" + (f"  ({detail})" if detail else ""))

    # --- checks ------------------------------------------------------------
    def keep_alive(self):
        label = self.label("keepalive")
        program = self.script("server.sh", """
state="$1"
echo "start $$ $(pwd -P) $XPC_SERVICE_NAME" >> "$state"
/bin/sleep 600 &
echo "grandchild $!" >> "$state"
trap 'echo term >> "$state"; exit 0' TERM
while :; do /bin/sleep 0.2; done
""")
        self.install(label, program, ["server.state"], runAtLoad=True, keepAlive="always", throttleInterval=2)
        before = self.status(label)
        assert before["activity"] == "inactive" and not before["automaticStartup"], before
        assert self.launchd(label) is None, "installing a definition must not register it"
        assert self.lines("server.state") == [], "installing a definition must not run it"
        self.passed("a new definition is saved switched off and is neither registered nor run")

        # Manual Start while automatic startup is off.
        self.cli("start", label)
        self.wait("the command to start", lambda: len(self.lines("server.state")) >= 2)
        status = self.status(label)
        job = self.launchd(label)
        record = self.record(label)
        assert status["activity"] == "running" and status["loadedInstance"] == "managed", status
        assert not status["automaticStartup"], "Start changed the saved preference"
        assert job["program"] == self.runner, job
        assert job["path"] == str(self.data / "Agents" / f"{label}.plist"), job["path"]
        start = self.lines("server.state")[0].split(" ")
        # The command runs in the very process launchd started: no wrapper in between.
        assert int(job["pid"]) == record["pid"] == int(start[1]), (job["pid"], record, start)
        assert start[2] == str(self.work) and start[3] == label, start
        assert not list((self.data / "LaunchAgents").glob("*")), "automatic startup is off, yet a LaunchAgent was installed"
        self.passed("manual Start works with automatic startup off and leaves the preference off",
                    f"launchd's job process {job['pid']} is the command itself")

        # launchd's own restart policy is still in force.
        os.kill(int(job["pid"]), signal.SIGKILL)
        self.wait("launchd to restart the service", lambda: sum(l.startswith("start ") for l in self.lines("server.state")) >= 2, timeout=40)
        restarted = self.wait("the restarted job's process", lambda: (self.launchd(label) or {}).get("pid"))
        assert restarted != job["pid"]
        after = self.launchd(label)
        last = {key: value for key, value in after.items() if key.startswith("last ")}
        killed = self.status(label)
        assert killed["lastSignal"] or killed["lastExitCode"] is not None, killed
        self.passed("KeepAlive restarts the service after its command is killed",
                    f"new process {restarted}; launchd reports {last}; shown as: {killed['lastSignal'] or killed['lastExitCode']}")

        # Explicit Stop: no respawn, orderly termination, descendants gone, preference kept.
        grandchild = self.wait("the grandchild", lambda: [l for l in self.lines("server.state") if l.startswith("grandchild ")][1:] or None)[-1].split(" ")[1]
        starts = sum(l.startswith("start ") for l in self.lines("server.state"))
        began = time.monotonic()
        self.cli("stop", label, "--wait", "20")
        took = time.monotonic() - began
        assert self.launchd(label) is None, "the job is still registered after Stop"
        assert self.lines("server.state")[-1] == "term", "the command did not receive the termination request"
        assert self.status(label)["activity"] == "inactive"
        self.wait("the grandchild to be gone", lambda: not self.alive(grandchild), timeout=10)
        time.sleep(5)
        assert sum(l.startswith("start ") for l in self.lines("server.state")) == starts, "launchd restarted a stopped service"
        assert not self.status(label)["automaticStartup"]
        self.passed("Stop under KeepAlive ends the registration, the command exits by itself, nothing restarts it",
                    f"stopped in {took:.1f} s; grandchild {grandchild} gone; quiet for 5 s more")

        # Automatic startup on: the session loads the file a login would load.
        self.cli("set-automatic", label, "on")
        assert self.launchd(label) is None, "turning automatic startup on must not start anything"
        installed = self.data / "LaunchAgents" / f"{label}.plist"
        rendered = plistlib.loads(installed.read_bytes())
        assert rendered["ProgramArguments"] == [self.runner, "--root", str(self.data), "run", label], rendered
        assert rendered["AssociatedBundleIdentifiers"] == ["io.github.sergkhl.MacHelm"]
        assert rendered["KeepAlive"] is True and rendered["ThrottleInterval"] == 2
        self.cli("start", label)
        assert self.wait("the job", lambda: self.launchd(label))["path"] == str(installed)
        self.cli("set-automatic", label, "off")
        assert not installed.exists() and self.status(label)["activity"] == "running", "the running job must be left alone"
        self.passed("the automatic preference changes a file only; the running job is left as it is")
        self.cli("stop", label, "--wait", "20")
        self.cli("remove", label)
        assert self.cli("status", label, expect=1).returncode == 1

    def after_failure(self):
        label = self.label("onfailure")
        program = self.script("worker.sh", """
echo run >> worker.runs
exit "$(cat worker.exit)"
""")
        (self.work / "worker.exit").write_text("0\n")
        self.install(label, program, runAtLoad=True, keepAlive="afterFailure", throttleInterval=2)
        self.cli("start", label)
        self.wait("the first run", lambda: len(self.lines("worker.runs")) == 1)
        self.wait("the clean exit to be recorded", lambda: (self.launchd(label) or {}).get("last exit code") == "0")
        time.sleep(4)
        status = self.status(label)
        assert len(self.lines("worker.runs")) == 1, "a successful exit was restarted"
        assert status["activity"] == "idle" and status["lastExitCode"] == 0, status
        self.passed("a successful exit is not restarted and is shown as exited", status["state"])

        (self.work / "worker.exit").write_text("3\n")
        self.cli("start", label)
        self.wait("launchd to restart after the failure", lambda: len(self.lines("worker.runs")) >= 3, timeout=40)
        job = self.launchd(label)
        assert job["last exit code"].startswith("3"), job
        assert self.status(label)["lastExitCode"] == 3
        self.passed("the command's exit status reaches launchd unchanged and a failure is restarted",
                    f"last exit code = {job['last exit code']}")
        self.cli("stop", label, "--wait", "20")
        runs = len(self.lines("worker.runs"))
        time.sleep(4)
        assert len(self.lines("worker.runs")) == runs, "a stopped failing service ran again"
        self.cli("remove", label)

    def stubborn(self):
        label = self.label("stubborn")
        program = self.script("stubborn.sh", """
/bin/sleep 600 &
echo "$$ $!" > stubborn.pids
trap '' TERM
while :; do /bin/sleep 0.2; done
""")
        self.install(label, program, runAtLoad=True, keepAlive="always", exitTimeOut=2)
        self.cli("start", label)
        child, grandchild = self.wait("the command", lambda: self.lines("stubborn.pids"))[0].split(" ")
        began = time.monotonic()
        result = self.cli("stop", label, "--wait", "20", expect=None)
        took = time.monotonic() - began
        assert result.returncode == 0, result.stdout + result.stderr
        assert self.launchd(label) is None
        assert not self.alive(child), "the command outlived its stopped job"
        self.wait("the grandchild to be gone", lambda: not self.alive(grandchild), timeout=10)
        status = self.status(label)
        assert status["activity"] == "inactive" and status["problems"] == [], status
        assert 1.5 <= took <= 10, f"expected launchd's 2 s exit timeout to end it, took {took:.1f} s"
        self.passed("a command that ignores the request is ended by launchd's own exit timeout, as before the takeover",
                    f"{took:.1f} s with ExitTimeOut 2; command {child} and its child {grandchild} gone; no stray process reported")
        self.cli("remove", label)

    def one_shot(self):
        label = self.label("oneshot")
        program = self.script("once.sh", """
echo run >> once.runs
/bin/sleep "$(cat once.sleep)"
""")
        (self.work / "once.sleep").write_text("0\n")
        self.install(label, program, runAtLoad=True)
        assert self.cli("start", label, expect=1).returncode == 1
        self.cli("run-now", label)
        self.wait("the run", lambda: len(self.lines("once.runs")) == 1)
        self.wait("the job to finish", lambda: self.status(label)["activity"] == "idle")
        time.sleep(3)
        assert len(self.lines("once.runs")) == 1, "a login job ran more than once"
        status = self.status(label)
        assert status["state"] == "Finished" and status["lastExitCode"] == 0, status
        for _ in range(3):
            self.status(label)
        assert len(self.lines("once.runs")) == 1, "reading status ran the job"
        self.passed("a one-shot job runs once when loaded and reading its status does not run it again")

        (self.work / "once.sleep").write_text("4\n")
        self.cli("run-now", label)
        self.wait("the second run", lambda: len(self.lines("once.runs")) == 2)
        refused = self.cli("run-now", label, expect=1)
        assert "already running" in refused.stderr, refused.stderr
        time.sleep(1)
        assert len(self.lines("once.runs")) == 2
        self.passed("Run Now runs it once more and is refused while a run is in progress")
        self.cli("stop", label, "--wait", "20")
        self.cli("remove", label)

    def scheduled(self):
        label = self.label("scheduled")
        program = self.script("backup.sh", "echo run >> backup.runs")
        agents = self.data / "LaunchAgents"
        agents.mkdir(parents=True, exist_ok=True)
        source = agents / f"{label}.plist"
        original = plistlib.dumps({"Label": label, "ProgramArguments": [program], "WorkingDirectory": str(self.work),
                                   "StartCalendarInterval": {"Month": 1, "Day": 1, "Hour": 3, "Minute": 0}})
        source.write_bytes(original)
        self.cli("import", str(source))
        assert source.read_bytes() == original and self.launchd(label) is None
        self.cli("take-over", label)
        assert self.launchd(label) is None and self.lines("backup.runs") == [], "taking over must not load or run anything"
        backups = list((self.data / "Backups").glob(f"*{label}*/{label}.plist"))
        assert len(backups) == 1 and backups[0].read_bytes() == original, backups
        self.passed("import and takeover keep an exact backup and neither load nor run the job")

        self.cli("resume-schedule", label)
        status = self.status(label)
        assert status["activity"] == "idle" and status["state"] == "Scheduled; not running now", status
        time.sleep(2)
        assert self.lines("backup.runs") == [], "loading the schedule ran the job"
        self.cli("run-now", label)
        self.wait("the run", lambda: len(self.lines("backup.runs")) == 1)
        self.passed("a scheduled job waits for its time and runs at once only on Run Now")
        self.cli("stop", label, "--wait", "20")

        # The owner replaces the LaunchAgent by hand; it is used only when they say so.
        changed = plistlib.dumps({"Label": label, "ProgramArguments": [program, "by-hand"], "WorkingDirectory": str(self.work),
                                  "StartCalendarInterval": {"Month": 2, "Day": 1, "Hour": 4, "Minute": 0}})
        source.write_bytes(changed)
        conflict = self.status(label)
        assert any("changed outside MacHelm" in problem for problem in conflict["problems"]), conflict
        assert self.cli("run-now", label, expect=1).returncode == 1 and source.read_bytes() == changed
        self.cli("accept-change", label)
        accepted = self.status(label)
        assert accepted["problems"] == [] and self.launchd(label) is None, accepted
        assert plistlib.loads(source.read_bytes())["StartCalendarInterval"] == {"Month": 2, "Day": 1, "Hour": 4, "Minute": 0}
        self.passed("a LaunchAgent changed by hand is a conflict until accepted, and accepting it runs nothing")
        original = changed

        self.cli("revert", label)
        assert source.read_bytes() == original, "the rollback did not restore the exact original"
        self.passed("revert puts the exact original back")
        self.cli("remove", label)

    # --- driver ------------------------------------------------------------
    def clean_up(self):
        left = []
        for label in self.labels:
            if self.launchd(label) is not None:
                subprocess.run(["/bin/launchctl", "bootout", f"{DOMAIN}/{label}"], capture_output=True)
                deadline = time.monotonic() + 20
                while self.launchd(label) is not None and time.monotonic() < deadline:
                    time.sleep(0.2)
                if self.launchd(label) is not None:
                    left.append(label)
        return left

    def main(self):
        print(f"Runner: {self.runner}\nTest root: {self.root}\nLabels: {PREFIX}.*.{self.run_id}")
        failure = None
        try:
            for check in (self.keep_alive, self.after_failure, self.stubborn, self.one_shot, self.scheduled):
                check()
        except Exception as error:  # the first failure is kept as it happened
            failure = f"{type(error).__name__}: {error}"
            self.results.append({"check": "first failure", "result": "fail", "detail": failure})
            print(f"FAIL  {failure}")
        finally:
            left = self.clean_up()
            if left:
                failure = (failure or "") + f" Still registered: {left}"
            print("No test job is left registered." if not left else f"STILL REGISTERED: {left}")
            if self.evidence:
                self.evidence.mkdir(parents=True, exist_ok=True)
                summary = {"runner": self.runner, "runID": self.run_id, "root": str(self.root),
                           "results": self.results, "leftRegistered": left, "passed": failure is None}
                (self.evidence / f"native-check-{self.run_id}.json").write_text(json.dumps(summary, indent=2) + "\n")
        print("PASSED" if failure is None else "FAILED")
        return 0 if failure is None else 1


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3) or not os.access(sys.argv[1], os.X_OK):
        sys.exit(__doc__)
    sys.exit(Check(sys.argv[1], sys.argv[2] if len(sys.argv) == 3 else None).main())
