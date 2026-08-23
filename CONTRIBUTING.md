# Contributing to Kinlogue

Thank you for helping improve Kinlogue. The project welcomes focused bug fixes, tests, documentation, accessibility improvements, and carefully scoped features that preserve its local-first and non-diagnostic boundaries.

## Before changing code

1. Read [AGENTS.md](AGENTS.md), [docs/index.md](docs/index.md), and the topic page for the area you plan to change.
2. Search the existing implementation and tests before proposing a new abstraction.
3. Open an issue for a material behavior or storage-format change. Security vulnerabilities must use the private process in [SECURITY.md](SECURITY.md).

The Swift package manifest is build and test infrastructure for the macOS application. Only the `Kinlogue` executable is a published product; Core, Platform, and test-support targets are internal and are not a stable library API.

## Privacy rules

Use generated or synthetic data only. Never add real medical records, names, identifiers, private paths, screenshots of user data, content-bearing logs, credentials, recovery codes, signing material, or backup files to Git, issues, pull requests, test output, or build artifacts. Do not ignore medical file extensions in `.gitignore`; the repository privacy guard must be able to reject them.

## Development workflow

Kinlogue requires macOS 14+ and Swift 6 from Xcode or Command Line Tools. Add or strengthen a proof-first test for behavior changes, then run the checks appropriate to your change:

```sh
swift build --disable-sandbox
scripts/compile-localizations.sh --check
scripts/lint.sh
scripts/privacy-guard.sh
scripts/test.sh
```

Changes to user-visible strings must update the String Catalog and generated English/Chinese resources. Changes to behavior or commitments must update the relevant topic documentation, `docs/index.md`, and `docs/log.md`.

## Pull requests

Keep each pull request to one logical outcome. Explain the privacy and migration impact, list exact verification commands, and state manual gates that were not run. All examples and attachments must be synthetic. By submitting a contribution, you agree that it is licensed under the repository's [GPL-3.0 license](LICENSE).
