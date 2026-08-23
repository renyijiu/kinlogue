# DICOM folder import contract evidence (2026-08-07)

This source note records repository-local U3 implementation facts. It contains
no patient data, private sample path, raw DICOM UID, pixel dump or source file
name. All executable evidence uses runtime-generated identity-free fixtures.

- `DICOMImportPolicy` freezes the directory, object, byte, dimension, worker,
  descriptor and free-space budgets used by the Platform import path.
- `DICOMFolderScanner` holds the caller's security-scoped directory access,
  traverses an iterative component-identity worklist with descriptor-relative
  no-follow operations, admits regular Part 10 candidates only, and immediately
  copies them to opaque Vault-owned files. Transient component names are never
  journaled or logged.
- The queue is fixed at two admissions and executes at most two workers. Deep
  traversal reopens each recorded component from the held root, closes the
  previous descriptor immediately, and shares one verified staging-operation
  descriptor across a worker pair. Content/path-free metrics count root,
  traversal/readdir, source, staging, decoder and promotion descriptor use.
- Each source descriptor is checked before and after its streaming copy. The
  staged file is hashed while copying, made read-only, synchronized and later
  rehashed before any index or catalog fact is derived.
- A decoded image frame is validated against both the fixed IPC envelope and
  the active import policy, reduced immediately to bounded image attributes,
  and then released. Raw sample buffers do not accumulate across the study.
- The allowlist indexer accepts classic single-frame Explicit VR Little Endian
  MR objects through the isolated decoder contract. Explicitly allowed SR and
  encapsulated-document SOP families remain inert attachments; parsing stops
  once the required allowlist fields are present, before SR content sequences.
  Mixed studies,
  unsupported images and one SOP identity with unequal bytes fail before
  publication. Raw UIDs and free-text tags are transient only.
- One process-wide Vault mutation lease covers receipt creation, staging,
  indexing and manifest-last publication. A durable opaque receipt exists
  before the first staged byte and binds the staging directory's device/inode
  identity before scanning starts.
- Reconciliation runs under the same lifecycle coordination on reopen and
  before another import. It reads the current catalog reachability set first,
  preserves reachable promoted objects, and removes only unreachable
  journal-owned objects. Staging cleanup uses descriptor-relative identity
  checks and refuses symlinks or replaced directories; failed cleanup retains
  the receipt for retry. A later import fails closed while that retry remains,
  so unresolved ownership debt cannot accumulate more receipts.
- Exact digest/length duplicates are removed descriptor-relatively immediately
  after their bounded staging batch and contribute only an aggregate ignored
  count. The unique-object and unique-byte limits retain one copy, not every
  repeated source entry.
- The complete sorted attachment/index promotion set is registered in one
  durable receipt update before the first managed-object write. Objects and
  the bounded study index are then promoted before `library.json`.
  Fault injection at journal, attachment, index, object and manifest boundaries
  reopens to either the complete old generation or one complete new study.
- Focused generated-fixture tests cover recursive admission, ignored ordinary
  files, exact duplicate collapse, inert SR retention, mixed/conflicting study
  rejection, capacity failure, cancellation, concurrent exact re-import,
  abandoned staging recovery and replacement-safe cleanup.
- Generated stress evidence covers 220 unique files, an exact depth-16 tree,
  two workers, queue depth two, all import-owned descriptors at or below eight,
  unique-byte read/write accounting, at most three managed full reads/two
  writes per retained object, peak added disk below `2 × uniqueBytes + 256 MiB`
  and queued cancellation below one second. Deterministic admission tests cover
  rename, deletion, growth, truncation, replacement, security-scope denial and
  selected-root rename/symlink replacement without escaping the held root FD.
- U3 persists only deterministic `stableContentFallback` instance ordering.
  Geometry/Instance Number ordering and its validation remain U4 work and are
  not claimed by this source note.
- Real fixture processes prove that a killed importer releases the kernel
  lease and the next process reclaims staging, and that whole-Vault deletion
  waits for an active import rather than racing it.
- The final focused DICOM/storage/process/package regression passes 113 tests
  in 7 suites. The repository-wide gate passes 628 tests in 58 suites with six
  existing Vision sandbox known issues, followed by the isolated real-socket
  RSS/backpressure test passing 1/1.
- Clean revision `f3d7d17d38d9e8189c1d8657e05b9b9cbae34441` passes
  `scripts/verify-app.sh --require-clean-source`. Its ad-hoc signed App content
  manifest SHA-256 is
  `7effed6a6d3f557fc4d37e3f2c2bf0f393d8816d92c50a8002abc020adacd081`
  and its embedded Helper executable SHA-256 is
  `535c4f1fb3dcf157846ce29c54a3368c858f9257e0b9809cc733c3755d110f82`.
  Reusing that exact verified bundle, `scripts/verify-dicom-xpc.sh
  --use-verified-app` passes strict signatures, raw generated-fixture
  round-trip, malformed-input rejection, production Helper crash containment,
  compile-time-only hang watchdog, unified-log canary scanning and zero
  runtime sockets.

This is a Platform/storage capability. The App composition, folder picker,
review UI and Viewer remain later units; no user-visible DICOM import or image
viewing capability is claimed by this note. Installed user-flow acceptance,
macOS 14/15, Developer ID/notarization, private MRI compatibility and manual
accessibility remain unexecuted.
