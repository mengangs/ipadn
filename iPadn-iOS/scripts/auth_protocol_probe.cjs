// Offline smoke test: initializes the supplied WASM runtime, without Apple accounts or network.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const { webcrypto, randomBytes } = require('node:crypto');
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
  // Match the host WebAssembly realm so Emscripten can recognize its TypeError
  // and install the required typed function wrapper. Browsers use one realm.
  console: { log() {}, warn() {}, error() {} }, TypeError, URL, TextEncoder, TextDecoder, WebAssembly, crypto: webcrypto, performance,
  setTimeout, clearTimeout, setInterval, clearInterval, document,
  atob: value => Buffer.from(value, 'base64').toString('binary'),
  btoa: value => Buffer.from(value, 'binary').toString('base64'),
  fetch: async (address, options = {}) => {
    const url = new URL(address);
    if (url.pathname.endsWith('/proxy')) {
      const upstream = url.searchParams.get('url');
      assert.ok(['https://s.mzstatic.com/sap/setupCert.plist', 'https://fpinit.itunes.apple.com/v1/signSapSetup/legacy'].includes(upstream));
      const response = await fetch(upstream, { ...options, signal: AbortSignal.timeout(30000) });
      const data = await response.arrayBuffer();
      console.log(JSON.stringify({stage: 'setup', status: response.status, bytes: data.byteLength}));
      return {ok: response.ok, status: response.status, arrayBuffer: async () => data};
    }
    assert.equal(url.host, 'localhost');
    const data = fs.readFileSync(path.join(runtime, url.pathname.split('/').pop()));
    return { ok: true, status: 200, arrayBuffer: async () => data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength) };
  }
};
sandbox.window = sandbox;
context = vm.createContext(sandbox);
const timeout = setTimeout(() => { console.error('Probe exceeded 240 seconds'); process.exit(1); }, 240000);
(async () => {
  vm.runInContext(fs.readFileSync(path.join(runtime, 'sap-signer.js'), 'utf8'), context, { filename: 'sap-signer.js' });
  const guid = randomBytes(6).toString('hex').toUpperCase();
  // Reserved .invalid domain: this is not a real Apple account, and the probe
  // never reads credentials from environment variables or device storage.
  const body = `<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>appleId</key><string>ipadn-probe@example.invalid</string><key>attempt</key><string>1</string><key>guid</key><string>${guid}</string><key>password</key><string>invalid-nonexistent-test-password</string><key>rmp</key><string>0</string><key>why</key><string>signIn</string></dict></plist>`;
  const encoded = Buffer.from(body).toString('base64');
  for (const style of ['split', 'unsigned']) {
    console.log(JSON.stringify({stage: 'start', style}));
    let signature;
    if (style === 'split') {
      await context.sapInitialize(guid, {proxyURL: 'https://localhost/proxy'});
      try { signature = await context.sapSign(encoded); } finally { await context.sapClose(); }
    }
    if (signature) console.log(JSON.stringify({stage:'signed', style, signatureBytes: Buffer.from(signature, 'base64').length}));
    let address = 'https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate/';
    for (let hop = 0; hop < 5; hop++) {
      const url = new URL(address);
      assert.ok(url.protocol === 'https:' && (url.hostname === 'buy.itunes.apple.com' || url.hostname.endsWith('-buy.itunes.apple.com')));
      const response = await fetch(url, {method:'POST', body, redirect:'manual', signal:AbortSignal.timeout(30000),
        headers:{'User-Agent':'Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6',
          'Content-Type':'application/x-www-form-urlencoded', 'Accept':'application/xml', ...(signature ? {'X-Apple-ActionSignature':signature} : {}), 'Connection':'close'}});
      const data = Buffer.from(await response.arrayBuffer());
      const text = data.toString('utf8');
      const failure = text.match(/<key>failureType<\/key>\s*<(?:string|integer)>(-?[0-9]{1,6})<\/(?:string|integer)>/);
      console.log(JSON.stringify({stage:'response', style, hop, host:url.hostname, status:response.status, bytes:data.length,
        format: data.length === 0 ? 'empty' : /<(?:plist|Document|dict)[ >]/.test(text) ? 'xml' : 'other',
        failure: failure ? failure[1] : undefined, cookieCount: response.headers.getSetCookie().length, appleServer: response.headers.get('server') === 'Apple',
        hasBackend: response.headers.has('x-responding-instance') || response.headers.has('apple-originating-system'),
        hasCorrelation: response.headers.has('x-apple-jingle-correlation-key')}));
      const location = response.headers.get('location');
      if ([301,302,303,307,308].includes(response.status) && location) { address = new URL(location, url).href; continue; }
      break;
    }
  }
  clearTimeout(timeout);
  process.exit(0);
})().catch(error => { clearTimeout(timeout); console.error(JSON.stringify({stage:'failed', type:error.name, message:String(error.message).slice(0,180)})); process.exit(1); });
