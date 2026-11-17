# 第三方组件说明

iPadn 本身以 GPL-2.0-or-later 发布（见仓库根目录 `LICENSE`）。应用及构建流程涉及以下第三方或内建组件：

## FairPlayCore C 解密核心

`iPadn-iOS/FairPlayCore/`（`FairPlayCore.c`、`include/FairPlayCore.h`、`include/module.modulemap`）及其 Swift 封装（`iPadn/Services/FairPlay/`）为本项目原创实现的零外部依赖纯 C 模块，用于本机 FairPlay Mach-O SINF 解密与验证（不修改签名工具或系统权限）。该组件随仓库一并以 GPL-2.0-or-later 许可证发布，已直接集成至 `iPadn.xcodeproj` 与本地构建流程。

## 验证运行组件（`vendor/SAPRuntime`）

`vendor/SAPRuntime` 包含 9 个清单受控文件（见同目录 `manifest.json` 与来源清单 [`PROVENANCE.json`](vendor/SAPRuntime/PROVENANCE.json)），构建时通过 `manifest.json` SHA-256 双射校验后打包进应用资源：

- `wasm_exec.js`：Go WebAssembly 运行支持层，随附 `Go-BSD-3-Clause.txt`。
- `sap-signer.js`：本地适配的 JavaScript 适配层，Store 验证加载与调用逻辑参考 [Dadoum/Provision](https://github.com/Dadoum/Provision)、`hpidcock/ap` 及 `trikesh32/ipatool` (`store-proof`)，随附 `LGPL-2.0.txt`（LGPL-2.0-only，与本项目的 GPL-2.0-or-later 兼容）。
- `index.html`：本项目原创宿主页面。
- `sap.wasm`、`unicorn_x86.js`（参考来源归因自 `IPA-Tool-3.0.scripting` / `ScriptingApp/Community-Scripts` 固定提交 `f9509c530b730d8be36639db5b7825cadb431898`）及 `libCoreADI.so`、`libstoreservicescore.so`（来自 Apple Music for Android x86_64 官方软件包，按固定 SHA-256 校验）：为预编译二进制或专有共享库组件。

> **合规边界声明（见 `PROVENANCE.json`）**：上述组件内嵌的原版权及许可证注释均按原样保留，它们并未因随仓库维护而成为本项目原创；完整上游源码与再分发授权并未针对专有/无源码预编译二进制确立，未确认许可范围不由本项目扩张或另行授予。若进行严格全开源合规裁剪，可通过移除相关二进制资产并将构建切换到严格开源模式（`--strict-oss` / `--allow-missing-runtime`）隔离处理。

## Mac App Store 安装包处理组件

设备版 IPA 由 `scripts/build_mac_pkg_bridge.sh` 在构建时从固定提交获取并静态链接以下源码，许可证文本随 IPA 一并放在应用包内：

- [ipatool](https://github.com/majd/ipatool/tree/4484b55d366e177ae6c8c7358c61588712c572fad)（MIT）：StoreAgent 运行环境、Mach-O 加载器与 Apple 组件校验。本项目的调用层位于 `MacPKGBridge/bridge.go`。
- [Unicorn TCI 分支](https://github.com/Naville/unicorn/tree/53471ef9cf480fab094bf13db3e5d2f9e2c30dc5)（GPL-2.0）：无 JIT 的 x86-64 解释器。分发包含该组件的 IPA 时须同时提供对应源码及许可证。

Apple 的 StoreAgent 等运行文件不包含在仓库或 IPA 中，由应用在首次处理时从 Apple 官方软件更新服务器下载，并按 ipatool 固定的 SHA-256 校验后缓存在本机。

## 原生安装组件

设备版 IPA 由 `scripts/build_native_install.sh` 静态链接 `NativeInstall`（本项目的 Rust 调用层）及其依赖，许可证文本随 IPA 一并放在应用包内：

- [idevice](https://github.com/jkcoxson/idevice) 0.1.68（MIT，Jackson Coxson）：远程配对、设备隧道、文件传输与系统安装服务的协议实现。版本在 `NativeInstall/Cargo.toml` 中固定，依赖树由 `Cargo.lock` 固定。
- 其余 Rust 依赖（tokio、rustls、RustCrypto 等）均为 MIT 或 Apache-2.0 许可，完整清单见 `NativeInstall/Cargo.lock`。

该组件只连接本机的系统安装服务，不包含签名、改包或绕过授权的代码。

## ZIPFoundation

使用 Swift Package Manager 固定解析 ZIPFoundation 0.9.19（MIT，Thomas Zoechling）。完整许可证文本随仓库及 IPA 附带于 `iPadn/Resources/ZIPFoundation-MIT.txt`（原始上游见 [LICENSE](https://github.com/weichsel/ZIPFoundation/blob/0.9.19/LICENSE)），打包和再分发时保留相应声明。

## Telegram iOS 列表运动与手势

`iPadn/Views/RevealMotion.swift` 改编自 Telegram contributors 的 [ItemListRevealMotion.swift](https://github.com/TelegramMessenger/Telegram-iOS/blob/24638bc69bd083981b178dd1e7f921eebbf7fc46/submodules/ItemListUI/Sources/ItemListRevealMotion.swift)，固定提交 `24638bc69bd083981b178dd1e7f921eebbf7fc46`，GPL-2.0-or-later。保留其阻尼、弹簧、速度衔接与操作阈值模型。SwiftUI 宿主适配位于 `RevealInteraction.swift`，不依赖 Telegram 的网络、账号或显示框架。[Telegram 官方许可说明](https://telegram.org/apps#source-code)。

`RevealInteraction.swift` 的原生手势识别器同时参考该提交的 [ItemListRevealTouchGestureRecognizer.swift](https://github.com/TelegramMessenger/Telegram-iOS/blob/24638bc69bd083981b178dd1e7f921eebbf7fc46/submodules/ItemListUI/Sources/ItemListRevealTouchGestureRecognizer.swift)，按本应用的 SwiftUI 列表宿主适配横向识别、纵向让行、速度采样、按钮点击与取消处理，遵循相同许可证。

本仓库不包含 Apple 账号凭据、验证码、签名证书或私钥。
