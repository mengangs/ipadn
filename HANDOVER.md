# iPadn 项目全面交接与问题排查文档 (HANDOVER.md)

> **更新时间**：2026-11-10
> **代码仓库**：`https://github.com/mengangs/ipadn.git` (`main` 分支)  
> **本地工作区**：`D:\iOS-Dev\projects\ipadn` (映射到 WSL2: `/mnt/d/iOS-Dev/projects/ipadn`)  
> **目标产品**：iOS 原生应用 `iPadn` (`app.local.iPadn`)

---

## 2026-11-11 iPadn 1.9.0（build 25）汇总

用户已授权：审查后提交、CI 编译测试通过后发布 1.9.0。本节为最新状态，下方原生安装小节为过程记录。

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
