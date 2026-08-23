# DICOM XPC / Xcode build evidence (2026-08-07)

## Scope

This note records repository-local U1 evidence for the isolated decoder boundary. It does not claim that DICOM import, catalog persistence, a Series viewer, or private MRI compatibility is implemented.

## Locked dependency and build facts

- Root `Package.swift` and the checked-in `packaging/KinlogueDICOMDecoderHelper.xcodeproj` both require official DICOM-Swift exact `1.3.3`.
- Both resolved files pin DICOM-Swift revision `9ae0851e134af274651b646519b8a7aaeee05f05`; the Xcode resolution also pins swift-argument-parser `1.8.2` and ZIPFoundation `0.9.20`.
- The Xcode target is a native macOS XPC service. It directly compiles the repository IPC and Helper sources and is the only production target that links `DicomCore`.
- Xcode generates standard `DICOMDecoder_DicomCore.bundle` and `ZIPFoundation_ZIPFoundation.bundle` resources. The packaged copies are nested only under `KinlogueDICOMDecoderHelper.xpc/Contents/Resources`; no build-machine absolute path or flat root bundle is used.
- `scripts/build-app.sh` signs each resource bundle, then the Helper with its independent entitlement, then the outer App. No recursive `--deep` signing is used in this path.

## Runtime and boundary evidence

`scripts/verify-dicom-xpc.sh` rebuilds the App/Helper from the locked graph, compiles a temporary non-published probe host from the reviewed Foundation-only sources, verifies nested signatures, and launches it through Launch Services. In an environment that permits launchd/XPC, it completed with:

```text
DICOM XPC verification passed: strict signatures and real generated-fixture round-trip
```

The probe generates identity-free Explicit VR Little Endian, single-frame MR Image Storage objects at runtime. It checks ordinary unsigned MONOCHROME2 and signed MONOCHROME1 raw little-endian bytes, proving the Helper uses `getFrame(0)` rather than upstream `getPixels*` presentation transforms. The main-process adapter validates the Part 10 envelope, resets the descriptor offset, and sends one read-only `FileHandle` plus a bounded request. The Helper copies exactly the declared bytes into an opaque private temporary file, rejects an extra byte, invokes `DCMDecoder`, independently validates the original Pixel Data VR/VL plus frame descriptor and bytes, validates the bounded response DTO, and cleans the temporary file. `FileHandle` is explicitly allow-listed on both sides of the `NSXPCInterface`.

A runtime mutation showed exact 1.3.3 can still return expected-sized pixels when the original Pixel Data value length is forged; the Kinlogue VR/VL check now rejects that case. The gate also sends SIGKILL to the production Helper while a real client is active and builds the same Helper source with a compile-time-only hang branch. The production hard watchdog terminates the faulted process before the client's longer timeout, while the host remains alive and receives only a fixed interruption/unavailable code. Repeated requests are observed with `lsof` and create no IP socket. A run-scoped synthetic free-text/URL canary does not appear in Helper unified logs, stdout/stderr, or built artifacts, and Helper logs contain no private filesystem path.

The packaged Helper's signed entitlement is exactly:

```json
{"com.apple.security.app-sandbox":true}
```

It has no network client/server, inherit, user-selected file, or Vault-root entitlement. The main App executable symbol scan contains no `DCMDecoder`, `DicomCore`, DICOMweb, DIMSE, Storage SCP, or JPIP implementation symbol; the Helper contains the approved decoder. Adapter tests verify that interruption, timeout, unavailability, malformed/oversized framing, corrupt/truncated Part 10 input, and invalid DTOs fail closed without an in-process fallback.

## Verification status

- Passed: focused DICOM adapter/IPC tests, packaging boundary tests, exact package graph verifier/tests, privacy guard, third-party notice test, related packaging/release script safety tests, `scripts/build-app.sh`, `scripts/verify-app.sh --lan-prerequisites-only`, strict signature/entitlement/link-map/Mach-O inspection, and the real raw/mutation/crash/hang/log/socket XPC probe.
- Not executed in this uncommitted U1 tree: full `scripts/test.sh`, clean-source full `scripts/verify-app.sh`, installed acceptance, macOS 14/15 compatibility, Viewer UI/accessibility, catalog v3, or any private MRI sample comparison.
- Privacy: no user-provided MRI file was read, copied, logged, or used as a fixture.
