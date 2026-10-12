# IPA Tool Native — 独立 iOS 工程

基于附件 `IPA-Tool-3.0.scripting` 迁移的 SwiftUI 应用，用于自己签名安装。最低 iOS 17，支持 iPhone / iPad。运行时不依赖 Scripting App。

工程已通过 GitHub Actions 云编译，并生成未签名 IPA；**10 个模拟器单元测试全部通过**。编译环境为 Xcode 26.0.1，测试运行于 iOS 26 模拟器。Apple 认证、实际下载、已购记录、后台生命周期及最终安装仍需在自己的 iPhone 上验证。详细结果见 `VERIFICATION.md`。

[通过的编译记录](https://github.com/mengangs/ipadn/actions/runs/38195930796) · [未签名 IPA 产物](https://github.com/mengangs/ipadn/actions/runs/38195930796/artifacts/11722874325)

## 打开和签名安装

GitHub 版本的签名资源在编译前从原项目的固定 commit 下载。`vendor/SAPRuntime/manifest.json` 记录下载地址、压缩包大小及 SHA-256，并分别记录五个资源的 SHA-256；这些资源已确认与用户附件完全一致。GitHub Actions、IPA 编译脚本和 Xcode 预编译步骤会自动恢复并校验资源。首次编译需要联网，之后使用本地缓存。签名引擎本身没有修改。

1. 在 Mac 上解压工程，用 Xcode 16 或更新版本打开 `IPATool.xcodeproj`。
2. 等待 Swift Package Manager 获取 ZIPFoundation 0.9.19。首次打开需要能访问 GitHub。
3. 选择 `IPATool` Target → Signing & Capabilities，设置自己的 Team，并把 Bundle Identifier 改为自己的唯一标识。
4. 连接 iPhone，选择这台设备作为运行目标，运行。按你的设备要求启用开发者模式、信任开发签名。
5. 不要在未完成认证前同时操作多个账号。签名或生成下载初始化数据时保持应用在前台。

如果你使用自己的 IPA 签名工具，可以先在 Mac 上执行：

```bash
bash scripts/build_unsigned_ipa.sh
```

结果为 `build/IPATool-unsigned.ipa`。它必须再经过你的签名工具签名，才可以安装。脚本不会读取你的证书、私钥或 Apple 账号。当前环境没有执行过此编译脚本。

## 已迁移的原功能

| 原脚本能力 | 本工程中的对应实现 |
|---|---|
| 关键词 / App ID / App Store 链接搜索 | 原生网络接口、搜索历史、使用频率图；支持地区切换 |
| App ID + 内部版本 ID 搜索 | 直接请求 Apple 指定版本下载信息并校验版本与平台 |
| iOS / tvOS | 平台数据查询、tvOS 最新版本 ID 获取与平台守卫 |
| Apple 账号登录、验证码、多账号切换 | 原协议移植；密码、Cookie、Token 改为 Keychain 存储 |
| SAP 请求签名、KBSync | 完整保留附件中的 JS / WASM 资源，使用 WebKit 与原生回环服务承载 |
| Apple 官方版本列表、第三方版本来源 | 官方查询与第三方版本名称合并；Timbrd / Bilin 可配置 |
| 免费应用许可获取、Cookie 刷新、下载接口兜底 | 原逻辑迁移；增加重试上限，避免原脚本的无限递归风险 |
| 已购记录与时间筛选 | 原 DAAP / DMAP 协议移植；账号分别缓存记录 |
| 下载任务、暂停、恢复、排序、通知 | 原生后台 URLSession、恢复数据、重启恢复、任务顺序调整 |
| 下载完成后写入 metadata / sinf | ZIPFoundation 更新 IPA；校验 Bundle ID 与版本，不解压整个安装包 |
| 本地 IPA 导入、文件管理、批量删除 | Files 文档打开、文件选择器、下载列表、选择后删除与原生导出 |
| 安装 / 降级入口 | 兼容原 plist 元数据格式和 127.0.0.1:8000 文件服务；仍需 Surge/Loon 配合 |
| 分享菜单 / 快捷指令输入 | App Intents 的搜索、导入与链接下载操作；自定义 URL Scheme |
| 下载与安装设置、恢复配置 | 原生设置页；恢复默认设置保留账号、文件及历史缓存 |

上表描述**代码实现范围**，不是所有功能已通过真机测试的声明。

## 增强和扩展

- 支持第三方版本来源编辑、启停、增加和删除。接口模板使用 `{id}` 占位符，兼容 `external_identifier` / `bundle_version` 字段；支持顶层数组或指定容器键。
- 同一应用的不同版本、不同账号分别记录，避免原任务以 App ID 为唯一键导致版本覆盖。
- 下载队列上限、并发数量可调；同一版本与账号的进行中任务会去重。
- 失败的 Apple 下载支持重新获取授权下载链接；保留失败任务直到替换任务创建成功。
- 支持 HTTPS 直链下载。此入口只管理文件，不会自行生成 Apple 账号授权信息。
- 原生后台下载接管网络传输。URLSession 的恢复行为由服务器和 iOS 决定；不支持断点恢复时可以重新下载。
- 在后台结束前保存原始下载文件；IPA 处理使用单独工作副本，处理失败不会删除原始文件。
- 生成文件名包含任务标识，避免不同版本、不同账号互相覆盖。
- 采用系统列表、动态字体、深浅色外观和 VoiceOver 按钮标签。
- 诊断导出只含任务状态摘要，排除账号、密码、Cookie、Token、下载 URL。

## 安装 / 降级链路

安装入口继续使用原脚本的 `itms-services` + HTTPS manifest + Surge/Loon 代理方案。预设 plist 服务来自附件，不代表本次已验证它们当前可用。

本工程会启动**独立 App 自己的**回环文件服务：

```text
http://127.0.0.1:8000/<filename>.ipa
```

只开放用户在本应用里选择过的安装包；支持 HEAD、单区间 Range 和流式读取。它不绑定局域网地址。SAP 引擎使用另一个动态端口和随机路径，避免端口冲突，也不允许代理任意上游 URL。

原 Surge/Loon 模块不在用户提供的附件内，因此不能假定它的具体重写规则已适配这个独立应用。你需要核对模块中 manifest 的文件地址转发规则，使其最终指向上述路径；应用的文件名会带任务标识。若 Scripting 原文件服务仍占用 8000 端口，需先停止那个服务。

安装入口不会给下载到的应用重新签名。应用的许可、设备、签名、iOS 版本及安装规则都会影响安装或降级结果；无法仅通过将工具迁移成独立 App 保证成功。必要时先导出 IPA，再交给你已有的签名 / 安装工具。

## 快捷指令与外部输入

在快捷指令中添加本应用的以下操作，可在快捷指令设置中启用「在共享表单中显示」：

- 搜索应用或商店链接：传入分享的 App Store URL、App ID 或关键词。
- 导入 IPA 安装包：传入文件。
- 下载 IPA 链接：传入 HTTPS 安装包 URL。

URL Scheme 示例：

```text
ipatool://search?id=414478124
ipatool://download?url=<URL-encoded HTTPS address>
```

也可以在 Files 中用本应用打开 `.ipa` 文件。这里使用 App Intents 和系统文档入口，不额外要求 App Group 或分享扩展的签名配置。

## 代码结构

```text
IPATool/App       应用入口、状态编排、快捷指令
IPATool/Models    统一模型、本地资源登记、搜索输入解析
IPATool/Services  Apple / Store / Version / Download / Package / Signing 服务
IPATool/Views     四个标签页、应用详情、登录、设置和扩展来源编辑
IPATool/Resources 图标、隐私清单、完整 SAPRuntime
IPAToolTests      原生单元测试
scripts           工程生成、结构检查、离线 WASM 检查和 Mac 编译脚本
```

账号凭据统一在 Keychain；设置与搜索历史在 UserDefaults；任务、已购和版本缓存为分开保存的 JSON 文件。下载状态只有 DownloadManager 一个写入入口。文件重置和账号移除不联动删除其他业务数据。

扩展服务优先通过现有业务模型添加；例如新增版本来源通常不需要改动 UI 或 Apple 协议层。资源 Key 集中在 `LocalResources`；恢复默认设置只恢复配置。

## 原生验证

```bash
python3 scripts/verify_project.py
node scripts/runtime_smoke_test.cjs
```

以上检查可在当前环境运行，但不能检查 Swift 类型、SDK API 可用性或 SwiftUI 渲染。

Mac 上先查看可用测试目标，再运行原生测试：

```bash
xcodebuild -showdestinations -project IPATool.xcodeproj -scheme IPATool
xcodebuild test -project IPATool.xcodeproj -scheme IPATool \
  -destination 'platform=iOS Simulator,id=<你的模拟器 UUID>'
```

单元测试覆盖搜索解析、DMAP 边界、Range 请求、编码保存、IPA 元数据读取以及授权文件写入。这些测试已在 GitHub Actions 的 iOS 模拟器上执行，10 个全部通过。

## 真机验收顺序

1. 先不登录，检查关键词、App ID、商店链接和第三方版本查询。
2. 导入自己已有的 IPA，验证名称 / Bundle ID / 版本显示、导出、批量删除。
3. 登录自己的 Apple 账号，验证验证码、账号切换、退出和移除。
4. 下载一个自己已经有许可的免费应用，检查 metadata 与 sinf 处理和导出文件。
5. 验证暂停 / 恢复、锁屏下载、切后台、系统结束后再次打开应用，以及不同版本并存。
6. 验证 Apple 官方历史版本与已购记录。
7. 最后适配自己的 Surge/Loon 规则，验证安装入口；如不使用代理，走 IPA 导出与自己的签名工具。

## 来源

原脚本作者：小白脸。源码来源记录为附件内的 `script.json`，远程项目是 [ScriptingApp/Community-Scripts](https://github.com/ScriptingApp/Community-Scripts)。附件名为 3.0，内部元数据 version 为 2.0.3。

SAPRuntime 五个文件直接来自附件，未修改，SHA-256 记录在 `verification.json`。ZIPFoundation 是唯一新增的第三方 Swift Package；其许可见该包的 LICENSE。没有在应用包中混入原脚本的重复备份文件。
