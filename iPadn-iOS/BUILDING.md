# 自行编译 iPadn

iPadn 是一个 SwiftUI 应用，最低支持 iOS 17，适用于 iPhone 和 iPad。当前版本为 1.7.2（build 18）。

## 准备

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

## 持续集成

GitHub Actions 会对每个 PR 和 `main` 分支执行设备编译、IPA 检查和模拟器测试，并上传以下产物（界面效果以真机检查为准）：

| 产物 | 内容 |
| --- | --- |
| `iPadn-unsigned-ipa` | 未签名安装包 |
| `iPadn-build-diagnostics` | 构建日志与测试结果 |

手动运行工作流并勾选 `run_tests` 与 `publish_release`，会在全部检查通过后发布 GitHub Release，发布说明取自仓库根目录的 `RELEASE_NOTES.md`。已存在的同名标签不会被覆盖。

## 扩展

- **历史版本来源**：接口返回包含 `external_identifier` 与 `bundle_version` 字段的列表即可，可在应用设置中添加。
- **下架应用名称目录**：`iPadn/Resources/app-name-directory.json`，每条记录包含 `id`、`name`、`aliases`、`platform`（`itunes` / `atv9`）和可核对的 `source`。只收录名称与 App ID 的对应关系，不收录下载链接或账号信息。

第三方组件及许可见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
