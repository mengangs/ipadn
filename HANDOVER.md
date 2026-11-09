# iPadn 项目全面交接与问题排查文档 (HANDOVER.md)

> **更新时间**：2026-11-09  
> **代码仓库**：`https://github.com/mengangs/ipadn.git` (`main` 分支)  
> **本地工作区**：`D:\iOS-Dev\projects\ipadn` (映射到 WSL2: `/mnt/d/iOS-Dev/projects/ipadn`)  
> **目标产品**：iOS 原生应用 `iPadn` (`app.local.iPadn`)

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
