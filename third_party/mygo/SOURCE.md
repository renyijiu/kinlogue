# mygo local source

This directory is the Go runtime/UI subset of [egoist/mygo v0.3.7](https://github.com/egoist/mygo/tree/v0.3.7), pinned to commit `d7f292d6d972eb0718d4012d23527df009e6b349` (2026-10-09). It retains the root Go files, `go.mod`, `go.sum`, `LICENSE`, `internal/`, `transfer/`, and `ui/`, including their platform implementations, embedded resources, and tests. Upstream CLI, examples, plugins, website, and JavaScript packages are not included. The upstream MIT license is in [LICENSE](LICENSE).

The original module checksum is `h1:hT6jjSBRqtvl3b0zReFGdGjGaNfz1IqvhnrK+Vrje94=`; its `go.mod` checksum is `h1:1sRzZ6jEhKE7iuEQXjyoXDgxyxQ1uTgMHDcDKZvoDIU=`. These identify the upstream module, not this modified directory. Kinlogue still requires `github.com/egoist/mygo v0.3.7` and applies exactly one local `replace` in the root `go.mod`. Build and package checks must retain that distinction rather than describe the binary as using unmodified upstream code.

## Local patch

Every file except the two below is byte-identical to upstream v0.3.7. The patch lets the app word calendars in its own language; upstream draws them in English only. It changes only:

- `ui/date.go`: add `CalendarText` and `SetCalendarText`. The month title, weekday headings, day names for accessibility and the previous/next month button names come from it; the default is the upstream English wording, so an app that never calls `SetCalendarText` sees no change.
- `ui/datetime_test.go`: add a regression test for app-provided wording, partial wording and restoring the default.

No private macOS API, replacement widget, additional dependency, or runtime bypass was introduced. Platform bridges are unchanged.

## The input patch carried on v0.2.15

Until 2026-10-10 this directory was v0.2.15 with a second patch to `ui/editor.go`, `ui/input.go`, `ui/runtime.go`, `ui/access.go` and `ui/menu.go`. It kept the committed text and selection while an input method composed, restored them when the composition was cancelled, made a commit one undo step, and reset the host's input context between fields. It was not carried to v0.3.7:

- v0.3 routes macOS, Windows and Linux input through a per-control text-input client (`ui/editor_input.go`). A composition and its commit are one undo transaction there, including when the platform ends the marked text before inserting, and each control owns its own client, so the host reset the old patch added has no counterpart.
- Upstream differs on purpose in two respects. Composing over a selection replaces the selected text at once, in the bound value too, and cancelling the composition does not bring it back; one undo does. The old patch kept the selection until commit and left no trace of a cancelled composition.
- The headless `Tester.Compose` still drives the older queued path, where a cancelled composition over a selection also drops the redo history. That path is not the one real input takes on macOS.

`ui/editor_regression_test.go`, which tested the old patch through editor internals that no longer exist, was removed with it.

## Verification and updates

Run from the repository root:

```sh
cd third_party/mygo
go test ./ui
go test -race ./ui
go vet ./ui
```

The root module's `go test ./...` does not traverse this nested module; CI must run its UI tests explicitly. These tests use the headless event path and generated synthetic text. They do not prove that any particular installed Chinese input method, VoiceOver session, or another operating system works end to end; those remain manual/platform acceptance tasks, and the acceptance done on v0.2.15 does not carry over to this version.

When upgrading, replace the retained subset with the new upstream files, re-apply the two-file calendar patch unless upstream has gained its own calendar wording, run upstream's `mygo migrate-ui` and `mygo vet` on Kinlogue when the release asks for it, and run both the nested UI tests and Kinlogue's application/package checks. Remove the local replacement only after the selected upstream version covers the calendar wording. Avoid unrelated formatting or vendoring additional upstream tools into this directory.
