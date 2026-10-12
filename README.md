# iPadn

![iPadn](iPadn-iOS/iPadn/Resources/Assets.xcassets/BrandMark.imageset/brand.png)

iPadn 是一款 iPhone / iPad 应用安装包管理工具，支持搜索应用、查看历史版本、同步已购记录、下载和导出 IPA。

## 功能

- **搜索**：输入名称、App ID 或 App Store 链接，切换商店地区与平台；保存收藏和最近搜索。
- **名称目录**：同时查询本机记录、已购记录和 iPadn 自己维护的目录，支持收录应用的旧名称别名。目录目前从 Forward 开始，不是完整的下架应用数据库。
- **历史版本**：查看、筛选历史版本，或输入指定版本 ID。
- **下载管理**：显示进度、速率与剩余时间，支持暂停、继续、重试、后台传输及导出。
- **已购与账号**：管理多个 Apple 账号，同步已购记录并补全可获取的应用图标。
- **文件管理**：导入 IPA、链接下载、批量整理和快捷指令。

界面使用黑白灰配色，支持深色模式、动态字号和 iPad 侧栏。后台验证保持安静，登录和下载进度只显示必要的操作状态。

## 安装

需要 **iOS / iPadOS 17 或更新版本**。

打开 [云编译页面](https://github.com/mengangs/ipadn/actions/workflows/ios-build.yml)，下载最近成功构建中的 `iPadn-unsigned-ipa`，解压后自行签名安装。

## 账号与数据

登录凭据保存在本机钥匙串，验证码不保存。当前接口不提供 Apple 原生头像，应用不设置替代头像或照片编辑功能。

搜索到应用资料不代表仍有下载权限。实际下载取决于账号许可、商店地区及 Apple 文件可用性。当前不支持直接获取 TestFlight IPA。

[使用指南](iPadn-iOS/README.md) · [版本更新](iPadn-iOS/UIUX-1.2.md) · [开发文档](iPadn-iOS/BUILDING.md) · [组件声明](iPadn-iOS/THIRD_PARTY_NOTICES.md)
