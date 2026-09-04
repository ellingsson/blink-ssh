const assert = require('assert');
const fs = require('fs');
const vm = require('vm');

const source = fs.readFileSync('SSHOnly/XTermBridge.js', 'utf8');
const context = {
  Uint8Array,
  TextEncoder,
  Buffer,
  atob: (value) => Buffer.from(value, 'base64').toString('binary'),
  btoa: (value) => Buffer.from(value, 'binary').toString('base64'),
  globalThis: {},
};
vm.createContext(context);
vm.runInContext(source, context);
const bridge = context.globalThis.XTermBridge;

assert.deepStrictEqual(
  Array.from(bridge.decodeBase64(Buffer.from(Array.from({ length: 256 }, (_, index) => index)).toString('base64'))),
  Array.from({ length: 256 }, (_, index) => index)
);
assert.strictEqual(
  bridge.encodeInput('å😀\u001b[A'),
  Buffer.from('å😀\u001b[A', 'utf8').toString('base64')
);
assert.throws(() => bridge.decodeBase64('!not-base64!'), /Invalid base64/);

console.log('XTermBridgeTests passed');
