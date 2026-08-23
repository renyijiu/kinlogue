# DICOM MRI Viewer 验收矩阵

Status: the clean `10d58e6` candidate passed installed acceptance with generated,
identity-free data, including the production workflow and embedded XPC Helper.
The same report-bound bundle also passed the standalone XPC signature, raw
round-trip, crash/hang containment, recovery, log-canary and zero-runtime-socket
gate. One explicitly authorized, repository-external private MRI study also
passed an isolated full import. Broader vendor/system coverage remains limited. Manual accessibility,
macOS 14/15 independent machines, Developer ID signing and notarization remain
`notExecuted`. Current status is owned by
[the current release ledger](current-release.md).

## Candidate and evidence identity

| Field | Value |
| --- | --- |
| Installed evidence bundle | `0.5.0` / build `5` |
| Source revision used by installed acceptance | `10d58e6ee4949c85e297e4cc8b5757eeecd481ea` |
| Environment | macOS `26.6`, arm64, Xcode `26.6` / Swift `6.3.3` |
| App content-manifest SHA-256 | `4745f6955d048f39b70e92fff8dd60f5f64263f4e089a2c4a8423f02b5c04c28` |
| App executable SHA-256 | `c5c685976b15c9dbd4061df629071e3acf06660b2d3371100efa9baa705909ea` |
| Helper executable SHA-256 | `9888b87d5bfe9a6a86db90c30c57d571bb1635d42fd503141773e6e262bcb195` |
| Signing posture | ad-hoc; Developer ID and notarization `notExecuted` |

The installed driver used the report-bound App, created a random isolated
acceptance identity, and exercised the production App composition and embedded
XPC Helper through Launch Services. The fixture generator created three Series,
216 viewable classic single-frame MR instances and one retained inert SR object;
it contains no Patient Name, Patient ID or birth date. No private MRI directory
or real patient data was read for this evidence.

## Automated installed result

| Gate | Status | Result |
| --- | --- | --- |
| Folder import and atomic publication | `passed` | 217 retained objects; 216 viewable + 1 inert; 3 Series |
| Restart and reopen | `passed` | 3 slices rendered after restart |
| Viewer render workload | `passed` | 648 slices rendered before restart |
| Cached window/level p95 | `passed` | 1 ms |
| Foreground slice p95 | `passed` | 58 ms |
| Close-time RSS bound | `passed` | peak delta 17,416,192 bytes; within configured limit |
| Import concurrency | `passed` | 2 workers; queue depth 2; maximum 6 managed live descriptors |
| Import I/O | `passed` | source read 1,912,104 bytes; staging write 1,912,104 bytes; managed full reads 5,735,808 bytes |
| Read/write amplification | `passed` | at most 3 managed full reads and 2 writes per object |
| Peak added disk | `passed` | 4,026,608 bytes |
| Study deletion and cleanup | `passed` | DICOM catalog returned to zero studies/Series/objects; owned input and temporary acceptance state removed |
| Ordinary Vault restart/forced termination | `passed` | the post-DICOM generation-bound baseline survived restart and forced termination |
| Installed automated result | `passed` | `dist/verification-report.json` recorded `automatedOverall=passed` and `dicomInstalledAcceptance=passed` |
| Installed candidate standalone XPC crash/hang containment | `passed` | `scripts/verify-dicom-xpc.sh --use-verified-app` passed signatures, raw round-trip, deterministic request-level crash injection, recovery decode, watchdog, unified-log canary and zero runtime sockets against the report-bound bundle |

The acceptance report kept `overall=pendingManual`. Timing and RSS values
are observations from this one machine and synthetic workload, not public
cross-device performance guarantees.

## Private interoperability result

On 2026-08-09, the user explicitly authorized a repository-external private MRI
folder check. The current working source and its locally rebuilt production XPC
Helper completed `DICOMImportWorkflow` into a mode-0700 temporary plaintext Vault;
the retained inventory matched every admitted DICOM object, with no non-DICOM or
duplicate exclusions. The temporary Vault, probe host and structural diagnostic
script were removed immediately after validation. No source path, filename,
patient tag, raw UID, free text, pixel, screenshot or sample file was written to
Git, project docs, application logs or persistent build products. This is one
interoperability sample on the current Mac, not a clean-source release gate or a
cross-vendor compatibility guarantee.

## Product support boundary

| Capability | Current status |
| --- | --- |
| Local folder import of classic single-frame MR Image Storage | supported |
| Explicit VR Little Endian, grayscale MONOCHROME1/2, 8/16-bit bounded path | supported |
| Geometry/Instance Number/stable-content ordering, preferred largest-Series default, visible Series totals/navigation and slice navigation | supported |
| Ordered spatial-slice loop playback | supported at 2/5/10/15 slices per second, bounded by decode time; not a temporal/dynamic reconstruction |
| Viewer window presentation | supported as a resizable standard macOS window with native close, minimize and zoom/full-screen controls |
| Window/level, pan, zoom, Fit/Reset and keyboard entry points | supported |
| Valid non-image objects such as the narrow retained SR fixture | retained inert; not displayed |
| Diagnostic interpretation, measurements, MPR/MIP or 3D reconstruction | unsupported |
| Compressed transfer syntaxes, enhanced/multiframe or color images | unsupported |
| PACS, DIMSE, DICOMweb, cloud sync or remote viewing | unsupported |
| Confirmed study-level member timeline entry | supported; date/member/retained-object summary only |
| OCR, search or comparison over DICOM content | unsupported |
| Persistent previews, screenshots or Viewer-triggered automatic export | unsupported; the separate Settings → Data Management flow can explicitly include confirmed DICOM originals in the all-originals plaintext ZIP |

The Vault stores imported DICOM originals and indexes in plaintext inside the
App Sandbox. SHA-256 is used for local integrity and deduplication, not for
confidentiality, authentication or rollback protection.

## Remaining matrix

| Environment or manual gate | Status | Required evidence |
| --- | --- | --- |
| macOS 14 independent machine | `notExecuted` | install, import, Viewer, restart, delete and lifecycle run |
| macOS 15 independent machine | `notExecuted` | install, import, Viewer, restart, delete and lifecycle run |
| Private real MRI compatibility | `passed` (one sample) | isolated full import passed with explicit user authorization; expand to additional vendors/checks without retaining private data |
| Keyboard, VoiceOver and trackpad manual review | `notExecuted` | focus order, announcements, control reachability, gestures and failure recovery |
| Developer ID signed/notarized distribution | `notExecuted` | signing, notarization, staple, Gatekeeper and exact distributed-artifact replay |

Any further private sample check requires explicit user authorization and must
remain outside Git, logs, screenshots and persistent build products; only a
content-free aggregate result may be recorded here.
