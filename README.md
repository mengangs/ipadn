# iPadn

![iPadn](iPadn-iOS/iPadn/Resources/Assets.xcassets/BrandMark.imageset/brand.png)

iPadn 是一款 iPhone / iPad 应用安装包管理工具。搜索应用、查看历史版本、同步已购记录，下载并导出 IPA。

[下载最新版本](https://github.com/mengangs/ipadn/releases/latest) · [使用指南](iPadn-iOS/README.md) · [反馈问题](https://github.com/mengangs/ipadn/issues)

## 功能

- **搜索**：按名称、App ID 或 App Store 链接查找应用，切换商店地区与 iOS / tvOS 平台，保存收藏和最近搜索。
- **历史版本**：筛选版本号或版本 ID，查询 Apple 版本列表，手动指定版本，配置其他版本来源。
- **下载管理**：后台下载、暂停与继续、失败重试、批量整理和 IPA 导出；显示进度、速率与预计剩余时间。
- **已购与账号**：管理多个 Apple 账号，同步和搜索购买记录。
- **文件与快捷指令**：导入 IPA 或包含 Payload 的 ZIP，添加 HTTPS 下载链接，通过快捷指令或 `ipadn://` 链接打开应用。

界面采用黑白主题，支持深色模式、动态字号和 iPad 侧栏。默认使用立体图标，可在「账号 → 设置 → 应用图标」切换为扁平风格。

## 安装

需要 **iOS / iPadOS 17 或更新版本**。

1. 在 [Releases](https://github.com/mengangs/ipadn/releases) 下载最新版 `iPadn-*.ipa`。
2. 使用自己的签名工具签名。
3. 按签名工具的指引安装到 iPhone 或 iPad。

安装包未签名，本项目用于自行签名使用，不上架 App Store。无需向本项目提供 Apple 账号、签名证书或私钥。

## 账号与数据

登录凭据保存在设备钥匙串，验证码不会保存。退出账号保留本机登录信息；移除账号清理该账号信息和已购缓存，保留下载文件。

清除版本查询缓存、恢复默认设置不会删除账号或 IPA。删除下载任务会同时删除对应安装包，操作前会提示确认。无法读取的本地文件会保留原件，请先备份再检查。

## 下架应用与 TestFlight

搜索会同时查找本机记录、已购记录和 iPadn 名称目录。目录目前从 Forward 开始，包含旧名称别名；覆盖范围有限，不是完整的下架应用数据库。

找到应用资料不代表仍有下载权限。实际下载取决于账号许可、商店地区和 Apple 文件可用性。当前不支持直接下载 TestFlight IPA；已有 IPA 仍可导入管理。

[详细使用说明](iPadn-iOS/README.md) · [自行编译](iPadn-iOS/BUILDING.md) · [组件声明](iPadn-iOS/THIRD_PARTY_NOTICES.md)
