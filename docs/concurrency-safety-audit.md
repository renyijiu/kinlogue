# Swift 6 unchecked Sendable audit

This audit covers production declarations under `Sources/`. It records why the
remaining compiler escape hatches are safe, what invariant must remain true,
and how repository automation detects unreviewed additions.

<!-- concurrency-inventory: unchecked=67 files=35 dicom=10 core=0 unsafe=2 -->

## Current inventory

| Area | Inventory | Boundary |
| --- | --- | --- |
| `KinlogueCore` | 0 unchecked declarations | Domain values and state machines remain checked `Sendable`. |
| `KinloguePlatform/DICOM` | 10 `@unchecked Sendable` declarations | Lock-protected pixel/reply/budget state, actor-backed runtime services, and one scanner-owned descriptor lease with structured concurrent read-only use. |
| LAN and storage platform code | 33 `@unchecked Sendable` declarations | Private locks/serial queues, actor confinement, SwiftNIO event-loop confinement, or immutable task-local error transport. |
| Original export orchestration and capability probes | 7 `@unchecked Sendable` declarations | Lock-protected cancellation/progress and probe metrics; one exporter-owned descriptor whose close lifetime is structured and idempotent. |
| Encrypted backup and restore | 16 `@unchecked Sendable` declarations | Immutable service authority, actor/cross-process serialization, lock-protected configuration/history/metrics and publication leases, and structured descriptor lifetimes. |
| DICOM XPC Helper | 2 `nonisolated(unsafe)` properties | One private lock protects both process-lifecycle collections. |

The inventory is 66 unchecked conformances across 35 files, plus two unsafe
static properties in the Helper. The audit found no demonstrated data race.
Three immutable/stateless wrappers (`LANManualReadHandler`,
`LANInboundBytesHandler`, and `LANUploadSink.PendingReservations`) use checked
`Sendable` conformance and must not gain unsynchronized mutable state.

## Safety mechanisms

- **Private-lock ownership.** Reply completion, pixel lifetime, DICOM memory
  reservations, LAN admission/permit accounting, partial-file ownership,
  filesystem durability state, mutation/process leases and network-monitor
  lifecycle keep all shared mutable state behind a
  private `NSLock`. RAII permits remove their owner under the lock before
  releasing an upstream reservation, so repeated release/deinit remains
  idempotent.
- **Actor confinement.** `LANReceiver.Runtime` is created, read and mutated only
  by the enclosing `LANReceiver` actor. `DICOMSliceRuntime` stores immutable
  references to a lock-protected budget and actor-based cache/scheduler.
  `DICOMVaultImportSession` carries immutable metadata plus a lock-protected
  mutation lease that is validated by the `PlaintextVault` actor.
- **Serial observation queue.** `LANInboxChangeMonitor` installs and owns every
  Dispatch filesystem source on one private queue; generation reads and stop
  transitions synchronize on that queue, handlers capture the monitor weakly,
  and deinitialization only cancels exclusively owned sources.
- **Structured operation ownership.** `VaultDICOMOperationDescriptorLease` has
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
- **Original export orchestration.** `OriginalExportCancellationGate` and
  `OriginalExportProgressRelay` keep their cancellation phase and coalesced
  progress state behind private locks; accepted progress is delivered on the
  main actor. `PlaintextOriginalArchiveSource` has immutable descriptor
  metadata, an idempotent lock-protected `close`, and a structured exporter
  lifetime in which actor-confined reads finish before the source is closed.
- **Writer probe metrics.** `WorkerState`, `IntegerMaximum`, and
  `WorkerStateTimestamp` expose only lock-protected mutations and copied
  snapshots. Their mutable result, maximum, and timestamp storage never
  escapes the wrapper.
- **Encrypted backup and restore.** Configuration and repository history use
  private locks plus process-wide/cross-process serialization. Publication
  flocks the owner-only, no-follow app-private configuration-root directory
  inode bound to the expected writer/repository authority, then preserves the
  `repository → configuration` lock order through authoritative scan and
  durable witness. Retention keeps that lease while its lock-protected scan
  generation advances only after exact target and planned-keep validation.
  Work, source, output and restored-file descriptors have one structured
  owner; mutable counters and close/publication transitions are lock-protected,
  and every read closure finishes before its owner closes the descriptor.
  Restore root activation additionally holds the shared Vault mutation lease.
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

Thread Sanitizer runs for LAN upload, DICOM lifetime and Vault mutation remain
a useful future release gate, but they do not replace these structural
invariants and are not required for the retained ad-hoc test distribution.
