# DICOM catalog v3 contract evidence (2026-08-07)

This source note records repository-local implementation facts, not patient or
image data. It is derived from the U2 requirements in
[`../plans/2026-08-06-001-feat-dicom-mri-viewer-plan.md`](../plans/2026-08-06-001-feat-dicom-mri-viewer-plan.md)
and the executable evidence in `Sources/`, `Tests/`, `packaging/`, and
`scripts/`.

- `VaultCatalog` format 3 has an explicit DICOM study root and preserves
  retained non-image objects separately from viewable image instances.
- Persistent UID values are 32-byte vault-local opaque digests with fixed
  domain/version/scope; raw source UIDs are excluded.
- The predecessor package contract is read `[1,2,3]`, write `3`. The old v2
  rollback archive scripts remain historical evidence rather than being
  repurposed for v3.
- A signed runtime gate accepts only the exact `0.4.0` / build `4`
  preparatory metadata or an archive-bound restricted successor, an exact
  phase token, a canonical run ID and the predecessor ZIP digest. Its
  generated graph contains one viewable object, one inert object, the
  separately stored index, the versioned fingerprint and scoped opaque UID
  digests. Events contain only fixed codes, counts and SHA-256 values.
- Independent v3 publisher/verifier/installed-runner entry points implement
  clean-source immutable publication, portable app/XPC signature verification
  and predecessor → successor → exact predecessor graph-preservation checks.
  Historical v2 entry points remain hard-coded and unchanged; v3 entry points
  additionally reject compatibility-contract environment overrides.
- Focused App runtime tests exercised the generated graph through catalog
  generations 2–5 and cleanup; focused script safety tests and `zsh -n` passed.
- The exact predecessor was published from clean revision
  `17e6c0bacabe3c6d2d236c3341c5cd9f4dbcc2a3` into a durable external archive
  named `Kinlogue-0.4.0-4`. Its ZIP SHA-256 is
  `7205988a4b6a29ca4fb4b4aef3fe59b13bf58901c11d5b6a82b0cbf8ca70aeb8`.
  Independent portable verification passed with a `0555` committed directory,
  `0444` payloads, exact hashes, ad-hoc App signature, isolated Helper signature
  and standard nested resources. No user-specific archive path is recorded in
  the repository.
- The real Launch Services rehearsal passed predecessor seed/reopen-write,
  restricted successor write, fresh exact-predecessor rollback/reopen-write and
  cleanup. The final report recorded catalog generation 5, one study, two
  retained objects (one viewable and one inert), one series, graph SHA-256
  `6eafe00fc47a02e165d24877877fd0483fc3d4e79d79f0966f8b16bfa0cda7ea`
  and `cleanup=true`. Temporary installs, the synthetic Acceptance root and
  Kinlogue/Helper processes were absent after the run.
- A first publication attempt under a macOS File Provider-managed directory was
  correctly rejected by the independent verifier after its committed directory
  mode drifted from `0555` to `0700`. The publisher now runs the portable
  verifier before reporting success, and the verifier checks committed-directory
  permissions both before and after full archive/signature inspection.
- The optional exact historical-v2 installed downgrade probe remains
  `notExecuted`. Developer ID, notarization, macOS 14/15 independent machines,
  real MRI data and manual accessibility checks are also outside this evidence.
