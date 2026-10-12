# iPadn

![iPadn](iPadn-iOS/iPadn/Resources/Assets.xcassets/BrandMark.imageset/brand.png)

iPadn 是一款面向 iPhone / iPad 的应用安装包管理工具：搜索应用、查找历史版本、同步已购记录、下载与导出 IPA。保持黑白主题，支持深色模式、动态字号和 iPad 侧栏。

## 可以做什么

- **搜索与收藏**：按名称、App ID、App Store 链接查询，切换地区与 iOS / tvOS 平台；保留收藏和最近搜索，支持直接输入「App ID 版本 ID」。
- **历史版本**：筛选版本号或内部版本 ID，查询 Apple 版本列表，配置第三方版本来源，手动指定版本下载。
- **下载管理**：后台传输、暂停/继续、刷新失败任务授权、批量整理和 IPA 导出；显示进度、传输速率及预计剩余时间。
- **已购与账号**：在多个 Apple 账号间切换，同步和搜索购买记录。登录凭据保存在设备钥匙串，验证码不保存。
- **文件与快捷指令**：从「文件」导入 IPA 或包含 Payload 的 ZIP，添加 HTTPS 直链，使用快捷指令或 `ipadn://` 链接。
- **下架应用线索**：搜索本机记录、已购记录和随应用内置的名称目录。目录目前从 Forward 开始，支持旧名称别名；离线时使用内置及缓存资料。

名称目录覆盖有限，搜索到资料不代表仍有下载许可。下载取决于账号授权、地区和 Apple 文件可用性；当前不提供 TestFlight 账号接入或直接下载测试版 IPA。

## 获取与安装

需要 **iOS / iPadOS 17 或更新版本**。本项目用于自行签名安装，不上架 App Store。

1. 打开 [GitHub Actions 构建列表](https://github.com/mengangs/ipadn/actions/workflows/ios-build.yml)，选择与你需要的代码提交对应的构建。
2. 下载 `iPadn-unsigned-ipa`，解压取得 `iPadn-unsigned.ipa`、SHA-256 校验文件与构建信息。
3. 核对提交和校验值，再用自己的签名工具签名安装。

`iPadn-interface-screenshots` 保存界面截图，`iPadn-build-diagnostics` 保存构建日志与测试结果。IPA 上传成功不等于所有测试通过，请同时查看测试步骤和 [验证记录](iPadn-iOS/VERIFICATION.md)。不需要向 GitHub 上传 Apple 账号、证书或私钥。

## 数据与维护

退出账号保留本机账号；移除账号清理该账号登录信息与已购缓存，保留已下载文件。删除下载任务会同时删除对应安装包，操作前有确认提示。

清除版本缓存、恢复默认设置不会删除账号或下载文件。无法读取的本地 IPA 会保留原件并提示，其他任务仍可使用；损坏的任务/收藏/已购记录不会被空数据覆盖。Debug 截图模式与正式数据隔离。

## 开发与验证

原生 SwiftUI 项目，共享 scheme 为 `iPadn`。完整编译、XCTest 与模拟器运行需要 macOS、Xcode 和 iOS SDK；Linux 可进行项目结构、资源哈希和离线 WASM 校验。

```bash
cd iPadn-iOS
python3 scripts/assemble_runtime.py
python3 scripts/verify_project.py
node scripts/runtime_smoke_test.cjs
# macOS + Xcode：
bash scripts/build_unsigned_ipa.sh
```

校验报告写入忽略的 `build/verification.json`。PR 和主分支构建执行设备编译、模拟器单元/交互测试及截图。真实 Apple 登录、下载授权、后台恢复和自行签名安装仍需真机验收。

[使用指南](iPadn-iOS/README.md) · [开发文档](iPadn-iOS/BUILDING.md) · [检查与修复记录](iPadn-iOS/REVIEW.md) · [组件声明](iPadn-iOS/THIRD_PARTY_NOTICES.md)
