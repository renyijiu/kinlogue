"use strict";

(() => {
  const MAX_PARALLEL_UPLOADS = 2;
  const MAX_SESSION_FILES = 1000;
  const MAX_COMPARISON_CANDIDATES = 4;
  const COMPARISON_CHUNK_BYTES = 1024 * 1024;
  const MAX_COMPARISON_READ_BYTES = 64 * 1024 * 1024;
  const MAX_COMPARISON_MILLISECONDS = 1000;

  class ComparisonBudgetAbort extends Error {}
  class UserComparisonCancellation extends Error {}

  const elements = {
    pairSection: document.querySelector("#pair-section"),
    pairForm: document.querySelector("#pair-form"),
    pairCode: document.querySelector("#pair-code"),
    uploadSection: document.querySelector("#upload-section"),
    sessionSection: document.querySelector("#session-section"),
    filePicker: document.querySelector("#file-picker"),
    fileList: document.querySelector("#file-list"),
    emptyFiles: document.querySelector("#empty-files"),
    duplicateSummary: document.querySelector("#duplicate-summary"),
    clearPage: document.querySelector("#clear-page"),
    status: document.querySelector("#status"),
  };

  const state = {
    csrfToken: "",
    entries: [],
    pendingUploads: [],
    activeUploads: 0,
    ignoredDuplicateCount: 0,
    pollTimer: 0,
    restoreTimer: 0,
    controllers: new Set(),
    requests: new Set(),
    pickerTask: Promise.resolve(),
    generation: 0,
    mutationEpoch: 0,
    polling: false,
    clearing: false,
    progressRenderScheduled: false,
    cancelledRemoteFileIDs: new Set(),
  };

  function setStatus(message) {
    elements.status.textContent = message;
  }

  function publicError(response) {
    const error = new Error(response && response.status === 429
      ? "操作过于频繁，请稍后再试。"
      : "操作未完成，请确认 Mac 仍在接收后重试。");
    error.status = response ? response.status : 0;
    return error;
  }

  async function requestJSON(path, method, body, extraHeaders = {}) {
    const headers = { Accept: "application/json", ...extraHeaders };
    if (body !== undefined) {
      headers["Content-Type"] = "application/json";
    }
    if (state.csrfToken) {
      headers["X-Kinlogue-CSRF"] = state.csrfToken;
    }
    const controller = new AbortController();
    state.controllers.add(controller);
    try {
      const response = await window.fetch(path, {
        method,
        headers,
        body: body === undefined ? undefined : JSON.stringify(body),
        credentials: "same-origin",
        cache: "no-store",
        redirect: "error",
        referrerPolicy: "no-referrer",
        signal: controller.signal,
      });
      if (!response.ok) {
        throw publicError(response);
      }
      return response.status === 204 ? null : response.json();
    } finally {
      state.controllers.delete(controller);
    }
  }

  function randomID(cryptoProvider = globalThis.crypto) {
    if (cryptoProvider && typeof cryptoProvider.randomUUID === "function") {
      try {
        return cryptoProvider.randomUUID().toLowerCase();
      } catch (_) {}
    }
    if (!cryptoProvider || typeof cryptoProvider.getRandomValues !== "function") {
      throw new Error("cryptographic random IDs unavailable");
    }
    const bytes = new Uint8Array(16);
    cryptoProvider.getRandomValues(bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
    return [hex.slice(0, 8), hex.slice(8, 12), hex.slice(12, 16),
      hex.slice(16, 20), hex.slice(20)].join("-");
  }

  function localEntry(file) {
    return {
      remoteFileID: randomID(),
      file,
      displayName: file.name,
      declaredByteCount: file.size,
      mediaType: file.type || null,
      attemptRevision: 0,
      state: "comparing",
      progress: 0,
      receivedByteCount: 0,
      request: null,
      removed: false,
    };
  }

  function metadataMatches(left, right) {
    return left.name === right.name
      && left.size === right.size
      && left.lastModified === right.lastModified
      && left.type === right.type;
  }

  function monotonicNow() {
    return globalThis.performance && typeof globalThis.performance.now === "function"
      ? globalThis.performance.now()
      : Date.now();
  }

  function yieldToBrowser() {
    return new Promise((resolve) => {
      if (typeof globalThis.requestAnimationFrame === "function") {
        globalThis.requestAnimationFrame(() => resolve());
      } else {
        globalThis.setTimeout(resolve, 0);
      }
    });
  }

  async function filesAreExactlyEqual(candidate, entry, budget) {
    const left = candidate.file;
    const right = entry.file;
    if (!left || !right || typeof left.slice !== "function" || typeof right.slice !== "function") {
      throw new ComparisonBudgetAbort("comparison unavailable");
    }
    for (let offset = 0; offset < left.size; offset += COMPARISON_CHUNK_BYTES) {
      if (entry.removed) {
        throw new UserComparisonCancellation();
      }
      if (monotonicNow() - budget.startedAt >= MAX_COMPARISON_MILLISECONDS) {
        throw new ComparisonBudgetAbort("comparison timed out");
      }
      const end = Math.min(left.size, offset + COMPARISON_CHUNK_BYTES);
      const nextReadBytes = budget.readBytes + ((end - offset) * 2);
      if (nextReadBytes > MAX_COMPARISON_READ_BYTES) {
        throw new ComparisonBudgetAbort("comparison read budget exhausted");
      }
      let chunks;
      try {
        chunks = await Promise.all([
          left.slice(offset, end).arrayBuffer(),
          right.slice(offset, end).arrayBuffer(),
        ]);
      } catch (_) {
        throw new ComparisonBudgetAbort("comparison read failed");
      }
      budget.readBytes = nextReadBytes;
      const leftBytes = new Uint8Array(chunks[0]);
      const rightBytes = new Uint8Array(chunks[1]);
      for (let index = 0; index < leftBytes.length; index += 1) {
        if (leftBytes[index] !== rightBytes[index]) {
          return false;
        }
      }
      if (end < left.size) {
        await yieldToBrowser();
      }
    }
    return true;
  }

  async function isConfirmedDuplicate(entry, budget) {
    const candidates = state.entries.filter((candidate) => (
      candidate !== entry
      && !candidate.removed
      && candidate.file
      && candidate.state !== "saved"
      && metadataMatches(candidate.file, entry.file)
    ));
    const bounded = candidates.slice(0, MAX_COMPARISON_CANDIDATES);
    for (const candidate of bounded) {
      if (await filesAreExactlyEqual(candidate, entry, budget)) {
        return true;
      }
    }
    if (candidates.length > MAX_COMPARISON_CANDIDATES) {
      throw new ComparisonBudgetAbort("candidate budget exhausted");
    }
    return false;
  }

  async function processPickerFiles(files, generation) {
    if (generation !== state.generation) return;
    const budget = { startedAt: monotonicNow(), readBytes: 0 };
    for (const file of files) {
      if (generation !== state.generation) return;
      if (state.entries.length >= MAX_SESSION_FILES) {
        setStatus(`本次连接最多保留 ${MAX_SESSION_FILES} 个文件。`);
        break;
      }
      const entry = localEntry(file);
      state.entries.push(entry);
      state.mutationEpoch += 1;
      renderFiles();
      try {
        const isDuplicate = await isConfirmedDuplicate(entry, budget);
        if (generation !== state.generation) return;
        if (isDuplicate) {
          entry.removed = true;
          removeEntryLocally(entry);
          state.ignoredDuplicateCount += 1;
          renderFiles();
          continue;
        }
      } catch (error) {
        if (generation !== state.generation) return;
        if (error instanceof UserComparisonCancellation) {
          removeEntryLocally(entry);
          renderFiles();
          continue;
        }
        // Capability, read, candidate, byte and time budget failures all fall
        // back to normal upload; the Mac remains the deduplication authority.
      }
      if (entry.removed) {
        removeEntryLocally(entry);
        continue;
      }
      entry.state = "reserving";
      state.mutationEpoch += 1;
      renderFiles();
      await reserveAndQueue(entry);
      if (generation !== state.generation) return;
    }
    if (generation !== state.generation) return;
    renderFiles();
    if (state.ignoredDuplicateCount > 0) {
      setStatus(`已忽略 ${state.ignoredDuplicateCount} 个确认相同的重复选择，其余文件继续上传。`);
    }
  }

  async function reserveAndQueue(entry) {
    const generation = state.generation;
    try {
      const response = await requestJSON("/api/files/reserve", "POST", {
        remoteFileID: entry.remoteFileID,
        displayName: entry.displayName,
        declaredByteCount: entry.declaredByteCount,
        mediaType: entry.mediaType,
        attemptRevision: entry.attemptRevision,
      });
      if (generation !== state.generation || entry.removed) {
        return;
      }
      if (!response || !response.file || response.file.remoteFileID !== entry.remoteFileID) {
        throw new Error("invalid reserve response");
      }
      applyRemoteStatus(entry, response.file);
      if (entry.state !== "saved" && entry.state !== "cancelled") {
        entry.state = "queued";
        state.pendingUploads.push(entry);
        state.mutationEpoch += 1;
        pumpUploads();
      }
    } catch (_) {
      if (generation === state.generation && !entry.removed) {
        entry.state = "failed";
        state.mutationEpoch += 1;
        setStatus("一个文件暂时无法开始上传，可以重试。 ");
      }
    }
    if (generation !== state.generation) return;
    renderFiles();
    startPolling();
  }

  function pumpUploads() {
    while (state.activeUploads < MAX_PARALLEL_UPLOADS && state.pendingUploads.length > 0) {
      const entry = state.pendingUploads.shift();
      if (!entry || entry.removed || entry.state !== "queued") {
        continue;
      }
      entry.state = "uploading";
      state.activeUploads += 1;
      state.mutationEpoch += 1;
      beginUpload(entry);
    }
    renderFiles();
  }

  function beginUpload(entry) {
    const generation = state.generation;
    const request = new XMLHttpRequest();
    entry.request = request;
    state.requests.add(request);
    state.mutationEpoch += 1;
    request.open("PUT", `/api/files/${encodeURIComponent(entry.remoteFileID)}`);
    request.responseType = "json";
    request.withCredentials = true;
    request.setRequestHeader("Content-Type", "application/octet-stream");
    request.setRequestHeader("X-Kinlogue-CSRF", state.csrfToken);
    request.setRequestHeader("X-Kinlogue-Attempt-Revision", String(entry.attemptRevision));
    request.upload.addEventListener("progress", (event) => {
      if (generation !== state.generation) return;
      if (event.lengthComputable && event.total > 0) {
        entry.progress = Math.min(100, Math.round((event.loaded / event.total) * 100));
        entry.receivedByteCount = Math.min(entry.declaredByteCount, event.loaded);
        state.mutationEpoch += 1;
        scheduleProgressRender();
      }
    });
    request.addEventListener("load", () => {
      const succeeded = request.status >= 200 && request.status < 300
        && request.response && request.response.outcome === "saved";
      finishUpload(entry, request, succeeded, generation);
    });
    request.addEventListener("error", () => finishUpload(entry, request, false, generation));
    request.addEventListener("abort", () => finishUpload(entry, request, false, generation));
    request.send(entry.file);
  }

  function finishUpload(entry, request, succeeded, generation) {
    if (generation !== state.generation || entry.request !== request) {
      return;
    }
    entry.request = null;
    state.requests.delete(request);
    state.activeUploads = Math.max(0, state.activeUploads - 1);
    state.mutationEpoch = (state.mutationEpoch || 0) + 1;
    if (!state.clearing && !entry.removed) {
      if (succeeded) {
        entry.state = "saved";
        entry.progress = 100;
        entry.receivedByteCount = entry.declaredByteCount;
        setStatus("文件已保存到 Mac。可以继续添加文件。 ");
      } else if (entry.state !== "cancelling") {
        entry.state = "failed";
        setStatus("一个文件上传中断，可以重试整个文件。 ");
      }
    }
    renderFiles();
    pumpUploads();
    startPolling();
  }

  async function retryEntry(entry) {
    if (!entry.file || entry.removed || entry.state !== "failed") {
      return;
    }
    entry.attemptRevision += 1;
    entry.progress = 0;
    entry.receivedByteCount = 0;
    entry.state = "reserving";
    state.mutationEpoch = (state.mutationEpoch || 0) + 1;
    renderFiles();
    await reserveAndQueue(entry);
  }

  async function removeEntry(entry) {
    if (entry.state === "saved" || entry.state === "cancelled") {
      return;
    }
    entry.removed = true;
    state.mutationEpoch = (state.mutationEpoch || 0) + 1;
    const generation = state.generation;
    if (entry.state === "comparing") {
      removeEntryLocally(entry);
      renderFiles();
      return;
    }
    state.pendingUploads = state.pendingUploads.filter((candidate) => candidate !== entry);
    entry.state = "cancelling";
    if (entry.request) {
      entry.request.abort();
    }
    renderFiles();
    startPolling();
    try {
      await requestJSON(
        `/api/files/${encodeURIComponent(entry.remoteFileID)}/cancel`,
        "POST",
        undefined,
        { "X-Kinlogue-Attempt-Revision": String(entry.attemptRevision) }
      );
      if (generation !== state.generation) return;
      entry.state = "cancelled";
      if (state.cancelledRemoteFileIDs) {
        state.cancelledRemoteFileIDs.add(entry.remoteFileID);
      }
      state.mutationEpoch = (state.mutationEpoch || 0) + 1;
      removeEntryLocally(entry);
      setStatus("已取消这个文件。 ");
    } catch (_) {
      if (generation !== state.generation) return;
      entry.removed = false;
      entry.state = "failed";
      state.mutationEpoch = (state.mutationEpoch || 0) + 1;
      setStatus("暂时无法取消这个文件，请重试。 ");
    }
    renderFiles();
  }

  function removeEntryLocally(entry) {
    const index = state.entries.indexOf(entry);
    if (index >= 0) {
      state.entries.splice(index, 1);
      state.mutationEpoch += 1;
    }
  }

  function addFiles() {
    const picked = Array.from(elements.filePicker.files || []);
    const generation = state.generation;
    elements.filePicker.value = "";
    state.pickerTask = state.pickerTask
      .then(() => processPickerFiles(picked, generation))
      .catch(() => {
        if (generation === state.generation) {
          setStatus("部分文件暂时无法加入，请重新选择。");
        }
      });
  }

  function applyRemoteStatus(entry, remote) {
    if (!remote || remote.remoteFileID !== entry.remoteFileID) {
      return;
    }
    if (state.cancelledRemoteFileIDs
        && state.cancelledRemoteFileIDs.has(remote.remoteFileID)) {
      return;
    }
    const remoteRevision = Number.isSafeInteger(remote.attemptRevision)
      ? remote.attemptRevision
      : -1;
    if (remoteRevision < entry.attemptRevision) {
      return;
    }
    if (["saved", "cancelled"].includes(entry.state)) {
      return;
    }
    if (entry.state === "cancelling" && remote.state !== "cancelled") {
      return;
    }
    if (remoteRevision === entry.attemptRevision) {
      if (entry.state === "failed" && !["saved", "cancelled"].includes(remote.state)) {
        return;
      }
      if (entry.state === "uploading" && remote.state === "reserved") {
        return;
      }
    }
    entry.displayName = remote.displayName;
    entry.declaredByteCount = remote.declaredByteCount;
    entry.receivedByteCount = remote.receivedByteCount;
    entry.attemptRevision = remoteRevision;
    if (["reserved", "receiving", "saved", "interrupted", "cancelled"].includes(remote.state)) {
      entry.state = remote.state;
    }
  }

  function fileStateLabel(entry) {
    switch (entry.state) {
    case "comparing": return "正在检查是否重复";
    case "reserving": return "正在准备上传";
    case "reserved":
    case "queued": return "等待上传";
    case "uploading":
    case "receiving": return `上传中 ${entry.progress || 0}%`;
    case "saved": return "已保存到 Mac";
    case "interrupted":
    case "failed": return "上传中断，可重试";
    case "cancelling": return "正在取消";
    case "cancelled": return "已取消";
    default: return "状态已更新";
    }
  }

  function fileSize(bytes) {
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KiB`;
    return `${(bytes / (1024 * 1024)).toFixed(1)} MiB`;
  }

  function actionButton(label, action, disabled = false) {
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = label;
    button.disabled = disabled;
    button.addEventListener("click", action);
    return button;
  }

  function renderFiles() {
    elements.fileList.replaceChildren();
    elements.emptyFiles.hidden = state.entries.length > 0;
    elements.duplicateSummary.hidden = state.ignoredDuplicateCount === 0;
    elements.duplicateSummary.textContent = state.ignoredDuplicateCount > 0
      ? `已忽略 ${state.ignoredDuplicateCount} 个确认相同的重复选择。`
      : "";
    for (const entry of state.entries) {
      const row = document.createElement("li");
      row.className = "file-row";
      const name = document.createElement("span");
      name.className = "file-name";
      name.textContent = entry.displayName;
      const meta = document.createElement("span");
      meta.className = "file-meta";
      meta.textContent = `${fileSize(entry.declaredByteCount)} · ${fileStateLabel(entry)}`;
      row.append(name, meta);
      const actions = document.createElement("span");
      actions.className = "row-actions";
      if ((entry.state === "failed" || entry.state === "interrupted") && entry.file) {
        actions.append(actionButton("重试", () => retryEntry(entry)));
      }
      if (!["saved", "cancelled", "cancelling"].includes(entry.state) && entry.file) {
        actions.append(actionButton("移除", () => removeEntry(entry)));
      }
      if (actions.childElementCount > 0) {
        row.append(actions);
      }
      elements.fileList.append(row);
    }
  }

  function scheduleProgressRender() {
    if (state.progressRenderScheduled) return;
    state.progressRenderScheduled = true;
    const generation = state.generation;
    const render = () => {
      state.progressRenderScheduled = false;
      if (generation === state.generation) renderFiles();
    };
    if (typeof globalThis.requestAnimationFrame === "function") {
      globalThis.requestAnimationFrame(render);
    } else {
      globalThis.setTimeout(render, 0);
    }
  }

  function beginSessionEpoch() {
    state.generation += 1;
    state.polling = false;
    if (state.pollTimer) globalThis.clearTimeout(state.pollTimer);
    if (state.restoreTimer) globalThis.clearTimeout(state.restoreTimer);
    state.pollTimer = 0;
    state.restoreTimer = 0;
    for (const request of state.requests) request.abort();
    for (const controller of state.controllers) controller.abort();
    state.requests.clear();
    state.controllers.clear();
    state.csrfToken = "";
    state.entries = [];
    state.pendingUploads = [];
    state.activeUploads = 0;
    state.ignoredDuplicateCount = 0;
    state.mutationEpoch = 0;
    state.pickerTask = Promise.resolve();
    state.progressRenderScheduled = false;
    if (state.cancelledRemoteFileIDs) state.cancelledRemoteFileIDs.clear();
  }

  async function pair(event) {
    event.preventDefault();
    const generation = state.generation;
    const code = elements.pairCode.value.trim();
    if (!/^[0-9]{6}$/.test(code)) {
      setStatus("请输入 6 位数字验证码。 ");
      return;
    }
    try {
      const response = await requestJSON("/api/pair", "POST", { code });
      if (generation !== state.generation) return;
      if (!response || typeof response.csrfToken !== "string" || !response.csrfToken) {
        throw new Error("invalid pairing response");
      }
      beginSessionEpoch();
      state.csrfToken = response.csrfToken;
      elements.pairCode.value = "";
      renderFiles();
      showPairedSession("已连接。请选择要上传的文件。 ");
    } catch (_) {
      if (generation === state.generation) {
        setStatus("连接失败。请检查验证码，稍后再试。 ");
      }
    }
  }

  function showPairedSession(message) {
    elements.pairSection.hidden = true;
    elements.uploadSection.hidden = false;
    elements.sessionSection.hidden = false;
    elements.filePicker.disabled = !hasCryptographicIDSource();
    setStatus(hasCryptographicIDSource()
      ? message
      : "此浏览器无法提供安全的随机标识，请换用新版浏览器。 ");
    startPolling();
  }

  async function restoreSession() {
    const generation = state.generation;
    try {
      const snapshot = await requestJSON("/api/session", "GET");
      if (generation !== state.generation || !snapshot
          || typeof snapshot.csrfToken !== "string" || !snapshot.csrfToken) {
        return;
      }
      state.csrfToken = snapshot.csrfToken;
      mergeSession(snapshot);
      showPairedSession("已恢复本次 Mac 接收会话。 ");
    } catch (error) {
      if (generation === state.generation && error.status === 429) {
        if (state.restoreTimer) globalThis.clearTimeout(state.restoreTimer);
        state.restoreTimer = globalThis.setTimeout(restoreSession, 1100);
      }
    }
  }

  function mergeSession(snapshot) {
    const remoteFiles = Array.isArray(snapshot.files) ? snapshot.files : [];
    const entriesByID = new Map(state.entries.map((entry) => [entry.remoteFileID, entry]));
    for (const remote of remoteFiles) {
      if (state.cancelledRemoteFileIDs
          && state.cancelledRemoteFileIDs.has(remote.remoteFileID)) {
        continue;
      }
      let entry = entriesByID.get(remote.remoteFileID);
      if (!entry) {
        entry = {
          remoteFileID: remote.remoteFileID,
          file: null,
          displayName: remote.displayName,
          declaredByteCount: remote.declaredByteCount,
          mediaType: null,
          attemptRevision: remote.attemptRevision,
          state: remote.state,
          progress: remote.declaredByteCount > 0
            ? Math.round((remote.receivedByteCount / remote.declaredByteCount) * 100)
            : 0,
          receivedByteCount: remote.receivedByteCount,
          request: null,
          removed: false,
        };
        state.entries.push(entry);
        entriesByID.set(entry.remoteFileID, entry);
      } else {
        applyRemoteStatus(entry, remote);
      }
    }
    renderFiles();
  }

  async function pollSession() {
    if (!state.csrfToken || state.polling) return;
    const generation = state.generation;
    const mutationEpoch = state.mutationEpoch;
    state.polling = true;
    try {
      const snapshot = await requestJSON("/api/session", "GET");
      if (generation === state.generation && mutationEpoch === state.mutationEpoch) {
        mergeSession(snapshot);
      }
    } catch (error) {
      if (generation === state.generation && !state.clearing && error.status !== 429) {
        clearSessionState("无法连接到 Mac，本页连接已清除。 ");
      }
    } finally {
      if (generation === state.generation) state.polling = false;
    }
  }

  function startPolling() {
    if (state.pollTimer) globalThis.clearTimeout(state.pollTimer);
    state.pollTimer = 0;
    const hasUnsettledFile = state.entries.some((entry) =>
      !["saved", "cancelled", "comparing"].includes(entry.state));
    if (!state.csrfToken || !hasUnsettledFile) return;
    state.pollTimer = globalThis.setTimeout(async () => {
      state.pollTimer = 0;
      await pollSession();
      startPolling();
    }, 1500);
  }

  async function clearPage() {
    try {
      if (state.csrfToken) await requestJSON("/api/session/logout", "POST");
    } catch (_) {}
    clearSessionState();
  }

  function clearSessionState(message = "本页连接已清除，请重新输入验证码。 ") {
    state.clearing = true;
    beginSessionEpoch();
    elements.pairSection.hidden = false;
    elements.uploadSection.hidden = true;
    elements.sessionSection.hidden = true;
    elements.filePicker.value = "";
    renderFiles();
    setStatus(message);
    state.clearing = false;
  }

  function hasCryptographicIDSource() {
    return Boolean(globalThis.crypto && (
      typeof globalThis.crypto.randomUUID === "function"
      || typeof globalThis.crypto.getRandomValues === "function"
    ));
  }

  elements.pairForm.addEventListener("submit", pair);
  elements.filePicker.addEventListener("change", addFiles);
  elements.clearPage.addEventListener("click", clearPage);
  renderFiles();
  restoreSession();
})();
