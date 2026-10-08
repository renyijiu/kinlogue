Intent: Implement the first independent Go desktop report workflow: create member, choose local file, real PDFKit/Vision extraction, raw-and-corrected review, explicit confirmation, member-scoped search, and reopen persisted records. Preserve the separate Swift baseline and clearly report preview limits.

Risk divisions:
- Persistence and authority: internal/library/store.go owns SQLite transactions, original publication, sole-process flock, state gates and member-scoped confirmed search.
- Lifecycle and cancellation: internal/app/service.go serializes mutations through native work, rejects late results and drains on close.
- Native parsing and source evidence: internal/macos and internal/document bound public API extraction/rendering and preserve page/coordinate provenance.
- UI editing and ordering: internal/desktop uses one window, action and preview generations, dirty-navigation dialogs and bilingual semantic keys.
- Packaging trust: cmd/kinlogue, scripts/build-go-preview.sh, scripts/verify-go-preview.sh and packaging/go-preview enforce independent identity, fixed dependency versions, sandbox plus user-selected read-only entitlements and no network.
- Evidence: Go tests, the explicit implementation plan and docs/go-native-preview.md distinguish real current-Mac tests from pending installation/IME/VoiceOver/system-version checks.
Cross-division checks: original durability before DB references; canceled extraction versus saved/confirmed review; UI selections versus stale native preview; runtime bundle identity versus produced entitlements. No generated repetition requires special treatment.
