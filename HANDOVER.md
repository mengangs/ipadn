# iPadn 项目开发与交接文档 (Handover Document)

> **文档创建时间**：2026-11-09  
> **代码仓库**：`https://github.com/mengangs/ipadn.git` (`main` 分支)  
> **本地工作区**：`D:\iOS-Dev\projects\ipadn` (映射到 WSL2: `/mnt/d/iOS-Dev/projects/ipadn`)  
> **目标产品**：iOS 原生应用 `iPadn` (`app.local.iPadn`)

---

## 一、项目核心功能与架构背景

iPadn 是一个运行在 iOS 设备的开源工具，类似于运行在手机端的 `ipatool`：
1. **App Store 协议交互**：通过 `AppleService.swift` 与苹果 iTunes Store / App Store API 通信，支持使用用户自备的 Apple ID 获取下载授权（获取 SINF 许可证与 `songList` 下载链接）。
2. **IPA 打包与授权注入**：通过 `PackageService.swift` 解包下载的官方资源包，将 Apple ID 元数据（`iTunesMetadata.plist`）以及 FairPlay 签名凭证（`.sinf`）注入到 `.ipa` 中。
3. **本地部署安装**：通过 `InstallationService.swift` 启动本地回环服务器（`LoopbackServer`），使用 iOS 原生 OTA 协议（`itms-services://?action=download-manifest`）实现免越狱设备端一键安装。

---

## 二、近期用户需求与已完成的修改

### 1. 多二进制组件（如支付宝）SINF 签名与完整性校验修复
* **问题背景**：单二进制应用（如 B站、瑞幸咖啡）安装后可正常启动并在 App Store 显示“更新”，但多二进制应用（如支付宝包含主程序以及 WatchKit / 插件 / Frameworks）安装后在桌面出现白图标，提示“无法安装，无法验证其完整性”。
* **技术根因**：
  * 苹果对多二进制应用的下载响应中，`song["sinfs"]` 包含了多个 `.sinf` 授权块（按 `id` 排序）；
  * 同时在 IPA 的 `Payload/<App>.app/SC_Info/Manifest.plist` 中声明了 `SinfPaths`，分别对应主程序和各个扩展二进制。
  * 之前 iPadn 只提取了第一个 `sinf` 且只覆盖了根目录单个二进制，其他扩展二进制缺少授权，触发 iOS 内核 AMFI/FairPlay 校验失败。
* **已完成改动**：
  * [`iPadn-iOS/iPadn/Models/Models.swift`](iPadn-iOS/iPadn/Models/Models.swift): 在 `DownloadAsset` 中增加 `var sinfs: [Data]?`。
  * [`iPadn-iOS/iPadn/Services/AppleService.swift`](iPadn-iOS/iPadn/Services/AppleService.swift): 解析并按 `id` 升序提取所有 SINF 数据；将 `purchaseMetadata` 独立为 `nonisolated static` 方法。
  * [`iPadn-iOS/iPadn/Services/PackageService.swift`](iPadn-iOS/iPadn/Services/PackageService.swift): 读取 `SC_Info/Manifest.plist` 的 `SinfPaths`，将所有 SINF 按路径复制到各个二进制组件中；严格保留 `.supp` 辅助文件。

### 2. 界面与交互体验恢复
* **TabBar 毛玻璃效果**：
  * [`iPadn-iOS/iPadn/Views/SharedViews.swift`](iPadn-iOS/iPadn/Views/SharedViews.swift): 在根 `TabView` 上增加了 `.toolbarBackground(.visible, for: .tabBar)` 与 `.toolbarBackground(.ultraThinMaterial, for: .tabBar)`，恢复系统原生磨砂玻璃背景。
* **侧滑删除优化**：
  * [`DownloadsView.swift`](iPadn-iOS/iPadn/Views/DownloadsView.swift)、[`AccountsView.swift`](iPadn-iOS/iPadn/Views/AccountsView.swift)、[`SearchView.swift`](iPadn-iOS/iPadn/Views/SearchView.swift)、[`SettingsView.swift`](iPadn-iOS/iPadn/Views/SettingsView.swift)、[`StorageView.swift`](iPadn-iOS/iPadn/Views/StorageView.swift): 均配置了 `.trailing` 与 `.leading` 侧滑操作，并设置 `allowsFullSwipe: true` 支持一滑到底直接删除。

---

## 三、待 Codex 解决的已知问题 (Action Items)

### 🔴 关键问题 1：CI 构建中的单元测试报错 (`CoreTests.swift`)

在最新的 GitHub Actions 运行（#285，ID: `42575546155`）中，以下测试用例报错：
```text
/Users/runner/work/ipadn/ipadn/iPadn-iOS/iPadnTests/CoreTests.swift:37: error: 
-[iPadnTests.CoreTests testPackageCompletionCannotOverwriteSharedIdentifierPrefixAndHandlesLongNames] : 
XCTAssertThrowsError failed: did not throw an error

/Users/runner/work/ipadn/ipadn/iPadn-iOS/iPadnTests/CoreTests.swift:38: error: 
-[iPadnTests.CoreTests testPackageCompletionCannotOverwriteSharedIdentifierPrefixAndHandlesLongNames] : 
XCTAssertEqual failed: ("647 bytes") is not equal to ("647 bytes")
```

#### 根因分析：
在 [`iPadn-iOS/iPadn/Services/PackageService.swift`](iPadn-iOS/iPadn/Services/PackageService.swift) 的第 164~172 行：
```swift
// A retry or identifier collision must not delete an existing user package.
try? FileManager.default.createDirectory(at: LocalResources.packages, withIntermediateDirectories: true)
if FileManager.default.fileExists(atPath: destination.path) {
    try? FileManager.default.removeItem(at: destination)
}
do {
    try FileManager.default.moveItem(at: working, to: destination)
} catch {
    try FileManager.default.copyItem(at: working, to: destination)
    try? FileManager.default.removeItem(at: working)
}
```
* **原版代码逻辑**：`try FileManager.default.moveItem(at: working, to: destination)`。原作者特意设计成：当文件已存在（冲突）时，**禁止覆盖已有安装包**，必须直接抛出异常！
* **测试用例预期**：`CoreTests.swift` 的 `testPackageCompletionCannotOverwriteSharedIdentifierPrefixAndHandlesLongNames` 测试了该冲突防御逻辑（断言二次同 ID 存储必须 throw）。
* **修复方案**：
  将 `PackageService.swift` 中的该段文件移动逻辑还原为不允许主动 `removeItem`，直接调用系统 `moveItem`（让其在目标文件存在时抛出错误）。

---

### 🔴 关键问题 2：CI 构建中的 UI 自动化测试不稳定 (`InteractionTests.swift`)

#### 现象：
GitHub Actions 里的 macOS 运行环境没有物理 GPU，运行模拟器 UI 测试容易卡顿超时。
* 工作流路径：`.github/workflows/ios-build.yml`
* 执行命令：`xcodebuild test -project iPadn.xcodeproj -scheme iPadn ...`
* 该命令同时执行了单元测试（`iPadnTests`）和界面自动化测试（`iPadnUITests`）。由于 UI 测试消耗近 18 分钟且频繁因为界面渲染延迟闪退（exit code 65），如果不需要每次 push 触发 UI 渲染测试，可建议在 CI 中拆分或限制仅跑 `iPadnTests`，将 UI 测试改为按需触发（`workflow_dispatch`）。

---

## 四、技术原理与系统边界解答 (供回复或参考)

针对用户询问的以下两个技术疑点，在技术架构上的机理如下：

### 1. 为什么设置里只有“删除 App”而没有“卸载 App”（Offload App）？
* **原理**：iOS 的“卸载 App”操作会将应用二进制删除但保留沙盒数据，当用户点击桌面云朵图标时，系统底层（`appstored`）必须直接向苹果 App Store 服务器重新发起下载。
* **边界**：通过本地 OTA（`itms-services://`）安装的应用，iOS 底层（`installd`）会将其安装来源标记为企业/外部清单分发（`enterpriseInstallURL`）。iOS 系统为了防止外部服务失效导致数据丢失，**硬编码对所有 OTA 安装的应用禁用“卸载 App”，仅提供“删除 App”**。在免越狱环境下，任何应用均无法改变此系统底层行为。
* **解决途径**：在 App Store 官方商店中，对识别出“已购/更新”的应用点击一次“更新”，App Store 会下载最新版本覆盖，此时系统安装来源变更为 `com.apple.AppStore`，“卸载 App”选项就会恢复。

### 2. 为什么爱思助手显示为“共享正版”，Apple ID 显示为“-”？
* **原理**：
  * **“共享正版”**是爱思助手自身的命名规则，代表该应用具有苹果官方正版 FairPlay DRM 证书（`Apple iPhone OS Application Signing`），但非爱思助手自身客户端绑定的账号直接购买。它属于 100% 的官方正版，不影响功能，不掉签，且能被系统 App Store 识别。
  * Apple ID 显示为“-”是因为在 OTA 清单安装过程中，系统 `installd` 自动生成了轻量级元数据。如果在电脑端通过 USB 数据线安装该 `.ipa`，爱思即可直接解析我们写入 `iTunesMetadata.plist` 中的 Apple ID 账号。

---

## 五、常用构建与调试命令

1. **WSL 本地快速编译**：
   ```powershell
   wsl -d Ubuntu -- bash -lc "cd /mnt/d/iOS-Dev/projects/ipadn && /usr/local/bin/xtool dev build --ipa"
   ```
   输出安装包路径：`D:\iOS-Dev\projects\ipadn\xtool\iPadn.ipa`

2. **真机一键签名 + 部署 + 启动（iPhone 15 Pro）**：
   ```powershell
   python "D:\iOS-Dev\.agents\skills\ios-real-device-workflow\scripts\ios-control.py" deploy "D:\iOS-Dev\projects\ipadn\xtool\iPadn.ipa" "app.local.iPadn"
   ```

3. **查看真机实时日志**：
   ```powershell
   python "D:\iOS-Dev\.agents\skills\ios-real-device-workflow\scripts\ios-control.py" syslog iPadn 5
   ```
