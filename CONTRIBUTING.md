# Contributing to MacHelm

MacHelm combines tools with different effects: some read system state, while others change power settings, manage services, control fans, or remove selected files. Keep a contribution focused on the behavior it changes and make its effect clear in the interface and pull request.

## Development

Use macOS 26 or later and Xcode 26 or later. Open `MacHelm.xcodeproj` with the MacHelm scheme. Choose your own development team for the app, both helpers, and the service runner; the repository does not supply signing credentials. The [README](README.md#build) gives the command-line build.

`scripts/generate-xcode-project.py` generates the checked-in Xcode project, shared scheme, workspace, and the four products' `Info.plist` files from the Swift source inventory and its build configuration. It uses Python's standard library and stable object identifiers. Edit the generator for shared build-setting changes, then regenerate after those changes or after adding or removing Swift sources:

```sh
python3 scripts/generate-xcode-project.py
python3 scripts/generate-xcode-project.py --check
```

Commit the generator changes and resulting generated files together. `--check` reports drift without writing; `--check --list-sources` also prints each target's source membership. Keep contributor-specific signing choices out of the generated files; the command-line `DEVELOPMENT_TEAM` and `CODE_SIGN_IDENTITY` overrides apply to a local build. The original chip artwork lives in `assets/machelm-icon.svg`; the application icon variants are under `MacHelm/Assets.xcassets/AppIcon.appiconset/`.

Run the checks relevant to your change:

```sh
swift test --scratch-path build/swift-tests
python3 -B -m unittest discover -s Storage -p 'test_cleanup_macos_dev.py'
python3 -B -m unittest discover -s AccessoryCheck -p 'test_accessory_check.py'
```

The Swift package covers the shared policy, runtime, and service components; Xcode builds the graphical application and embedded helpers. For a signed application, run both artifact verification scripts described in the README. Read [Cursor hide](docs/cursor-hide.md) before changing pointer ownership or the private backend, [Fan Control](docs/fan-control.md) before changing its native interfaces or recovery behavior, and [Startup Services](docs/startup-services.md) before changing registration behavior.

## Changes and validation

Keep system effects behind testable interfaces. Make failure, cancellation, ownership, and restoration paths explicit. Preserve accessibility labels and keyboard access when changing the interface. Add a regression test when it can demonstrate the bug or behavior under review; avoid tests that merely repeat implementation details.

A pull request should state the problem, the resulting behavior, the checks run, and any remaining limits. Give a concrete example where it helps. Distinguish unit tests, an Xcode build, a signed-artifact inspection, a native run on a named Mac, and distribution verification. A mocked recovery test is useful evidence for the algorithm; it is not evidence that a physical fan returned to automatic.

For cursor changes, separate a successful WindowServer API return from an observed pointer disappearance. Record the foreground app or game, macOS version, display setup, shortcut result, and normal-Quit behavior in a native check. Tests of request ownership cannot establish in-game visibility or cleanup after a force quit.

Keep build outputs, signed bundles, credentials, local validation captures, and personal service definitions out of the repository. A useful diagnostic attachment is the smallest redacted excerpt that shows the failure and its context.

## Bug reports

Use the [bug report form](https://github.com/sergkhl/MacHelm/issues/new?template=bug_report.yml). Include the Mac model, macOS version, MacHelm version or commit, affected tool, reproduction steps, expected result, and observed result. Include helper approval and signing details when they matter, without sharing private keys, tokens, or service secrets.

For a security-sensitive report, follow [SECURITY.md](SECURITY.md).
