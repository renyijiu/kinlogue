# mygo dependency provenance

As of 2026-10-26, Kinlogue uses the unmodified official [mygo v0.6.4](https://github.com/egoist/mygo/tree/v0.6.4) module, pinned to commit `6255ea40139d06e0762a7c4a32626148ba410478` (2026-10-25 UTC). The module checksum is `h1:VzCqZKgvXcym5cSYKoC6IkTgcVeGZquPiui/a3oE36o=` and its go.mod checksum is `h1:dVav53PwF2xEotjf4oA5lTY2Jp2exgzyjLhbSXhbMwE=`.

Upstream now provides translated calendar controls through `App.SetLocale` and `locales/zh-Hans`. The calendar patch, copied source and local replacement have been retired. This directory retains provenance and the MIT [LICENSE](LICENSE) only; it is not a Go module. The builder obtains the linked module's license from the checksum-verified module cache. The earlier input patch remains retired.

See the [upgrade source note](../../docs/sources/mygo-0.6.4-upgrade-2026-10-26.md) and [current verification](../../docs/go-native-preview.md#本轮验证状态). Root application tests cover integration; `go test github.com/egoist/mygo/ui` additionally runs the locked upstream UI tests. Headless tests do not establish real IME, VoiceOver or platform acceptance.

## Archived v0.4.8 notes

The notes below describe the former source subset, patch and nested-module commands. They are historical, not current build instructions. The former files remain available in [commit bdb25e1](https://github.com/renyijiu/kinlogue/tree/bdb25e1ebf650be880621aea1c100b57d87afce9/third_party/mygo).

### mygo local source

This directory is the Go runtime/UI subset of [egoist/mygo v0.4.8](https://github.com/egoist/mygo/tree/v0.4.8), pinned to commit `c0e1068027faf8b14777c9cb925c937ef34ac2bb` (2026-10-12 UTC). It retains the root Go files, `go.mod`, `go.sum`, `LICENSE`, `internal/`, `transfer/`, `audio/`, and `ui/`, including their platform implementations, embedded resources, and tests. Upstream CLI, examples, plugins, website, and JavaScript packages are not included. The upstream MIT license is in [LICENSE](LICENSE).

The original module checksum is `h1:NpzFFiv8L4uXhkriknAehoucN//gtCtnGgr/DzQxZIw=`; its `go.mod` checksum is `h1:+B7ZTBwVfa/nL/6+o6Vm8xBFYwJoFCg4VJbY9k6T0E8=`. These identify the upstream module, not this modified directory. Kinlogue still requires `github.com/egoist/mygo v0.4.8` and applies exactly one local `replace` in the root `go.mod`. Build and package checks must retain that distinction rather than describe the binary as using unmodified upstream code.

#### Local patch

The only behavioral patch lets the app word calendars in its own language; upstream draws them in English only. It changes these two files:

- `ui/date.go`: add `CalendarText` and `SetCalendarText`. The month title, weekday headings, day names for accessibility and the previous/next month button names come from it; the default is the upstream English wording, so an app that never calls `SetCalendarText` sees no change.
- `ui/datetime_test.go`: add a regression test for app-provided wording, partial wording and restoring the default.

`internal/gpu/metal/metal.go` has only a four-field whitespace alignment from `gofmt`, required by the repository formatting gate. All other retained files are byte-identical to upstream v0.4.8.

No private macOS API, replacement widget, additional dependency, or runtime bypass was introduced. Platform bridges are unchanged.

#### The input patch carried on v0.2.15

Until 2026-10-10 this directory was v0.2.15 with a second patch to `ui/editor.go`, `ui/input.go`, `ui/runtime.go`, `ui/access.go` and `ui/menu.go`. It kept the committed text and selection while an input method composed, restored them when the composition was cancelled, made a commit one undo step, and reset the host's input context between fields. It was not carried to v0.3.7:

- v0.3 routes macOS, Windows and Linux input through a per-control text-input client (`ui/editor_input.go`). A composition and its commit are one undo transaction there, including when the platform ends the marked text before inserting, and each control owns its own client, so the host reset the old patch added has no counterpart.
- Upstream differs on purpose in two respects. Composing over a selection replaces the selected text at once, in the bound value too, and cancelling the composition does not bring it back; one undo does. The old patch kept the selection until commit and left no trace of a cancelled composition.
- The headless `Tester.Compose` still drives the older queued path, where a cancelled composition over a selection also drops the redo history. That path is not the one real input takes on macOS.

`ui/editor_regression_test.go`, which tested the old patch through editor internals that no longer exist, was removed with it.

#### Verification and updates

Run from the repository root:

```sh
cd third_party/mygo
go test ./ui
go test -race ./ui
go vet ./ui
```

The root module's `go test ./...` does not traverse this nested module; CI must run its UI tests explicitly. These tests use the headless event path and generated synthetic text. They do not prove that any particular installed Chinese input method, VoiceOver session, or another operating system works end to end; those remain manual/platform acceptance tasks, and the acceptance done on v0.2.15 does not carry over to this version.

When upgrading, replace the retained subset with the new upstream files, re-apply the two-file calendar patch unless upstream has gained its own calendar wording, run upstream's `mygo migrate-ui` and `mygo vet` on Kinlogue when the release asks for it, and run both the nested UI tests and Kinlogue's application/package checks. Remove the local replacement only after the selected upstream version covers the calendar wording. Avoid unrelated formatting or vendoring additional upstream tools into this directory.
