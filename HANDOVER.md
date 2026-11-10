# iPadn 项目全面交接与问题排查文档 (HANDOVER.md)

> **更新时间**：2026-11-10
> **代码仓库**：`https://github.com/mengangs/ipadn.git` (`main` 分支)  
> **本地工作区**：`D:\iOS-Dev\projects\ipadn` (映射到 WSL2: `/mnt/d/iOS-Dev/projects/ipadn`)  
> **目标产品**：iOS 原生应用 `iPadn` (`app.local.iPadn`)

---

## 2026-11-10 本地修复与验证进度（优先于下文的原始待办）

本轮用户已批准 UI/UX、流畅性和稳定性优化，以及提交推送与 CI 验证。随后用户发来 X / Swiftgram 与新版对比截图，明确连接真机并授权调试；以最新授权为准。禁止安装支付宝。

### 当前任务与发布限制（优先于后面的历史记录）

- 用户最新明确要求：**暂时不要发布 1.8.5**。顶部提示恢复紧凑布局，排查侧滑掉帧，编译、测试并与 1.8.0 对比后交用户验收。随后用户看到贴底的小确认窗口，明确要求删除提示用回原来的样式：删除/移除确认与下载操作菜单恢复原生底部 sheet，不再采用独立窄悬浮卡片。普通字号确认框保持 1.8.0 的尺寸、间距和按钮；辅助字号允许滚动，确保长文案和按钮可达。
- 旧的发布授权已被以上要求覆盖；运行 `42782145978` 已取消，未创建 1.8.5 Release。后续手动验证必须使用 `publish_release=false`。
- 验证运行 `42791902264` 已因用户更改确认框方案取消；新方案的最终编译、测试与真机结果待补充。先前窄卡片截图不能用作最终效果。
- 与 `v1.8.0` 源码对比：顶部单行提示恢复 18pt 横向/11pt 纵向内边距与 0.2 秒动画，并保留至少 44pt 点击高度；撤销提示去掉此前在 44pt 按钮外额外增加的 22pt 高度。普通字号确认框恢复原来的 320pt detent、24pt 内边距、20pt 内容间距、52pt 主按钮和至少 48pt 取消按钮；确认框大字号仍使用原生 large sheet，并增加内容滚动。系统输入表单/文件选择器仍使用原生布局。
- 侧滑改为每个显示刷新最多提交一次完整状态，跳过未变化帧；缓存 UIKit 宿主查找结果，减少一层移动卡片裁剪。相同真机、1 秒相同 HID 横滑、相同高刷配置下，两组单次采样的状态提交数从 268/266 降为 223/222（约 17%）；对应显示回调间隔约 8.33ms。该指标不是 GPU 呈现 FPS，也不保证所有场景零卡顿。调试包原先缺少高刷开关的问题已在本地配置/后处理工具中补齐；生产配置此前已有该开关。

### 本次真机复查（以下含历史进度）

- 历史版本安排：**1.8.5（build 24）**；`1.8.1` 未正式发布，本轮变更一并进入 1.8.5。当前发布暂停，以本页上方最新要求为准。
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
