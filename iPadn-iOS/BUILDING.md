# 自行编译 iPadn

iPadn 是一个 SwiftUI 应用，最低支持 iOS / iPadOS 16（原生安装需 17.4+，实时活动需 16.1+，本机配对需 27+），适用于 iPhone 和 iPad。当前源码版本为 2.2.0（build 34）。

## GitHub 云编译（无需本地 Mac）

日常构建和发布使用 GitHub Actions 的 macOS runner（`xcode-27`），不需要本地 Mac。推送到 `main` 或提交 PR 后会自动编译和测试；也可以在 Actions 中手动运行 **Build iPadn**，勾选 `run_tests` 和 `publish_release` 发布新版。

日常构建执行完整 `iPadnTests`（含安装、认证、FairPlay 解密、加密备份、签名组件和布局测试）。界面交互测试 `iPadnUITests` 可在手动运行时同时勾选 `run_tests` 和 `run_ui_tests` 执行。

也支持推送与项目版本一致的新标签（例如 `v2.2.0`）触发编译、单元测试和 Release 发布；标签与 IPA 版本不一致时拒绝发布。安装包在检查与测试全部通过后才发布，发布完成后工作流自动调用 `scripts/generate_altstore_source.py` 同步根目录 `altstore-source.json`。

下文的 Mac 和 Xcode 要求仅适用于自行在本地编译。

## 准备

Windows + WSL 使用 `xtool` 本地真机调试构建时，底层通过仓库根目录本地构建配置同时链接 `FairPlayCore` C 模块（`iPadn-iOS/FairPlayCore/`）与 `libipadn_native.a`；构建未签名 IPA 后须先运行 `scripts/xtool_postbuild.py` 修正 `LC_BUILD_VERSION` 的 SDK 标记（保留最小支持版本并确保 `CADisableMinimumFrameDurationOnPhone=true`），随后可执行 `scripts/verify_ipa.py`（支持 `--min-sdk 26.0 --require-high-refresh`）再签名安装，避免触发旧界面兼容模式。云端 Xcode 构建无需这一步。

- 一台装有 Xcode 26 或 Xcode 27 的 Mac
- Python 3（含 Node.js 用于运行 `runtime_smoke_test.cjs`）
- Go 1.26.5：用于编译 Mac 安装包处理组件（`MacPKGBridge`）。不编译这个组件也能构建应用，只是不能下载需要处理的 Mac 安装包。
- Rust（stable）及 `aarch64-apple-ios` 目标：用于编译原生安装组件（`NativeInstall`）。不编译这个组件也能构建应用，只是安装方式里没有「原生安装」。
- `FairPlayCore` C 核心（`iPadn-iOS/FairPlayCore/`）：仓库内置零外部依赖纯 C 模块，已通过 `include/module.modulemap` 直接接入 Xcode `iPadn` target 与 SPM 构建，无需额外安装系统库。

## 构建未签名 IPA

在 `iPadn-iOS` 目录运行：

```bash
bash scripts/build_unsigned_ipa.sh
```

输出为 `build/iPadn-unsigned.ipa`。脚本会先校验并打包验证组件，再尝试编译 Mac 安装包处理组件；没有安装 Go 时会跳过该组件。设置 `IPADN_REQUIRE_MACPKG=1` 可要求必须包含它。

原生安装组件由 `scripts/build_native_install.sh` 编译为 `build/native/libipadn_native.a`，没有安装 Rust 时会跳过。设置 `IPADN_REQUIRE_NATIVE=1` 可要求必须包含它。该组件是纯 Rust 实现，不依赖 Apple SDK，可以在 macOS 或 Linux 上交叉编译；Windows + WSL 的 xtool 本地构建在根目录 `Package.swift` 中用链接参数引入同一个静态库。

`NativeInstall/examples/cli.rs` 可以在与设备同一局域网的电脑上运行同一套代码，用于在不编译应用的情况下检查配对文件和安装流程：

```bash
cargo run --release --example cli -- lookup <配对文件> <设备地址> <端口> <Bundle ID>
```

用 Xcode 打开 `iPadn.xcodeproj`，选择共享 scheme `iPadn`，即可运行和调试。

## 修改工程

工程文件由脚本生成。新增或删除源码、资源或本地化文件后，请从 `iPadn-iOS` 目录运行：

```bash
python3 scripts/generate_project.py
python3 scripts/verify_project.py
```

`generate_project.py` 会将 `FairPlayCore` C 模块（`FairPlayCore/FairPlayCore.c` 与 `FairPlayCore/include/module.modulemap`）、应用主目标 `iPadn`、实时活动与小组件扩展 `iPadnLiveActivity`，以及测试目标统一写入 `iPadn.xcodeproj/project.pbxproj`。`verify_project.py` 会同时核验 `FairPlayCore` 接入、三段式版本号与构建号一致性、`SAPRuntime` 文件校验和、内置许可证文件及全部 11 种语言的本地化完整性。

`PairingActivityAttributes` 在主应用（`iPadn/Services`）和扩展 `iPadnLiveActivity` 中各有一份，ActivityKit 按类型名匹配，两份的字段必须保持一致；主应用与扩展共享 App Group 时必须保持权限与结构体定义同步。

`tools/native_install/` 是独立的电脑端对照工具，用于通过 USB 验证原生安装协议，不参与应用构建；它有单独的离线测试工作流 `native-install-probe.yml`。

## 本地化

界面完整支持 **11 种语言**：简体中文（`zh-Hans`）、繁體中文（`zh-Hant`）、English（`en`）、日本語（`ja`）、한국어（ko）、Русский（`ru`）、Español（`es`）、Français（`fr`）、Deutsch（`de`）、Português (Brasil)（`pt-BR`）与 العربية（`ar`，从右到左 RTL 排版）。简体中文是字符串目录的源语言（键即中文原文），全部 11 种语言的译文都保存在同一套字符串目录中：

- `iPadn/Resources/Localizable.xcstrings`：界面与提示文字（含 FairPlay 解密、备份恢复与设置页面）
- `iPadn/Resources/InfoPlist.xcstrings`：网络权限说明、文稿类型名称
- `iPadn/Resources/AppShortcuts.xcstrings`：快捷指令短语
- `iPadnLiveActivity/Localizable.xcstrings`：实时活动（锁屏、灵动岛、小组件）文案，扩展运行在独立进程，使用自己的目录

繁体中文由简体用 OpenCC（台湾用语）转换后，再按 Apple 台湾用词习惯修正（如帳號、憑證、主畫面、動態島、取得驗證碼）；英文由社区贡献者校对完善，其余语言为参照中英文的机器辅助翻译，欢迎母语者在仓库提交校对。

工程的开发语言（`developmentRegion`）为英文（`en`），这样未匹配到具体语言的设备会回退显示英文；源语言（`sourceLanguage`）为 `zh-Hans`。11 种语言每个键都必须完整赋值。

**写法约定**

- `Text("…")`、`Button("…")`、`Label("…")`、`Section("…")`、`.navigationTitle`、`.accessibilityLabel` 等参数是 `LocalizedStringKey`，字面量会自动本地化，不要再包一层。
- 模型、服务和提示里组合出来的文字用 `AppText.text("…")`（`iPadn/App/Localization.swift`）。它按当前界面语言查找，测试可指定语言。
- 不要拼接翻译片段（`AppText.text("A") + name`）；把整句写成一个键，用插值生成 `%@`／`%lld` 占位符。
- 计数短语保留 `%lld`，英文在目录里加复数变化（`one`／`other`），中文及东亚语言只写 `other`。
- 已是最终语言的字符串传给 `LocalizedStringKey` 参数时，会被当作键再查一次；键不存在时原样显示，可以接受，但不要用这种方式处理含 `%` 的用户数据。
- 不翻译：协议字段、SF Symbols、Bundle ID、商店返回的应用资料、以及作为数据保存的标记值（`DownloadStatus`／`DownloadFilter` 的 `rawValue`、`未在公开商店找到`、`未导入`、`未知版本`）。

**新增或修改文字**

更新或新增字符串后，可运行 `python3 iPadn-iOS/scripts/verify_project.py` 核验全部 **11 种语言**的键覆盖率、英文/韩文残留汉字检查、占位符（`%@`、`%lld`、`%%`、`${…}`）一致性和复数规则。缺失任一语言或占位符不匹配都会导致检查失败。

比价时内购项目名称按界面/系统语言读取对应地区商店的本地名称（简体中文读中国区、繁体中文读台湾区、日语读日本区、韩语读韩国区等）。

需要整体核对键集合时用导出（导出要求开发语言等于目录源语言）：

```bash
python3 scripts/generate_project.py --development-language zh-Hans
xcodebuild -project iPadn.xcodeproj -scheme iPadn -destination 'platform=iOS Simulator,name=iPhone 17' \
  -exportLocalizations -localizationPath build/localizations -exportLanguage zh-Hans
python3 scripts/generate_project.py   # 恢复开发语言 en
```

**测试与语言**

单元测试在 `setUp` 中把 `AppText.locale` 固定为 `zh-Hans`，断言中文；涉及货币、数字的断言显式传 `locale:`。界面测试用 `-AppleLanguages (zh-Hans)` 启动应用，断言也是中文。其他语言界面及阿拉伯语 RTL 镜像可在系统语言设置中切换验证。

英文 README 见仓库根目录的 [README_EN.md](../README_EN.md)。

## 测试

**Xcode 测试（macOS / GitHub Actions）**

- `iPadnTests`：单元测试，覆盖下载、认证、备份加密、FairPlayCore C 解密与验证、`RecordStore`、原生安装与本地化规则
- `iPadnUITests`：界面交互测试

**跨平台与构建前静态检查（Linux / WSL / macOS / 仓库根目录或 `iPadn-iOS`）**

```bash
python3 iPadn-iOS/scripts/verify_project.py
python3 -I iPadn-iOS/scripts/compile_reveal_animations.py --check
node iPadn-iOS/scripts/runtime_smoke_test.cjs
python3 tools/run_record_store_checks.py
python3 tools/fairplay_ui_catalog.py
```

在安装了 `swiftc` 的环境中（如 GitHub Actions macOS 或 WSL Swift 工具链），还可以单独编译运行脱敏策略检查：

```bash
swiftc iPadn-iOS/iPadn/Views/DiagnosticRedactor.swift iPadn-iOS/iPadn/Views/PackageOutputPolicy.swift tools/tests/fairplay_redaction_checks.swift -o /tmp/fp_redact_check
/tmp/fp_redact_check
```

IPA 打包后可使用以下脚本做完整校验（标准版与 `--lite` 精简版）：

```bash
python3 iPadn-iOS/scripts/verify_ipa.py --min-sdk 26.0 --require-high-refresh <ipa路径>
python3 iPadn-iOS/scripts/verify_ipa.py --lite --min-sdk 26.0 --require-high-refresh <lite-ipa路径>
python3 tools/fp_ipa_check.py <ipa路径>
```

用 `--visual-preview` 参数启动时会使用演示数据和独立的存储空间，不会读写真实的账号或下载记录。Release 构建不包含演示数据。

调试预览可叠加 `--largest-text`（最大辅助字号）、`--dark`、`--notice-preview`（保留可点按关闭的示例提示，供尺寸检查）及 `--reveal-metrics`。后者只在侧滑结束时记录显示回调间隔和界面状态提交次数，不在每帧输出日志；它不能代表 GPU 实际呈现帧率。比较时使用同一设备、同样的前台手势，排除退到后台或截图干扰的采样。

Windows/WSL 使用 `xtool` 进行本地包调试签名前，请先执行仓库根目录本地工具 `scripts/xtool_postbuild.py`，修正 SDK 标记并保留 `CADisableMinimumFrameDurationOnPhone=true`（与生产 `iPadn/Info.plist` 一致），避免进入旧界面兼容模式或限制高刷；Xcode/CI 包直接使用生产配置。

## 持续集成

GitHub Actions 会对每个 PR 和 `main` 分支执行设备编译、IPA 检查和模拟器测试，并上传以下产物（界面效果以真机检查为准）：

| 产物 | 内容 |
| --- | --- |
| `iPadn-unsigned-ipa` | 未签名标准版安装包与校验信息 |
| `iPadn-build-diagnostics` | 构建日志与测试结果 |

手动运行工作流并勾选 `run_tests` 与 `publish_release`，会在全部检查通过后发布 GitHub Release，发布说明取自仓库根目录的 `RELEASE_NOTES.md`，随后自动生成 `iPadn-<version>-lite-unsigned.ipa` 并通过 `scripts/generate_altstore_source.py` 更新 `altstore-source.json`。已存在的同名 Release 不会被覆盖；推送 `v*` 标签触发发布时使用该标签对应的源码，并要求标签与 IPA 三段版本号完全一致。

发布前手动运行应开启 `run_tests`、`run_ui_tests`；只能发布完整检查通过的同一提交产物，核对源码、SHA-256、IPA 校验和测试摘要。

`ui_test_scope` 默认为 `full`，执行全部 UI 用例。局部修改提示时可选 `notices`：仍执行全部单元测试，只复跑提示尺寸/边缘点击/最大字号确认和删除撤销两项 UI 回归，不删除或放宽任何测试；该范围不能触发自动发布。发布记录应注明实际验证范围，不能把局部回归说成最新提交的全量 UI 通过。

Windows 手动发布说明必须从 UTF-8 文件生成并通过 `gh release ... --notes-file` 上传。不要把包含中文的 PowerShell here-string 通过默认原生管道传给 Python：Windows PowerShell 的 `$OutputEncoding` 可能为 ASCII，中文会在 Python 接收前变成问号，`python -X utf8` 无法恢复。发布后必须从 GitHub API 回读正文，规范化换行后与本地 UTF-8 文件逐字对比，并检查问号乱码及替换字符；附件校验通过不能代替文案核验。

## 扩展

- **历史版本来源**：接口返回包含 `external_identifier` 与 `bundle_version` 字段的列表即可，可在应用设置中添加。
- **下架应用名称目录**：`iPadn/Resources/app-name-directory.json`，每条记录包含 `id`、`name`、`aliases`、`platform`（`itunes` / `atv9`）和可核对的 `source`。只收录名称与 App ID 的对应关系，不收录下载链接或账号信息。

第三方组件及许可见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 登录异常排查

登录先读取 Apple 的 `bag.xml` 配置，再向经校验的 Apple 商店登录地址发送签名请求。Apple 当前实际返回 `Document/Protocol/plist` XML 封装和顶层配置；解析同时兼容标准 XML/binary plist 与旧版 `urlBag` 嵌套结构。空响应、非 plist 响应及部分临时 HTTP 错误最多重试一次；密码错误或双重认证响应不会自动重复提交，429 限流也不会立即重试。

真机登录仍失败时，在「账号 › 设置 › 备份与维护」中导出诊断信息。登录诊断只保留本次会话最近一次登录的阶段、请求次数、HTTP 状态、响应格式、字节数和系统错误码，不保存响应正文、账号、密码、验证码、签名、Cookie 或令牌。配置请求和配置解析分别记录 HTTP 状态、格式及静态错误原因，避免再次只记录 `application; code=0`。本机账号记录读取失败时保留原记录，不自动清空钥匙串。

## iPadn 更新检查

优先使用 GitHub Releases API；请求失败、限流或返回异常数据时改读该仓库的公开 Atom 发布订阅。只接受本仓库的正式三段版本号，使用发布流程约定的 IPA 文件名。检查到的版本与当前安装版本相同时显示「已是最新版本」；两个通道都失败才提示检查失败，不把缓存或安装来源当作检查成功的依据。

诊断信息会记录 API 和订阅通道各自的 HTTP 状态、格式及是否限流，不包含响应正文或任意响应头。

## 认证参考与验证范围

2026-11-08 通过 GitHub macOS runner 请求真实 Apple bag，复现标准 Foundation plist 解析的 `NSCocoaErrorDomain 3840`；Apple 响应使用 `Document/Protocol` 包裹，认证 URL 仍为 `https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate`。回归测试保留去掉无关字段后的同结构样本。

也对照了 [xtool 的 GrandSlam 实现](https://github.com/xtool-org/xtool/tree/a2875dd/Sources/XKit/GrandSlam)：该实现通过 GSA lookup、SRP、Anisette 完成认证，面向开发者服务，与本项目 App Store SAP 认证的接口和凭据用途不同。本次没有直接替换为 GSA URL，也没有引入 xtool 的依赖。动态接口查询、HTTP/解码错误区分可作为参考。

云端公开接口验证不使用真实账号。密码、双重认证、下载授权仍需要真机验证，不能由公开配置解析和单元测试通过推断成功。
