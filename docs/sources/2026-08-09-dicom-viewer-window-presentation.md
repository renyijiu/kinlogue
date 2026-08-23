# DICOM Viewer standard-window presentation evidence (2026-08-09)

This note records the current presentation contract for the local 2D DICOM
Viewer. It contains no source path, patient identity, raw DICOM identifier,
free text, pixel data or screenshot.

## Root cause and implementation

- Both Viewer entry paths previously used SwiftUI `.sheet`: the Library path
  attached a Viewer sheet to `AppShellView`, while the Review path attached a
  second nested sheet to `DICOMStudyReviewContainer`. A sheet is owned by the
  main window and therefore does not provide an independent macOS title bar,
  native traffic-light controls or normal window resizing.
- `KinlogueGUIApp` now declares one typed `WindowGroup` for
  `DICOMStudy.ID`. Both entry paths validate the current catalog-owned study ID
  and call `openWindow(id:value:)`; neither path creates a Viewer sheet.
- This supersedes the earlier Review-path metadata-reuse statement: every
  independent window now loads the same narrow App-owned Viewer contract. It
  does not decode pixels until the Viewer selects a Series and slice.
- The Viewer scene has a 1,120 × 820 point default size and uses
  `.windowResizability(.contentMinSize)`. The existing 760 × 620 point content
  minimum remains the lower bound. Closing the native window triggers the
  existing `onDisappear` cleanup, which stops playback, releases the memory
  pressure monitor and closes the per-window slice service.
- Viewer opening is no longer stored as root modal state. This lets the Review
  sheet remain open while the user compares its aggregate metadata with the
  independent image window, without blocking the main App lifecycle model.

## Verification observed

- A proof-first source contract failed against both legacy `.sheet` routes and
  the missing `WindowGroup`; it passes after the routing change.
- Focused presentation and App-model tests pass, including opening a Viewer
  request while Review remains the active modal and rejecting a study ID after
  it disappears from the refreshed catalog.
- `scripts/test.sh --quiet` passes 761 tests in 73 suites plus the isolated real
  socket/RSS gate; the six Vision checks remain the documented outer-sandbox
  known issues.
- A newly rebuilt dirty-source `dist/Kinlogue.app` was launched as a fresh
  process. Accessibility reported the Viewer as a `standard window` with native
  close, minimize and zoom/full-screen controls. Invoking native window zoom
  retained a functional Viewer; invoking native close removed the Viewer and
  returned focus to the main medical-imaging window.

## Evidence boundary

The local bundle is ad-hoc signed and does not replace the clean-source release,
Developer ID/notarization, independent macOS 14/15, keyboard or VoiceOver
matrices. No private image content or identity-bearing accessibility output is
persisted in this note or the repository.
