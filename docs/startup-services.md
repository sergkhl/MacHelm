# Startup Services

Startup Services manages programs and scripts through the current user's LaunchAgents. Each service remains its own launchd job, with its own restart or schedule rules. MacHelm's dashboard is a controller for those jobs; the jobs can keep running after the dashboard or the app closes.

## Add or import

**Add…** saves a program or script with automatic startup off and does not run it. **Import…** reads an existing LaunchAgent into the catalog for viewing without starting, stopping, or rewriting it. Unsupported plist fields are reported at import rather than silently discarded.

An imported service remains controlled by its original LaunchAgent until you choose **Manage with MacHelm**. That action backs up the original file and installs a managed definition in its place. It leaves the current session running as found; a job already loaded from its original definition continues using that definition until a stop/start or the next login.

The service runner must be available inside a signed `/Applications/MacHelm.app` for management actions. A build in another directory can view and import services, but cannot start them or change their login registration. macOS's MacHelm background-item setting covers the managed services and privileged helpers.

## Controls

| Control | Effect |
| --- | --- |
| **At login** | Changes registration for the next login. It does not start or stop the current job. |
| **Start** | Starts a continuous service for this session. |
| **Stop** | Ends the current registration so launchd does not immediately restart it. The login preference stays as saved. |
| **Run Now** | Runs a one-shot or scheduled service once, without duplicating a run already in progress. |
| **Resume Schedule** | Restores a stopped schedule for the current session without immediately running it. |
| **Log** | Shows the end of the service's configured log files. |
| **Remove…** | For an observed service, removes it from the list. For a stopped managed service, removes its startup definition while retaining scripts, data, logs, and the original backup. |

Friendly names are editable. If another tool changes a managed plist, MacHelm reports the conflict. **Use Changed Definition** backs up the external version and adopts its program, arguments, and schedule without starting or stopping it.

## Built-in names and integrations

Version 0.1 recognizes these existing service labels. They are optional presets for services already present on a machine; MacHelm does not ship or install the services themselves.

| Service label | Default name |
| --- | --- |
| `com.globesoul.wg-keepalive` | WireGuard Keepalive |
| `com.globesoul.skyrimnet-native-tts` | Skyrim English Speech — Pocket TTS |
| `com.globesoul.skyrimnet-fish-tts` | Skyrim Russian Speech — Fish TTS |
| `local.whisper-server.skyrimnet` | Skyrim Speech Recognition — Whisper |
| `com.quantumcraft.reply-assistant` | Telegram Reply Assistant |
| `com.user.loginscript` | Tahoe Background Process Priority |

The Fish TTS preset displays its dependency on Whisper for uncached reference transcripts; MacHelm does not start dependencies automatically. The Telegram preset checks `.local/service.owner.lock` relative to that service's working directory to avoid competing owners of its data. Other imported LaunchAgents work through the supported generic import fields. New services receive labels under `io.github.sergkhl.MacHelm.service.`.

The presets' labels belong to their external services, so they retain those labels when managed by MacHelm.

## Data and command-line access

The catalog, managed definitions, backups, runner state, and default logs live in:

```text
~/Library/Application Support/io.github.sergkhl.MacHelm/StartupServices/
```

The active user LaunchAgents remain in `~/Library/LaunchAgents/`. Catalog changes take an exclusive lock so the GUI and command-line runner coordinate their changes.

The installed runner offers the same service operations. For example, these commands only inspect local state:

```sh
/Applications/MacHelm.app/Contents/Library/HelperTools/MacHelmServiceRunner status --json
/Applications/MacHelm.app/Contents/Library/HelperTools/MacHelmServiceRunner discover --json
```

Run the runner without a command to see its usage. Developers can use `--root <folder>` with an isolated catalog and LaunchAgents directory for tests; consult the tests before performing lifecycle checks.

## Removing or moving MacHelm

Managed definitions reference the runner at `/Applications/MacHelm.app`. Stop the affected services, then remove their managed definitions or restore their originals before moving or deleting the app. For an imported service with an original backup, the runner's `revert <label>` restores that exact original after the service has stopped. Removing a service in the UI keeps the backup and does not automatically re-enable the original.

MacHelm 0.1 has fresh preferences, catalog, and helper identities. It does not import the state of an earlier private installation automatically. Existing integrations that explicitly name another app's runner need a coordinated update before they can use MacHelm.
