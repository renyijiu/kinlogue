# Security Policy

Kinlogue handles unusually sensitive local data. Security reports are welcome, but the report itself must not create another disclosure.

## Supported version

Only the current `main` branch is supported before the first stable release. Historical development snapshots and ad-hoc prereleases do not receive security fixes.

## Reporting a vulnerability

Use GitHub **private vulnerability reporting** from the repository Security tab. Do not open a public issue or pull request for an unpatched vulnerability.

Never attach real medical records, screenshots of user data, private filesystem paths, content-bearing logs, credentials, recovery codes, signing material, or `.kinloguebackup` files. Build the smallest reproduction from synthetic data and redact environment-specific identifiers. If synthetic data cannot demonstrate the issue, describe the missing precondition without sending the private source material.

Include the affected revision, macOS version, expected security boundary, reproduction steps, and observed impact. The maintainer will acknowledge reports on a best-effort basis, validate them privately, and coordinate disclosure after a fix is available. Please do not test against systems or data you do not own or have explicit permission to use.

## Public reports

Non-security bugs may use the issue tracker, but they must follow the same synthetic-only data rule. Known product and trust boundaries are documented in [PRIVACY.md](PRIVACY.md) and [docs/privacy-and-security.md](docs/privacy-and-security.md).
