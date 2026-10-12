// Offline smoke test: initializes the supplied WASM runtime, without Apple accounts or network.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const { webcrypto } = require('node:crypto');
const { performance } = require('node:perf_hooks');
const runtime = path.resolve(__dirname, '../iPadn/Resources/SAPRuntime');
const base = 'https://localhost/runtime/';
let context;
let wasmFetches = 0;
const document = {
  currentScript: { src: base + 'sap-signer.js' }, baseURI: base + 'index.html',
  createElement() { return {}; },
  head: {
    appendChild(script) {
      const filename = new URL(script.src).pathname.split('/').pop();
      const previous = document.currentScript;
      document.currentScript = script;
      try {
        vm.runInContext(fs.readFileSync(path.join(runtime, filename), 'utf8'), context, { filename });
        queueMicrotask(() => script.onload());
      } catch (error) { queueMicrotask(() => script.onerror(error)); }
      finally { document.currentScript = previous; }
    }
  }
};
const sandbox = {
  console, URL, TextEncoder, TextDecoder, WebAssembly, crypto: webcrypto, performance,
  setTimeout, clearTimeout, setInterval, clearInterval, document,
  atob: value => Buffer.from(value, 'base64').toString('binary'),
  btoa: value => Buffer.from(value, 'binary').toString('base64'),
  fetch: async address => {
    const url = new URL(address);
    assert.equal(url.host, 'localhost', 'Smoke test must never access an upstream server');
    if (url.pathname.endsWith('/sap.wasm')) wasmFetches++;
    const data = fs.readFileSync(path.join(runtime, url.pathname.split('/').pop()));
    return { ok: true, status: 200, arrayBuffer: async () => data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength) };
  }
};
sandbox.window = sandbox;
context = vm.createContext(sandbox);
const timeout = setTimeout(() => { console.error('Runtime initialization exceeded 60 seconds'); process.exit(1); }, 60_000);
(async () => {
  const wasm = fs.readFileSync(path.join(runtime, 'sap.wasm'));
  assert.equal(WebAssembly.validate(wasm), true);
  vm.runInContext(fs.readFileSync(path.join(runtime, 'sap-signer.js'), 'utf8'), context, { filename: 'sap-signer.js' });
  await assert.rejects(context.sapSign('YQ=='), /not initialized/);
  await assert.rejects(context.sapGenerateKBSync('invalid', '123'), /six hexadecimal/);
  await assert.rejects(context.sapGenerateKBSync('AABBCCDDEEFF', '0'), /nonzero/);
  await assert.rejects(context.sapGenerateKBSync('AABBCCDDEEFF', '18446744073709551616'), /nonzero/);
  const coldStart = performance.now();
  await context.loadSapSigner();
  const coldMs = performance.now() - coldStart;
  assert.equal(context.sapWasmSignerReady, true);
  for (const name of ['sapWasmPrepareSetup', 'sapWasmFinishSetup', 'sapWasmSign', 'sapWasmGenerateKBSync', 'sapWasmClose']) {
    assert.equal(typeof context[name], 'function', name + ' must exist');
  }
  const module = context.unicornModule;
  const warmStart = performance.now();
  await context.loadSapSigner();
  const warmMs = performance.now() - warmStart;
  assert.equal(context.unicornModule, module, 'A repeated load must reuse the initialized runtime');
  assert.equal(wasmFetches, 1, 'WASM must not be fetched again for the warm load');
  console.log('PASS: WASM validation, runtime initialization, exported entry points, and four input/precondition checks');
  console.log(`Runtime load: cold ${coldMs.toFixed(1)} ms; warm ${warmMs.toFixed(3)} ms (Node offline; device signing not benchmarked).`);
  console.log('No Apple login, upstream signing handshake, valid KBSync generation, or WebKit execution was tested.');
  clearTimeout(timeout);
  process.exit(0);
})().catch(error => { clearTimeout(timeout); console.error(error); process.exit(1); });
