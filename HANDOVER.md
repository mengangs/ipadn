# iPadn 项目全面交接与问题排查文档 (HANDOVER.md)

> **更新时间**：2026-11-13（2.0.1 发布准备）
> **代码仓库**：`https://github.com/mengangs/ipadn.git` (`main` 分支)  
> **本地工作区**：`D:\iOS-Dev\projects\ipadn` (映射到 WSL2: `/mnt/d/iOS-Dev/projects/ipadn`)  
> **目标产品**：iOS 原生应用 `iPadn` (`app.local.iPadn`)

---

## 2026-11-13 iPadn 2.0.1（build 29，发布准备）

- 历史版本显示各自的远端完整 IPA 大小：复用 ZIP 范围读取取得的总长度，不下载整个 IPA，也不复用最新版商店大小；这不是解包大小或个性化处理后的最终文件大小。旧缓存兼容并在需要大小时刷新，取不到则显示「—」。Mac 元数据不要求 IPA 大小。
- 历史行分开显示版本/下载、日期/大小、版本 ID；无障碍大字体改为纵向。长按使用系统菜单复制版本号或版本 ID，未知版本不显示复制版本号。
- 下载卡片侧滑删除/分享，整张圆角卡片随内容移动；展开时临时关闭 UIKit 单元格祖先裁剪，收起恢复且不修改滚动视口。点外部收起而不触发底层控件；分享使用应用名和版本号。
- 删除撤销保留真实 5 秒期限，新增秒数/进度环；完成环转勾号/安装；重复点击当前标签返回顶部；任务长按保留系统菜单，不发布自定义浮层。
- 自动安装：只在开启自动安装且使用原生方式时直接串行安装，需配对与 LocalDevVPN；其他方式仍弹安装页。保留静音音频后台保活和应用自己的实时活动，不引入 BGContinuedProcessingTask。修复前台恢复将正在安装任务再次入队；待办偏好使用 LocalResources.defaults，防止预览清除正式待办。没有新增扩展，精简版仍不含实时活动/小组件。
- 搜索历史改为标签，设置可关闭发现。
- 已完成真机验证：历史多版本大小各不相同、缓存重开保留、普通/大字体布局、更新说明展开收起、原生长按菜单/外部关闭、旧版本 ID 复制后粘贴，以及双向卡片侧滑/恢复。没有下载或安装其他应用。涉及回环/LocalDevVPN 的安装端到端由用户自行测试，不能视为本次已验证。
- CI 修复：按 UDID 显式启动并等待测试模拟器就绪；撤销测试先点按钮再断言恢复，避免慢快照耗尽 5 秒窗口，不延长产品时限、不跳过失败测试。新增 ZIP 大小/旧缓存迁移、历史大小/长按粘贴/大字体回归。最终集成版完整 CI 尚待完成；通过后再合并、打 v2.0.1 标签发布标准/精简 IPA 与 SHA-256，发版后由工作流更新 AltStore 源。
- 版本来源：generate_project.py 的 MARKETING_VERSION=2.0.1 / CURRENT_PROJECT_VERSION=29，应用/扩展共享；本地不入库的 Config/xtool/*.plist 同步。README 中英版与 RELEASE_NOTES.md 已更新。

## 2026-11-12 iPadn 2.0.0（build 28）

用户确认以 2.0.0 发布（大版本更新）。包含下面第一、二、三批的全部内容，以及 #69、#70。发版流程：`release/2.0.0` 分支升版本（`generate_project.py` 的 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`）、写 `RELEASE_NOTES.md`、更新两份 README，完整 CI 通过后合并，推送 `v2.0.0` 标签触发发布（同时发布标准版和精简版 IPA，并更新 AltStore 源）。本地 `Config/xtool/*.plist` 的版本号要手动同步（不在 git 中）。

### 第一、二批
- **#42 一键全部更新**：下载页两个以上可更新时显示「全部更新」（`ToolStore.downloadAllUpdates`）。
- **#45**：关注的付费应用可设目标价（`WatchRecord.target`、`WatchService.notifies`，设置里可关）；「备份与维护」导出/导入设置与关注（`AppBackup`，不含账号、令牌、安装包）；设置首页改成分类入口（`SettingsView.Page`）；关闭「新版本提醒」后下载页也不显示更新提示；版本卡片改为紧凑一行。
- **#48 AltStore 源**：`altstore-source.json`（最近 10 个版本）由 `iPadn-iOS/scripts/generate_altstore_source.py` 生成，发版后自动更新并推送到 main；只取标准版安装包（名称不含 `-lite-`）。地址 `https://raw.githubusercontent.com/mengangs/ipadn/main/altstore-source.json`，尚未在真实签名工具中加载验证。
- **#49 支持 iOS / iPadOS 16**（来自 tageniu 的 #47）：主程序最低 16.0，iOS 17 写法用 `compatible…` 封装（`DesignSystem.swift`），扩展仍为 17。新代码不要直接用 iOS 17 才有的 API。本地 xtool 构建的 `Package.swift` 是 `.v17`，查不出 iOS 16 问题，要靠 CI。没有 iOS 16 真机测试。
- **#51 本机应用**（账号页）：借原生安装的配对列出已装应用，分组「可更新 / 链接安装 / App Store / 其他」，`InstalledAppsView`、Rust `iPadnNativeList`。需要 iOS 17.4+ 和配对文件。
- **#52 图标崩溃修复**：不再解析安装包里的 `Assets.car`（网易云音乐会让 `UIImage(named:in:)` 断言崩溃）；扫描图标期间崩溃过的任务不再重复扫描（`packageIconScansInProgress`）。
- **#53 下载页编辑模式**：紧凑列表、全选、抽屉式动画，两套列表常驻避免切换卡顿。

### 第三批（全部完成）
- **#55 安装包信息页**：任务详情 →「安装包信息」，权限（按含义合并）、扩展、语言、URL Scheme、后台模式、Watch / App Clip、框架（`PackageInfoService`、`PackageInfoView`）。
- **#56 用户评论**：详情页「评论」卡片 + 全部评论页（星级筛选、地区切换、最多 500 条），来源 `itunes.apple.com/{cc}/rss/customerreviews`（`ReviewService`、`ReviewViews.swift`）。
- **#57**：版本历史默认显示 5 个。
- **#58 翻译**：简介和更新说明在 iOS 17.4+ 显示「翻译」，系统翻译面板「替换为译文」后可「显示原文」（`TranslateButton`，用 NaturalLanguage 判断是否外语）。`Translation` 弱链接（`-weak_framework Translation`），iOS 16 与 17.0–17.3 不受影响。
- **#59 应用锁**：设置 →「应用锁」，面容 / 触控 ID / 密码，可选立即或 1/5/15 分钟后要求验证；锁屏是独立窗口，盖住所有弹窗，也遮住多任务预览；开关本身需要验证（`AppLock.swift`）。锁屏显示与桌面一致的图标样式和深浅。DEBUG 可用 `--visual-preview --lock` 截图。新增 `NSFaceIDUsageDescription`。
- **#60 仅 Wi‑Fi 下载 / 下载完成自动安装**（设置 → 下载，默认关）：只有蜂窝时下载回到队列，连上 Wi‑Fi 自动继续，下载页可「仍使用蜂窝数据下载」；自动安装在 iPadn 位于前台且已解锁时弹出安装页并开始安装（`AutoInstall.swift`）。自动安装未在真机完整测试。
- **#61 灵动岛 / 锁屏下载进度**：在原有扩展里新增 `DownloadLiveActivity`，不新增 App ID。后台时用 `ProgressView(timerInterval:)` 按测速估算，回前台校正；全部完成显示 10 分钟，暂停/删除立即结束（`DownloadActivity.swift`，设置可关）。DEBUG 可用 `--open-url=<链接>` 启动测试下载。
- **#62 快捷指令动作**：下载应用、检查更新、下载全部更新、下载进度、暂停/继续全部、关注应用；两个 Siri 短语。本地 xtool 构建不生成 App Intents 元数据，只能用 CI 构建的安装包测试；尚未真机测试。
- **#63 版本对比**（专业模式）：安装包信息页列出同一应用的其他已下载版本，对比版本、权限、扩展、框架、语言等增减（`PackageComparison`）。未真机测试（需要同一应用两个版本）。
- **#64 发现页**：搜索页最近搜索和关注下面的「发现」：免费榜、付费榜、畅销榜，按当前地区和平台，可按分类筛选（`ChartService`，来源 `itunes.apple.com/{cc}/rss/top…applications`）。
- **#65 Wi‑Fi 传输**（账号页）：同一 Wi‑Fi 下电脑浏览器下载已完成的安装包。只在页面打开时运行：切到后台用后台任务继续（实测约 10–30 秒），被系统暂停后回到前台用同一密钥和端口自动恢复（地址不变，端口被占时重试几次再换端口）；离开页面、点停止或闲置 10 分钟才停止、下次打开换新地址；地址含 128 位随机密钥，20 次错误请求停止；只应答局域网地址；只读（`WiFiTransferServer`）。本地网络权限说明已更新。
- **#66 桌面小组件 + 精简版**：扩展里加快捷入口小组件（小、中、锁屏圆形），通过 `ipadn://open?tab=…[&check=updates]` 打开，无 App Group、不读应用数据。发版同时发布 `iPadn-<版本>-lite-unsigned.ipa`（`scripts/make_lite_ipa.py` 去掉扩展，只需 1 个 App ID）；每次 CI 构建也会生成精简版。
- **#67 LiveContainer 提示**（来自 issue #44）：在 LiveContainer 中运行时，下载页提示在 LiveContainer 里长按 iPadn 打开「修复文件导入」（Fix File Picker），之后才能导入导出和弹出系统安装窗口。DEBUG 可用 `--livecontainer` 显示。
- **#69**：「下载完成后自动安装」此前从不弹出安装页——`.onReceive($pendingAutoInstalls)` 在 `@Published` 值写入前触发（willSet），读到的仍是空队列；改为 `AutoInstall.presentSoon` 下一轮主队列再取，并从 key window 弹出。真机验证：下载 OneDrive 26.1.3 后自动弹出并原生安装完成。另加：榜单页右上角地区菜单；版本对比在大小显示相同时隐藏大小行。
- **#70 流畅度与打磨**（issue #41）：选中的标签页原是 `ToolStore` 的 `@Published tab`，28 个视图观察 ToolStore，每次切换都让四个标签页全部失效重建；改为单独的 `TabState`（`store.tab` 仍可读写），只有 `RootView` 观察。iPhone 15 Pro 实测每次切换 CPU：搜索 0.45→0.24 s、已购 0.35→0.26 s、账号 0.31→0.24 s、下载 0.60→0.54 s。版本对比行显示版本 ID；近期新增英文文案统一为句首大写（sentence case）；VisualTests 改用 `drawHierarchy`（`layer.render` 截下载/已购/账号页是黑屏）。
- **#68 阻止 App Store 更新**（来自 issue #46，未用系统漏洞）：原生安装页开关，开启后通过安装器的 `iTunesMetadata` 选项传入改过的购买记录（`softwareVersionExternalIdentifier` = 2000000000），安装包本身不改；关掉再装一次即可恢复更新。本机应用页标记「已阻止更新」。真机验证：版本号改旧 → App Store 显示「更新」，改高 → 显示「打开」，应用正常启动；用户在 iPadn 里实测有效。

### 2026-11-12 真机测试与性能测量（iPhone 15 Pro，iOS 27）
- 全部新功能已在真机走过一遍：发现与榜单地区切换、评论、简介翻译、版本默认 5 个、自动安装、版本对比、Wi‑Fi 传输（电脑下载、访问记录、离开页面即停止）、编辑模式、本机应用、灵动岛进度、安装包信息、LiveContainer 提示；小组件和阻止更新由用户实测。快捷指令和 AltStore 源按用户要求暂不测。未测：仅 Wi‑Fi 下载（无法切到蜂窝）、更新说明翻译（测试应用无更新说明）。
- 性能：空闲 0% CPU、不重绘，内存约 112 MB；榜单（100 行）、本机应用（163 行）、详情页滚动都在测量工具的 60 FPS 上限（系统设置 App 也是 60）。行的侧滑用 UIKit 手势，不受 iOS 18 `DragGesture` 滚动问题影响。测量脚本：`.build/native-pair/perf*.py`（`dvt sysmon` 读 CPU、`dvt graphics` 读 FPS；测量时手机不能被人使用，否则数据和点按都会乱）。

### Issues
- #44、#46 已回复并关闭。#41（iOS 18 卡顿）已回复，请对方提供机型、卡顿页面和录屏，仍开着。#54（iPhone duo 适配）未处理，含义不明，需要先问清楚。
- LiveContainer + 美区账号下载 401：仍在等用户的诊断信息。

### 已结案：原生安装后 WQFiles / AppsManager 无法备份数据（2026-11-12 用户转述）
- **结论（报告者最终确认）：与 iPadn 无关。** 原生安装的应用经 App Store 更新后也能正常备份，只有 HashPhotos 一个应用不行；它即使彻底删除、重启后从 App Store 安装，不打开时能备份，打开一次后就不行。原因是 WQFiles 无法备份 0 KB 文件：HashPhotos 运行时会生成 0 KB 文件，同一文件夹下其他文件都能备份，删除这些 0 KB 文件后整个应用数据就能备份。AppsManager 另有自身问题（App Store 安装的应用也会路径错误、备份只有几 KB）。
- 原生安装每次换数据容器 UUID 是系统行为，数据会迁移，不影响备份，无需处理。下面是排查过程记录。
- 现象：用 iPadn 原生安装的应用，WQFiles 无法备份，AppsManager-iOS27（基于 Apps Manager 1.8.4 的修改版）看不到它的数据大小；App Store 安装的可以。卸载（保留数据）后从 App Store 重新安装，仍然不行。报告者的 iPadn、WQFiles、AppsManager 都装在 LiveContainer 里；iOS 27.0.1。诊断日志没有相关信息。
- 已查（2026-11-12，本机 iPhone，用电脑上的 installation_proxy 装 OneDrive 26.1.4 测试后已删除）：
  - 所有用户应用（163 个）`IsHostBackupEligible` 都是 True，原生安装的也是，签名、购买记录与 App Store 安装一致。
  - **每次 installation_proxy 安装或覆盖，应用都会换一个新的数据容器 UUID**（5852E224 → A23AE3F5 → 2F88D91A → 6F845DD3），系统记录（`Container`、`HOME`）始终指向新目录，数据会迁移。
  - App Store 安装的应用有 `ParallelPlaceholderPath = True`，installation_proxy 安装的没有。
  - 未能确认 App Store 更新是否也会换数据目录（App Store 缓存了更新状态，没能触发更新）。
- 初步怀疑：这些工具在 iOS 27 上借漏洞直接扫描数据目录，可能找到旧的空目录或同一应用的多个目录；「卸载保留数据」会保留同一个目录，所以从 App Store 重装也不变。尚未证实。
- 已请报告者提供：AppsManager 里该应用显示的数据路径截图；一个之前没装过、直接原生安装的应用能否备份；把出问题的应用彻底删除（不是保留数据卸载）后从 App Store 安装能否恢复。
- 可能方向：确认 App Store 更新是否保留容器路径；看安装选项能否保留原容器或带上与 App Store 相同的标记。
- **报告者回复（2026-11-12）**：①之前原生安装过、彻底删除后从 App Store 安装：WQFiles、WQManager 能备份，AppsManager 不能（路径和 WQFiles 不同、提示路径打不开，重装 AppsManager 也一样）；②手机上没装过、直接原生安装：WQFiles、WQManager 正常，AppsManager 能看到数据大小和目录，但备份只有几 KB。
- 结论：AppsManager 自身有问题（App Store 安装的也不行），与 iPadn 无关；WQFiles 只在「原生安装覆盖已有应用」时失败，与覆盖安装换新数据目录一致。已请对方试：覆盖安装后重启手机再用 WQFiles 备份——能恢复说明是 WQFiles 缓存旧路径，否则是旧目录残留，需要继续找保留容器的办法。临时办法：彻底删除后再装（会清空数据）。

- **决定不做**：分享扩展（多占 App ID、LiveContainer 不支持、跳转不可靠）；带实时数据的小组件（需要 App Group，签名工具支持不一）。
- **CI 偶发失败**：`testLargeDownloadListsLaunchAndScroll`、`testSignerCancelResumesPendingJavaScript`、`testHistoryDeletionCanBeUndone`、模拟器 "Failed to terminate" / "Failed to get background assertion"、构建时从 GitHub 克隆依赖失败、macOS 运行机排不上队，重跑即可。
- **本地工具**：`.build/native-pair/` 下有 `update_branch.sh`（合并 main 并自动解决字符串目录和测试冲突）、`union_catalog.py`、`resolve_tests.py`、`resolve_both.py`、`set_version_id.py`、`probe_*.py`。Bash heredoc 会吃掉反斜杠，编辑脚本用文件写。

## 2026-11-11 iPadn 1.9.2（build 27）

- **已发布**：2026-11-11 19:19（UTC+8）[iPadn v1.9.2](https://github.com/mengangs/ipadn/releases/tag/v1.9.2)，Latest，标签指向 `c03e2f2f`（PR #39、#40 合并；内容与 CI run 43005857736 测试的提交 `1ec2decd` 完全相同）。IPA SHA-256 `b9b183b3eeb61dde6f4b901e7d381c4e3021a02bf6b1f84300e007721c95e3d9`，与校验文件、build-info 一致；发布正文以 `RELEASE_NOTES.md` 开头逐字一致；136 项单元测试 + 11 项 UI 测试通过。正式包已装到 iPhone 15 Pro，版本 1.9.2（27）。
- **内容**：#36 后台下载文件无读取权限时自动改用应用内下载（`DownloadManager.isPermissionError`、`fallBackToForeground`）；更新后图标主题显示（`AppIconService.rememberedAlternate`）；「设置 › 支持 iPadn」（`SupportView.swift`，爱发电 + USDT BEP20 `0x5f0cff7587b9fc305f9fa626135789bd5100818e`，地址已与用户币安截图逐字及二维码核对）；诊断信息记录最近失败请求（`RequestFailureLog`，仅元数据）、「复制诊断信息」、401 提示重新登录。
- **README**：支持区（徽章、USDT 二维码 `docs/images/usdt-bep20.png`、`.github/FUNDING.yml`）；去掉 Stars 徽章和趋势图；补充 iOS 27 以下配对为何需要电脑。GitHub 仓库简介已中英双语。
- **issue**：#33 已回复并关闭（邀请校对翻译）；#36 已回复修复并关闭。
- **待办**：LiveContainer + 美区账号下载 401，等用户用 1.9.2 的「复制诊断信息」反馈后定位。iOS 16 已通过 #49 支持；iOS 15 不做。

## 2026-11-11 iPadn 1.9.1（build 26）多语言版本

用户已授权：第二批语言加阿拉伯语、真机测试、合并 PR、发布 1.9.1、更新 README 截图与 GitHub 简介。本节为最新状态。

- **已发布**：2026-11-11 15:01（UTC+8）[iPadn v1.9.1](https://github.com/mengangs/ipadn/releases/tag/v1.9.1)，Latest，非草稿/预发布，标签指向合并提交 `84a0110a`（PR #37 合并进 `main`，PR #35 随之显示为已合并）。IPA SHA-256 `1813195b0415916be4959da0e189b63b652b672c4b297b2b986fc29f17de582b`，与校验文件、附件 digest、build-info（commit `84a0110a`、run 42974832480）一致；发布正文以 `RELEASE_NOTES.md` 开头逐字一致，无乱码。安装包内 App 与实时活动扩展均含 11 个 lproj。
- **测试**：完整 CI run 42972128807（提交 `26e8b90`）通过，单元测试 134 项、UI 测试 11 项，0 失败；之后只换了 README 截图。偶发失败 `testSignerCancelResumesPendingJavaScript`（WebKit 超时，与改动无关）出现过一次。正式安装包已在 iPhone 15 Pro（iOS 27.0.1）安装并启动，版本 1.9.1（26）。
- **语言**：zh-Hans（源）、en（#35，kylefmohr）、zh-Hant、ja、ko、ru、es、fr、de、pt-BR、ar（从右到左）。除英文外为机器辅助翻译。本地辅助脚本在 `.build/native-pair/`（`build_catalogs2.py`、`t2_*.json`）。`verify_project.py` 要求 11 种语言且占位符一致。
- **真机发现并修复**：阿拉伯语下左右滑动方向（`RevealInteraction` 按布局方向换算触点）；「免费」按地区取文案导致简体界面显示繁体「免費」、详情页显示英文「Free」（改按界面语言，`AppText` 按语言+文字匹配语言包，价格为 0 即视为免费）；内购名称优先读语言本国商店（`InAppPriceService.nameRegions`）；搜索结果分类单独一行；已购下载按钮改为云朵图标；安装方式分段改用短名称；安装设置结果改为顶部小提示，安装弹窗内也能显示；配对引导步骤此前未翻译。
- **README**：中英文各 8 张真机截图（`docs/images/{zh,en}/`），由 `.build/native-pair/compose_shots.py` 合成；账号页用演示数据，详情页邮箱与头像已替换。调试启动参数 `--visual-preview` 使用公开应用（Netflix、Spotify、Notion、Disney+），`--installation` 直接打开安装设置（不在主界面内，看不到顶部提示）。
- **GitHub**：仓库简介改为中英双语，添加 9 个主题标签，主页指向最新发布。
- **待用户决定**：是否回复 issue #33 邀请提问者校对翻译（公开回复需用户同意）。

## 2026-11-11 iPadn 1.9.0（build 25）汇总

用户已授权：审查后提交、CI 编译测试通过后发布 1.9.0。本节为最新状态，下方原生安装小节为过程记录。

- **已发布**：2026-11-11 08:17（UTC+8）[iPadn v1.9.0](https://github.com/mengangs/ipadn/releases/tag/v1.9.0)，build 25，Latest，非草稿/预发布，标签指向 `7b6b8dae`（`main` 已快进到同一提交）。IPA SHA-256 `432e787aee12612fa1c8212fbd39813c920ed22c3e75f93530f5ef9b5c3e7184`，附件 digest、校验文件与 build-info 已核对一致；发布正文与 `RELEASE_NOTES.md` 逐字一致（CI 末尾追加验证行），无问号乱码。
- **验证范围**：同一提交的分支完整运行 [42925501376](https://github.com/mengangs/ipadn/actions/runs/42925501376)：Release 编译、IPA 校验（Mac PKG 与原生安装均已链接、扩展已嵌入）、143 项测试（含全部 UI）通过、0 失败。标签运行 [42928442473](https://github.com/mengangs/ipadn/actions/runs/42928442473) 重新编译并跑 132 项单元测试后发布。离线探针工作流 Ubuntu/Windows 通过。CI 包已在真机（iOS 27.0.1）签名安装并正常启动，数据保留。

- 原生安装（详见下节）；iOS 27 起本机配对：`OnDevicePairing.swift` + Rust `pairing.rs`（idevice `PairableHost`），Swift 用 `NetService` 广播 `_remotepairing-pairable-host._tcp`。配对期间以静音音频（mixWithOthers，`UIBackgroundModes` 增加 `audio`）保持后台，仅配对时启用；实时活动扩展 `iPadnLiveActivity` 显示步骤与配对码，图标为内嵌的应用图标。真机（iOS 27.0.1）本机配对、导入、检查连接、OneDrive 原生安装与覆盖均由用户确认通过。
- 验证码：Apple 只在「密码登录且不带验证码」时推送验证码。`ExistingAccountVerificationView` 打开时先调用 `requestVerificationCode` 触发推送；Apple 直接放行则自动继续；60 秒内再次放行仍被要求验证时停止自动继续、改为提示手动获取验证码，避免循环。新增重新发送；`ToolStore.requestVerification` 供下载列表、已购批量、Mac 包统一弹出验证。真机未遇到 Apple 要求验证的场景，未实测。
- 会话 Cookie：store 响应的 Set-Cookie 按名合并（`AppleService.mergedCookie`），内存中立即生效，钥匙串最多每分钟写一次，退到后台时保存。目的是减少反复要求验证，效果未实测。
- 下载：#34（100% 后重下）根因为 #32 的 -3000 兜底每个任务都先走后台下载；现首次启动用 Apple `success.html`（68 字节）探测后台下载，失败即记住（按版本+安装路径），之后直接应用内下载。真机探测成功路径已在 nsurlsessiond 日志中确认；失败路径未复现。
- 签名组件：轮询改为队列，`SAPSigner.userInitiated`（TaskLocal）标记的用户操作优先；空闲保留 90 秒改为 5 分钟；详情页打开时预热。新增排队顺序单元测试（CI 运行）。
- 版本来源：默认新增 iosdump（`{appId}`，与 `{id}` 均支持），老用户列表仅补一次（`versionSourcesSchema`）；设置中「检测全部来源」用微信（414478124）探测。
- 界面：暂停任务详情显示实时已下载与总大小；账号行分隔线（inset 68）；开发者应用横排按卡片圆角裁剪。
- 未处理：issue #33 英文本地化。

## 2026-11-11 原生安装（过程记录）

用户报告三个问题：iPadn 手机内安装的应用 App Store 显示云朵且不能更新；爱思显示“共享正版”；不能覆盖 App Store 已装版本。三者同一根因，已在真机（iPhone 15 Pro，iOS 27.0.1）取证：

- 清单安装（`itms-services`）后系统记录只剩带 `enterpriseInstallURL` 的精简元数据，没有 `itemId`、`softwareVersionExternalIdentifier` 和账号购买信息。
- 清单安装覆盖商店应用时，`appstored` 在下载前拒绝：`ASDErrorDomain 855 "Must uninstall existing app"`。清单字段无法绕过。
- 同一个 IPA 走 `installation_proxy`（Install / Upgrade）保留完整记录，App Store 显示 Open，覆盖升级不要求卸载，数据保留。只传 `CFBundleIdentifier` 即可，系统自己读取包内的 `iTunesMetadata.plist` 和 SINF。

已实现（用户已确认方案）：

- `iPadn-iOS/NativeInstall/`：Rust 封装库，依赖 `idevice` 0.1.68（纯 Rust 加密后端），导出 `iPadnNativeInstall` / `Lookup` / `Cancel` / `Free`。流程为远程配对校验、TLS-PSK 隧道、RSD、AFC 分块上传、Install 或 Upgrade。只校验配对，不会发起新的配对。
- `iPadn/Services/NativeInstaller.swift`：`dlsym` 解析符号（与 Mac PKG 组件同一模式），配对文件保存在 Application Support，Bonjour 发现 `_remotepairing._tcp` 端口，默认 49152，设备地址 `10.7.0.1`。
- 安装设置新增「原生安装」，默认关闭；安装页显示连接、传输、系统安装三段进度。没有链接该库的构建不显示这个选项。
- 构建：`scripts/build_native_install.sh`、`build_unsigned_ipa.sh`（`IPADN_NATIVE_LDFLAGS`，`IPADN_REQUIRE_NATIVE=1`）、`verify_ipa.py`、CI 增加 Rust 步骤。本地 xtool 在根目录 `Package.swift` 用绝对路径 `-force_load`。
- 测试：`iPadnTests/NativeInstallerTests.swift`（5 项，尚未在 CI 运行）。

验证状态：

- 通过：电脑端探针全新安装、3 次覆盖升级；经 iOS 17+ 隧道的升级；Rust 库在电脑上经 Wi-Fi 用远程配对文件完成查询和覆盖升级（270 MB 约 45 秒）；应用链接该库后真机可启动，原生安装设置页显示正常。
- 通过（2026-11-11 00:40 前后，用户在真机操作）：自动导入配对文件、LocalDevVPN 下「检查连接」、OneDrive 原生安装与再次覆盖安装，均无报错；App Store 显示已安装。电脑端回读记录：`itemId` 477537958、`softwareVersionExternalIdentifier` 894270367、购买信息存在、无 `enterpriseInstallURL`。
- 文件选择器在 iPadn 自己的「文件」目录中点选无反应，原因未查明；已改为优先自动读取 iPadn 文件夹中的配对文件，选择器作为后备并放宽文件类型。
- **未验证**：对清单安装的应用（如 `com.bilibili.inter`）做原生覆盖能否修复记录；爱思中的分类显示；有新版本时 App Store 的实际更新；CI 的 Xcode 构建与新增单元测试。
- 已知限制：LocalDevVPN 与其他代理或 VPN 不能同时开启；配对文件需在电脑上生成（`idevice_pair`，或本机临时工具 `.build/native-pair/native-pair.exe`）。

真机当前状态：装的是本地 xtool 调试构建（非 CI 正式包，不含 Mac PKG 组件）；OneDrive 26.1.4 为测试应用；配对文件已在应用内导入（Application Support），「文件」目录中的副本导入后被删除；原生安装已选为当前安装方式。测试机是用户日常手机，可能正在使用，操作屏幕前先确认前台应用。

## 2026-11-10 本地修复与验证进度（优先于下文的原始待办）

本轮用户已批准 UI/UX、流畅性和稳定性优化，以及提交推送与 CI 验证。随后用户发来 X / Swiftgram 与新版对比截图，明确连接真机并授权调试；以最新授权为准。禁止安装支付宝。

### 当前任务与发布授权（优先于后面的历史记录）

- **已完成发布**：2026-11-10 20:52（UTC+8）发布 [iPadn v1.8.5](https://github.com/mengangs/ipadn/releases/tag/v1.8.5)，build 24，正式 Latest，非草稿/预发布。标签指向已验证源码 `56b38bb42b5d28346805ca7a38e450b350d72395`。IPA SHA-256 为 `cdabe980bd592ecbab1af8d65ba4e343efab4ccd35bf06c2384e2a99102ba81b`；GitHub 附件服务端 digest、下载的校验文件与构建信息均已核对一致。
- **发布文案编码已修正**：用户指出末尾验证说明和链接文字变成问号。原因是 Windows PowerShell 默认 ASCII 管道损坏了追加的中文；已用 UTF-8 文件修正远端正文，并从 GitHub API 回读与原文逐字核对通过。IPA 附件 ID、大小和 SHA-256 均未改变。后续发布须同时校验文案，流程已补充到 `BUILDING.md`。
- **最终验证范围**：[42816175788](https://github.com/mengangs/ipadn/actions/runs/42816175788) 全部通过：Release 编译/IPA 校验、122 项单元、2 项提示/最大字号/撤销 UI，124 通过、0 失败、0 跳过。其余 9 项 UI 已在上轮完整运行通过，最后仅调整提示 interaction/accessibility shape；不声称最新提交重新跑过全部 11 项 UI。未追加截图对比。
- **最终真机状态**：已签名安装同一云端完整 Release 包（含 Mac PKG 处理组件）并正常启动，未留在预览/大字号模式；真实记录保留，未安装支付宝。短时应用日志检查未见应用错误。普通提示顶部留白点按关闭、原生确认取消、最大辅助字号文字与按钮可达均已验证。
- 用户先要求暂不发布，之后最新明确授权：**测试通过后可以发布新版**。完成当前验证与最终检查后可直接发布 1.8.5（build 24），无需再次确认；不能绕过失败测试。
- 顶部提示恢复紧凑布局；用户看到贴底的小确认窗口后，明确要求删除提示用回原来的样式：删除/移除确认与下载操作菜单恢复原生底部 sheet，不再采用独立窄悬浮卡片。普通字号确认框保持 1.8.0 的尺寸、间距和按钮；辅助字号允许滚动，确保长文案和按钮可达。
- 旧运行 `42782145978`、窄卡片方案运行 `42791902264` 已取消，未创建 1.8.5 Release。验证 `42793328713`（`7b1da63`）的 Release 编译与 122 项单元测试通过，11 项 UI 中 9 项通过、2 项失败，不能发布该包。
- 失败原因已从已有无障碍层级定位：提示容器上的 `notice.banner` 会覆盖内部撤销按钮标识，现将该标识仅放在普通提示按钮上；最大字号页面打开确认 sheet 后字体环境被系统重置，现显式传递 `dynamicTypeSize`，保留最大字号滚动与按钮可达断言。修复后的最终相关回归已通过，发布结果见本节顶部。
- 修复运行 `42812063480`（`f304a2c`）：122 项单元及 10 项 UI 通过，撤销与最大字号均已修复；唯一失败是普通提示的 AX frame 只包含 18pt 文字区域。已根据 Apple `ContentShapeKinds` 文档将提示和撤销按钮的 interaction/accessibility shape 显式覆盖完整点击区域，保留 44pt 断言并新增边缘点击关闭验证。
- 针对最后这处提示区域修复，CI 新增可选 `ui_test_scope=notices`，保留全部测试，默认仍为 full；本轮只复跑全部单元与受影响的提示/最大字号/撤销两项 UI，不重复其余已通过 UI。自动发布仅接受 full；本次按完整回归与后续针对性验证的结果单独核验发布。
- 最后热区补丁 `56b38bb` 的验证运行 `42816175788` 已通过并发布同一产物。WSL 编译通过；真机保持显示的演示提示在点击文字外侧顶部留白后立即关闭，辅助最大字号确认的文字、确认和取消按钮已检查完整可达。最终包来自该运行，未使用 `7b1da63` / `f304a2c` 的旧候选包。
- 用户后续要求不追加测试截图，界面效果以真机为准；保留已经运行的功能回归，结果通过后直接发布，不再开新一轮截图对比。
- 原生确认框已在云端正式包真机验证：双向侧滑保留原色，打开系统底部确认框后取消，OneDrive 任务和文件仍在。真机证据为 `.build/device-final-{release-reveal,native-confirmation,after-cancel}.png`；先前窄卡片截图不能用作最终效果。后续两个辅助功能补丁仍待最终验证。
- 与 `v1.8.0` 源码对比：顶部单行提示恢复 18pt 横向/11pt 纵向内边距与 0.2 秒动画，并保留至少 44pt 点击高度；撤销提示去掉此前在 44pt 按钮外额外增加的 22pt 高度。普通字号确认框恢复原来的 320pt detent、24pt 内边距、20pt 内容间距、52pt 主按钮和至少 48pt 取消按钮；确认框大字号仍使用原生 large sheet，并增加内容滚动。系统输入表单/文件选择器仍使用原生布局。
- 侧滑改为每个显示刷新最多提交一次完整状态，跳过未变化帧；缓存 UIKit 宿主查找结果，减少一层移动卡片裁剪。相同真机、1 秒相同 HID 横滑、相同高刷配置下，两组单次采样的状态提交数从 268/266 降为 223/222（约 17%）；对应显示回调间隔约 8.33ms。该指标不是 GPU 呈现 FPS，也不保证所有场景零卡顿。调试包原先缺少高刷开关的问题已在本地配置/后处理工具中补齐；生产配置此前已有该开关。

### 本次真机复查（以下含历史进度）

- 历史版本安排：**1.8.5（build 24）**；`1.8.1` 未正式发布，本轮变更一并进入 1.8.5；以本页上方最新授权和验证结果为准。
- 发布检查 `42778941839`：Release 编译、IPA 校验、122 项单元测试及 9 项 UI 用例通过；新增关注跳转用例错误等待仅登录后出现的 `detail.get`，导致 1 项 UI 失败，Release 未发布。已改用所有登录状态均存在的 `app.copy-id` 验证详情页，保留滑动不跳转与点按跳转断言。手机已安装该轮 1.8.5 完整包，侧滑颜色、账号分组三态与正常启动已真机验证；后续只有测试定位修正，无应用代码变化。最终发布重跑结果待补充。

- 后续用户要求侧滑时不要变灰，账号行只在拖动时变圆。已将临时禁用与按钮标签外观分开，真实业务禁用仍弱化；关注及版本来源改用状态驱动导航，避免系统额外禁用样式。真机历史、账号、暂停/完成任务、关注、来源行均保持原色，收起后可正常点击/跳转。
- 账号静止时与原生“添加账号”行连接成连续分组，当前拖动行通过 Telegram 模型的 surface 弹簧变圆，收回恢复分组。真机三态截图在 `.build/device-account-group-{rest,open,closed}.png`。
- 补齐磁盘容量显示 `85F4.1` 与应用事件计时 `35F9.1` 的 API 用途声明，同步工程生成脚本。独立运行 `42776071924` 编译与 122 项单元测试通过；真机存储页可显示设备可用容量。未把一条系统 sandbox 日志直接归因为声明缺失。
- 侧滑颜色补丁运行 `42774325012` 编译成功，但新增 UI 用例把关注演示应用误写为下载任务的 `preview-1`；已改为实际 `preview-app`，保留导航、侧滑与收起断言。账号分组新补丁的最终完整 CI 待补充。

- 已推送 `5eb90ec`、`d1fa9aa`、`ec30459`、`da7a8ff`。最终云端 [42769519514](https://github.com/mengangs/ipadn/actions/runs/42769519514) 全部通过：Release IPA 编译上传、122 项单元测试、10 项 UI 测试，0 失败。Mac 包队列先清理当前任务再恢复 continuation 的修复通过原用例连续 20 次检查。前一轮 `42763446095` 的队列状态失败已解决。
- 真机确认原生侧滑样式不符合参考图，已重做为整张圆角卡片平移；历史记录为红色胶囊文字，其他列表为圆形图标加下方标题。原生手势参考固定 Telegram 提交，补充来源声明；拦截横滑结束误触，支持点开卡片收起、纵向滚动让行。
- 真机验证完成：历史胶囊删除及撤销、下载圆形动作、展开卡片点按收起、双向滑动、深色与 accessibility2 大字体账号卡片、移除确认框、1000 条演示任务实际滚动及复用行侧滑、纵向滚动收起。调试使用 `--visual-preview` 独立存储，未删除真实账号与下载、未安装其他应用。
- 已签名安装云端 `42769519514` / `da7a8ff` 的完整 Release IPA（包含 Mac 包处理组件），并恢复正常启动。原有 3 条搜索历史及 1 条 OneDrive 下载记录保留。正式包左右滑动均为红色动作，玻璃胶囊 TabBar 正常。截图在忽略目录 `.build/device-release-*.png`；采样 syslog 未发现应用异常。
- 设备 FPS 工具输出是全局逐秒采样且含空闲 0 值，不能作为应用 120 FPS 或加载提速百分比的证据。未做这类性能承诺。
- xtool IPA 必须先执行 `scripts/xtool_postbuild.py` 再签名安装：原始 Mach-O SDK 标记 17 会触发旧 UI 兼容模式，修正为 SDK 26 后保留最低 iOS 17，真机玻璃胶囊 TabBar 恢复。云端 Xcode 构建无此问题。

- 新增 `RevealMotion.swift`（固定 Telegram 提交，详见第三方说明）及 SwiftUI 侧滑宿主，覆盖下载、账号、历史、关注、存储和版本来源；新增撤销通知与减少动态效果适配。
- 下载回调使用任务对象身份、接收文件使用 UUID 隔离；进度使用独立行级 publisher；批量删除在串行后台队列提交，失败回滚，启动恢复未提交移除的文件。
- 启动缓存异步加载，关注及账号记录后台串行保存；搜索同查询同地区刷新保留结果；图标及截图请求合并，后台解码。
- 本地 WSL 6 项真实 Swift/XCTest 侧滑模型测试通过；应用已编译。新增跨 Session 竞争、进度隔离、批量删除失败/成功用例，以及 UI 撤销和 100/500/1000 条记录检查。云端结果后续补充。

- 已修复 `PackageService` 静默覆盖目标 IPA 的回归，保留原有文件并抛出冲突错误。
- 多组件 SINF 保持服务器原顺序，严格匹配 `SinfPaths` 数量与安全相对路径，不再按不透明 ID 排序或缺失时复制主 SINF。辅助签名文件保持不变。
- Manifest 和安装代理使用应用真实版本号；没有发现 Apple 官方支持用 Manifest 扩展字段改变 OTA 安装来源分类的机制。
- 2026-11-09 真机改用原先未安装的 OneDrive，完成多组件下载、打包、OTA 安装及启动验证。未安装支付宝。OneDrive 测试应用、任务和 IPA 已清理。
- GitHub 最新失败运行 `42583066116` 的设备 IPA 编译和上传成功；失败来自包覆盖测试、签名取消测试卡死、签名超时错误被通用提示掩盖。该次 8 项 UI 交互测试全部通过。
- 已修复签名复用失败时持有 operationID 递归重试的死锁：退出当前 attempt 并完成释放后再重试；取消和超时保留原始终止错误。新增冷启动恢复和复用超时回归用例。SINF 纯解析辅助方法标记为 `nonisolated`，避免同步测试触发 MainActor 编译错误。
- 下载、账号、搜索历史、存储和版本来源的双向侧滑删除显式使用红色；公共主按钮样式按 destructive 角色显示红底白字。TabBar 毛玻璃配置保留。
- CI 日常运行完整 `iPadnTests`；手动勾选 `run_tests` 与 `run_ui_tests` 可额外运行 `iPadnUITests`，不删除旧测试。
- 已对照 `v1.8.0`：Apple 登录解析、更新订阅备用源、图标、已购归档等相关文件没有变化；保留版本、外观迁移、已下载更新包等旧测试仍在。这里只能确认源码保留，不能代替修复后云端 XCTest 的通过结果。
- WSL Swift 编译和 IPA 打包、项目静态校验、离线运行组件 smoke test 已通过。最终 CI 与真机结果见上方复查记录；未发布新 Release。

---

## 一、重大实测验证结论（核心突破点）

**用户实测事实**：
> 将 iPadn 下载生成的 `.ipa` 导出到电脑，通过电脑端爱思助手（USB 数据线）安装到 iPhone 上：
> 1. 爱思助手中**完全正常显示为【苹果正版】**，且**完整显示个人 Apple ID**！
> 2. iPhone 系统【设置】->【iPhone 储存空间】中**完全正常显示【卸载 App】（Offload App）**！

### 该事实证明的关键结论：
1. **IPA 打包与元数据注入完全正确**：
   我们在 `AppleService.swift` 和 `PackageService.swift` 中构造并写入的 `iTunesMetadata.plist`（包含 `com.apple.iTunesStore.downloadInfo`、`AppleID`、`DSPersonID`、`itemId`）以及 SINF 结构是 **100% 正确且受 iOS 系统认可的**。
2. **问题出在【应用内安装方式】（OTA `itms-services://`）**：
   * **爱思助手安装**：走的是 USB `installation_proxy`，系统 `installd` 直接解包 IPA 根目录下的 `iTunesMetadata.plist`，保留了全部正版 App Store 标识（无 `enterpriseInstallURL`）。
   * **iPadn 手机内一键安装**：走的是 iOS 原生 OTA 协议（`itms-services://?action=download-manifest`）。iOS 底层 `installd` 会将 OTA 安装归类为企业/外部清单分发，自动生成一个带有 `enterpriseInstallURL` 的简略元数据，覆盖了安装包原有的 `iTunesMetadata.plist`，从而导致系统隐藏了“卸载 App”，爱思助手也因此将其归为“共享正版”。

---

## 二、当前待 Codex 解决的完整问题清单

### 🔴 任务 1：研究优化应用内安装（`itms-services://` 清单），尝试保留“苹果正版”与“卸载 App”
* **现状**：[`iPadn-iOS/iPadn/Services/InstallationService.swift`](iPadn-iOS/iPadn/Services/InstallationService.swift) 的 `ManifestBuilder.manifest` 目前仅写入了：
  ```swift
  "metadata": [
      "bundle-identifier": app.bundleID,
      "bundle-version": overwriteVersion,
      "kind": "software",
      "title": app.name
  ]
  ```
  版本号被写成了 `99999.时间戳`。
* **排查与尝试方向**：
  1. 研究 iOS `itms-services` manifest plist 规范：能否在 manifest 的 `metadata` 中传入 `item-id`、真实的 `bundle-version`、`store-cohort` 或 `downloadInfo`？
  2. 观察 `installd` 在 OTA 安装时是否支持把原包的 `iTunesMetadata.plist` 合并保留，还是由于某些特定字段触发了企业覆盖；
  3. 若 OTA 协议本身由 iOS 系统强制注入 `enterpriseInstallURL`，评估是否有其他免越狱设备端安装机制（例如本地回环代理模拟），或给出确切机制结论。

---

### 🔴 任务 2：多组件应用（如支付宝）安装完整性校验失败（桌面白图标）
* **现状**：
  * 单二进制应用（如 B站、瑞幸咖啡）已完全正常，不仅能正常安装打开，且 App Store 均已能识别并显示官方【更新】按钮。
  * 但包含大量 Extensions/WatchKit/Frameworks 的复杂多组件应用（如支付宝），安装后仍出现桌面白图标，提示“无法安装，无法验证其完整性”。
* **排查方向**：
  * 检查 [`iPadn-iOS/iPadn/Services/PackageService.swift`](iPadn-iOS/iPadn/Services/PackageService.swift) 中的 SINF 分发逻辑：
    1. 苹果接口返回的 `song["sinfs"]` 数组包含多个授权块（按 `id` 排序）。
    2. 查看支付宝 IPA 解包后 `Payload/alipay.app/SC_Info/Manifest.plist` 中的 `SinfPaths`，确认各个路径（如 AppExtensions、Frameworks）是否都得到了正确的 SINF 覆盖。
    3. 检查是否有特定的扩展或二进制未包含在 `Manifest.plist` 中，或者路径前缀处理（如斜杠、大小写）导致漏写。
    4. 确保 `.supp` 辅助签名文件和 `CodeResources` 完整性未被破坏。

---

### 🔴 任务 3：修复 CI 构建中的单元测试报错 (`CoreTests.swift`)
* **现状**：GitHub Actions 构建（#285，ID: `42575546155`）在单元测试步骤报错：
  ```text
  /Users/runner/work/ipadn/ipadn/iPadn-iOS/iPadnTests/CoreTests.swift:37: error: 
  -[iPadnTests.CoreTests testPackageCompletionCannotOverwriteSharedIdentifierPrefixAndHandlesLongNames] : 
  XCTAssertThrowsError failed: did not throw an error
  ```
* **精准定位与修复**：
  在 [`iPadn-iOS/iPadn/Services/PackageService.swift`](iPadn-iOS/iPadn/Services/PackageService.swift) 第 164~166 行：
  ```swift
  // 原有代码添加了主动删除逻辑，破坏了“目标文件已存在时禁止覆盖并抛出异常”的规范：
  if FileManager.default.fileExists(atPath: destination.path) {
      try? FileManager.default.removeItem(at: destination)
  }
  ```
  **修复方案**：删掉主动 `removeItem`，恢复使用原版的 `try FileManager.default.moveItem(at: working, to: destination)`，使其在冲突时正常抛错，即可通过该单元测试。

---

### 🔴 任务 4：CI 流程中模拟器 UI 自动化测试不稳定
* **现状**：`.github/workflows/ios-build.yml` 中 `xcodebuild test` 会同时执行单元测试（`iPadnTests`）与界面自动化测试（`iPadnUITests`）。GitHub macOS 云端虚拟机无 GPU 加速，UI 测试耗时近 18 分钟且易卡顿超时。
* **修复建议**：可在 CI 脚本中通过 `-only-testing:iPadnTests` 仅执行单元测试，保证 CI 快速绿灯并产出 IPA；将耗时的 UI 测试设为可选或手动触发。

---

### 🔴 任务 5：UI / UX 细节核验（TabBar 毛玻璃与侧滑删除）
* **现状**：
  * 在 [`SharedViews.swift`](iPadn-iOS/iPadn/Views/SharedViews.swift) 中已为 `TabView` 添加了 `.toolbarBackground(.visible, for: .tabBar)` 与 `.toolbarBackground(.ultraThinMaterial, for: .tabBar)`。
  * 在 `DownloadsView.swift`、`AccountsView.swift` 等处已配置了左右双向侧滑全滑删除。
* **待验证**：在真机上运行验证视觉效果是否与原版完全一致。

---

## 三、常用构建与调试命令

1. **WSL2 本地构建 IPA**：
   ```powershell
   wsl -d Ubuntu -- bash -lc "cd /mnt/d/iOS-Dev/projects/ipadn && /usr/local/bin/xtool dev build --ipa"
   ```
   输出路径：`D:\iOS-Dev\projects\ipadn\xtool\iPadn.ipa`

2. **真机一键签名 + 部署 + 启动（iPhone 15 Pro）**：
   ```powershell
   python "D:\iOS-Dev\.agents\skills\ios-real-device-workflow\scripts\ios-control.py" deploy "D:\iOS-Dev\projects\ipadn\xtool\iPadn.ipa" "app.local.iPadn"
   ```
