/**
 * Generate tests/encoding_fixtures.json from the browser's real encoder.
 *
 * The MCP server ports textToAltSequence() to Python; this fixture file pins
 * both implementations to the same output without needing Node at test time.
 *
 * Usage: node tests/gen_fixtures.cjs
 */
const {readFileSync, writeFileSync} = require('fs');
const path = require('path');
const vm = require('vm');

const root = path.resolve(__dirname, '..');
const html = readFileSync(path.join(root, 'templates/index.html'), 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
const encodingScript = script.slice(
  script.indexOf('let GBK_TABLE'),
  script.indexOf('// ---------- 状态管理')
);

const context = vm.createContext({
  btoa: text => Buffer.from(text, 'binary').toString('base64'),
  unescape,
  encodeURIComponent,
  setTimeout,
});
vm.runInContext(encodingScript, context);

const table = readFileSync(path.join(root, 'templates/gbk_table.json'), 'utf8');
vm.runInContext(`GBK_TABLE = ${table}; GBK_AVAILABLE = true;`, context);

const samples = [
  '',
  'A',
  'a1b2c3',
  '中医A ！',
  '你好，世界',
  '测试 中文 与 English 混合 123',
  '第一行\n第二行',
  'CRLF\r\n换行',
  'tab\there',
  '😀 表情与代理对',
  'ＡＢＣ全角',
  '[]{}<>()!@#$%^&*',
  '多行\n文本\t结束\n',
];

const encodings = ['gbk', 'unicode', 'mdwin', 'ascii', 'base64'];
const fixtures = [];
for (const text of samples) {
  for (const encoding of encodings) {
    fixtures.push({
      text,
      encoding,
      items: JSON.parse(JSON.stringify(context.textToAltSequence(text, encoding))),
    });
  }
}

const out = path.join(__dirname, 'encoding_fixtures.json');
writeFileSync(out, JSON.stringify(fixtures, null, 1) + '\n');
console.log(`wrote ${fixtures.length} fixtures to ${out}`);
