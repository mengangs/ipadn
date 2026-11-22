## iPadn 2.3.4

**目录 / Contents**：[简体中文](#-核心修复与优化) · [TestFlight 说明与免责](#-testflight-实验性说明与免责声明) · [English](#english) · [TestFlight Notice](#testflight-experimental-notice--disclaimer)

本次为 **v2.3.4** 体验打磨与一致性升级版：全面打通 **TestFlight** 与常规下载体验（后台下载保活、灵动岛百分比实时同步、取消多余分组、全应用统一极简单色 TestFlight 图标，并同步接入「已解密」「Wi‑Fi 传输」与「存储空间」）；重构下载/TestFlight 暂停、继续与全状态切换弹性形变动效；优化本机配对引导与全应用居中确认弹窗，并修复双重认证与系统兼容细节。安装包均未签名，请使用自用签名工具签名后安装。

### 🔧 核心修复与优化

- **TestFlight 后台下载与灵动岛实时同步**
  - 完善 TestFlight 后台下载保活、随时暂停/继续与速度/ETA 展示，进度环与常规 App Store 下载体验保持一致。
  - 修复灵动岛与锁屏实时活动在退回后台后进度百分比停滞的问题（启用高频更新许可与后台保活同步，完成或暂停时自动收起）。
- **全应用 TestFlight 统一列表与极简单色图标**
  - 「下载」页与「应用包 › 原始 IPA」取消单独的 TestFlight 分组，与普通 IPA 合并排序展示；统一在版本信息行前置极简单色 TestFlight 图标，彻底移除旧蓝色 `TF` 胶囊与会话级「已安装」残留，安装行为与普通 IPA 完全一致。
  - 补全所有关联页面的统一展示与数据联动：**「应用包 › 已解密」**、解密详情、处理记录、原始 IPA 详情、安装页、**「Wi‑Fi 传输」**以及**「设置 › 备份与维护 › 存储空间」**（支持容量统计与侧滑删除）；删除原始 TestFlight IPA 后，已解密产物与处理记录仍持久保留 TestFlight 标识。
- **下载与 TestFlight 状态切换弹性形变动效**
  - 修复并升级 `AppStoreActionButton` 形变动画，统一覆盖搜索、详情、下载页与 TestFlight 列表/详情页：获取 → 加载旋转弧 → 下载进度环 → 暂停/继续胶囊 → 完成打钩 → 安装全程原地弹性过渡，状态文字平滑纵滑切换，进度条在主题色与暂停灰之间柔和渐变。
- **配对引导、居中弹窗与认证兼容修复**
  - 优化原生安装配对向导：将「取消配对」移至导航栏左上角与「打开设置」对称，修正 6 位配对码输入与布局体验。
  - 全应用删除、清理等二次确认统一采用原生居中弹窗，并为专业模式「应用包」补全侧滑 5 秒撤销删除。
  - 修复双重认证（2FA）流程细节，完善 `NativeInstall` 在 iOS 17.4+ 的可用性防护与多语言/单元测试覆盖。

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

**v2.3.4** delivers a major UX, motion, and consistency polish across **Downloads**, **TestFlight**, and **Packages**: it adds full TestFlight background downloads with live Dynamic Island percentage sync, merges TestFlight and regular IPAs into unified lists with a refined monochrome TestFlight icon across every screen (including Decrypted outputs, Wi‑Fi Transfer, and Storage), introduces fluid spring morph animations for pause/resume/download state transitions, refines the Native Install pairing guide and centered confirmation alerts, and fixes 2FA and iOS 17.4+ compatibility edge cases. Both packages are unsigned—sign with your own tool before installing.

#### Fixes & Improvements Since v2.3.3

- **TestFlight Background Downloads & Live Dynamic Island Sync**
  - Adds background keep-alive, pause/resume, live speed/ETA, and App Store-style downloading rings for TestFlight downloads.
  - Fixes Dynamic Island & Lock Screen Live Activity percentages stalling in the background by enabling frequent Live Activity updates and coordinated background sync.
- **Unified TestFlight Lists, Monochrome Icon & Full-App Coverage**
  - Merges TestFlight items into unified **Downloads** and **Packages › Original IPAs** lists (no separate cluttered section) with a cohesive monochrome TestFlight icon in the metadata slot, removing blue `TF` pills and session-only "Installed" badges so install behavior matches standard IPAs.
  - Extends consistent TestFlight icon and package visibility to **Packages › Decrypted**, Decryption Detail/History, Source Detail, Install sheet, **Wi‑Fi Transfer**, and **Settings › Storage** (with size tracking & swipe-to-delete), while persisting TestFlight provenance on `DecryptRecord` even after removing the source IPA.
- **Fluid Spring Morph Animations for Pause/Resume & State Changes**
  - Fixes outer morph animations in `AppStoreActionButton` and unifies Downloads, TestFlight Home, and TestFlight Detail around persistent action controls so Get → Loading → Progress Ring → Pause/Resume Pill → Completion Check → Install smoothly morph in place alongside gentle status-line transitions and progress tint fades.
- **Pairing UX, Centered Alerts & 2FA/Compatibility Fixes**
  - Moves **Cancel Pairing** to the top-left toolbar mirroring **Open Settings** and polishes the 6-digit pairing PIN guide.
  - Standardizes destructive confirmations on native centered alerts, adds 5-second Undo to **Packages** swipe deletion, and fixes 2FA edge cases and iOS 17.4+ `NativeInstall` guards.

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
