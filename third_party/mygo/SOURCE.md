# mygo local source

This directory is the Go runtime/UI subset of [egoist/mygo v0.2.15](https://github.com/egoist/mygo/tree/v0.2.15), pinned to commit `da84fc54dfc532704f60d5a066c0d1025d4dd282` (2026-10-06). It retains the root Go files, `go.mod`, `go.sum`, `LICENSE`, `internal/`, and `ui/`, including their platform implementations, embedded resources, and tests. Upstream CLI, examples, website, and JavaScript packages are not included. The upstream MIT license is in [LICENSE](LICENSE).

The original module checksum is `h1:I+JbmjJnAXD1XbPRM0qhEHKuVMgdKvV1yNlprPldVXk=`; its `go.mod` checksum is `h1:1sRzZ6jEhKE7iuEQXjyoXDgxyxQ1uTgMHDcDKZvoDIU=`. These identify the upstream module, not this modified directory. Kinlogue still requires `github.com/egoist/mygo v0.2.15` and applies exactly one local `replace` in the root `go.mod`. Build and package checks must retain that distinction rather than describe the binary as using unmodified upstream code.

## Local patch

The patch addresses reproducible text-input data loss and undo boundaries. It changes only:

- `ui/editor.go`: preserve the committed text and selection during input-method composition; cancel without deleting selected text or changing undo/redo history; distinguish app-requested cancellation from native completion so only the former requests a host reset. A later native text/composition callback supersedes an earlier queued cancellation, preserving subsequent candidates. Commit one replacement as one undo step; coalesce consecutive typed characters that replace a selection; keep clipboard paste separate from adjacent typing.
- `ui/input.go`: give the input method the committed document and selection during composition, so native replacement ranges still address the original text; consume app cancellation requests once and deactivate the native input context before reactivating the same field or activating a different field, including fields with identical visible state.
- `ui/runtime.go`: retain the focused input identity alongside the host input state so native marked text cannot survive a field change.
- `ui/access.go`: expose the committed value and selection consistently to accessibility.
- `ui/menu.go`: use the renamed composition cancellation helper.
- `ui/access_test.go`: update the original input-method test to expect the selected character to remain in the bound value until commit.
- `ui/editor_regression_test.go`: add synthetic regression coverage for cancellation, direct and macOS-style unmark/commit sequences, replacement ranges, undo/redo, selection direction, paragraphs, app-set values, focus/read-only transitions, typing pauses, caret movement, and paste boundaries. Host-event tests verify same-field app cancellation and the inactive/active handoff between different input identities; native completion, replacement candidates, and later native events queued after an app command keep their context without unnecessary resets.

Composition candidates are still rendered through the upstream layout path. No private macOS API, replacement widget, additional dependency, or runtime bypass was introduced. Platform bridges are unchanged.

## Verification and updates

Run from the repository root:

```sh
cd third_party/mygo
go test ./ui
go test -race ./ui
go vet ./ui
```

The root module's `go test ./...` does not traverse this nested module; CI must run its UI tests explicitly. These tests use the public headless event path and generated synthetic text. They do not prove that any particular installed Chinese input method, VoiceOver session, or another operating system works end to end; those remain manual/platform acceptance tasks.

When upgrading, compare the seven local patch files against this exact upstream revision, check whether upstream has resolved the same cases, and run both the nested UI tests and Kinlogue's application/package checks. Remove the local replacement only after the selected upstream version passes these regressions. Avoid unrelated formatting or vendoring additional upstream tools into this directory.
