# Swift 6 unchecked Sendable audit

This audit covers production declarations under `Sources/`. It records why the
remaining compiler escape hatches are safe, what invariant must remain true,
and how repository automation detects unreviewed additions.

<!-- concurrency-inventory: unchecked=55 files=30 dicom=10 core=0 unsafe=2 -->

## Current inventory

| Area | Inventory | Boundary |
| --- | --- | --- |
| `KinlogueCore` | 0 unchecked declarations | Domain values and state machines remain checked `Sendable`. |
| `KinloguePlatform/DICOM` | 10 `@unchecked Sendable` declarations | Lock-protected pixel/reply/budget state, actor-backed runtime services, and one scanner-owned descriptor lease with structured concurrent read-only use. |
| LAN and storage platform code | 28 `@unchecked Sendable` declarations | Private locks/serial queues, actor confinement, SwiftNIO event-loop confinement, or immutable task-local error transport. |
| Backup capture, restore and settings platform code | 9 `@unchecked Sendable` declarations | Lock-protected logical spool, original pins, per-reader descriptors and cancellation; immutable restore verifier and transaction authority; staging output and restored-file writers with one structured owner; a settings store whose file transactions are serialized by a process lock plus `flock`. |
| App backup, export and folder authority | 3 `@unchecked Sendable` declarations | Immutable folder authority collaborators, and lock-protected export cancellation and progress coalescing. |
| Writer and storage-scale probes | 5 `@unchecked Sendable` declarations | Probe metrics and phase records behind private locks, returned as copied snapshots. |
| DICOM XPC Helper | 2 `nonisolated(unsafe)` properties | One private lock protects both process-lifecycle collections. |

The inventory is 55 unchecked conformances across 30 files, plus two unsafe
static properties in the Helper. The audit found no demonstrated data race.
Three immutable/stateless wrappers (`LANManualReadHandler`,
`LANInboundBytesHandler`, and `LANUploadSink.PendingReservations`) use checked
`Sendable` conformance and must not gain unsynchronized mutable state.

The SQLite kernel adds two unchecked owners: `SQLiteLibraryStore` serializes
connection/lifetime/pin admission with a lock around GRDB's serial queue;
`SQLiteOriginalPin` serializes descriptor consumption and idempotent release,
retaining the store until its pin is released. `SQLiteReportQueryCancellation`
keeps the query cancellation flag behind a private lock across the Swift task
and GRDB queue; it never interrupts another query. `SQLiteLANScopes` protects its token set with a private lock; scope creation/revocation and final publication also share database admission, so revocation cannot acknowledge before an in-flight commit completes. These are development paths.
DICOM active-operation IDs use the same admission lock and cover scanner/indexer
and gaps between staged originals; recovery skips them and owner close rejects
while they remain. Async SQLite decoding retains one private pin and an owned
FileHandle across await; no pin lock crosses await, and a post-validation failure
also closes the duplicate descriptor. This adds no unchecked declarations.
App recovery and LAN task ownership stays on the main actor.
SQLiteCommitNotifications protects bounded stream continuations with its own lock;
yield/finish happen after database admission has been released. The search
Predicate retains immutable CF strings and one captured locale across synchronous
worker lanes; LaneResults locks one result per lane, and concurrentPerform drains
all lanes before the database read ends. App observation and request registries
are main-actor owned and drain before destructive lifecycle work.
The shared SQLiteLibraryOwner protects its single connection claim with a lock
while retaining immutable filesystem authority across root replacement. Logical
backup spool, original pin ownership, per-reader descriptors and cancellation
have private locks; descriptor reads finish before close, and batch pin release
leaves the wrapper lock before entering store admission. The capture progress
handler is confined to one synchronous serialized connection scope and uninstalled
before its retained context ends. Probe phase and FD/footprint metrics return
locked snapshots and never expose mutable collections. SQLiteOriginalReadMetrics
uses a private lock for application pread-byte counts; it does not measure kernel
disk traffic. Integrity quarantine stays under database admission, while the App
idle task and cancellation/drain identity stay on MainActor.

## Safety mechanisms

- **Private-lock ownership.** Reply completion, pixel lifetime, DICOM memory
  reservations, LAN admission/permit accounting, partial-file ownership,
  filesystem durability state and network-monitor
  lifecycle keep all shared mutable state behind a
  private `NSLock`. RAII permits remove their owner under the lock before
  releasing an upstream reservation, so repeated release/deinit remains
  idempotent.
- **Actor confinement.** `LANReceiver.Runtime` is created, read and mutated only
  by the enclosing `LANReceiver` actor. `DICOMSliceRuntime` stores immutable
  references to a lock-protected budget and actor-based cache/scheduler.
- **Structured operation ownership.** `DICOMOperationDescriptorLease` has
  one close owner in the folder scanner. A bounded throwing task group may
  concurrently read its stable descriptor for POSIX operations; child tasks do
  not mutate or close the lease, and the group joins before the scanner closes
  it. Detached users or any additional mutation would require explicit
  synchronization.
- **SwiftNIO event-loop confinement.** Request-line and HTTP handler mutable
  fields are touched only on their channel event loop. Context wrappers may
  cross a task boundary only to schedule work back onto that loop before the
  context is dereferenced.
- **Immutable error transport.** `LANUploadSink.PendingAdmissionFailure` is an
  immutable wrapper created, thrown and consumed inside one sink task chain;
  its existential error is not exposed as independently shared mutable state.
- **Backup and export orchestration.** `BackupExportCancellationGate` and
  `BackupProgressRelay` keep their cancellation phase and coalesced progress
  state behind private locks; accepted progress is delivered on the main
  actor. `BackupFolderAuthority` stores only immutable Sendable collaborators,
  and each folder use owns its security scope for the duration of the call.
- **Writer probe metrics.** `WorkerState`, `IntegerMaximum`, and
  `WorkerStateTimestamp` expose only lock-protected mutations and copied
  snapshots. Their mutable result, maximum, and timestamp storage never
  escapes the wrapper.
- **Backup archives and restore.** `BackupArchiveWriter` is an actor; the
  ZIP provider runs in one nonisolated synchronous call and reads only from
  the snapshot's lock-protected spool and pin readers, which finish before the
  snapshot is released. `BackupSettingsStore` holds no mutable state of its
  own: every read-modify-write runs under a process-wide lock and an
  owner-only `flock`. Restore staging output, restored-file writers and the
  verifier have one structured owner per preparation; mutable byte counts and
  close transitions are lock-protected. Restore root activation runs under a
  per-root in-process gate while the library owner's lock keeps other
  processes out.
- **Helper process lifecycle.** `DICOMDecoderProcessLifecycle.lock` protects
  both unsafe static collections for every request/watchdog read and mutation.
  A timeout may terminate the Helper; successful requests leave ordinary XPC
  process lifetime management to macOS.

Every declaration above now has a nearby `SAFETY:` comment naming its concrete
invariant. The comment is part of the implementation contract, not evidence by
itself; the corresponding lock/actor/event-loop path and tests remain the
source of truth.

## Automated change policy

`scripts/verify-docs.sh`, invoked by `scripts/lint.sh`, recomputes this inventory
from `Sources/`, requires a nearby `SAFETY:` invariant for every
`@unchecked Sendable` and `nonisolated(unsafe)` occurrence, and fails when the
machine-readable inventory above drifts. New escape hatches therefore require:

1. the smallest viable scope and a concrete synchronization/confinement reason;
2. a nearby `SAFETY:` comment;
3. a concurrency or lifecycle test that would fail when the invariant breaks;
4. an updated inventory and audit explanation.

Thread Sanitizer runs for LAN upload, DICOM lifetime and library mutation remain
a useful future release gate, but they do not replace these structural
invariants and are not required for the retained ad-hoc test distribution.
