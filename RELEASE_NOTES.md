## iPadn 2.3.5

**目录 / Contents**：[简体中文](#-核心修复与优化) · [TestFlight 说明与免责](#-testflight-实验性说明与免责声明) · [English](#english) · [TestFlight Notice](#testflight-experimental-notice--disclaimer)

本次为 **v2.3.5** 稳定性修复与体验升级版：根治 **iOS 16.0–16.2 强链接符号闪退**、**iOS 27.2 beta 2 历史版本加载闪退** 与 **iPadOS 全屏/专业模式导航栏异常**；**TestFlight 现支持切换下载 Apple TV 等多平台测试包**并统一展示单色客户端标识，同时修复大型/多变体游戏误报「产物校验失败，已清理」及详情页顶部虚化异常；在「设置 › 外观与图标」开放**自定义全部 177 个 Apple 商店地区**（支持搜索筛选、勾选、拖拽排序与国旗展示）；并修复 FairPlay 高熵插件误拒、登录 `5020`/2FA 提示、未购免费应用首次获取旧版报错与「应用包」批量导入打断问题。安装包均未签名，请使用自用签名工具签名后安装。

### 🔧 核心修复与优化

- **修复 iOS 16/27 闪退与 iPadOS 专业模式导航异常**
  - 移除强链接 iOS 17+/18+ 的 `UnevenRoundedRectangle` 与全部 `.onGeometryChange` 调用，改用向后兼容路径与几何读取实现，根治 iOS 16.0 / 16.0.2 / 16.2 打开界面或卡片时因动态符号缺失导致的闪退。
  - 修复 iOS 27.2 beta 2 在应用详情页加载历史版本时偶发崩溃的问题（修正版本行布局优先级与骨架屏几何回调防抖阈值）。
  - 修复 iPadOS 全屏及开启「专业模式」后导航栏切换错乱、标题丢失与工具栏按钮跨标签泄露的问题，改为按当前活动标签隔离独立导航栈。
- **TestFlight 支持 Apple TV 多平台下载、校验修复与顶部优化**
  - TestFlight 详情页新增多平台切换（如 `iOS` / `Apple TV`），支持直接下载 Apple TV（tvOS）测试包，并与同一应用的 iOS 测试包独立索引、互不覆盖。
  - 在「下载」「应用包」「存储空间」「包体详情」「解密详情」等全应用页面为 Apple TV 等非 iPhone 包并列展示单色客户端图标（紧邻单色 TestFlight 图标）；点击 TestFlight 任务与安装包详情均可查看来源、客户端与对应最低系统版本（如 `tvOS`）；Apple TV 测试包下载后与常规商店包一致不显示「安装」按钮且不触发自动安装。
  - 修复 TestFlight 下载大型/多变体游戏（如多架构或超大二进制包）误报「产物校验失败，已清理」的问题：改用流式读取 Mach-O 头部前缀并兼容 FAT 32/64 位架构 `cryptid` 校验，修正替换 SINF 计数与完整变体（`packages.full`）筛选逻辑。
  - 修复进入 TestFlight 应用详情页时顶部状态栏与封面衔接处出现浅色虚化断层的显示异常，改用不透明模糊与导航栏原生外观平滑衔接。
- **设置开放自定义 177 个商店地区（支持搜索筛选与排序）**
  - 在「设置 › 外观与图标 › 商店地区」开放自定义管理搜索页显示的地区列表，覆盖全部 **177** 个 Apple App Store 商店地区（补齐 `AF`、`LI`）。
  - 支持按中文名称、英文名称或 ISO‑2 地区代码实时搜索筛选（精确匹配代码优先置顶）、点击勾选、拖拽排序、国旗与代码同屏展示及一键「恢复默认」（至少保留 1 个地区）。
- **修复 FairPlay 解密误拒、首次获取旧版报错与批量导入体验**
  - 修复专业模式本机 FairPlay 解密部分高熵插件二进制（如 `_codecs_cn`）时被误判校验失败的问题，补充基于解码后指令特征的放行校验。
  - 完善 App Store 登录诊断与错误文案：记录 `SAPSigner` 失败阶段详情，修正 `5020` 与双重认证提示文案，避免误导。
  - 修复未获取过的免费应用首次「获取」并加载历史版本时因 Apple 许可延迟偶发失败的问题（获取许可后自动清理旧缓存并执行短退避重试）。
  - 修复「应用包」批量导入多个 IPA 时中途自动跳进详情页打断队列的问题，新增实时导入计数（`正在添加安装包（已完成/总数）`）、批量完成提示与可关闭错误横幅。

---

### 📢 官方频道与反馈说明

- **官方 Telegram 频道**：👉 [**https://t.me/ipadn_official**](https://t.me/ipadn_official)
- **GitHub Issues 仅保留只读归档**：新版安装包与源码优先在官方 Telegram 频道发布；使用问题、排障与 Bug 反馈请直接前往频道**对应版本贴文评论区**提交。

### ⚠️ TestFlight 实验性说明与免责声明

- **实验性功能提醒**：TestFlight 下载与原生安装为 `v2.3.x` 系列推出的**实验性功能**，受 Apple 服务端策略、账号当前有效 Beta 资格、本地网络/代理与本机配对影响，建议先使用备用 Apple 账号体验，勿分享配对文件、令牌或完整备份；详细用法与排障指南见 [README — TestFlight 实验性新功能](README.md#testflight-实验性新功能)。
- **免责声明**：iPadn 基于 [GPL-2.0-or-later](LICENSE) 开源，仅限个人合法备份、授权测试与技术研究，与 Apple Inc. 无关；因使用本工具带来的账号风控或数据风险由使用者自行承担。

### 📦 安装包与签名源

- `iPadn-2.3.5-unsigned.ipa`：标准版，含实时活动（灵动岛、锁屏进度）与桌面小组件扩展，签名需要 2 个 App ID。
- `iPadn-2.3.5-lite-unsigned.ipa`：精简版，移除扩展，只需 1 个 App ID；不提供实时活动或小组件，其他功能完全一致。
- SideStore、AltStore、Feather 等签名工具可添加源：`https://raw.githubusercontent.com/mengangs/ipadn/main/altstore-source.json`。

---

### English

**v2.3.5** delivers key stability fixes and highly requested improvements: eliminates **iOS 16.0–16.2 strong-linked symbol crashes**, **iOS 27.2 beta 2 version-history crashes**, and **iPadOS full-screen / Pro mode toolbar & navigation bugs**; adds **multi-platform TestFlight downloads (including Apple TV)** with monochrome client badges, fixes false validation rejections on large/multi-variant games, and polishes the TestFlight detail top blur; opens a searchable, reorderable **177-region Storefront picker** under Settings › Appearance & icon; and resolves FairPlay high-entropy false rejections, login `5020`/2FA messaging, first-time free-app license retries, and multi-IPA batch import interruptions. Both packages are unsigned—sign with your own tool before installing.

#### Fixes & Improvements Since v2.3.4

- **Fix iOS 16/27 Crashes & iPadOS Pro Mode Navigation**
  - Removes strong-linked iOS 17+/18+ `UnevenRoundedRectangle` and all `.onGeometryChange` usages in favor of backward-compatible paths and geometry observers, resolving launch and view crashes on iOS 16.0 / 16.0.2 / 16.2.
  - Fixes a crash on iOS 27.2 beta 2 when loading version history on App Detail by stabilizing row layout priorities and shimmer geometry change thresholds.
  - Fixes missing titles, broken navigation, and leaked cross-tab toolbars in iPadOS full-screen & Pro mode by isolating a single active `NavigationStack` per tab.
- **TestFlight Apple TV Support, Validation & Hero Blur Fix**
  - Adds platform switching (`iOS` / `Apple TV`, etc.) on TestFlight detail pages to download Apple TV (tvOS) beta IPAs alongside iOS builds, indexed cleanly per `(bundle, platform)`.
  - Places monochrome platform icons beside the monochrome TestFlight icon across **Downloads**, **Packages**, **Storage**, **Package Info**, and **Decryption Detail**; displays source, client platform, and accurate minimum OS (e.g., `tvOS`) in task & package details; hides the Install button and skips Auto-Install for Apple TV IPAs just like regular App Store Apple TV downloads.
  - Fixes false "validation failed, cleaned up" errors on large or multi-variant TestFlight games via streaming Mach-O header prefix reads, FAT 32/64-bit `cryptid` inspection, accurate SINF replacement counting, and `packages.full`-first variant selection.
  - Eliminates the light top-edge blur band on TestFlight detail pages using opaque hero blur and native navigation bar appearance syncing.
- **Customizable 177 Storefront Regions with Search & Reorder**
  - Adds **Settings › Appearance & icon › Storefront Regions** covering all **177** Apple App Store regions (including `AF` and `LI`).
  - Supports instant search by localized name, English name, or ISO‑2 code (with exact ISO‑2 matches ranked first), tap-to-toggle, drag-to-reorder, flag + code display, and one-tap **Reset to Defaults**.
- **FairPlay, Login/License Retry & Batch Import Fixes**
  - Fixes on-device FairPlay decryption falsely rejecting legitimate high-entropy plugin binaries (such as `_codecs_cn`) by accepting verified decrypted instruction streams.
  - Improves App Store sign-in `5020` / 2FA messaging and adds staged `SAPSigner` failure diagnostics.
  - Automatically invalidates stale version caches and performs short backoff retries after acquiring a free app license so first-time older-version fetches no longer fail on transient `9610` delays.
  - Fixes multi-IPA batch import in **Packages** prematurely opening a detail sheet mid-batch, adding live `(done/total)` progress, batch completion toast, and a dismissible error banner.

#### Official Telegram Channel & GitHub Issues Archive
- **Official Telegram Channel**: [**https://t.me/ipadn_official**](https://t.me/ipadn_official) (new builds & source archives land here first).
- **GitHub Issues Read-Only**: Please post support questions, TestFlight diagnostics, and bug reports under the matching release post in our Telegram channel.

#### TestFlight Experimental Notice & Disclaimer
- TestFlight download and native installation in `v2.3.x` are **experimental** and depend on Apple server behavior, active per-account invitations, proxy/DNS setup, and device pairing state. Testing with a secondary Apple Account first is recommended, and never share pairing files, tokens, or unencrypted backups (see [README_EN — TestFlight Experimental](README_EN.md#testflight-experimental)).
- Released under [GPL-2.0-or-later](LICENSE) for authorized personal testing, backups, and research; unaffiliated with Apple Inc., with all account or data risks assumed by the user.

#### Packages
- `iPadn-2.3.5-unsigned.ipa`: Standard build with Live Activities & Widgets (requires 2 App IDs).
- `iPadn-2.3.5-lite-unsigned.ipa`: Lite build without extensions (requires 1 App ID; identical core features).
- AltStore / SideStore / Feather repo: `https://raw.githubusercontent.com/mengangs/ipadn/main/altstore-source.json`.

更早版本的更新内容见 [Releases](https://github.com/mengangs/ipadn/releases)。
