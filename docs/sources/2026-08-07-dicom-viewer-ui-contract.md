# DICOM Viewer UI contract evidence (2026-08-07)

This note records repository-local U6 evidence for the bounded 2D Viewer. It
contains no patient data, source path, raw DICOM UID, pixel dump, screenshot or
private sample observation. All automated pixels and studies are generated and
identity-free.

## Implemented boundary

- `LiveAppService` returns only App-owned Series summaries: opaque local ID,
  ordinal, slice count, dimensions and persisted ordering provenance. The UI's
  MR label comes from the frozen supported-object contract, not transported
  DICOM free text.
  `AppComposition` creates a fresh `DICOMSliceService` per Viewer presentation.
- The Viewer has a dedicated immutable metadata contract. Opening it from an
  already-loaded Review reuses that summary instead of rereading and decoding
  the persisted index; opening from the Library loads the same narrow contract.
- `DICOMStudyViewerModel` is `@MainActor`; each metadata/open/render request has
  a generation. Selecting a Series or slice drops the prior image before
  awaiting, and late prior results cannot repaint. A current Series/open or
  slice failure has a stable retry path; metadata failure has no stale retry.
- The Viewer shows only user-confirmed member/date context, modality, dimensions,
  Series/slice ordinals, fallback-order warning and inert-object count. Views do
  not read Vault objects, descriptors, attachment URLs, paths, raw UIDs, decoder
  types or DICOM free text.
- `DICOMImageCanvas` creates a temporary grayscale `CGImage` only inside the
  synchronous non-escaping `DICOMSliceImage.withGrayscaleBytes` borrow. It does
  not copy pixels to `Data`, create a persistent preview, use the clipboard,
  expose drag/export, or log content.
- Inputs are explicit and non-overlapping: primary drag adjusts W/L; Space or
  secondary drag pans; pinch or Command-scroll zooms; ordinary scroll and arrow
  keys move slices. Fit, Reset, zoom controls and a keyboard adjustment menu are
  available without relying on gestures or color alone.
- Continuous W/L input keeps at most one active render plus the newest pending
  request, endpoint slice navigation is a no-op, neighbor prefetch is not
  repeated by W/L renders, and the AppKit canvas invalidates only when the
  rendered image identity or transform changes.
- A main-queue memory-pressure source calls the same bounded service eviction as
  tests. Series switch, Viewer close, study deletion and Vault lifecycle changes
  clear presentation state; a service close invalidates its retained image.

## Verification observed

- Proof-first model RED: the first focused build failed because
  `DICOMStudyViewerModel`, `DICOMSeriesSummary` and the App-owned slice-service
  abstraction did not exist.
- Proof-first layout/source RED: the focused build then failed because the
  Viewer layout and three View files did not exist.
- Final Viewer model/layout/input/canvas/source-safety run passes 17 tests in 4
  suites. It covers first persisted slice plus neighbor prefetch, exact slice
  navigation, late Series result rejection, current failure/retry, open retry,
  finite W/L/zoom/pan, deterministic Fit/Reset, empty/fallback states,
  pressure/close and in-flight close fencing, metadata reuse, endpoint no-op,
  W/L coalescing and redraw invalidation. An offscreen 2×2 grayscale render
  proves persisted top-to-bottom row order. The current-Mac main-thread
  pan/zoom test asserts p95 below 8 ms.
- The proportionate `DICOM|AppLocalization|LocalizationPackaging|LiveDICOMAppServiceIntegrationTests|AppModelTests`
  regression passes 187 tests in 24 suites, including the real generated-folder
  `DICOMImportWorkflow -> PlaintextVault -> LiveAppService` path.
- `scripts/test.sh --quiet` passes 708 tests in 72 suites plus the isolated real
  Socket/RSS gate; six Vision checks remain the existing outer-sandbox known
  issues. Lint, privacy guard, localization drift, exact package graph and diff
  checks pass. The required simplify review applied 3 quality and 5 efficiency
  improvements; its reuse lens found no duplicate abstraction to replace.

## Not yet proved

This U6 source evidence does not claim a clean release bundle, installed Viewer
flow, three-pass scrolling RSS/release result, cached W/L or uncached foreground
decode p95, macOS 14/15 compatibility, private MRI compatibility, or manual
keyboard/VoiceOver/trackpad acceptance. Those remain U7/manual gates. No private
MRI directory was read for this evidence.

## 2026-08-09 revision pointer

The synchronous-borrow canvas lifetime statement above is historical. It is
superseded by [`2026-08-09-dicom-canvas-lifetime-correction.md`](2026-08-09-dicom-canvas-lifetime-correction.md),
which records the CoreAnimation deferred-release crash evidence and the bounded
owned-snapshot correction.

The sheet-presentation and Review metadata-reuse statements above are also
historical. They are superseded by
[`2026-08-09-dicom-viewer-window-presentation.md`](2026-08-09-dicom-viewer-window-presentation.md),
which records the typed standard-window scene and its per-window metadata load.
