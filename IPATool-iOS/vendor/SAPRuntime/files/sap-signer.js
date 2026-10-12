(function (root) {
  "use strict";

  const CERTIFICATE_URL = "https://s.mzstatic.com/sap/setupCert.plist";
  const SETUP_URL = "https://fpinit.itunes.apple.com/v1/signSapSetup/legacy";
  const SCRIPT_BASE_URL = (() => {
    const script = typeof document === "undefined" ? null : document.currentScript;
    const base = script && script.src
      ? script.src
      : (typeof document === "undefined" ? "./" : document.baseURI);
    return new URL(".", base).href;
  })();
  const DEFAULT_PROXY_URL = new URL("../proxy", SCRIPT_BASE_URL).href;
  const NATIVE_MEMORY_SHIMS = new Set([
    "_malloc", "_malloc_good_size", "_calloc", "_free",
    "_memcpy", "_memmove", "_memset", "___bzero",
    "___memcpy_chk", "___memset_chk", "_strlen", "_pthread_once",
    "_pthread_mutex_lock", "_pthread_mutex_unlock",
    "_pthread_rwlock_init", "_pthread_rwlock_init$UNIX2003",
    "_pthread_rwlock_unlock", "_pthread_rwlock_unlock$UNIX2003",
    "_pthread_rwlock_wrlock", "_pthread_rwlock_wrlock$UNIX2003"
  ]);

  let runtimePromise = null;
  let currentSigner = null;
  let kbsyncQueue = Promise.resolve();

  function loadScript(url) {
    return new Promise((resolve, reject) => {
      const script = document.createElement("script");
      script.src = url;
      script.onload = resolve;
      script.onerror = () => reject(new Error("load script failed: " + url));
      document.head.appendChild(script);
    });
  }

  function bytesToBase64(bytes) {
    let text = "";
    const chunkSize = 0x8000;
    for (let offset = 0; offset < bytes.length; offset += chunkSize) {
      text += String.fromCharCode(...bytes.subarray(offset, offset + chunkSize));
    }
    return btoa(text);
  }

  function base64ToBytes(value) {
    const text = atob(value);
    const bytes = new Uint8Array(text.length);
    for (let index = 0; index < text.length; index++) bytes[index] = text.charCodeAt(index);
    return bytes;
  }

  function unsigned64(value) {
    return BigInt.asUintN(64, BigInt(value));
  }

  function installShimBridge() {
    const registered = new Map();
    const nativeEntries = new Set();
    root.sapWasmShimHandled = false;

    root.sapWasmRegisterShim = (address, name) => {
      const value = BigInt(address);
      registered.set(value, name);
      if (NATIVE_MEMORY_SHIMS.has(name)) nativeEntries.add(value);
    };

    root.sapWasmShimName = address => registered.get(BigInt(address)) || null;

    root.sapWasmTrapHook = (handle, address) => {
      root.sapWasmShimHandled = false;
      const current = unsigned64(address);
      const name = registered.get(current);
      if (name && NATIVE_MEMORY_SHIMS.has(name)) return;
      if (!name) {
        for (const start of nativeEntries) {
          if (current > start && current < start + 64n) return;
        }
      }
      handle.emu_stop();
    };
  }

  async function initialize(options) {
    if (runtimePromise) return runtimePromise;

    runtimePromise = (async () => {
      const unicornURL = options.unicornURL || new URL("unicorn_x86.js", SCRIPT_BASE_URL).href;
      const wasmExecURL = options.wasmExecURL || new URL("wasm_exec.js", SCRIPT_BASE_URL).href;
      const wasmURL = options.wasmURL || new URL("sap.wasm", SCRIPT_BASE_URL).href;

      const timed = async (stage, operation) => {
        const logger = root.sapWasmKBSyncLog;
        if (typeof logger !== "function") return operation();
        logger(JSON.stringify({ event: "stageStart", stage }));
        const at = performance.now();
        try { return await operation(); }
        finally { logger(JSON.stringify({ event: "stageEnd", stage, durationMs: performance.now() - at })); }
      };
      if (typeof root.MUnicorn !== "function") await timed("runtime.unicorn.script", () => loadScript(unicornURL));
      if (typeof root.MUnicorn !== "function") throw new Error("Unicorn.js factory is unavailable");
      root.unicornModule = await timed("runtime.unicorn.instantiate", () => root.MUnicorn());
      if (!root.unicornModule) throw new Error("Unicorn.js initialization failed");

      installShimBridge();
      if (typeof root.Go !== "function") await timed("runtime.go.script", () => loadScript(wasmExecURL));
      if (typeof root.Go !== "function") throw new Error("Go WASM runtime is unavailable");

      const bytes = await timed("runtime.sap.fetch", async () => {
        const response = await fetch(wasmURL, { cache: "no-store" });
        if (!response.ok) throw new Error("load SAP WASM failed: " + response.status);
        return response.arrayBuffer();
      });
      const go = new root.Go();
      const compiled = await timed("runtime.sap.instantiate", () => WebAssembly.instantiate(bytes, go.importObject));
      go.run(compiled.instance);

      const deadline = Date.now() + 30000;
      while (!root.sapWasmSignerReady) {
        if (Date.now() >= deadline) throw new Error("SAP WASM initialization timed out");
        await new Promise(resolve => setTimeout(resolve, 10));
      }
    })();

    try {
      await runtimePromise;
    } catch (error) {
      runtimePromise = null;
      throw error;
    }
  }

  function proxyURL(proxyBase, upstream) {
    const target = new URL(proxyBase, document.baseURI);
    target.search = "";
    target.searchParams.set("url", upstream);
    return target.href;
  }

  async function requestCertificate(proxyBase) {
    const response = await fetch(proxyURL(proxyBase, CERTIFICATE_URL), { cache: "no-store" });
    if (!response.ok) throw new Error("fetch SAP setup certificate failed: " + response.status);
    return bytesToBase64(new Uint8Array(await response.arrayBuffer()));
  }

  async function exchangeSetup(proxyBase, requestBase64) {
    const response = await fetch(proxyURL(proxyBase, SETUP_URL), {
      method: "POST",
      headers: { "Content-Type": "application/x-plist" },
      body: base64ToBytes(requestBase64)
    });
    if (!response.ok) throw new Error("SAP setup request failed: " + response.status);
    return bytesToBase64(new Uint8Array(await response.arrayBuffer()));
  }

  class SapSigner {
    constructor(guid, options) {
      if (typeof guid !== "string" || guid.trim().length === 0) {
        throw new TypeError("guid must be a non-empty string");
      }

      this.guid = guid;
      this.options = options || {};
      this.queue = Promise.resolve();
      this.initialized = false;
    }

    enqueue(operation) {
      const result = this.queue.then(operation);
      this.queue = result.catch(() => {});
      return result;
    }

    initialize() {
      return this.enqueue(async () => {
        if (this.initialized) throw new Error("SAP signer is already initialized");
        await initialize(this.options);

        try {
          const proxyBase = this.options.proxyURL || DEFAULT_PROXY_URL;
          const certificate = await requestCertificate(proxyBase);
          const preparation = JSON.parse(root.sapWasmPrepareSetup(this.guid, certificate));
          if (preparation.error) throw new Error(preparation.error);

          const reply = await exchangeSetup(proxyBase, preparation.requestBase64);
          const completion = JSON.parse(root.sapWasmFinishSetup(reply));
          if (completion.error) throw new Error(completion.error);
          if (completion.ready !== true) throw new Error("SAP signer setup did not complete");

          this.initialized = true;
          return true;
        } catch (error) {
          root.sapWasmClose();
          throw error;
        }
      });
    }

    sign(bodyBase64) {
      return this.enqueue(async () => {
        if (!this.initialized) throw new Error("SAP signer is not initialized");
        if (typeof bodyBase64 !== "string" || bodyBase64.length === 0) {
          throw new TypeError("body Base64 must be a non-empty string");
        }

        const result = JSON.parse(root.sapWasmSign(bodyBase64));
        if (result.error) throw new Error(result.error);
        if (typeof result.signatureBase64 !== "string" || result.signatureBase64.length === 0) {
          throw new Error("SAP signer returned an empty signature");
        }

        return result.signatureBase64;
      });
    }

    close() {
      return this.enqueue(async () => {
        if (!this.initialized) return false;

        const result = JSON.parse(root.sapWasmClose());
        if (result.error) throw new Error(result.error);
        this.initialized = false;
        return true;
      });
    }
  }

  async function loadSapSigner(options) {
    await initialize(options || {});
    return true;
  }

  async function sapGenerateKBSync(guid, dsid, options) {
    if (typeof guid !== "string") throw new TypeError("guid must be a string");
    const normalizedGuid = guid.trim().replace(/:/g, "").toUpperCase();
    if (!/^[0-9A-F]{12}$/.test(normalizedGuid)) {
      throw new TypeError("kbsync GUID must contain exactly six hexadecimal bytes");
    }
    // Decimal strings and BigInts preserve the full uint64 DSID. A Number
    // is accepted only when JavaScript has represented it without rounding.
    if (typeof dsid === "number" && !Number.isSafeInteger(dsid)) {
      throw new TypeError("DSID numbers must be safe integers; use a decimal string for larger values");
    }
    if (!["string", "number", "bigint"].includes(typeof dsid)) {
      throw new TypeError("DSID must be a decimal string, safe integer, or BigInt");
    }
    const decimalDSID = String(dsid).trim();
    if (!/^[0-9]+$/.test(decimalDSID) || decimalDSID.length > 20) {
      throw new TypeError("DSID must be a nonzero decimal uint64");
    }
    const numericDSID = BigInt(decimalDSID);
    if (numericDSID === 0n || numericDSID > 0xffffffffffffffffn) {
      throw new TypeError("DSID must be a nonzero decimal uint64");
    }
    const execute = async () => {
      const profile = kbsyncProfiler(options || {});
      try {
        if (profile) profile.start("runtime.initialize");
        await initialize(options || {});
        if (profile) {
          profile.end("runtime.initialize");
          profile.instrument(root.unicornModule);
        }
        const result = JSON.parse(root.sapWasmGenerateKBSync(normalizedGuid, String(numericDSID)));
        if (result.error) throw new Error(result.error);
        if (typeof result.kbsyncBase64 !== "string" || result.kbsyncBase64.length === 0) {
          throw new Error("StoreAgent returned an empty kbsync");
        }
        return result.kbsyncBase64;
      } catch (error) {
        if (profile) profile.data.error = String(error);
        throw error;
      } finally {
        if (profile) profile.finish();
      }
    };
    const pending = kbsyncQueue.then(execute);
    kbsyncQueue = pending.catch(() => {});
    return pending;
  }

  function kbsyncProfiler(options) {
    if (!options.debug && typeof options.onDebug !== "function") return null;
    const started = performance.now();
    const previousLogger = root.sapWasmKBSyncLog;
    const previousChunk = root.sapWasmInstructionChunk;
    if (options.instructionChunk !== undefined) {
      if (!Number.isSafeInteger(options.instructionChunk) || options.instructionChunk <= 0) {
        throw new TypeError("instructionChunk must be a positive safe integer");
      }
      root.sapWasmInstructionChunk = options.instructionChunk;
    }
    let originalConstructor = null;
    let module = null;
    let phase = "runtime.initialize";
    const starts = new Map();
    const data = { backend: "wasm-tci", stages: {}, engines: [], segments: [], events: [] };
    const emit = event => {
      event.elapsedMs = performance.now() - started;
      data.events.push(event);
      if (options.debug) console.debug("[kbsync]", JSON.stringify(event));
      if (typeof options.onDebug === "function") {
        try { options.onDebug(event); } catch (_) { /* Diagnostics must not interrupt guest execution. */ }
      }
    };
    root.sapWasmKBSyncLog = value => {
      const event = JSON.parse(value);
      if (event.event === "stageStart") phase = event.stage;
      if (event.event === "stageEnd") data.stages[event.stage] = event.durationMs;
      emit(event);
    };
    return {
      data,
      start(name) {
        starts.set(name, performance.now());
        phase = name;
        emit({ event: "stageStart", stage: name });
      },
      end(name) {
        const durationMs = performance.now() - starts.get(name);
        data.stages[name] = durationMs;
        emit({ event: "stageEnd", stage: name, durationMs });
      },
      instrument(runtime) {
        data.backend = runtime.sapRuntimeBackend || "wasm-tci";
        data.build = runtime.sapRuntimeBuild || "unspecified";
        emit({ event: "runtime", backend: data.backend, build: data.build });
        module = runtime;
        originalConstructor = module.Unicorn;
        module.Unicorn = function (...arguments_) {
          const opening = performance.now();
          const engine = new originalConstructor(...arguments_);
          const stats = { id: data.engines.length + 1, openMs: performance.now() - opening, calls: {}, closed: false };
          data.engines.push(stats);
          const originalRead = engine.reg_read_i64;
          for (const name of ["emu_start", "mem_map", "mem_write", "mem_read", "reg_read_i64", "reg_write_i64", "hook_add", "hook_del", "ctl_set_tcg_buffer_size", "close"]) {
            const original = engine[name];
            engine[name] = function (...args) {
              const at = performance.now();
              let failure = null;
              try {
                const result = original.apply(this, args);
                if (name === "close") stats.closed = true;
                return result;
              } catch (error) {
                failure = String(error);
                throw error;
              } finally {
                const durationMs = performance.now() - at;
                const call = stats.calls[name] || (stats.calls[name] = { count: 0, durationMs: 0, bytes: 0 });
                call.count++;
                call.durationMs += durationMs;
                if (name === "mem_write") call.bytes += args[1].length;
                if (name === "mem_read" || name === "mem_map") call.bytes += Number(args[1]);
                if (name === "emu_start") {
                  const event = { event: "segment", stage: phase, engine: stats.id,
                    begin: "0x" + BigInt.asUintN(64, args[0]).toString(16),
                    durationMs };
                  if (module.sapTciJitStats) event.jit = { ...module.sapTciJitStats };
                  try {
                    const rip = originalRead.call(this, module.X86_REG_RIP);
                    event.end = "0x" + BigInt.asUintN(64, rip).toString(16);
                    event.stop = root.sapWasmShimName ? root.sapWasmShimName(rip) : null;
                  } catch (error) { event.diagnosticError = String(error); }
                  if (failure) event.error = failure;
                  data.segments.push(event);
                  emit(event);
                }
              }
            };
          }
          return engine;
        };
        module.Unicorn.prototype = originalConstructor.prototype;
      },
      finish() {
        if (module) module.Unicorn = originalConstructor;
        root.sapWasmKBSyncLog = previousLogger;
        root.sapWasmInstructionChunk = previousChunk;
        data.totalMs = performance.now() - started;
        root.sapKBSyncLastProfile = data;
        emit({ event: "summary", durationMs: data.totalMs, stages: data.stages, engines: data.engines });
      }
    };
  }

  async function createSapSigner(guid, options) {
    const signer = new SapSigner(guid, options || {});
    await signer.initialize();
    return signer;
  }

  function sapInitialize(guid, options) {
    if (currentSigner) return Promise.reject(new Error("SAP signer is already initialized"));
    currentSigner = new SapSigner(guid, options || {});
    return currentSigner.initialize().catch(error => {
      currentSigner = null;
      throw error;
    });
  }

  function sapSign(bodyBase64) {
    if (!currentSigner) return Promise.reject(new Error("SAP signer is not initialized"));
    return currentSigner.sign(bodyBase64);
  }

  // Compatibility/control path matching the original one-shot ordering:
  // setup completion and body signing happen inside one Go/WASM call, then
  // the signer state is destroyed immediately.
  function sapSignOnce(guid, bodyBase64, options) {
    return (async () => {
      if (typeof bodyBase64 !== "string" || bodyBase64.length === 0) {
        throw new TypeError("body Base64 must be a non-empty string");
      }

      const signer = new SapSigner(guid, options || {});
      try {
        await initialize(signer.options);
        const proxyBase = signer.options.proxyURL || DEFAULT_PROXY_URL;
        const certificate = await requestCertificate(proxyBase);
        const preparation = JSON.parse(root.sapWasmPrepareSetup(signer.guid, certificate, bodyBase64));
        if (preparation.error) throw new Error(preparation.error);
        const reply = await exchangeSetup(proxyBase, preparation.requestBase64);
        const result = JSON.parse(root.sapWasmFinishSetupAndSign(reply));
        if (result.error) throw new Error(result.error);
        return result.signatureBase64;
      } finally {
        root.sapWasmClose();
      }
    })();
  }

  function sapClose() {
    if (!currentSigner) return Promise.resolve(false);
    const signer = currentSigner;
    currentSigner = null;
    return signer.close();
  }

  root.loadSapSigner = loadSapSigner;
  root.sapGenerateKBSync = sapGenerateKBSync;
  root.createSapSigner = createSapSigner;
  root.SapSigner = SapSigner;
  root.sapInitialize = sapInitialize;
  root.sapSign = sapSign;
  root.sapSignOnce = sapSignOnce;
  root.sapClose = sapClose;
})(typeof globalThis === "undefined" ? window : globalThis);
