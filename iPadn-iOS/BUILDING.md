# 自行编译 iPadn

iPadn 是一个 SwiftUI 应用，最低支持 iOS 17，适用于 iPhone 和 iPad。当前源码版本为 1.8.5（build 24）。

## GitHub 云编译（无需本地 Mac）

日常构建和发布使用 GitHub Actions 的 macOS runner，不需要本地 Mac。推送到 `main` 或提交 PR 后会自动编译和测试；也可以在 Actions 中手动运行 **Build iPadn**，勾选 `run_tests` 和 `publish_release` 发布新版。

日常构建执行完整 `iPadnTests`（含安装、认证、签名组件和布局测试）。界面交互测试 `iPadnUITests` 可在手动运行时同时勾选 `run_tests` 和 `run_ui_tests` 执行。

也支持推送与项目版本一致的新标签（例如 `v1.8.5`）触发编译、单元测试和 Release 发布；标签与 IPA 版本不一致时拒绝发布。安装包在检查与测试全部通过后才发布。

下文的 Mac 和 Xcode 要求仅适用于自行在本地编译。

## 准备

Windows + WSL 使用 xtool 真机调试时，构建后须先在仓库根目录运行 `python scripts/xtool_postbuild.py xtool/iPadn.ipa`，再签名安装。该脚本修正 xtool 误写的 Mach-O SDK 标记，保留最低 iOS 17 支持；漏掉这一步会触发系统旧界面兼容模式，导致 TabBar 外观变化。云端 Xcode 构建无需这一步。

- 一台装有 Xcode 26 的 Mac
- Python 3
- Go 1.26：用于编译 Mac 安装包处理组件。不编译这个组件也能构建应用，只是不能下载需要处理的 Mac 安装包。

## 构建未签名 IPA

在 `iPadn-iOS` 目录运行：

```bash
bash scripts/build_unsigned_ipa.sh
```

输出为 `build/iPadn-unsigned.ipa`。脚本会先校验并打包验证组件，再尝试编译 Mac 安装包处理组件；没有安装 Go 时会跳过该组件。设置 `IPADN_REQUIRE_MACPKG=1` 可要求必须包含它。

用 Xcode 打开 `iPadn.xcodeproj`，选择共享 scheme `iPadn`，即可运行和调试。

## 修改工程

工程文件由脚本生成。新增或删除 Swift 文件后运行：

```bash
python3 scripts/generate_project.py
python3 scripts/verify_project.py
```

## 测试

- `iPadnTests`：单元测试与安装测试
- `iPadnUITests`：界面交互测试

用 `--visual-preview` 参数启动时会使用演示数据和独立的存储空间，不会读写真实的账号或下载记录。Release 构建不包含演示数据。

调试预览可叠加 `--largest-text`（最大辅助字号）、`--dark`、`--notice-preview`（保留可点按关闭的示例提示，供尺寸检查）及 `--reveal-metrics`。后者只在侧滑结束时记录显示回调间隔和界面状态提交次数，不在每帧输出日志；它不能代表 GPU 实际呈现帧率。比较时使用同一设备、同样的前台手势，排除退到后台或截图干扰的采样。

Windows/WSL 的 xtool 本地包签名前仍需执行根目录本地工具 `scripts/xtool_postbuild.py`，修正 SDK 标记，并确保 `Config/xtool/Info.plist` 中 `CADisableMinimumFrameDurationOnPhone=true`，与生产 `iPadn/Info.plist` 一致。否则调试包可能进入旧界面兼容模式或限制高刷新率；Xcode/CI 包直接使用生产配置。

## 持续集成

GitHub Actions 会对每个 PR 和 `main` 分支执行设备编译、IPA 检查和模拟器测试，并上传以下产物（界面效果以真机检查为准）：

| 产物 | 内容 |
| --- | --- |
| `iPadn-unsigned-ipa` | 未签名安装包 |
| `iPadn-build-diagnostics` | 构建日志与测试结果 |

手动运行工作流并勾选 `run_tests` 与 `publish_release`，会在全部检查通过后发布 GitHub Release，发布说明取自仓库根目录的 `RELEASE_NOTES.md`。已存在的同名 Release 不会被覆盖；标签触发发布时使用该标签对应的源码。

发布前手动运行应开启 `run_tests`、`run_ui_tests`。用户最新已授权测试通过后发布 1.8.5；只能发布完整检查通过的同一提交产物，核对源码、SHA-256、IPA 校验和测试摘要。

`ui_test_scope` 默认为 `full`，执行全部 UI 用例。局部修改提示时可选 `notices`：仍执行全部单元测试，只复跑提示尺寸/边缘点击/最大字号确认和删除撤销两项 UI 回归，不删除或放宽任何测试；该范围不能触发自动发布。发布记录应注明实际验证范围，不能把局部回归说成最新提交的全量 UI 通过。

## 扩展

- **历史版本来源**：接口返回包含 `external_identifier` 与 `bundle_version` 字段的列表即可，可在应用设置中添加。
- **下架应用名称目录**：`iPadn/Resources/app-name-directory.json`，每条记录包含 `id`、`name`、`aliases`、`platform`（`itunes` / `atv9`）和可核对的 `source`。只收录名称与 App ID 的对应关系，不收录下载链接或账号信息。

第三方组件及许可见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 登录异常排查

登录先读取 Apple 的 `bag.xml` 配置，再向经校验的 Apple 商店登录地址发送签名请求。Apple 当前实际返回 `Document/Protocol/plist` XML 封装和顶层配置；解析同时兼容标准 XML/binary plist 与旧版 `urlBag` 嵌套结构。空响应、非 plist 响应及部分临时 HTTP 错误最多重试一次；密码错误或双重认证响应不会自动重复提交，429 限流也不会立即重试。

真机登录仍失败时，在「账号 › 设置 › 维护」中导出诊断信息。登录诊断只保留本次会话最近一次登录的阶段、请求次数、HTTP 状态、响应格式、字节数和系统错误码，不保存响应正文、账号、密码、验证码、签名、Cookie 或令牌。配置请求和配置解析分别记录 HTTP 状态、格式及静态错误原因，避免再次只记录 `application; code=0`。本机账号记录读取失败时保留原记录，不自动清空钥匙串。

## iPadn 更新检查

优先使用 GitHub Releases API；请求失败、限流或返回异常数据时改读该仓库的公开 Atom 发布订阅。只接受本仓库的正式三段版本号，使用发布流程约定的 IPA 文件名。检查到的版本与当前安装版本相同时显示「已是最新版本」；两个通道都失败才提示检查失败，不把缓存或安装来源当作检查成功的依据。

诊断信息会记录 API 和订阅通道各自的 HTTP 状态、格式及是否限流，不包含响应正文或任意响应头。

## 认证参考与验证范围

2026-11-08 通过 GitHub macOS runner 请求真实 Apple bag，复现标准 Foundation plist 解析的 `NSCocoaErrorDomain 3840`；Apple 响应使用 `Document/Protocol` 包裹，认证 URL 仍为 `https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate`。回归测试保留去掉无关字段后的同结构样本。

也对照了 [xtool 的 GrandSlam 实现](https://github.com/xtool-org/xtool/tree/a2875dd/Sources/XKit/GrandSlam)：该实现通过 GSA lookup、SRP、Anisette 完成认证，面向开发者服务，与本项目 App Store SAP 认证的接口和凭据用途不同。本次没有直接替换为 GSA URL，也没有引入 xtool 的依赖。动态接口查询、HTTP/解码错误区分可作为参考。

云端公开接口验证不使用真实账号。密码、双重认证、下载授权仍需要真机验证，不能由公开配置解析和单元测试通过推断成功。
