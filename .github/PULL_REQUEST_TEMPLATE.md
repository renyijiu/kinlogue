## What changed

Describe the user-visible or safety outcome, not only the files changed.

## Verification

List the exact commands and manual checks you ran. Mark unexecuted checks honestly.

## Privacy and safety checklist

- [ ] Tests, examples, logs, and screenshots use synthetic data only.
- [ ] This PR contains no real medical records, identifying metadata, private paths, credentials, recovery codes, backup files, or user content.
- [ ] New behavior has proof-first coverage or an explicit reason why automated coverage is unsuitable.
- [ ] Privacy, storage, networking, localization, and release documentation are updated where applicable.
- [ ] `scripts/privacy-guard.sh`, `scripts/verify-docs.sh`, and `git diff --check` pass.

If a vulnerability could expose data or credentials, stop and use private vulnerability reporting instead of opening a public PR or issue.
