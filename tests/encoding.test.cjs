const assert = require('assert').strict;
const {readFileSync} = require('fs');
const path = require('path');
const {spawnSync} = require('child_process');
const vm = require('vm');
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
    typeBtn: {}, stopBtn: {}
  };
  const requests = [];
  context.$ = id => elements[id];
  context.log = context.toast = () => {};
  context.fetch = async (url, opts) => {
    requests.push({url, ...opts});
    return {json: async () => ({ok: true})};
  };
  vm.runInContext('GBK_AVAILABLE = false; let isTyping = false;', context);
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
