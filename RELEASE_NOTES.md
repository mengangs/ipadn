## iPadn 2.3.4

**目录 / Contents**：[简体中文](#-核心修复与优化) · [TestFlight 说明与免责](#-testflight-实验性说明与免责声明) · [English](#english) · [TestFlight Notice](#testflight-experimental-notice--disclaimer)

本次为 **v2.3.4** 体验与稳定性重磅优化版：全面打通 **TestFlight 与「下载」页实时同步**（开始下载后自动进入列表、支持真暂停/断点续传、实时网速与底部角标同步），根治多账号切换反复触发验证码与 0 应用账号卡顿问题；统一「应用包」与「下载」页的**左滑 5 秒撤销倒计时 vs 长按确认弹窗直删**交互并升级居中原生 Alert；补齐 App Store 账单/付款/条款类报错引导，并为 iOS 17.4 以下设备加上原生安装版本门禁与 Bonjour 跨设备端口隔离。安装包均未签名，请使用自用签名工具签名后安装。

### 🔧 核心修复与优化

- **TestFlight 实时同步到「下载」页 + 真暂停 / 断点续传**
  - TestFlight 任务在元数据就绪并实际开始下载后，实时同步显示在「下载」页顶部（与普通下载保持一致，准备阶段不提前占位）并同步更新底部「下载」标签角标。
  - 任务卡片支持与常规下载完全一致的 **暂停 / 继续** 按钮、实时速度与剩余时间估算，暂停通过 `resumeData` 断点保存，续传不消耗重试次数并在 CDN 签名过期时自动刷新链接；同时联动「全部暂停 / 全部继续」。
- **根治 TestFlight 切号反复请求验证码、多手机号验证与 0 应用账号切换**
  - 后台静默已购同步不再在未完成全量历史时反复触发无验证码登录刷新；TestFlight 启动与切换账号时优先静默恢复本地会话与 10-cookie 快照，不再自动发起会触发系统验证码推送的 GSA 登录。
  - 完善多受信任手机号验证选择器（单号码自动发送、多号码弹窗选择），修复 2FA 弹窗关闭竞态与验证后瞬时 `503` 重试，并优化 0 应用账号本地缓存加载（0ms 显示空态且遵守刷新冷却）及 `TFDoh` 2 秒并发探测避免长阻塞。
- **「应用包」与「下载」页删除交互统一 & 居中原生确认弹窗**
  - 专业模式「应用包」全部 5 类列表项（TestFlight、原始包、独立包、解密产物、孤立产物）左滑删除统一接入 **5 秒撤销倒计时**（原子暂存，点击撤销可完整恢复文件与解密记录）；长按菜单删除与批量删除改为弹出居中原生确认弹窗，确认后立即删除不再重复倒计时。
  - 全应用操作确认弹窗升级为 iOS 26 居中原生 `.alert` 样式，消除底部 ActionSheet 遮挡与快速重入竞态。
- **App Store 账单/条款失败引导与原生安装 iOS 17.4+ 防护**
  - 扩展 `buyProductFailure` 识别（新增 `3038` 新版条款及 `5111 / 2022 / 3002 / 5062 / 5304` 付款/账单/首次商店设置类错误），引导用户先在系统 App Store 完成账单或条款确认后重试。
  - 原生安装新增 **iOS 17.4+ 系统版本前置校验与设置页说明**（iOS 16 仅支持传统 lockdownd，无法建立 RPPairing 通道，直接提示改用「一键安装」或「本机证书」）；修复 `RemotePairingPort` 在同局域网存在其他 iOS 17.4+/27 设备时误采对方 `_remotepairing._tcp` 端口的问题，并为 `lookup` / `installedApps` 补齐失败阶段诊断日志。

---

### 📢 官方频道与反馈说明

- **官方 Telegram 频道**：👉 [**https://t.me/ipadn_official**](https://t.me/ipadn_official)
- **GitHub Issues 仅保留只读归档**：新版安装包与源码优先在官方 Telegram 频道发布；使用问题、排障与 Bug 反馈请直接前往频道**对应版本贴文评论区**提交。

### ⚠️ TestFlight 实验性说明与免责声明

- **实验性功能提醒**：TestFlight 下载与原生安装为 `v2.3.x` 系列推出的**实验性功能**，受 Apple 服务端策略、账号当前有效 Beta 资格、本地网络/代理与本机配对影响，建议先使用备用 Apple 账号体验，勿分享配对文件、令牌或完整备份；详细用法与排障指南见 [README — TestFlight 实验性新功能](README.md#testflight-实验性新功能)。
- **免责声明**：iPadn 基于 [GPL-2.0-or-later](LICENSE) 开源，仅限个人合法备份、授权测试与技术研究，与 Apple Inc. 无关；因使用本工具带来的账号风控或数据风险由使用者自行承担。

### 📦 安装包与签名源

- `iPadn-2.3.4-unsigned.ipa`：标准版，含实时活动（灵动岛、锁屏进度）与桌面小组件扩展，签名需要 2 个 App ID。
- `iPadn-2.3.4-lite-unsigned.ipa`：精简版，移除扩展，只需 1 个 App ID；不提供实时活动或小组件，其他功能完全一致。
- SideStore、AltStore、Feather 等签名工具可添加源：`https://raw.githubusercontent.com/mengangs/ipadn/main/altstore-source.json`。

---

### English

**v2.3.4** delivers major UX and reliability improvements: real-time **TestFlight download sync in Downloads** with true pause/resume and tab badge counts, fixes for repeated 2FA code prompts on account switches and multi-phone/0-app TestFlight sessions, unified **swipe-to-delete 5-second Undo vs. centered native alert immediate delete** across Packages and Downloads, clearer App Store billing/terms error guidance, and an iOS 17.4+ guard plus peer-LAN Bonjour isolation for Native Install. Both packages are unsigned—sign with your own tool before installing.

#### Fixes & Improvements Since v2.3.3

- **Real-Time TestFlight Sync in Downloads & True Pause/Resume**
  - Active TestFlight downloads now appear at the top of **Downloads** once transfer actually starts (never prematurely during metadata lookup) and update the bottom Downloads tab badge in real time.
  - Adds native **Pause / Resume** controls with `resumeData` preservation, live EWMA speed/ETA, automatic rotated CDN URL refresh on resume, and integration with Pause All / Resume All.
- **Stopped Repeated 2FA Prompts & Hardened TestFlight Multi-Account Auth**
  - Background purchase-history sync no longer triggers silent codeless sign-in retries when switching accounts; TestFlight launch and account switching restore local sessions & 10-cookie jars silently without kicking off unexpected GSA 2FA pushes.
  - Adds a trusted phone number picker for multi-phone SMS 2FA, fixes 2FA sheet dismissal races and transient post-2FA `503` retries, caches empty 0-app catalogs for instant switching, and caps `TFDoh` probes to 2 seconds in parallel.
- **Unified Packages & Downloads Deletion UX + Centered Native Alerts**
  - All five row types in Pro mode **Packages** now support swipe-to-delete with a **5-second atomic Undo countdown** (restoring both files and decryption records), while long-press and bulk deletions use centered native iOS alerts and delete immediately without a redundant countdown.
  - Migrates confirmation dialogs across the app to centered native `.alert` presentations.
- **App Store Billing/Terms Guidance & Native Install iOS 17.4+ Safeguards**
  - Detects additional `buyProductFailure` billing, payment, and terms codes (`3038`, `5111`, `2022`, `3002`, `5062`, `5304`) with clear guidance to complete setup in the system App Store first.
  - Adds an explicit **iOS 17.4+ minimum OS check** and Settings notice for Native Install (since iOS 16 lacks Apple's RPPairing tunnel), rejects non-local peer LAN `_remotepairing._tcp` endpoints during Bonjour port discovery, and logs `lookup` / `installedApps` failure stages into diagnostics.

#### Official Telegram Channel & GitHub Issues Archive
- **Official Telegram Channel**: [**https://t.me/ipadn_official**](https://t.me/ipadn_official) (new builds & source archives land here first).
- **GitHub Issues Read-Only**: Please post support questions, TestFlight diagnostics, and bug reports under the matching release post in our Telegram channel.

#### TestFlight Experimental Notice & Disclaimer
- TestFlight download and native installation in `v2.3.x` are **experimental** and depend on Apple server behavior, active per-account invitations, proxy/DNS setup, and device pairing state. Testing with a secondary Apple Account first is recommended, and never share pairing files, tokens, or unencrypted backups (see [README_EN — TestFlight Experimental](README_EN.md#testflight-experimental)).
- Released under [GPL-2.0-or-later](LICENSE) for authorized personal testing, backups, and research; unaffiliated with Apple Inc., with all account or data risks assumed by the user.

#### Packages
- `iPadn-2.3.4-unsigned.ipa`: Standard build with Live Activities & Widgets (requires 2 App IDs).
- `iPadn-2.3.4-lite-unsigned.ipa`: Lite build without extensions (requires 1 App ID; identical core features).
- AltStore / SideStore / Feather repo: `https://raw.githubusercontent.com/mengangs/ipadn/main/altstore-source.json`.

更早版本的更新内容见 [Releases](https://github.com/mengangs/ipadn/releases)。
