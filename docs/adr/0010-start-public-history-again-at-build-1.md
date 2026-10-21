---
status: accepted
---

# Start the public history again at 0.1 build 1, and keep the development history private

## Context

MacHelm 0.1 was first published on 2026-10-13 as build 1, followed by a fix as build 2. Twenty-two more commits, made locally and never pushed, took the source to development build 11. They record the work build by build, with hardware checks, review rounds and build bumps.

## Decision

Replace the public history with one commit that holds the current source as version 0.1, build 1, and move the `v0.1` tag and release onto it. Keep all 24 earlier commits, the original `v0.1` tag and the git-ignored validation records in the private, read-only repository `sergkhl/MacHelm-private-archive`. From this commit on, commits go straight to this repository and the build number counts up from 1.

## Alternatives

- **One squashed commit on top of the published history.** The 0.1 release would have stayed where it was. But a build 1 after builds 1 and 2 gives two different sources the same name, and calling it 0.2, build 1 would change the version only to avoid that.
- **A fresh repository at the same URL**, with this one renamed and made private. That is needed when private commits have already been pushed, because GitHub keeps serving rewritten commits by hash. None of these had been pushed, and the two replaced commits were public already, so this repository keeps its URL and settings.

## Consequences

- The development builds named in [Fan Control](../fan-control.md) and in ADRs 0006, 0007 and 0009 came before this commit. Those builds, and every commit hash from that time, exist only in the archive.
- Clones made before 2026-10-21 have unrelated history and must be cloned again.
- The two commits first published stay readable by hash on GitHub. They hold nothing that was not public already.
