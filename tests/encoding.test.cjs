const assert = require('assert').strict;
const {readFileSync, writeFileSync, mkdirSync, mkdtempSync, existsSync} = require('fs');
const path = require('path');
const {spawnSync} = require('child_process');
const vm = require('vm');
const {Worker: NodeWorker} = require('worker_threads');
const tests = [];
const test = (name, run) => tests.push({name, run});

const root = path.resolve(__dirname, '..');
const html = readFileSync(path.join(root, 'templates/index.html'), 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
const encodingScript = script.slice(script.indexOf('let GBK_TABLE'), script.indexOf('// ---------- 状态管理'));
const context = vm.createContext({
  btoa: text => Buffer.from(text, 'binary').toString('base64'), unescape, encodeURIComponent
});
vm.runInContext(encodingScript, context);
const convert = (text, encoding) => JSON.parse(JSON.stringify(context.textToAltSequence(text, encoding)));

// Execute the browser's actual Blob worker source in a separate Node thread.
const blobs = new Map();
let blobId = 0;
context.Blob = class { constructor(parts) { this.source = parts.join(''); } };
context.URL = {
  createObjectURL(blob) { const id = `blob:test-${++blobId}`; blobs.set(id, blob.source); return id; },
  revokeObjectURL(id) { blobs.delete(id); }
};
context.Worker = class {
  constructor(url) {
    this.worker = new NodeWorker(`
      const {parentPort} = require('worker_threads');
      const btoa = text => Buffer.from(text, 'binary').toString('base64');
      const self = {postMessage: data => parentPort.postMessage(data)};
      ${blobs.get(url)}
      parentPort.on('message', data => self.onmessage({data}));
    `, {eval: true});
    this.worker.on('message', data => this.onmessage && this.onmessage({data}));
    this.worker.on('error', error => this.onerror && this.onerror(error));
  }
  postMessage(data) { this.worker.postMessage(data); }
  terminate() { this.worker.terminate(); }
};
vm.runInContext('let isTyping = false; let typingStarting = false; let typingPreparation = null; let typingStateVersion = 0;', context);
vm.runInContext(script.slice(script.indexOf('function typingWorkerSource('), script.indexOf('async function startTyping(')), context);

test('page script parses and exposes the MDWIN option and input method hint', () => {
  new vm.Script(script);
  assert.match(html, /<option value="mdwin">医智赢/);
  assert.match(script, /mdwin:.*目标电脑需安装并启用医智赢输入法/);
});

test('MDWIN fixed vectors include Chinese, ASCII, punctuation and encrypted spaces', () => {
  assert.deepEqual(convert('中医A ！', 'mdwin'), [
    {code: 19913}, {code: 20703}, {code: 933}, {code: 964}, {code: 64741}
  ]);
  assert.deepEqual(convert('', 'mdwin'), []);
});

test('MDWIN preserves the reference UTF-16 surrogate pair behavior', () => {
  assert.deepEqual(convert('😀', 'mdwin'), [{code: 56281}, {code: 56804}]);
});

test('MDWIN keeps supported control keys in place and normalizes CRLF', () => {
  assert.deepEqual(convert('A\r\n中\t \b\x1bB', 'mdwin'), [
    {code: 933}, {control: 'enter'}, {code: 19913}, {control: 'tab'},
    {code: 964}, {control: 'backspace'}, {control: 'esc'}, {code: 934}
  ]);
  assert.deepEqual(convert('\x00\x01\x12\x13\x7f', 'mdwin'), []);
});

test('existing Unicode, GBK, ASCII and Base64 conversions retain their behavior', () => {
  assert.deepEqual(convert('中A \r\n\t😀', 'unicode'), [
    {code: 20013}, {code: 65}, {control: 'space'}, {control: 'enter'},
    {control: 'tab'}, {code: 128512}
  ]);
  vm.runInContext('GBK_TABLE = {"中": 54992}; GBK_AVAILABLE = true;', context);
  assert.deepEqual(convert('中A', 'gbk'), [{code: 54992}, {code: 65}]);
  assert.deepEqual(convert('中A1! \r\n\t', 'ascii'), [
    {code: 65}, {code: 49}, {control: 'space'}, {control: 'enter'}, {control: 'tab'}
  ]);
  assert.deepEqual(convert('中A', 'base64'), [...'5LitQQ=='].map(ch => ({code: ch.charCodeAt(0)})));
});

test('startTyping sends MDWIN items without requiring a GBK table', async () => {
  const elements = {
    textInput: {value: '中 A\n'}, encodingSelect: {value: 'mdwin'},
    engineModeSelect: {value: 'auto'}, reportDelaySlider: {value: '5'},
    typeBtn: {}, stopBtn: {}, progressFill: {style: {}}, progressNum: {}, progressLabel: {}
  };
  const requests = [];
  context.$ = id => elements[id];
  context.log = context.toast = () => {};
  context.fetch = async (url, opts) => {
    requests.push({url, ...opts});
    return {json: async () => ({ok: true})};
  };
  vm.runInContext('GBK_AVAILABLE = false;', context);
  vm.runInContext(script.slice(script.indexOf('async function api('), script.indexOf('// ---------- 编码转换')), context);
  vm.runInContext(script.slice(script.indexOf('async function startTyping('), script.indexOf('async function stopTyping(')), context);
  await context.startTyping();
  assert.equal(requests.length, 1);
  assert.equal(requests[0].url, '/api/type');
  assert.equal(requests[0].method, 'POST');
  assert.deepEqual(JSON.parse(requests[0].body), {
    encoding: 'mdwin', items: [{code: 19913}, {code: 964}, {code: 933}, {control: 'enter'}],
    mode: 'auto', report_delay: 5
  });
  assert.equal(elements.typeBtn.disabled, true);
});

test('actual server awk parser preserves interleaved codes and controls', () => {
  const server = readFileSync(path.join(root, 'server.sh'), 'utf8');
  const parser = server.match(/printf '%s' "\$_body" \| awk '([\s\S]*?)' > "\$_items_file"/)[1];
  const input = {
    encoding: 'mdwin', items: convert('\nA\t中 \nB', 'mdwin'), mode: 'auto', report_delay: 5
  };
  const expected = 'control enter\ncode 933\ncontrol tab\ncode 19913\ncode 964\ncontrol enter\ncode 934\n';
  for (const body of [JSON.stringify(input), JSON.stringify(input, null, 2)]) {
    const result = process.platform === 'win32'
      ? spawnSync(process.env.TEST_BASH || 'C:/Program Files/Git/bin/bash.exe',
        ['-c', 'awk "$1"', 'encoding-test', parser], {input: body, encoding: 'utf8'})
      : spawnSync('awk', [parser], {input: body, encoding: 'utf8'});
    assert.ifError(result.error);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout.replace(/\r/g, ''), expected);
  }
});

test('worker preserves every encoding and serializes bounded JSON lines', async () => {
  vm.runInContext('GBK_TABLE = {"中": 54992}; GBK_AVAILABLE = true;', context);
  for (const encoding of ['mdwin', 'gbk', 'unicode', 'ascii', 'base64']) {
    const text = '中 A\r\n\t😀';
    const prepared = await context.prepareTypingRequest(text, encoding, 'shell', 8);
    const body = JSON.parse(prepared.body);
    assert.deepEqual(body.items, convert(text, encoding));
    assert.equal(prepared.total, body.items.length);
    assert.equal(body.encoding, encoding);
    assert.equal(body.mode, 'shell');
    assert.equal(body.report_delay, 8);
    assert.ok(prepared.body.split('\n').every(line => line.length < 100));
  }
  assert.equal(blobs.size, 0);
});

test('long-text preparation leaves the main event loop responsive', async () => {
  const text = '中 A\n😀'.repeat(20000);
  let heartbeats = 0;
  const timer = setInterval(() => heartbeats++, 1);
  let prepared;
  try {
    prepared = await context.prepareTypingRequest(text, 'mdwin', 'auto', 5);
  } finally {
    clearInterval(timer);
  }
  assert.ok(heartbeats > 0, 'main thread must run while encoding is in progress');
  const items = JSON.parse(prepared.body).items;
  assert.equal(items.length, 120000);
  assert.deepEqual(items.slice(0, 6), [
    {code: 19913}, {code: 964}, {code: 933}, {control: 'enter'}, {code: 56281}, {code: 56804}
  ]);
  assert.deepEqual(items.slice(-6), items.slice(0, 6));
  const server = readFileSync(path.join(root, 'server.sh'), 'utf8');
  const parser = server.match(/printf '%s' "\$_body" \| awk '([\s\S]*?)' > "\$_items_file"/)[1];
  const result = process.platform === 'win32'
    ? spawnSync(process.env.TEST_BASH || 'C:/Program Files/Git/bin/bash.exe',
      ['-c', 'awk "$1"', 'encoding-test', parser], {input: prepared.body, encoding: 'utf8', maxBuffer: 8 * 1024 * 1024})
    : spawnSync('awk', [parser], {input: prepared.body, encoding: 'utf8', maxBuffer: 8 * 1024 * 1024});
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout.trim().split('\n').length, 120000);
  assert.ok(result.stdout.startsWith('code 19913\ncode 964\ncode 933\ncontrol enter\ncode 56281\ncode 56804\n'));
});

test('preparation can be cancelled without sending or losing the draft', async () => {
  vm.runInContext('isTyping = false;', context);
  const draft = '中A'.repeat(200000);
  const elements = {
    textInput: {value: draft}, encodingSelect: {value: 'mdwin'},
    engineModeSelect: {value: 'auto'}, reportDelaySlider: {value: '5'},
    typeBtn: {}, stopBtn: {}, progressFill: {style: {}}, progressNum: {}, progressLabel: {}
  };
  context.$ = id => elements[id];
  context.fetch = async () => { throw new Error('cancelled preparation must not send'); };
  vm.runInContext(script.slice(script.indexOf('async function stopTyping('), script.indexOf('// ---------- 延时设置')), context);
  const pending = context.startTyping();
  assert.equal(elements.typeBtn.disabled, true);
  assert.equal(elements.stopBtn.disabled, false);
  await context.stopTyping();
  await pending;
  assert.equal(elements.textInput.value, draft);
  assert.equal(elements.typeBtn.disabled, false);
  assert.equal(elements.stopBtn.disabled, true);
  assert.equal(blobs.size, 0);
});

test('worker startup errors restore the controls and preserve the input', async () => {
  const elements = {
    textInput: {value: '中A'}, encodingSelect: {value: 'mdwin'},
    engineModeSelect: {value: 'auto'}, reportDelaySlider: {value: '5'},
    typeBtn: {}, stopBtn: {}, progressFill: {style: {}}, progressNum: {}, progressLabel: {}
  };
  context.$ = id => elements[id];
  const NativeWorker = context.Worker;
  // Inject a startup failure, the same rejection path used when Blob workers are unavailable.
  context.Worker = class { constructor() { throw new Error('Worker unavailable'); } };
  try {
    await context.startTyping();
  } finally {
    context.Worker = NativeWorker;
  }
  assert.equal(elements.textInput.value, '中A');
  assert.equal(elements.typeBtn.disabled, false);
  assert.equal(elements.stopBtn.disabled, true);
  assert.equal(blobs.size, 0);
});

test('HTTP type response returns while a simulated slow HID task is still running', async () => {
  // Keep generated artifacts in the project's ignored .deleted directory; no files are removed.
  const archive = path.join(root, '.deleted', '2026-10-07');
  mkdirSync(archive, {recursive: true});
  const dir = mkdtempSync(path.join(archive, 'long-text-check-'));
  writeFileSync(path.join(dir, 'server.sh'), readFileSync(path.join(root, 'server.sh')));
  writeFileSync(path.join(dir, 'fake-hid'), '');
  writeFileSync(path.join(dir, 'hid_keyboard.sh'), `
hid_init() { return 0; }
hid_type_alt_code() { printf 'code %s\\n' "$1" >> "$STATE_DIR/written"; sleep 1; }
hid_type_control_char() { printf 'control %s\\n' "$1" >> "$STATE_DIR/written"; sleep 1; }
`);
  const posix = value => value.replace(/\\/g, '/').replace(/^([A-Za-z]):/, (_, drive) => '/' + drive.toLowerCase());
  const env = {...process.env, INSTALL_DIR: posix(dir), STATE_DIR: posix(path.join(dir, 'state')),
    HID_DEVICE: posix(path.join(dir, 'fake-hid')), LOG_FILE: posix(path.join(dir, 'log')),
    TYPE_MODE: 'shell'};
  const body = JSON.stringify({encoding: 'mdwin', mode: 'shell', items: convert('中\nA', 'mdwin')});
  const request = `POST /api/type HTTP/1.1\r\nContent-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`;
  const shell = process.platform === 'win32' ? process.env.TEST_BASH || 'C:/Program Files/Git/bin/bash.exe' : 'sh';
  const result = spawnSync(shell, [posix(path.join(dir, 'server.sh')), 'handle'], {env, input: request, encoding: 'utf8', timeout: 10000});
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr);
  const response = JSON.parse(result.stdout.split('\r\n\r\n')[1]);
  assert.equal(response.ok, true);
  assert.equal(response.total, 3);
  const statusFile = path.join(dir, 'state/status.json');
  assert.equal(JSON.parse(readFileSync(statusFile, 'utf8')).busy, true, 'response must precede task completion');
  const deadline = Date.now() + 10000;
  while (Date.now() < deadline) {
    await new Promise(resolve => setTimeout(resolve, 50));
    try {
      if (!JSON.parse(readFileSync(statusFile, 'utf8')).busy) break;
    } catch (_) { /* status file may be in the middle of a write */ }
  }
  assert.equal(JSON.parse(readFileSync(statusFile, 'utf8')).busy, false);
  assert.ok(existsSync(path.join(dir, 'state/written')));
  assert.equal(readFileSync(path.join(dir, 'state/written'), 'utf8'), 'code 19913\ncontrol enter\ncode 933\n');
});

test('HTTP handler reads a long worker request completely for the native engine', async () => {
  const archive = path.join(root, '.deleted', '2026-10-07');
  mkdirSync(archive, {recursive: true});
  const dir = mkdtempSync(path.join(archive, 'long-request-check-'));
  writeFileSync(path.join(dir, 'server.sh'), readFileSync(path.join(root, 'server.sh')));
  writeFileSync(path.join(dir, 'fake-hid'), '');
  writeFileSync(path.join(dir, 'hid_keyboard.sh'), '');
  writeFileSync(path.join(dir, 'hid_writer'), '#!/bin/sh\nif [ "$1" = "--help" ]; then exit 0; fi\ncat > "$STATE_DIR/written"\nsleep 3\n', {mode: 0o755});
  const posix = value => value.replace(/\\/g, '/').replace(/^([A-Za-z]):/, (_, drive) => '/' + drive.toLowerCase());
  const env = {...process.env, INSTALL_DIR: posix(dir), STATE_DIR: posix(path.join(dir, 'state')),
    HID_DEVICE: posix(path.join(dir, 'fake-hid')), LOG_FILE: posix(path.join(dir, 'log')),
    TYPE_MODE: 'native'};
  const prepared = await context.prepareTypingRequest('中\nA'.repeat(10000), 'mdwin', 'native', 5);
  const request = `POST /api/type HTTP/1.1\r\nContent-Length: ${Buffer.byteLength(prepared.body)}\r\n\r\n${prepared.body}`;
  const shell = process.platform === 'win32' ? process.env.TEST_BASH || 'C:/Program Files/Git/bin/bash.exe' : 'sh';
  const result = spawnSync(shell, [posix(path.join(dir, 'server.sh')), 'handle'], {env, input: request, encoding: 'utf8', timeout: 15000});
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr);
  const response = JSON.parse(result.stdout.split('\r\n\r\n')[1]);
  assert.equal(response.ok, true);
  assert.equal(response.total, 30000);
  const statusFile = path.join(dir, 'state/status.json');
  assert.equal(JSON.parse(readFileSync(statusFile, 'utf8')).busy, true);
  const deadline = Date.now() + 10000;
  while (Date.now() < deadline) {
    await new Promise(resolve => setTimeout(resolve, 50));
    try {
      if (!JSON.parse(readFileSync(statusFile, 'utf8')).busy) break;
    } catch (_) {}
  }
  assert.equal(JSON.parse(readFileSync(statusFile, 'utf8')).busy, false);
  assert.equal(readFileSync(path.join(dir, 'state/written'), 'utf8'),
    'code 19913\ncontrol enter\ncode 933\n'.repeat(10000));
});

(async () => {
  for (const {name, run} of tests) {
    await run();
    console.log(`PASS ${name}`);
  }
  console.log(`${tests.length} checks passed`);
})().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
