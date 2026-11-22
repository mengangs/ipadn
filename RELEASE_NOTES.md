## iPadn 2.3.4

**目录 / Contents**：[简体中文](#-核心修复与优化) · [TestFlight 说明与免责](#-testflight-实验性说明与免责声明) · [English](#english) · [TestFlight Notice](#testflight-experimental-notice--disclaimer)

本次为 **v2.3.4** 体验与稳定性全面升级版：全面打通 **TestFlight 实时同步下载、后台断点续传、统一自动安装与灵动岛进度同步**；取消下载页与「应用包」冗余分组并在全应用（含「已解密」「Wi‑Fi 传输」「存储空间」）统一极简单色 TestFlight 图标；重构下载与 TestFlight 暂停/继续及全状态切换弹性形变动效；根治多账号切换反复触发验证码、多手机号 2FA 与 0 应用账号卡顿；统一「应用包」5 秒侧滑撤销与全应用原生居中弹窗、优化本机配对引导，并补齐 App Store 账单/条款报错引导及原生安装 iOS 17.4+ 与局域网防护。安装包均未签名，请使用自用签名工具签名后安装。

### 🔧 核心修复与优化

- **TestFlight 同步下载、后台续传、自动安装与灵动岛同步**
  - TestFlight 任务在元数据就绪并实际开始下载后，实时同步显示在「下载」页顶部（准备阶段不提前占位）并联动底部「下载」标签角标，下载过程进度环与常规 App Store 下载体验保持一致。
  - 接入后台传输与前台回退保活，支持真暂停/断点续传（`resumeData` 保存、续传不消耗重试次数、CDN 签名过期自动刷新链接）、实时网速/ETA 估算，并联动「全部暂停 / 全部继续」。
  - TestFlight 同步接入「下载完成后自动安装」与统一安装弹窗，移除会话级「已安装」标签与按钮变色残留，安装行为与常规 IPA 完全一致。
  - TestFlight 与普通下载统一接入**灵动岛与锁屏实时活动**，启用高频实时活动更新与后台保活同步，彻底修复退回后台后灵动岛百分比停滞不同步的问题（完成或暂停自动收起）。
- **全应用统一列表/单色 TestFlight 图标与状态切换动效**
  - 「下载」页与「应用包 › 原始 IPA」取消单独的 TestFlight 分组，与普通 IPA 合并排序展示；全应用统一在版本信息行前置极简单色 TestFlight 图标，移除旧蓝色 `TF` 胶囊。
  - 补齐所有关联页面的统一展示与数据联动：**「应用包 › 已解密」**、解密详情、处理记录、正在处理卡片、原始 IPA 详情、安装页、**「Wi‑Fi 传输」**以及**「设置 › 备份与维护 › 存储空间」**（计入总容量、按大小排序并支持侧滑删除）；`DecryptRecord` 持久记录来源标识，删除原始 TF 包后解密产物与记录仍保留 TestFlight 图标。
  - 修复 `AppStoreActionButton` 外层形变动画并统一重构下载页（常规 + TestFlight）、TestFlight 列表与详情页为单一持久操作组件：获取 → 加载旋转弧 → 下载进度环 → 暂停/继续胶囊 → 完成打钩 → 安装全程原地弹性形变，状态文字纵滑切换，进度条颜色在主题色与暂停灰之间柔和过渡。
- **根治切号反复弹验证码、多手机号 2FA 与 0 应用账号**
  - 后台静默已购同步不再反复触发无验证码登录刷新；TestFlight 启动与切换账号优先静默恢复本地会话与 10-cookie 快照，避免误触发系统验证码推送。
  - 完善多受信任手机号 2FA 选择器（单号码自动发送、多号码弹窗选择），修复 2FA 弹窗关闭竞态与验证后瞬时 `503` 重试。
  - 优化 0 应用账号本地缓存加载（0ms 展示空态并遵守刷新冷却），并将 `TFDoh` 探测收紧为 2 秒并发，消除切号和启动时的长阻塞。
- **应用包侧滑撤销、居中弹窗、配对优化与 iOS 17.4+ 防护**
  - 专业模式「应用包」全部 5 类列表项（TestFlight、原始包、独立包、解密产物、孤立产物）左滑删除统一接入 **5 秒原子撤销倒计时**（可完整恢复文件与解密记录）；长按菜单删除与批量删除弹出居中确认弹窗并直删，不再重复倒计时。
  - 全应用所有二次确认弹窗（含退出登录、清除最近搜索、清除历史版本缓存等）统一升级为原生居中 `.alert`，并精简「账号」页移除与底部 Tab 重复的入口。
  - 优化 iOS 27 本机配对引导：将「取消配对」移至导航栏左上角与「打开设置」对称，修正 6 位配对码推送提醒与提示文字换行截断。
  - 扩展 App Store `buyProductFailure` 识别（新增 `3038` 新版条款及 `5111 / 2022 / 3002 / 5062 / 5304` 账单/付款/首次商店设置引导）；为原生安装新增 **iOS 17.4+ 系统版本前置校验与说明**，修复 `RemotePairingPort` 在同局域网多设备时误采对方 `_remotepairing._tcp` 端口的问题，并补齐 `lookup` / `installedApps` 失败阶段诊断日志。

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

**v2.3.4** is a major UX, motion, and reliability release: it brings real-time **TestFlight download sync, background pause/resume, unified Auto-Install, and live Dynamic Island percentage sync**; merges TestFlight into unified lists across every screen (including Decrypted outputs, Wi‑Fi Transfer, and Storage) with a cohesive monochrome icon; introduces fluid spring morph animations for pause/resume and state changes; eliminates repeated 2FA prompts, multi-phone 2FA races, and 0-app switching stalls; unifies 5-second swipe Undo in Packages with centered native alerts and a polished on-device pairing guide; and adds App Store billing/terms error guidance plus iOS 17.4+ & LAN Bonjour isolation guards for Native Install. Both packages are unsigned—sign with your own tool before installing.

#### Fixes & Improvements Since v2.3.3

- **TestFlight Sync, Background Resume, Auto-Install & Live Island**
  - Active TestFlight downloads appear at the top of **Downloads** once transfer starts (never prematurely during metadata lookup) with live tab badges, background transfer + foreground fallback keep-alive, true `resumeData` pause/resume, automatic CDN link refresh, EWMA speed/ETA, and Pause All / Resume All integration.
  - Extends **Auto-Install** and unified install sheets to TestFlight packages, removing session-only "Installed" badges so install behavior matches standard IPAs.
  - Unifies TestFlight and standard downloads on **Dynamic Island & Lock Screen Live Activities**, enabling frequent Live Activity updates and background keep-alive sync to fix stalled background percentages.
- **Unified Lists, Monochrome TF Icon & Fluid Morph Animations**
  - Merges TestFlight items into unified **Downloads** and **Packages › Original IPAs** lists with a refined monochrome TestFlight icon in the metadata slot, removing cluttered sections and legacy blue `TF` pills.
  - Extends consistent TestFlight icon and package visibility to **Packages › Decrypted**, Decryption Detail/History, live progress cards, Source Detail, Install sheet, **Wi‑Fi Transfer**, and **Settings › Storage** (size tracking & swipe delete), while persisting `isTestFlight` on `DecryptRecord` even after removing the source IPA.
  - Fixes outer morph animations in `AppStoreActionButton` and unifies Downloads, TestFlight Home, and TestFlight Detail around persistent action controls so Get → Loading → Ring → Pause/Resume Pill → Checkmark → Install smoothly morph in place alongside gentle status-line transitions and progress tint fades.
- **Fixed Repeated 2FA Prompts, Multi-Phone 2FA & 0-App Stalls**
  - Stops background purchase-history sync from triggering silent codeless sign-in retries on account switches; TestFlight launch and account switching silently restore local sessions & 10-cookie jars without pushing unexpected GSA 2FA prompts.
  - Adds a trusted phone picker for multi-phone SMS 2FA, fixes 2FA sheet dismissal races and transient post-2FA `503` retries, caches 0-app catalogs for instant 0ms switching, and caps `TFDoh` probes to 2 seconds in parallel.
- **Packages Undo, Centered Alerts, Pairing UX & iOS 17.4+ Guards**
  - Adds **5-second atomic swipe-to-delete Undo** across all five row types in Pro mode **Packages** (restoring both files and decryption records), while long-press and bulk deletions use centered native alerts and delete immediately; migrates all app confirmation dialogs (Sign Out, Clear Recent Searches, Clear Version Cache, etc.) to centered native `.alert` and removes redundant tabs from the Account list.
  - Moves **Cancel Pairing** to the top-left toolbar mirroring **Open Settings** and fixes the 6-digit pairing PIN notification and text wrapping layout.
  - Detects additional App Store `buyProductFailure` billing/terms codes (`3038`, `5111`, `2022`, `3002`, `5062`, `5304`), enforces an explicit **iOS 17.4+ guard** and Settings notice for Native Install, isolates local Bonjour `_remotepairing._tcp` discovery from peer LAN devices, and logs `lookup` / `installedApps` failure stages to diagnostics.

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
