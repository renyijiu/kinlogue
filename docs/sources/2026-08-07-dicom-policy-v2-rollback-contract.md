# DICOM ordering-policy-v2 rollback contract (2026-08-07)

This source note records repository-local U5 release-preparation facts. It
contains no patient data, source path, DICOM UID, pixel content or private
sample inventory.

- The previous exact `0.4.0` / build `4` archive remains immutable and accepts
  ordering policy v1 only. The current portable verifier continues to validate
  that exact historical archive without adding new metadata to it.
- Current source identifies itself as `0.5.0` / build `5`, release role
  `dicom-policy-v2-preparatory`. Its App Info declares
  `KinlogueDICOMOrderingPolicyVersion = 2`.
- The clean-source publisher accepts only that exact identity. It writes
  `dicomOrderingPolicyVersion = 2` into immutable release metadata; the
  verifier independently binds the value to App Info and the clean
  verification report.
- The signed installed gate accepts only exact `0.5.0` / build `5` predecessor
  or archive-bound non-production `0.5.1` / build `6` successor metadata.
  Durable archive binding/state, every one-line event and the decoded
  `DICOMStudyIndex` must all carry ordering policy `2`.
- The installed driver requires a `Kinlogue-0.5.0-5` archive, verifies it before
  extraction, checks policy `2` on every phase, and performs predecessor seed
  and ordinary write, successor write, fresh exact predecessor rollback write,
  then owned cleanup. It does not accept an environment-configured release
  identity.
- Proof-first focused tests initially failed because the runtime request did
  not have an ordering-policy field. After implementation, 23 runtime, script
  and packaging tests pass, as do shell syntax checks. The updated portable
  verifier also revalidates the existing exact `0.4.0-4` archive and its
  previously recorded hash.

From clean source revision `efdda04a71d4ba4edbab42a806a8a343cc68e86a`,
the publisher created the durable, immutable `Kinlogue-0.5.0-5` archive
outside the repository. Its ZIP SHA-256 is
`a908b483ecbfe0b4df54fede8b3477c154a19edf85fabbbd4587af109a533806`;
the bound App bundle-manifest SHA-256 is
`002cb68c4edd273ab5508eda7459b53fc84c4205da71e5b653bc35895a13402e`,
the App executable SHA-256 is
`060cc444fc6dd5f0dabc88344e8df4fad797aa20d0ba8c56d9ee37ad43d9f6f4`,
and the Helper executable SHA-256 is
`e8dc065ed27abf9994376d5dc19d0511de457e8dd2efca6299174c9e6b4c2d1c`.
The publisher's clean bundle gate and a separate portable verification both
passed. The first real installed run stopped at its preflight because a
Kinlogue instance from a different Codex worktree was already running; it did
not install an App, launch a phase or mutate the acceptance Vault. After that
owning task confirmed there was no unsaved work and closed its instance, the
same archive passed the complete Launch Services predecessor -> successor ->
fresh predecessor rollback run. The final report records catalog generation
`5`, ordering policy `2`, one study, two retained objects (one viewable and one
inert), one series, graph SHA-256
`b5935be33d06a45e890d307af307144e2d300099498eb45a407546a44428e6a5`,
inventory SHA-256
`a1188c409f90373508c7cf7cc4615668a291fe827fa516a9bfd050c80e690874`,
and `cleanup = true`. No installed App, acceptance Vault or Kinlogue process
remained. The optional historical catalog-v2 downgrade probe was not run.
