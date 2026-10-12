# Third-party provenance

The native app was initially ported from the user-supplied IPA-Tool-3.0.scripting archive, whose metadata attributes the script to 小白脸. Reference upstream: https://github.com/ScriptingApp/Community-Scripts, commit f9509c530b730d8be36639db5b7825cadb431898.

Four files under vendor/SAPRuntime/files (sap-signer.js, sap.wasm, unicorn_x86.js, wasm_exec.js) retain their original bytes. Their SHA-256 values are recorded in manifest.json. They are checked into this repository, not downloaded from upstream during a build. index.html is a new minimal native bridge maintained here; it does not contain the original visual page.

The vendored code includes a Go WebAssembly support layer and a Unicorn-based execution runtime. Existing embedded copyright/license comments are preserved. A complete license grant for all components was not established by this migration; provenance here is not a claim of original authorship or a new license grant.

ZIPFoundation 0.9.19 is resolved by Swift Package Manager. Its license and copyright notices remain in the package: https://github.com/weichsel/ZIPFoundation/blob/0.9.19/LICENSE.

No Apple passwords, authentication tokens, verification codes or signing certificates are included in the repository.
