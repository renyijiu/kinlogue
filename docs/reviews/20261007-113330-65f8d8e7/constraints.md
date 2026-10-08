# Review constraints

- Only second-milestone delta in internal, cmd, scripts/build-go-preview.sh, scripts/verify-go-preview.sh, packaging/go-preview, go.mod/go.sum, .github/workflows/go-ci.yml, and third_party/mygo/SOURCE.md plus seven local patch files against pinned upstream v0.2.15. Include scoped new/untracked files; exclude unchanged vendor.

- Read-only code; no commit, push, PR, branch/index mutation, external disclosure or new model route. Preserve prior first-phase review history. Native-only because prior automatic approval review rejected disclosure to Claude; no new authorization and no retry.

- Mac is locked: real IME, SavePanel sandbox export, installed v1 upgrade, and multi-source window acceptance have not run this milestone. Prior first-phase real UI evidence is historical. Do not wait for manual acceptance and do not claim it passed.

- Caller reports final CGO_ENABLED=0 go test ./..., go vet ./..., gofmt, diff check, final signed preview build and verify all passed. App export lifecycle race and desktop full race passed; native/mygo UI tests and targeted race/vet passed. This review did not rerun those tests.

- Privacy: keep operational artifact paths and evidence repository-relative; no private host absolute paths or user content. Runtime concrete locations are provided only in tool dispatch messages.

- No apply authority. Docs worker synchronized narrative and root owns final doc verification; documentation synchronization is context, not expanded code review scope.

- Root triage request: a mere 1000-line threshold without a concrete consequence or project requirement conflict should be tested against admission/validation rules rather than automatically treated as a blocking defect; retain the original lens artifact.
