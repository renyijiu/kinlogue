# DICOM slice service contract evidence (2026-08-07)

This source note records repository-local U4 implementation facts. It contains
no patient data, private sample path, raw DICOM UID, pixel dump, screenshot or
source file name. Every executable example uses runtime-generated,
identity-free DICOM fixtures.

- Import-time Series ordering policy v2 normalizes row/column orientation,
  derives the slice normal with their cross product and sorts finite patient
  positions by normal projection. Partial geometry, inconsistent orientation,
  duplicate/near-duplicate projected positions and inconsistent pixel layout
  fail closed. Variable positive slice spacing remains valid.
- When every slice lacks geometry, complete Instance Number metadata provides
  the first warned fallback; otherwise the order uses a stable digest/length
  content identity. File name, path and raw UID never participate. Persisted
  policy-v2 geometry order is validated in one linear pass over its stored
  projection order; policy-v1 indexes remain readable without being silently
  reordered.
- Kinlogue-owned pure transforms interpret 8/16-bit little-endian stored
  samples, Bits Stored/High Bit and signedness, then apply finite rescale,
  explicit DICOM W/L or a deterministic 1%/99% robust default, and finally
  MONOCHROME1 inversion to an 8-bit grayscale buffer. Default LINEAR Window
  Width below 1 is rejected consistently by IPC, the persisted domain model
  and custom display requests, matching [DICOM PS3.3 C.11.2.1.2.1](https://dicom.nema.org/medical/dicom/current/output/chtml/part03/sect_C.11.2.html#sect_C.11.2.1.2.1).
  The Helper reads only VOI LUT Function `(0028,1056)` on demand: empty or
  normalized `LINEAR` continues, while `LINEAR_EXACT`, `SIGMOID` and unknown
  values return `unsupportedObject`; it does not enumerate all tags. VOI LUT
  Sequence remains outside the product contract and follows the no-valid-W/L
  robust fallback without expanding IPC or persisted schema.
- `PlaintextVault` opens a requested study/Series into opaque descriptors bound
  to vault ID, catalog generation/commit/digest, local study/Series/instance
  IDs, attachment identity, digest, length and persisted image attributes.
  Each on-demand read revalidates that graph, opens only the managed object
  path, hashes the descriptor before and after decode, checks descriptor
  identity/length, and accepts only a frame whose attributes equal the index.
  A resolve still validates every DICOM index fail-closed, but retains only the
  requested study's already-verified index for that same operation, avoiding a
  second read/hash/decode of the target index without creating a persistent
  cache.
- The verified-object lifecycle lease covers descriptor validation and the
  owned raw frame snapshot only. Decode still crosses the existing
  `DICOMFrameDecoding` adapter into the sandboxed XPC Helper; Platform has no
  DicomCore fallback. Catalog coordination is released before transform and
  render, as required by KTD7.
- A process-shared lifecycle generation is captured with every verified raw
  snapshot or cache-hit validation. Vault destroy advances it before waiting
  for active descriptor leases. The slice service revalidates the generation
  immediately before publishing pixels; a late transform clears its cache and
  reservation and returns only a stable stale-session error.
- Production slice services share one process runtime: one 384 MiB checked
  memory budget, one canonical cache and one scheduler. The scheduler permits
  one active foreground decode and one active disposable prefetch. A newest
  pending foreground waits for the prior active work to finish even if that
  decoder ignores cancellation; intermediate pending work is cancelled. A
  predicted working set over 64 MiB disables prefetch. Admission counts the
  source object, both simultaneously live main-process raw reply/frame buffers,
  canonical pixels, render/upload buffers and, when W/L is absent, the robust
  percentile sort scratch, all with checked arithmetic before decoder work.
- Reservation transfer into canonical cache plus current render is synchronous
  and atomic. The LRU cache is bounded to 32 slices and 192 MiB. Canonical
  pixels use one reference-owned buffer, so eviction zeroizes the same storage
  held by all internal references instead of triggering Array copy-on-write.
  A canonical slice too large for the cache is zeroized while its active lease
  still owns the predicted working set, before that lease transfers.
- Each service retains only one replaceable render. `DICOMSliceImage` exposes
  pixels through a synchronous non-escaping buffer closure rather than a Data
  property. Series switch, memory pressure and close zeroize that shared
  storage, invalidate outstanding image handles and release their reservation.
  A caller may deliberately copy bytes inside the closure; that new copy is
  caller-owned and is not described as securely erased.
- Active and render reservations are idempotent RAII leases, so service
  deinitialization cannot strand the process budget. Detached decode/prefetch
  watchers do not retain a service behind an unresponsive decoder. Series
  switch, close and lifecycle failure evict only that session token; global
  cache clearing is reserved for process memory pressure.
- Request/open generations reject late Series opens and stale repaint.
  Same-slice foreground requests share one decode, newer foreground work
  preempts older work, caller cancellation cannot publish, and decoder errors
  map to fixed Kinlogue cases without dependency text, paths or UIDs.
- Focused generated-fixture regression currently passes 60 tests across the
  Core index, geometry, display transform, study indexer, decoder adapter,
  slice service and live Vault descriptor suites. It includes High Bit 14,
  signed/unsigned, rescale, MONOCHROME1/2, W/L fallback, oblique/reversed and
  variable geometry, v1 reopen, two-service global budgeting, cache
  zeroization, pressure/close, shared-waiter cancellation, tampering and
  destroy races, scheduler non-overlap, service-drop lease release, token-scoped
  cache isolation, dual-raw/sort-scratch admission and sub-unit W/L rejection.
- The proportionate `DICOM|PlaintextVault|StorageProcess` regression passes 158
  tests in 12 suites. `scripts/lint.sh`, `scripts/privacy-guard.sh`, package
  graph verification and `git diff --check` pass. The final U4 source passes
  the complete `scripts/test.sh --quiet` gate at 673 tests / 62 suites plus its
  isolated real-socket/RSS test; six Vision checks remain the pre-existing
  outer-sandbox known issues rather than product test failures.
- Clean revision `04449b0092051fc10e6bd37c9199d17074f6995b` passes
  `scripts/verify-app.sh --require-clean-source`. The verified App content
  manifest SHA-256 is
  `efdaf6b1bf709aa241c7e4cb9c874b23d0f735a1f00fd18faddb46897b96905a`;
  the embedded Helper executable SHA-256 is
  `1f7c8c7c955118893268bf1aa4f7c6292113b14b9f627c97b5cb6dc8f6a70578`.
  `scripts/verify-dicom-xpc.sh --use-verified-app` then passes against that
  same report-bound bundle, covering strict signatures, generated raw
  fixtures, malformed input, production Helper crash, compile-time-only hang
  watchdog, bounded logs and zero runtime sockets.

The archived exact `0.4.0` / build `4` catalog-v3 predecessor was compiled
with ordering policy v1 and rejects any other ordering-policy version. U4
source reads policy v1/v2 but writes policy v2. No current App flow can publish
that new index yet, so the archived checkpoint remains valid for the existing
user-visible product; before U5 exposes DICOM import, a new exact predecessor
archive and installed predecessor -> successor -> rollback rehearsal must
prove policy-v2 read/write compatibility. The earlier policy-v1-only rehearsal
must not be reused as that proof.

This remains a Platform/storage capability. App composition, import/review UI
and the Viewer canvas are U5 and later work; no user-visible DICOM viewing
capability is claimed. The three-pass DICOM scrolling RSS/latency benchmark,
installed user flow, macOS 14/15 matrix, private MRI compatibility, Developer
ID/notarization and manual accessibility remain unexecuted until separately
recorded.
