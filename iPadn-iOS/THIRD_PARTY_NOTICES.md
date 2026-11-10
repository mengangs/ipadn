# 第三方组件说明

iPadn 本身以 GPL-2.0-or-later 发布（见仓库根目录 `LICENSE`）。它使用了以下第三方组件。

## 验证运行组件

`vendor/SAPRuntime` 包含 SAP WebAssembly、Unicorn 执行组件、Go WebAssembly 支持层、Store 设备验证运行库（来自 Apple 官方软件包的 `libCoreADI.so` 与 `libstoreservicescore.so`）及本地 JavaScript 适配层（Store 验证加载与调用逻辑参考 [Dadoum/Provision](https://github.com/Dadoum/Provision) 与 `ipatool-store-proof`，LGPL-2.0），构建时校验 `manifest.json` 的 SHA-256 后打包，无需下载其他项目资源。

现有组件内嵌的版权及许可证注释均保留。运行组件的来源记录保存于同目录的 `PROVENANCE.json`；组件没有因为本地维护而变为本项目原创。未确认的许可范围不由本项目扩张或另行授予。

## Mac App Store 安装包处理组件

设备版 IPA 由 `scripts/build_mac_pkg_bridge.sh` 在构建时从固定提交获取并静态链接以下源码，许可证文本随 IPA 一并放在应用包内：

- [ipatool](https://github.com/majd/ipatool/tree/4484b55d366e177ae6c89758c61588712c572fad)（MIT）：StoreAgent 运行环境、Mach-O 加载器与 Apple 组件校验。本项目的调用层位于 `MacPKGBridge/bridge.go`。
- [Unicorn TCI 分支](https://github.com/Naville/unicorn/tree/53471ef9cf480fab094bf13db3e5d2f9e2c30dc5)（GPL-2.0）：无 JIT 的 x86-64 解释器。分发包含该组件的 IPA 时须同时提供对应源码及许可证。

Apple 的 StoreAgent 等运行文件不包含在仓库或 IPA 中，由应用在首次处理时从 Apple 官方软件更新服务器下载，并按 ipatool 固定的 SHA-256 校验后缓存在本机。

## ZIPFoundation

使用 Swift Package Manager 固定解析 ZIPFoundation 0.9.19。作者及许可证见组件原始 [LICENSE](https://github.com/weichsel/ZIPFoundation/blob/0.9.19/LICENSE)，打包和再分发时应保留相应声明。

## Telegram iOS 列表运动与手势

`iPadn/Views/RevealMotion.swift` 改编自 Telegram contributors 的 [ItemListRevealMotion.swift](https://github.com/TelegramMessenger/Telegram-iOS/blob/24638bc69bd083981b178dd1e7f921eebbf7fc46/submodules/ItemListUI/Sources/ItemListRevealMotion.swift)，固定提交 `24638bc69bd083981b178dd1e7f921eebbf7fc46`，GPL-2.0-or-later。保留其阻尼、弹簧、速度衔接与操作阈值模型。SwiftUI 宿主适配位于 `RevealInteraction.swift`，不依赖 Telegram 的网络、账号或显示框架。[Telegram 官方许可说明](https://telegram.org/apps#source-code)。

`RevealInteraction.swift` 的原生手势识别器同时参考该提交的 [ItemListRevealTouchGestureRecognizer.swift](https://github.com/TelegramMessenger/Telegram-iOS/blob/24638bc69bd083981b178dd1e7f921eebbf7fc46/submodules/ItemListUI/Sources/ItemListRevealTouchGestureRecognizer.swift)，按本应用的 SwiftUI 列表宿主适配横向识别、纵向让行、速度采样、按钮点击与取消处理，遵循相同许可证。

本仓库不包含 Apple 账号凭据、验证码、签名证书或私钥。
