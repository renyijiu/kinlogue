# DICOM canvas lifetime correction evidence (2026-08-09)

This note revises only the pixel-lifetime statement in the 2026-08-07 Viewer UI
evidence. It contains no patient data, private source path, raw UID, pixel dump
or screenshot.

## Observed failure

- The current local bundle produced `EXC_BREAKPOINT / SIGTRAP` while rapidly
  displaying slices. Its executable UUID matched the crash report.
- The failing thread was CoreAnimation's `CA::CG::Queue`. The stack entered the
  custom `CGDataProvider` release callback from `DICOMImageCanvasView.draw(_:)`,
  then failed Swift's executor check because the callback inherited main-actor
  isolation but CoreGraphics released it off the main queue.
- A prior report had the same exception, queue and source location. The reports
  showed neither memory-pressure termination nor a decoder-Helper crash, so the
  failure is not specific evidence of a corrupt Series.
- The deferred release also disproved the earlier assumption that a temporary
  `CGImage` could safely keep a borrowed slice pointer only for the lexical
  duration of `withGrayscaleBytes`.

## Corrected contract

- `DICOMCanvasImageFactory` validates positive dimensions and exact grayscale
  byte count, then copies the borrowed bytes into immutable `Data` and creates
  `CGDataProvider(data:)`. CoreGraphics retains that owned storage for any
  deferred rendering or cleanup thread; there is no App-owned release callback.
- `DICOMImageCanvasView` retains at most one owned `CGImage`, keyed by
  `renderID`. Transform-only redraws reuse it; a new frame or empty state
  replaces and releases it.
- The snapshot exists only in presentation memory. It is not persisted,
  exported, copied to the clipboard, searched, OCRed or logged.

## Verification

- The proof-first test initially failed to compile because the owned image
  factory did not exist. It now invalidates the source slice buffer after image
  creation and verifies that the provider still contains the original generated
  2×2 grayscale bytes.
- `DICOMViewerInteractionTests` passes 5 tests in 1 suite. The current full
  suite passes 760 tests in 73 suites plus the independent real socket/RSS gate.
  Lint, privacy, localization-drift and diff checks pass.
- A strict ad-hoc signed local bundle was rebuilt from the current dirty source.
  This does not replace clean-source release, macOS 14/15 or manual accessibility
  gates.

## 2026-08-11 off-main preparation revision

- A later review found that the owned `Data` copy, although lifetime-safe, still
  ran synchronously in the `@MainActor` canvas update. The maximum supported
  frame could therefore copy about 64 MiB while blocking input and drawing.
- The production canvas now sends each new `renderID` to one process-shared
  `DICOMCanvasImageRenderer` actor. That actor serializes the borrowed-byte copy
  and owned `CGImage` construction away from the main actor; cancellation is
  checked before and after the synchronous copy so an in-flight copy may finish,
  but it cannot publish and concurrent snapshot copies remain bounded to one.
- CoreGraphics' immutable `CGImage` is accepted as `Sendable` by the Swift 6
  SDK overlay, and its provider owns immutable `CFData`; no new
  `@unchecked Sendable` wrapper or borrowed release callback is required. The
  main actor publishes only a matching request generation and `renderID`.
- Focused tests cover source-buffer invalidation, transform-only reuse, a late
  older result, and a late result after empty-state clearing. The seven
  `DICOMViewerInteractionTests`, related layout tests, `swift build`, and diff
  check pass; full-suite, clean-source bundle and installed/manual gates were
  not executed for this revision.
