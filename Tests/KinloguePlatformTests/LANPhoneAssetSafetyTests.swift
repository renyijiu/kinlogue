import Foundation
import CryptoKit
import Testing
@testable import KinloguePlatform

struct LANPhoneAssetSafetyTests {
    @Test
    func loaderServesOnlyTheFixedEmbeddedRoutes() throws {
        #expect(LANPhoneAsset(rawValue: "/") == .page)
        #expect(LANPhoneAsset(rawValue: "/app.js") == .script)
        #expect(LANPhoneAsset(rawValue: "/styles.css") == .stylesheet)
        #expect(LANPhoneAsset(rawValue: "/index.html") == nil)
        #expect(LANPhoneAsset(rawValue: "/../Package.swift") == nil)
        #expect(LANPhoneAsset(rawValue: "/app.js?cache=1") == nil)
        #expect(LANPhoneAsset.page.contentType == "text/html; charset=utf-8")
        #expect(LANPhoneAsset.script.contentType == "application/javascript; charset=utf-8")
        #expect(LANPhoneAsset.stylesheet.contentType == "text/css; charset=utf-8")

        for asset in LANPhoneAsset.allCases {
            let payload = try LANPhoneAssetLoader.load(asset)
            #expect(!payload.data.isEmpty)
            #expect(payload.contentType == asset.contentType)
            #expect(payload.contentType.hasSuffix("; charset=utf-8"))
        }
    }

    @Test
    func pageIsSemanticAccessibleAndReferencesOnlyLocalAssets() throws {
        let html = try text(for: .page)

        #expect(html.contains("<html lang=\"zh-Hans\">"))
        #expect(html.contains("<main"))
        #expect(html.contains("<form"))
        #expect(html.contains("aria-live=\"polite\""))
        #expect(html.contains("type=\"file\""))
        #expect(html.contains("multiple"))
        #expect(html.contains("id=\"file-list\""))
        #expect(html.contains("可以一次多选，也可以之后继续添加"))
        #expect(html.contains("报告归属、日期和页序稍后在 Mac 上确认"))
        #expect(!html.localizedCaseInsensitiveContains("ba" + "tch"))
        #expect(!html.contains("批" + "次"))
        #expect(!html.contains("上移"))
        #expect(!html.contains("下移"))
        #expect(html.contains("href=\"/styles.css\""))
        #expect(html.contains("src=\"/app.js\""))
        #expect(!html.contains("<style"))
        #expect(!html.contains("style="))
        #expect(!html.contains("<script>"))
        #expect(!html.contains("http://"))
        #expect(!html.contains("https://"))
        #expect(!html.contains("//cdn"))
    }

    @Test
    func stylesheetUsesTheWarmSanctuaryDesignTokensAndInteractionStates() throws {
        let stylesheet = try text(for: .stylesheet)

        for token in [
            "--primary: #1e6254;",
            "--primary-hover: #15453b;",
            "--primary-active: #0f322b;",
            "--surface: #fff8f5;",
            "--container: #f5ece7;",
            "--accent: #df8a4a;",
            "--on-surface: #1e1b18;",
            "--on-variant: #3f4946;",
            "--outline: #bfc9c4;",
            "--chip: #e9e1dc;",
            "--card-hover: #fbf2ed;",
        ] {
            #expect(stylesheet.contains(token), "missing stylesheet token: \(token)")
        }

        #expect(stylesheet.contains("button:hover:not(:disabled)"))
        #expect(stylesheet.contains("button.secondary:hover:not(:disabled)"))
        #expect(stylesheet.contains("button:active:not(:disabled)"))
        #expect(stylesheet.contains("transform: scale(0.95)"))
        #expect(stylesheet.contains("@media (prefers-reduced-motion: no-preference)"))
        #expect(stylesheet.contains("@media (prefers-contrast: more)"))
    }

    @Test
    func scriptUsesTheFixedProtocolWithoutUnsafeBrowserCapabilities() throws {
        let script = try text(for: .script)

        for route in [
            "/api/pair",
            "/api/session",
            "/api/session/logout",
            "/api/files/reserve",
            "/api/files/",
            "/cancel",
        ] {
            #expect(script.contains(route))
        }
        #expect(script.contains("cryptoProvider.randomUUID()"))
        #expect(script.contains("crypto.getRandomValues"))
        #expect(script.contains("function randomID("))
        #expect(script.contains("declaredByteCount: file.size"))
        #expect(script.contains("XMLHttpRequest"))
        #expect(script.contains("request.upload.addEventListener(\"progress\""))
        #expect(script.contains("scheduleProgressRender()"))
        #expect(script.contains("state.progressRenderScheduled"))
        #expect(script.contains("globalThis.requestAnimationFrame(render)"))
        #expect(script.contains("request.send(entry.file)"))
        #expect(script.contains("X-Kinlogue-Attempt-Revision"))
        #expect(script.contains("const MAX_PARALLEL_UPLOADS = 2"))
        #expect(script.contains("const MAX_COMPARISON_CANDIDATES = 4"))
        #expect(script.contains("const COMPARISON_CHUNK_BYTES = 1024 * 1024"))
        #expect(script.contains("const MAX_COMPARISON_READ_BYTES = 64 * 1024 * 1024"))
        #expect(script.contains("const MAX_COMPARISON_MILLISECONDS = 1000"))
        #expect(script.contains("await yieldToBrowser()"))
        #expect(script.contains("back to normal upload"))
        #expect(script.contains("error instanceof UserComparisonCancellation"))
        #expect(script.contains("const hasUnsettledFile = state.entries.some"))
        #expect(script.contains("state.pollTimer = globalThis.setTimeout(async () =>"))
        #expect(script.contains("globalThis.clearTimeout(state.pollTimer)"))
        #expect(script.contains("globalThis.setTimeout(restoreSession, 1100)"))
        #expect(script.contains("error.status === 429"))
        #expect(script.contains("globalThis.clearTimeout(state.restoreTimer)"))
        #expect(script.contains("await pollSession()"))
        #expect(script.contains("state.polling"))
        #expect(script.contains("async function restoreSession()"))
        #expect(script.contains("restoreSession();"))
        #expect(script.contains("state.ignoredDuplicateCount"))
        #expect(script.contains("candidate.state !== \"saved\""))
        #expect(script.contains("确认相同的重复选择"))
        #expect(script.contains("response.outcome === \"saved\""))
        #expect(script.contains("textContent"))
        #expect(script.contains("clearSessionState"))
        #expect(script.contains("credentials: \"same-origin\""))
        #expect(!script.localizedCaseInsensitiveContains("ba" + "tch"))
        #expect(!script.contains("批" + "次"))
        #expect(!script.contains("上移"))
        #expect(!script.contains("下移"))

        let forbidden = [
            "innerHTML",
            "outerHTML",
            "insertAdjacentHTML",
            "eval(",
            "new Function",
            "serviceWorker",
            "localStorage",
            "sessionStorage",
            "indexedDB",
            "caches.",
            "WebSocket",
            ".download",
            "createObjectURL",
            "Math.random",
            "console.",
            "http://",
            "https://",
        ]
        for token in forbidden {
            #expect(!script.contains(token), "forbidden browser capability: \(token)")
        }
    }

    @Test
    func nodeSeamProducesLowercaseRFC4122V4IDsWithoutAnInsecureFallback() throws {
        let app = repository
            .appendingPathComponent("Sources/KinloguePlatform/Resources/LANUpload/app.js")
        let program = #"""
        const fs = require("node:fs");
        const vm = require("node:vm");
        const source = fs.readFileSync(process.argv[1], "utf8");
        const start = source.indexOf("  function randomID(");
        const end = source.indexOf("\n\n  function localEntry", start);
        if (start < 0 || end < 0) process.exit(2);
        const functionSource = source.slice(start, end).replace(/^  /gm, "");
        const randomID = vm.runInNewContext(`${functionSource}; randomID`);
        const direct = randomID({
          randomUUID: () => "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE",
        });
        if (direct !== "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee") process.exit(3);
        const fallback = randomID({
          getRandomValues: (target) => {
            for (let index = 0; index < target.length; index += 1) target[index] = index;
            return target;
          },
        });
        if (!/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(fallback)) {
          process.exit(4);
        }
        let rejected = false;
        try { randomID({}); } catch (_) { rejected = true; }
        if (!rejected || source.includes("Math.random")) process.exit(5);
        """#

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "-e", program, app.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
    }

    @Test
    func nodeSeamOnlySuppressesByteForByteDuplicatesAndBoundsComparison() throws {
        let app = repository
            .appendingPathComponent("Sources/KinloguePlatform/Resources/LANUpload/app.js")
        let program = #"""
        const fs = require("node:fs");
        const vm = require("node:vm");
        const source = fs.readFileSync(process.argv[1], "utf8");
        const start = source.indexOf("  function metadataMatches(");
        const end = source.indexOf("\n\n  async function processPickerFiles", start);
        if (start < 0 || end < 0) process.exit(2);
        const functions = source.slice(start, end).replace(/^  /gm, "");
        const context = {
          MAX_COMPARISON_CANDIDATES: 4,
          COMPARISON_CHUNK_BYTES: 2,
          MAX_COMPARISON_READ_BYTES: 64 * 1024 * 1024,
          MAX_COMPARISON_MILLISECONDS: 1000,
          ComparisonBudgetAbort: class ComparisonBudgetAbort extends Error {},
          UserComparisonCancellation: class UserComparisonCancellation extends Error {},
          state: { entries: [] },
          performance: { now: () => 0 },
          setTimeout,
          Uint8Array,
          Promise,
        };
        vm.createContext(context);
        vm.runInContext(`${functions}; this.isConfirmedDuplicate = isConfirmedDuplicate;`, context);
        function file(bytes, fail = false) {
          const data = Uint8Array.from(bytes);
          return {
            name: "same.jpg", size: data.length, lastModified: 10, type: "image/jpeg",
            slice(start, end) {
              return { arrayBuffer: async () => {
                if (fail) throw new Error("read failed");
                return data.slice(start, end).buffer;
              }};
            },
          };
        }
        function entry(bytes, fail = false) {
          return { file: file(bytes, fail), removed: false };
        }
        (async () => {
          const original = entry([1, 2, 3, 4]);
          const equal = entry([1, 2, 3, 4]);
          original.state = "saved";
          context.state.entries = [original, equal];
          if (await context.isConfirmedDuplicate(equal, { startedAt: 0, readBytes: 0 })) {
            process.exit(3);
          }
          original.state = "reserved";
          if (!await context.isConfirmedDuplicate(equal, { startedAt: 0, readBytes: 0 })) {
            process.exit(8);
          }
          const unequal = entry([1, 2, 3, 9]);
          context.state.entries = [original, unequal];
          if (await context.isConfirmedDuplicate(unequal, { startedAt: 0, readBytes: 0 })) {
            process.exit(4);
          }
          const unreadable = entry([1, 2, 3, 4], true);
          context.state.entries = [original, unreadable];
          let fellBack = false;
          try {
            await context.isConfirmedDuplicate(unreadable, { startedAt: 0, readBytes: 0 });
          } catch (error) {
            fellBack = error && error.constructor.name === "ComparisonBudgetAbort";
          }
          if (!fellBack) process.exit(5);
          const cancelled = entry([1, 2, 3, 4]);
          cancelled.removed = true;
          context.state.entries = [original, cancelled];
          let cancelledLocally = false;
          try {
            await context.isConfirmedDuplicate(cancelled, { startedAt: 0, readBytes: 0 });
          } catch (error) {
            cancelledLocally = error && error.constructor.name === "UserComparisonCancellation";
          }
          if (!cancelledLocally) process.exit(6);
        })().catch(() => process.exit(7));
        """#

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "-e", program, app.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
    }

    @Test
    func nodeSeamReleasesPollGuardWhenFailedPollClearsSession() throws {
        let app = repository
            .appendingPathComponent("Sources/KinloguePlatform/Resources/LANUpload/app.js")
        let program = #"""
        const fs = require("node:fs");
        const vm = require("node:vm");
        const source = fs.readFileSync(process.argv[1], "utf8");
        const start = source.indexOf("  async function pollSession(");
        const end = source.indexOf("\n\n  function hasCryptographicIDSource", start);
        const epochStart = source.indexOf("  function beginSessionEpoch(");
        const epochEnd = source.indexOf("\n\n  async function pair", epochStart);
        if (start < 0 || end < 0 || epochStart < 0 || epochEnd < 0) process.exit(2);
        const functions = [
          source.slice(epochStart, epochEnd),
          source.slice(start, end),
        ].join("\n\n").replace(/^  /gm, "");
        let requestCount = 0;
        let mergedCount = 0;
        const context = {
          state: {
            csrfToken: "old-token",
            polling: false,
            generation: 0,
            clearing: false,
            pollTimer: 0,
            restoreTimer: 0,
            requests: new Set(),
            controllers: new Set(),
            entries: [{ state: "reserved" }],
            pendingUploads: [],
            activeUploads: 0,
            ignoredDuplicateCount: 0,
          },
          elements: {
            pairSection: {}, uploadSection: {}, sessionSection: {}, filePicker: {},
          },
          requestJSON: async () => {
            requestCount += 1;
            if (requestCount === 1) {
              const error = new Error("connection lost");
              error.status = 500;
              throw error;
            }
            return { files: [] };
          },
          mergeSession: () => { mergedCount += 1; },
          renderFiles: () => {},
          setStatus: () => {},
          clearTimeout,
          setTimeout,
        };
        vm.createContext(context);
        vm.runInContext(`${functions}; this.pollSession = pollSession;`, context);
        (async () => {
          await context.pollSession();
          if (context.state.generation !== 1) process.exit(3);
          if (context.state.polling !== false) process.exit(4);
          context.state.csrfToken = "new-token";
          await context.pollSession();
          if (requestCount !== 2 || mergedCount !== 1) process.exit(5);
        })().catch(() => process.exit(6));
        """#

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "-e", program, app.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
    }

    @Test
    func nodeSeamRejectsStalePollAfterRetryCancelAndUploadCompletion() throws {
        let app = repository
            .appendingPathComponent("Sources/KinloguePlatform/Resources/LANUpload/app.js")
        let program = #"""
        const fs = require("node:fs");
        const vm = require("node:vm");
        const source = fs.readFileSync(process.argv[1], "utf8");
        function section(startMarker, endMarker) {
          const start = source.indexOf(startMarker);
          const end = source.indexOf(endMarker, start);
          if (start < 0 || end < 0) process.exit(2);
          return source.slice(start, end);
        }
        const functions = [
          section("  function finishUpload(", "\n\n  async function retryEntry"),
          section("  async function retryEntry(", "\n\n  async function removeEntry"),
          section("  async function removeEntry(", "\n\n  function removeEntryLocally"),
          section("  function removeEntryLocally(", "\n\n  function addFiles"),
          section("  function applyRemoteStatus(", "\n\n  function fileStateLabel"),
          section("  function mergeSession(", "\n\n  async function pollSession"),
          section("  async function pollSession(", "\n\n  function startPolling"),
        ].join("\n\n").replace(/^  /gm, "");
        let releasePoll;
        const heldPoll = new Promise((resolve) => { releasePoll = resolve; });
        const uploadRequest = {};
        const retry = {
          remoteFileID: "retry-file", file: {}, displayName: "retry.pdf",
          declaredByteCount: 4, receivedByteCount: 0, attemptRevision: 1,
          state: "failed", progress: 0, request: null, removed: false,
        };
        const cancelled = {
          remoteFileID: "cancel-file", file: {}, displayName: "cancel.pdf",
          declaredByteCount: 4, receivedByteCount: 1, attemptRevision: 0,
          state: "uploading", progress: 25, request: null, removed: false,
        };
        const completed = {
          remoteFileID: "complete-file", file: {}, displayName: "complete.pdf",
          declaredByteCount: 4, receivedByteCount: 2, attemptRevision: 0,
          state: "uploading", progress: 50, request: uploadRequest, removed: false,
        };
        const context = {
          state: {
            csrfToken: "token", generation: 0, mutationEpoch: 0, polling: false,
            clearing: false, entries: [retry, cancelled, completed],
            pendingUploads: [], activeUploads: 1,
            requests: new Set([uploadRequest]), cancelledRemoteFileIDs: new Set(),
          },
          requestJSON: async (path) => path === "/api/session" ? heldPoll : {},
          reserveAndQueue: async () => {},
          renderFiles: () => {}, pumpUploads: () => {}, startPolling: () => {},
          setStatus: () => {}, encodeURIComponent, Math,
        };
        vm.createContext(context);
        vm.runInContext(
          `${functions}; this.retryEntry = retryEntry; this.removeEntry = removeEntry;`
            + " this.finishUpload = finishUpload; this.pollSession = pollSession;"
            + " this.mergeSession = mergeSession; this.applyRemoteStatus = applyRemoteStatus;",
          context
        );
        (async () => {
          const poll = context.pollSession();
          await Promise.resolve();
          await context.retryEntry(retry);
          await context.removeEntry(cancelled);
          context.finishUpload(completed, uploadRequest, true, 0);
          releasePoll({ files: [
            { remoteFileID: "retry-file", displayName: "retry.pdf", declaredByteCount: 4,
              receivedByteCount: 1, attemptRevision: 1, state: "interrupted" },
            { remoteFileID: "cancel-file", displayName: "cancel.pdf", declaredByteCount: 4,
              receivedByteCount: 1, attemptRevision: 0, state: "receiving" },
            { remoteFileID: "complete-file", displayName: "complete.pdf", declaredByteCount: 4,
              receivedByteCount: 2, attemptRevision: 0, state: "receiving" },
          ]});
          await poll;
          if (retry.attemptRevision !== 2 || retry.state !== "reserving") process.exit(3);
          if (completed.state !== "saved" || completed.receivedByteCount !== 4) process.exit(4);
          if (context.state.entries.some((entry) => entry.remoteFileID === "cancel-file")) process.exit(5);

          context.mergeSession({ files: [{
            remoteFileID: "cancel-file", displayName: "cancel.pdf", declaredByteCount: 4,
            receivedByteCount: 3, attemptRevision: 0, state: "receiving",
          }]});
          if (context.state.entries.some((entry) => entry.remoteFileID === "cancel-file")) process.exit(6);
          context.applyRemoteStatus(retry, {
            remoteFileID: "retry-file", displayName: "retry.pdf", declaredByteCount: 4,
            receivedByteCount: 4, attemptRevision: 1, state: "saved",
          });
          if (retry.attemptRevision !== 2 || retry.state !== "reserving") process.exit(7);
          context.applyRemoteStatus(completed, {
            remoteFileID: "complete-file", displayName: "complete.pdf", declaredByteCount: 4,
            receivedByteCount: 2, attemptRevision: 1, state: "receiving",
          });
          if (completed.attemptRevision !== 0 || completed.state !== "saved"
              || completed.receivedByteCount !== 4) process.exit(8);
        })().catch(() => process.exit(9));
        """#

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "-e", program, app.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
    }

    @Test
    func nodeSeamRejectsRestoreSnapshotThatPredatesSuccessfulPairing() throws {
        let app = repository
            .appendingPathComponent("Sources/KinloguePlatform/Resources/LANUpload/app.js")
        let program = #"""
        const fs = require("node:fs");
        const vm = require("node:vm");
        const source = fs.readFileSync(process.argv[1], "utf8");
        const pairStart = source.indexOf("  async function pair(");
        const epochStart = source.indexOf("  function beginSessionEpoch(");
        const end = source.indexOf("\n\n  async function pollSession", pairStart);
        if (pairStart < 0 || end < 0) process.exit(2);
        const functions = [
          epochStart >= 0 ? source.slice(epochStart, pairStart) : "",
          source.slice(pairStart, end),
        ].join("\n\n").replace(/^  /gm, "");
        let releaseRestore;
        const heldRestore = new Promise((resolve) => { releaseRestore = resolve; });
        let status = "waiting";
        const context = {
          state: {
            csrfToken: "", entries: [], pendingUploads: [], activeUploads: 0,
            ignoredDuplicateCount: 0, pollTimer: 0, restoreTimer: 0,
            controllers: new Set(), requests: new Set(), pickerTask: Promise.resolve(),
            generation: 0, mutationEpoch: 7, polling: false, clearing: false,
            progressRenderScheduled: false,
            cancelledRemoteFileIDs: new Set(["old-cancelled-file"]),
          },
          elements: {
            pairCode: { value: "123456" }, pairSection: {}, uploadSection: {},
            sessionSection: {}, filePicker: { disabled: false },
          },
          requestJSON: async (path) => {
            if (path === "/api/session") return heldRestore;
            if (path === "/api/pair") return { csrfToken: "new-token" };
            throw new Error("unexpected request");
          },
          applyRemoteStatus: () => {}, renderFiles: () => {}, startPolling: () => {},
          hasCryptographicIDSource: () => true,
          setStatus: (message) => { status = message; },
          clearTimeout, Promise, Map, Math, Array,
        };
        vm.createContext(context);
        vm.runInContext(
          `${functions}; this.pair = pair; this.restoreSession = restoreSession;`,
          context
        );
        (async () => {
          const restore = context.restoreSession();
          await Promise.resolve();
          await context.pair({ preventDefault() {} });
          const pairedGeneration = context.state.generation;
          releaseRestore({
            csrfToken: "stale-token",
            files: [{
              remoteFileID: "stale-file", displayName: "stale.pdf",
              declaredByteCount: 4, receivedByteCount: 4,
              attemptRevision: 0, state: "saved",
            }],
          });
          await restore;
          if (context.state.csrfToken !== "new-token") process.exit(3);
          if (context.state.entries.length !== 0) process.exit(4);
          if (status !== "已连接。请选择要上传的文件。 ") process.exit(5);
          if (pairedGeneration !== 1 || context.state.generation !== pairedGeneration) process.exit(6);
          if (context.state.mutationEpoch !== 0) process.exit(7);
          if (context.state.cancelledRemoteFileIDs.size !== 0) process.exit(8);
        })().catch(() => process.exit(9));
        """#

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "-e", program, app.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
    }

    @Test
    func nodeSeamDropsQueuedPickerWorkAfterSessionGenerationChanges() throws {
        let app = repository
            .appendingPathComponent("Sources/KinloguePlatform/Resources/LANUpload/app.js")
        let program = #"""
        const fs = require("node:fs");
        const vm = require("node:vm");
        const source = fs.readFileSync(process.argv[1], "utf8");
        const processStart = source.indexOf("  async function processPickerFiles(");
        const processEnd = source.indexOf("\n\n  async function reserveAndQueue", processStart);
        const addStart = source.indexOf("  function addFiles(");
        const addEnd = source.indexOf("\n\n  function applyRemoteStatus", addStart);
        if (processStart < 0 || processEnd < 0 || addStart < 0 || addEnd < 0) process.exit(2);
        const functions = [
          source.slice(processStart, processEnd),
          source.slice(addStart, addEnd),
        ].join("\n\n").replace(/^  /gm, "");
        let releaseComparison;
        const comparison = new Promise((resolve) => { releaseComparison = resolve; });
        let localEntryCount = 0;
        let status = "old session";
        const oldFiles = [{ name: "first.pdf" }, { name: "second.pdf" }];
        const context = {
          MAX_SESSION_FILES: 1000,
          UserComparisonCancellation: class UserComparisonCancellation extends Error {},
          state: {
            entries: [],
            pendingUploads: [],
            ignoredDuplicateCount: 0,
            pickerTask: Promise.resolve(),
            generation: 0,
          },
          elements: { filePicker: { files: oldFiles, value: "picked" } },
          monotonicNow: () => 0,
          localEntry: (file) => {
            localEntryCount += 1;
            if (localEntryCount > 1) throw new Error("stale picker continued");
            return { file, state: "comparing", removed: false };
          },
          isConfirmedDuplicate: async () => {
            await comparison;
            return false;
          },
          removeEntryLocally: () => {},
          reserveAndQueue: async (entry) => { context.state.pendingUploads.push(entry); },
          renderFiles: () => {},
          setStatus: (message) => { status = message; },
          Array,
          Promise,
        };
        vm.createContext(context);
        vm.runInContext(
          `${functions}; this.addFiles = addFiles;`,
          context
        );
        (async () => {
          context.addFiles();
          await Promise.resolve();
          await Promise.resolve();
          if (context.state.entries.length !== 1) process.exit(3);
          context.state.generation += 1;
          context.state.entries = [];
          context.state.pendingUploads = [];
          status = "new session";
          releaseComparison();
          await context.state.pickerTask;
          if (context.state.entries.length !== 0) process.exit(4);
          if (context.state.pendingUploads.length !== 0) process.exit(5);
          if (status !== "new session") process.exit(6);
          if (localEntryCount !== 1) process.exit(7);
        })().catch(() => process.exit(8));
        """#

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "-e", program, app.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
    }

    @Test
    func nodeSeamDropsReserveFailureAfterSessionGenerationChanges() throws {
        let app = repository
            .appendingPathComponent("Sources/KinloguePlatform/Resources/LANUpload/app.js")
        let program = #"""
        const fs = require("node:fs");
        const vm = require("node:vm");
        const source = fs.readFileSync(process.argv[1], "utf8");
        const start = source.indexOf("  async function reserveAndQueue(");
        const end = source.indexOf("\n\n  function pumpUploads", start);
        if (start < 0 || end < 0) process.exit(2);
        const functionSource = source.slice(start, end).replace(/^  /gm, "");
        let rejectReserve;
        let renderCount = 0;
        let pollingStartCount = 0;
        const reserveRequest = new Promise((_, reject) => { rejectReserve = reject; });
        const context = {
          state: { generation: 0, pendingUploads: [] },
          requestJSON: async () => reserveRequest,
          applyRemoteStatus: () => {},
          pumpUploads: () => {},
          renderFiles: () => { renderCount += 1; },
          startPolling: () => { pollingStartCount += 1; },
          setStatus: () => {},
        };
        const entry = {
          remoteFileID: "old-file",
          displayName: "old.pdf",
          declaredByteCount: 4,
          mediaType: "application/pdf",
          attemptRevision: 0,
          removed: false,
          state: "reserving",
        };
        vm.createContext(context);
        vm.runInContext(
          `${functionSource}; this.reserveAndQueue = reserveAndQueue;`,
          context
        );
        (async () => {
          const task = context.reserveAndQueue(entry);
          await Promise.resolve();
          context.state.generation += 1;
          rejectReserve(new Error("old request aborted"));
          await task;
          if (renderCount !== 0) process.exit(3);
          if (pollingStartCount !== 0) process.exit(4);
          if (context.state.pendingUploads.length !== 0) process.exit(5);
          if (entry.state !== "reserving") process.exit(6);
        })().catch(() => process.exit(7));
        """#

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "-e", program, app.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
    }

    @Test
    func nodeSeamDropsUploadCompletionAfterSessionGenerationChanges() throws {
        let app = repository
            .appendingPathComponent("Sources/KinloguePlatform/Resources/LANUpload/app.js")
        let program = #"""
        const fs = require("node:fs");
        const vm = require("node:vm");
        const source = fs.readFileSync(process.argv[1], "utf8");
        const start = source.indexOf("  function finishUpload(");
        const end = source.indexOf("\n\n  async function retryEntry", start);
        if (start < 0 || end < 0) process.exit(2);
        const functionSource = source.slice(start, end).replace(/^  /gm, "");
        let renderCount = 0;
        let pumpCount = 0;
        let pollingStartCount = 0;
        let status = "new session";
        const request = {};
        const entry = {
          request,
          removed: false,
          state: "uploading",
          progress: 0,
          receivedByteCount: 0,
          declaredByteCount: 4,
        };
        const context = {
          state: {
            generation: 1,
            requests: new Set(),
            activeUploads: 1,
            clearing: false,
          },
          renderFiles: () => { renderCount += 1; },
          pumpUploads: () => { pumpCount += 1; },
          startPolling: () => { pollingStartCount += 1; },
          setStatus: (message) => { status = message; },
          Math,
        };
        vm.createContext(context);
        vm.runInContext(
          `${functionSource}; this.finishUpload = finishUpload;`,
          context
        );
        context.finishUpload(entry, request, true, 0);
        if (context.state.activeUploads !== 1) process.exit(3);
        if (entry.state !== "uploading" || entry.request !== request) process.exit(4);
        if (status !== "new session") process.exit(5);
        if (renderCount !== 0 || pumpCount !== 0 || pollingStartCount !== 0) process.exit(6);
        """#

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "-e", program, app.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
    }

    @Test
    func nodeSeamDropsCancelFailureAfterSessionGenerationChanges() throws {
        let app = repository
            .appendingPathComponent("Sources/KinloguePlatform/Resources/LANUpload/app.js")
        let program = #"""
        const fs = require("node:fs");
        const vm = require("node:vm");
        const source = fs.readFileSync(process.argv[1], "utf8");
        const start = source.indexOf("  async function removeEntry(");
        const end = source.indexOf("\n\n  function removeEntryLocally", start);
        if (start < 0 || end < 0) process.exit(2);
        const functionSource = source.slice(start, end).replace(/^  /gm, "");
        let rejectCancel;
        const cancelRequest = new Promise((_, reject) => { rejectCancel = reject; });
        let renderCount = 0;
        let pollingStartCount = 0;
        let status = "old session";
        const entry = {
          remoteFileID: "old-file",
          attemptRevision: 0,
          request: null,
          removed: false,
          state: "uploading",
        };
        const context = {
          state: {
            generation: 0,
            pendingUploads: [],
          },
          requestJSON: async () => cancelRequest,
          removeEntryLocally: () => {},
          renderFiles: () => { renderCount += 1; },
          startPolling: () => { pollingStartCount += 1; },
          setStatus: (message) => { status = message; },
          encodeURIComponent,
        };
        vm.createContext(context);
        vm.runInContext(
          `${functionSource}; this.removeEntry = removeEntry;`,
          context
        );
        (async () => {
          const task = context.removeEntry(entry);
          await Promise.resolve();
          context.state.generation += 1;
          status = "new session";
          rejectCancel(new Error("old cancel aborted"));
          await task;
          if (status !== "new session") process.exit(3);
          if (!entry.removed || entry.state !== "cancelling") process.exit(4);
          if (renderCount !== 1 || pollingStartCount !== 1) process.exit(5);
        })().catch(() => process.exit(6));
        """#

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "-e", program, app.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
    }

    @Test
    func stylesheetIsSelfContainedAndMobileFriendly() throws {
        let stylesheet = try text(for: .stylesheet)

        #expect(stylesheet.contains("env(safe-area-inset-top)"))
        #expect(stylesheet.contains("@media (max-width: 30rem)"))
        #expect(stylesheet.contains("prefers-reduced-motion"))
        #expect(!stylesheet.contains("@import"))
        #expect(!stylesheet.contains("url("))
        #expect(!stylesheet.contains("http://"))
        #expect(!stylesheet.contains("https://"))
    }

    @Test
    func thirdPartyNoticePinsTheReviewedLicensesAndAttributions() throws {
        let noticeURL = repository.appendingPathComponent("THIRD_PARTY_NOTICES.md")
        let noticeData = try Data(contentsOf: noticeURL)
        let notice = String(decoding: noticeData, as: UTF8.self)
        let digest = SHA256.hash(data: noticeData)
            .map { String(format: "%02x", $0) }
            .joined()

        #expect(
            digest == "0cb360cee49618f8e90185ba8e0c7d36ce7a7c4f6174e688584ba8417365f904"
        )
        for requiredText in [
            "SwiftNIO 2.101.3",
            "Swift Atomics 1.3.1",
            "Swift Collections 1.6.0",
            "Swift System 1.7.5",
            "DICOM-Swift 1.3.3",
            "Swift Argument Parser 1.8.2",
            "ZIPFoundation 0.9.20",
            "Copyright 2025 Thales Matheus Mendonça Santos",
            "Copyright (c) 2017-2025 Thomas Zoechling",
            "The SwiftNIO Project",
            "This product contains NodeJS's llhttp.",
            "Copyright Fedor Indutny, 2018.",
            "Apache License, Version 2.0",
            "TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION",
            "END OF TERMS AND CONDITIONS",
        ] {
            #expect(notice.contains(requiredText))
        }
    }

    @Test
    func buildScriptCopiesTheSwiftPackageResourceBundleIntoTheApp() throws {
        let script = try repositoryText("scripts/build-app.sh")
        let loader = try repositoryText(
            "Sources/KinloguePlatform/LAN/LANPhoneAssets.swift"
        )

        #expect(script.contains("Kinlogue_KinloguePlatform.bundle"))
        #expect(script.contains("Contents/Resources"))
        #expect(script.contains("/usr/bin/ditto"))
        #expect(script.contains("THIRD_PARTY_NOTICES.md"))
        #expect(script.contains("! -L \"$THIRD_PARTY_NOTICE_SOURCE\""))
        #expect(script.contains("-s \"$THIRD_PARTY_NOTICE_SOURCE\""))
        #expect(script.contains("/bin/cp --"))
        #expect(loader.contains("Bundle.main.resourceURL"))
        #expect(loader.contains("Kinlogue_KinloguePlatform.bundle"))
        #expect(loader.contains("Bundle.module"))
        #expect(loader.contains(
            "guard Bundle.main.bundleURL.pathExtension != \"app\" else"
        ))
        let packagedLookup = try #require(loader.range(of: "Bundle.main.resourceURL"))
        let testFallback = try #require(loader.range(of: "Bundle.module"))
        #expect(packagedLookup.lowerBound < testFallback.lowerBound)
    }

    @Test
    func mainBundleVerifierUsesAnExactResourceAllowList() throws {
        let verifier = try repositoryText("scripts/verify-app.sh")

        #expect(verifier.contains(
            "EXPECTED_PLATFORM_RESOURCE_BUNDLE=\"Kinlogue_KinloguePlatform.bundle\""
        ))
        for resource in [
            "./$EXPECTED_ICON_FILE",
            "./$EXPECTED_PLATFORM_RESOURCE_BUNDLE/Info.plist",
            "./$EXPECTED_PLATFORM_RESOURCE_BUNDLE/LANUpload/app.js",
            "./$EXPECTED_PLATFORM_RESOURCE_BUNDLE/LANUpload/index.html",
            "./$EXPECTED_PLATFORM_RESOURCE_BUNDLE/LANUpload/styles.css",
            "./$EXPECTED_THIRD_PARTY_NOTICE_FILE",
        ] {
            #expect(verifier.contains(resource))
        }
        #expect(verifier.contains(
            "EXPECTED_THIRD_PARTY_NOTICE_FILE=\"THIRD_PARTY_NOTICES.md\""
        ))
        #expect(verifier.contains(
            "EXPECTED_THIRD_PARTY_NOTICE_SHA256=\"0cb360cee49618f8e90185ba8e0c7d36ce7a7c4f6174e688584ba8417365f904\""
        ))
        #expect(verifier.contains(
            "/usr/bin/cmp -s \"$THIRD_PARTY_NOTICE_SOURCE\" \"$THIRD_PARTY_NOTICE_FILE\""
        ))
        #expect(verifier.contains(
            "/usr/bin/cmp -s \"$phone_asset_source\" \"$phone_asset_bundle\""
        ))
        #expect(verifier.contains("artifact.thirdPartyNoticeSHA256"))
        #expect(verifier.contains(
            "[[ \"$RESOURCE_FILES\" == \"$EXPECTED_RESOURCE_FILES\" ]]"
        ))
        #expect(verifier.contains(
            "/usr/bin/find \"$APP_BUNDLE\" -type l -print -quit"
        ))
        #expect(!verifier.contains(
            "./$EXPECTED_PLATFORM_RESOURCE_BUNDLE/**"
        ))
    }

    private func text(for asset: LANPhoneAsset) throws -> String {
        let payload = try LANPhoneAssetLoader.load(asset)
        return String(decoding: payload.data, as: UTF8.self)
    }

    private func repositoryText(_ relativePath: String) throws -> String {
        return try String(
            contentsOf: repository.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private var repository: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
