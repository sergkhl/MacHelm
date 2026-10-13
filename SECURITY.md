# Reporting a security issue

Report a vulnerability through [GitHub's private vulnerability reporting form](https://github.com/sergkhl/MacHelm/security/advisories/new). Include the affected version or commit, the conditions needed to reproduce it, the impact, and a minimal example where possible. Keep credentials, private service commands, and unrelated machine logs out of the report.

MacHelm includes privileged helpers, a startup-service runner, and storage-removal code. Reports involving their authentication, path handling, ownership, or cleanup behavior are security reports even when a local user is needed to reproduce them. Use the regular issue form for ordinary bugs that do not expose a vulnerability.

The project currently develops the 0.1 source line. A published source tag does not imply that a signed or notarized binary is available.
