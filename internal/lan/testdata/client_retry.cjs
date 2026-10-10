// Executes the shipped client in a deterministic DOM/XHR sandbox; no network.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
class Element {
  constructor() { this.children = []; this.listeners = {}; }
  addEventListener(kind, fn) { this.listeners[kind] = fn; }
  append(...items) { this.children.push(...items); }
  replaceChildren() { this.children = []; }
  get childElementCount() { return this.children.length; }
}
const elements = new Map();
const document = {
  querySelector(id) { if (!elements.has(id)) elements.set(id, new Element()); return elements.get(id); },
  createElement() { return new Element(); },
};
const requests = [];
class XHR extends Element {
  constructor() { super(); this.upload = new Element(); requests.push(this); }
  open() {}
  setRequestHeader() {}
  send() {}
  abort() {
    this.aborted = true;
    if (process.argv[3] === 'synchronous') this.emit('abort');
  } // Exercise both synchronous abort and delayed terminal events.
  emit(kind) { this.listeners[kind](); }
}
const reservations = [];
let snapshot;
const context = vm.createContext({document, XMLHttpRequest: XHR, AbortController,
  setTimeout: () => 1, clearTimeout: () => {},
  window: {fetch: async (path, options) => {
    if (path === '/api/session') return {ok: true, status: 200, json: async () => snapshot};
    assert.equal(path, '/api/files/reserve');
    const body = JSON.parse(options.body); reservations.push(body);
    return {ok: true, status: 201, json: async () => ({file: {...body, state: 'reserved', receivedByteCount: 0}})};
  }},
});
let source = fs.readFileSync(process.argv[2], 'utf8');
// Expose lexical functions only inside the test VM; shipped asset has no hook.
source = source.replace(/  restoreSession\(\);\n\}\)\(\);\s*$/, '  globalThis.testClient = {state, pumpUploads, pollSession, renderFiles};\n})();');
vm.runInContext(source, context);
(async () => {
  const {state, pumpUploads, pollSession} = context.testClient;
  state.csrfToken = 'synthetic-test';
  const entry = {remoteFileID: 'synthetic-file', file: {}, displayName: 'synthetic.txt',
    declaredByteCount: 100, attemptRevision: 0, state: 'queued', progress: 0, receivedByteCount: 0, removed: false};
  state.entries.push(entry); state.pendingUploads.push(entry); pumpUploads();
  const old = requests[0];
  assert.equal(state.activeUploads, 1);
  snapshot = {files: [{...entry, file: undefined, request: undefined, state: 'interrupted'}]};
  await pollSession();
  assert.equal(entry.state, 'interrupted');
  const retry = elements.get('#file-list').children[0].children[2].children.find(x => x.textContent === '重试');
  assert.ok(retry, 'poll interruption offers a retry');
  const first = retry.listeners.click();
  const second = retry.listeners.click(); // Repeated click before reservation responds.
  await Promise.all([first, second]);
  assert.equal(reservations.length, 1, 'one new reservation after interrupted upload');
  assert.equal(reservations[0].attemptRevision, 1);
  assert.equal(old.aborted, true);
  assert.equal(state.activeUploads, 1, 'old accounting settled before replacement');
  assert.equal(state.requests.size, 1);
  const current = requests[1];
  assert.equal(entry.request, current);
  old.upload.listeners.progress({lengthComputable: true, loaded: 99, total: 100});
  old.status = 200; old.response = {outcome: 'saved'};
  for (const event of ['abort', 'error', 'load']) old.emit(event);
  assert.equal(entry.progress, 0, 'late progress cannot alter replacement');
  assert.equal(entry.state, 'uploading', 'late terminal cannot settle replacement');
  assert.equal(entry.request, current);
  assert.equal(state.activeUploads, 1);
  current.status = 200; current.response = {outcome: 'saved'}; current.emit('load');
  current.emit('error');
  assert.equal(entry.state, 'saved');
  assert.equal(state.activeUploads, 0);
  assert.equal(state.requests.size, 0);
  console.log('client retry ordering passed');
})().catch(error => { console.error(error); process.exitCode = 1; });
