## iPadn 2.3.1

**目录 / Contents**：[简体中文](#-核心修复与优化) · [TestFlight 说明与免责](#-testflight-实验性说明与免责声明) · [English](#english) · [TestFlight Notice](#testflight-experimental-notice--disclaimer)

本次为 **v2.3.0** 的首个快速修复与性能优化版：全面恢复 **iOS / iPadOS 16** 兼容运行，解决高速滑动大量历史版本时因图标加载与持久化引起的掉帧卡顿，并补齐 Xcode / TestFlight CI 编译与初始化稳定性。安装包均未签名，请使用自用签名工具签名后安装。

### 🔧 核心修复与优化

- **恢复 iOS / iPadOS 16 完整兼容（感谢 [@tageniu](https://github.com/tageniu) 在 PR #108 的贡献）**
  - 修复 `v2.3.0` 构建时将部署目标升至 iOS 17 导致 iOS 16 设备冷启动即因 `dyld` 缺失 `Symbols.framework` 闪退的问题：统一把 SwiftPM、`xtool` 与 Xcode 的最低部署目标恢复为 **iOS 16.0**，并对 `Symbols`、`Translation`、`ActivityKit` 保持弱链接（`LC_LOAD_WEAK_DYLIB`）与完整运行时可用性防护。
  - 修复 iOS 16 设备本地生成安装 PKCS#12 证书时 `SecItemImport` 因默认 AES 算法不兼容导致的失败：iOS 16 上自动回退为兼容的 HMAC-SHA1 PKCS#12 MAC。
  - 补齐 Xcode 工程文件缺失的 `SigningCapability.swift` 引用，并修复 `iPadnLiveActivity` 扩展在 iOS 16 与双构建链（Xcode / `xtool`）下的可用性标注与编译通过。
- **显著优化「历史版本」快速滚动流畅度（400+ 版本长列表实测通过）**
  - 引入独立无锁内存缩略图缓存 `VersionIconCache`（`NSCache` 24 MiB 配额、去重并发与后台预解码至展示分辨率）：已缓存版本图标在回滑时首帧同步直出，无闪烁占位。
  - 未缓存行先进行轻量防抖（75 ms），快速飞掠时跳过无效磁盘解码；同时将版本元数据 JSON 持久化下沉到后台串行队列、跳过已完整加载条目与无变化状态写回，消除掉帧卡顿。
- **TestFlight / CI 初始化稳定性加固**
  - 适当放宽首次冷启动 `SAPSigner`（WebKit）初始化超时上限（45s–90s 可自适应），提升低速环境中 TestFlight 会话签名与 CI 测试稳定性。

---

### 📢 官方频道与反馈说明

- **官方 Telegram 频道**：👉 [**https://t.me/ipadn_official**](https://t.me/ipadn_official)
- **GitHub Issues 仅保留只读归档**：新版安装包与源码优先在官方 Telegram 频道发布；使用问题、排障与 Bug 反馈请直接前往频道**对应版本贴文评论区**提交。

### ⚠️ TestFlight 实验性说明与免责声明

- **实验性功能提醒**：TestFlight 下载与原生安装为 `v2.3.x` 系列推出的**实验性功能**，受 Apple 服务端策略、账号当前有效 Beta 资格、本地网络/代理与本机配对影响，建议先使用备用 Apple 账号体验，勿分享配对文件、令牌或完整备份；详细用法与排障指南见 [README — TestFlight 实验性新功能](README.md#testflight-实验性新功能)。
- **免责声明**：iPadn 基于 [GPL-2.0-or-later](LICENSE) 开源，仅限个人合法备份、授权测试与技术研究，与 Apple Inc. 无关；因使用本工具带来的账号风控或数据风险由使用者自行承担。

### 📦 安装包与签名源

- `iPadn-2.3.1-unsigned.ipa`：标准版，含实时活动（灵动岛、锁屏进度）与桌面小组件扩展，签名需要 2 个 App ID。
- `iPadn-2.3.1-lite-unsigned.ipa`：精简版，移除扩展，只需 1 个 App ID；不提供实时活动或小组件，其他功能完全一致。
- SideStore、AltStore、Feather 等签名工具可添加源：`https://raw.githubusercontent.com/mengangs/ipadn/main/altstore-source.json`。

---

### English

**v2.3.1** is a fast-follow stability and performance update to **v2.3.0**: it restores full **iOS / iPadOS 16** compatibility, eliminates frame drops during fast scrolling in long version history lists, and resolves Xcode / TestFlight CI build and cold-boot reliability issues. Both packages are unsigned—sign with your own tool before installing.

#### Fixes & Improvements Since v2.3.0

- **Restored iOS / iPadOS 16 Support (thanks [@tageniu](https://github.com/tageniu) for PR #108)**
  - Fixed the `v2.3.0` startup `dyld` crash on iOS 16 devices caused by an accidental iOS 17 minimum deployment target (`Symbols.framework` missing): lowered SwiftPM, `xtool`, and Xcode targets back to **iOS 16.0** while keeping `Symbols`, `Translation`, and `ActivityKit` weak-linked (`LC_LOAD_WEAK_DYLIB`) with proper availability guards.
  - Fixed local PKCS#12 certificate import failure on iOS 16 by falling back to HMAC-SHA1 MAC when AES-based `SecItemImport` defaults are unsupported.
  - Added the missing `SigningCapability.swift` reference to `iPadn.xcodeproj` and fixed `iPadnLiveActivity` availability annotations so both Xcode and `xtool` compile cleanly.
- **Smooth Fast Scrolling in App Version History**
  - Extracted a lock-free `VersionIconCache` (`NSCache` with a 24 MiB budget, in-flight request deduplication, and background `byPreparingThumbnail` decoding): previously loaded version icons now render synchronously on frame zero when scrolling back, eliminating flicker.
  - Debounced uncached row disk reads (75 ms) to skip fast-flung rows, moved version metadata snapshot writes off the main actor onto a dedicated background queue, and skipped redundant metadata reloads and no-op UI writes.
- **TestFlight & CI Cold-Boot Reliability**
  - Expanded the `SAPSigner` WebKit warm-up timeout floor/cap (45s–90s) to prevent spurious cold-boot timeouts under slow hosts or constrained CI runners.

#### Official Telegram Channel & GitHub Issues Archive
- **Official Telegram Channel**: [**https://t.me/ipadn_official**](https://t.me/ipadn_official) (new builds & source archives land here first).
- **GitHub Issues Read-Only**: Please post support questions, TestFlight diagnostics, and bug reports under the matching release post in our Telegram channel.

#### TestFlight Experimental Notice & Disclaimer
- TestFlight download and native installation in `v2.3.x` are **experimental** and depend on Apple server behavior, active per-account invitations, proxy/DNS setup, and device pairing state. Testing with a secondary Apple Account first is recommended, and never share pairing files, tokens, or unencrypted backups (see [README_EN — TestFlight Experimental](README_EN.md#testflight-experimental)).
- Released under [GPL-2.0-or-later](LICENSE) for authorized personal testing, backups, and research; unaffiliated with Apple Inc., with all account or data risks assumed by the user.

#### Packages
- `iPadn-2.3.1-unsigned.ipa`: Standard build with Live Activities & Widgets (requires 2 App IDs).
- `iPadn-2.3.1-lite-unsigned.ipa`: Lite build without extensions (requires 1 App ID; identical core features).
- AltStore / SideStore / Feather repo: `https://raw.githubusercontent.com/mengangs/ipadn/main/altstore-source.json`.

更早版本的更新内容（含 v2.3.0 TestFlight 完整说明）见 [Releases](https://github.com/mengangs/ipadn/releases)。
